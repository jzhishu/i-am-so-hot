import SwiftUI
import ThermalCore

/// 1 小时温度曲线（克制版静态折线）。
///
/// 设计约束：
/// - 无动画、无渐变填充、无网格线——1pt 单色折线 + 端点圆点。
/// - 由快照驱动（~1Hz），数据不变时 SwiftUI 不重绘。
/// - X 轴按桶时间戳真实定位（采样间隔不均匀时走势不变形）。
/// - 末端追加当前温度作为最新点（桶有最多 30s 滞后）。
struct TemperatureCurveView: View {

    let buckets: [TemperatureHistory.Bucket]
    let current: Double?
    let now: Date

    /// 曲线点：(epoch 秒, 温度)
    private var points: [(t: TimeInterval, v: Double)] {
        var pts = buckets.map { ($0.start, $0.avg) }
        if let current, current > 0 {
            pts.append((now.timeIntervalSince1970, current))
        }
        return pts
    }

    var body: some View {
        if points.count < 2 {
            EmptyView()
        } else {
            Canvas { context, size in
                drawCurve(in: size, context: &context)
            }
            .frame(height: 44)
        }
    }

    private func drawCurve(in size: CGSize, context: inout GraphicsContext) {
        let pts = points
        guard let minT = pts.map(\.t).min(), let maxT = pts.map(\.t).max(),
              let minV = pts.map(\.v).min(), let maxV = pts.map(\.v).max() else { return }

        // Y 轴留白 1°C，避免平线贴边；全平数据时给 ±1°C 量程
        let spanV = max(maxV - minV, 2)
        let lo = minV - (spanV > 2 ? 1 : 0)
        let hi = maxV + (spanV > 2 ? 1 : 0)
        let spanT = max(maxT - minT, 1)

        func point(_ p: (t: TimeInterval, v: Double)) -> CGPoint {
            CGPoint(
                x: (p.t - minT) / spanT * size.width,
                y: size.height * (1 - (p.v - lo) / (hi - lo))
            )
        }

        var path = Path()
        path.addLines(pts.map(point))
        context.stroke(
            path,
            with: .color(.secondary),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
        )

        // 末端圆点 = 当前温度，给走势一个「现在在这里」的锚点
        if let last = pts.last {
            let dot = Path(ellipseIn: CGRect(
                x: point(last).x - 2.5, y: point(last).y - 2.5, width: 5, height: 5
            ))
            context.fill(dot, with: .color(.secondary))
        }
    }
}
