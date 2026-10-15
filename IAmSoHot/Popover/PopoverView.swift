import SwiftUI
import ThermalCore

/// 下拉面板（PRD §6 / 热模型 v2 §12.3）。
///
/// UI 约束：
/// - 无动画、无实时火焰、无复杂渐变、无 60fps 图表。
/// - 列表 ~1Hz 刷新即可（由 MonitorService 驱动，快照替换）。
/// - 所有 +X°C 必须标注 Estimated。
///
/// 展示层恒等式（v2.2 修订）：**Σ Heat Share = 100%**，天然成立，
/// 不依赖 g、不依赖温度传感器，是面板唯一需要的「账平」保证。
/// 不再显示 Baseline——它是残差（真实底噪 + 模型误差），误差恰在
/// 高负载（用户唯一会看的时刻）最大，显示它反而损害可信度。
/// +°C 行项目为估算值，合计行不强行与 Current 对齐。
struct PopoverView: View {

    let snapshot: MonitorSnapshot
    let iconProvider: (AppHeatInfo) -> NSImage?
    let onQuit: (AppHeatInfo) -> Void

    /// 命名行数量，超出部分聚合为「N more apps」行（保证列表完整）
    private let maxNamedRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let forecast = snapshot.coolingForecast {
                Divider().padding(.vertical, 8)
                forecastSection(forecast)
            }
            Divider().padding(.vertical, 8)
            sectionTitle("HEATING YOUR MAC")
            appList
            Divider().padding(.vertical, 8)
            if let history = snapshot.history, history.hourBuckets.count >= 2 {
                historySection(history)
                Divider().padding(.vertical, 8)
            }
            bottomEquation
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Header

    /// 顶部文案随温度状态变化。
    /// 句式大小写用于动态状态；产品名 I AM SO HOT 全大写保留给真正高热状态，
    /// 文案本身就是状态指示器。
    /// 状态增量用内部模型 baseline（慢锚点+δ，仅供状态分级，不展示），
    /// 避免残差噪声影响文案稳定性。
    private var headline: String {
        guard let temp = snapshot.temperatureCelsius else { return "I AM SO HOT" }
        let delta = temp - snapshot.baselineCelsius
        if snapshot.thermalStateElevated && delta > 15 { return "I'm on Fire" }
        if delta > 15 { return "I AM SO HOT" }
        if delta > 5 { return "Getting Warm" }
        // 负载没了但机身还是热的（余热 > 4°C）：说清楚是在散热，
        // 否则 "I'm Cool" 配高温数字反直觉
        if residualHeatCelsius > 4 { return "Cooling Down" }
        return "I'm Cool"
    }

    /// 机身余热（°C）：baseline 高出 24h 环境底的部分。
    /// 之前负载把机身烤热了，散热时间常数几十分钟——
    /// 这部分热不是当前 App 的锅，但必须说出来（账平叙事）。
    /// 数据不足（冷启动）时为 0，不展示。
    private var residualHeatCelsius: Double {
        guard let floor = snapshot.history?.twentyFourHours?.min else { return 0 }
        return max(0, snapshot.baselineCelsius - floor)
    }

    private var header: some View {
        HStack {
            Text(headline)
                .font(.headline)
            Spacer()
            Text(temperatureText)
                .font(.headline)
                .monospacedDigit()
        }
    }

    private var temperatureText: String {
        guard let temp = snapshot.temperatureCelsius else { return "--°C" }
        // 整机封装功耗（实测）：温度 + 瓦数是最直接的两个物理量
        if let watts = snapshot.totalWatts {
            return String(format: "%.0f° · %.0fW", temp, watts)
        }
        return String(format: "%.0f°C", temp)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    // MARK: - App List（完整：命名行 + 长尾聚合行）

    private var namedApps: ArraySlice<AppHeatInfo> {
        snapshot.apps.prefix(maxNamedRows)
    }

    private var tailApps: ArraySlice<AppHeatInfo> {
        snapshot.apps.dropFirst(maxNamedRows)
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.apps.isEmpty {
                Text("No significant heat source")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(namedApps) { app in
                    appRow(app)
                }
                if !tailApps.isEmpty {
                    tailRow(tailApps)
                }
            }
        }
    }

    /// CPU 展示精度：小于 1% 时显示 "<1%"，避免四舍五入成 "CPU 0%"
    private func cpuText(_ cpu: Double) -> String {
        let percent = cpu * 100
        if percent < 1 && percent > 0 { return "<1%" }
        return String(format: "%.0f%%", percent)
    }

    /// 行内副标题：CPU + 瓦数（瓦数是用户可感知的耗电语言；
    /// Heat Share 是内部排序依据，对普通用户是黑话，不上 UI）
    private func subtitle(_ app: AppHeatInfo) -> String {
        // System Hardware：能耗对账缺口（摄像头/编解码/驱动），
        // 不占 CPU 是其本质特征，瓦数前置 + 说明来源
        if app.id == AppIdentity.systemHardware.id {
            let source = snapshot.cameraActive
                ? "camera is active — ISP / media"
                : "camera / media / chip hardware"
            return String(format: "~%.1fW · %@", app.watts, source)
        }
        return String(format: "CPU %@ · %.1fW", cpuText(app.cpu), app.watts)
    }

    private func appRow(_ app: AppHeatInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            appIcon(app)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                Text(subtitle(app))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "+%.1f°C", app.estimatedDeltaC))
                .font(.callout)
                .monospacedDigit()
            if app.canQuit {
                Button("Quit") { onQuit(app) }
                    .controlSize(.small)
            }
        }
    }

    /// 长尾聚合行：让 Σ 行项目 = Apps 总贡献，无截断差
    private func tailRow(_ tail: ArraySlice<AppHeatInfo>) -> some View {
        let sumDelta = tail.reduce(0) { $0 + $1.estimatedDeltaC }
        let sumCPU = tail.reduce(0) { $0 + $1.cpu }
        let sumWatts = tail.reduce(0) { $0 + $1.watts }
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(tail.count) more apps")
                    .foregroundStyle(.secondary)
                Text(String(format: "CPU %@ · %.1fW", cpuText(sumCPU), sumWatts))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "+%.1f°C", sumDelta))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func appIcon(_ app: AppHeatInfo) -> some View {
        if let image = iconProvider(app) {
            Image(nsImage: image)
                .resizable()
        } else {
            Image(systemName: systemIconName(for: app))
                .foregroundStyle(.secondary)
        }
    }

    private func systemIconName(for app: AppHeatInfo) -> String {
        switch app.id {
        case AppIdentity.macOS.id: return "cpu"
        case AppIdentity.systemHardware.id: return "bolt.fill"
        default: return "questionmark.app"
        }
    }

    // MARK: - 降温预测（v0.8）：Quit 后展示，预测周期结束自动消失

    private func forecastSection(_ forecast: CoolingForecastInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("COOLING FORECAST")
            Text("Quit \(forecast.appName)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            switch snapshot.predictionConfidence {
            case .normal:
                Text(forecast.milestones.map {
                    String(format: "~%.0f° in %@", $0.celsius, formatDuration($0.seconds))
                }.joined(separator: " · "))
                    .font(.callout)
                    .monospacedDigit()
            case .low:
                // Roadmap §7：模型不稳定时宁可模糊，不假精确；
                // 文案按降幅分级，小降幅不说 significantly（review P1）
                Text(forecast.steadyDrop >= 2
                     ? "Expected to cool significantly"
                     : "Expected to cool slightly")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        // 2 分钟以内一律用秒，避免 89s→~90s 与 90s→~2m 的边界跳变（review P3）
        if seconds < 120 { return String(format: "~%.0fs", seconds) }
        return String(format: "~%.0fm", seconds / 60)
    }

    // MARK: - 温度曲线（1h 走势，静态折线：无动画、单色细线，克制原则）

    @ViewBuilder
    private func historySection(_ history: TemperatureHistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("TEMPERATURE · 1H")
            TemperatureCurveView(
                buckets: history.hourBuckets,
                current: snapshot.temperatureCelsius,
                now: Date()
            )
            // 24h 极值一行带过（长期上下文），5min/1h 的 avg/max 已被曲线取代
            if let day = history.twentyFourHours {
                Text(String(format: "24h  min %.0f° · max %.0f°", day.min, day.max))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - 底部合计行（不凑恒等式，诚实呈现 App 解释了多少）

    private var bottomEquation: some View {
        VStack(spacing: 4) {
            HStack {
                Text("All apps combined")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "+%.1f°C", snapshot.appsTotalDeltaC))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // 余热分解：baseline 高出 24h 环境底的部分 = 之前负载还没散完的机身热
            if residualHeatCelsius > 3 {
                HStack {
                    Text("Earlier heat, still dissipating")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "+%.1f°C", residualHeatCelsius))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("Estimated values, not sensor measurements")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    PopoverView(
        snapshot: MonitorSnapshot(
            temperatureCelsius: 78,
            baselineCelsius: 50,
            totalCPU: 0.72,
            thermalStateElevated: true,
            mode: .live,
            apps: [
                AppHeatInfo(id: "chrome", name: "Google Chrome", bundlePath: nil, rootPid: 100, cpu: 0.38, processCount: 17, heatShare: 0.39, estimatedDeltaC: 11.2),
                AppHeatInfo(id: "cursor", name: "Cursor", bundlePath: nil, rootPid: 200, cpu: 0.21, processCount: 9, heatShare: 0.22, estimatedDeltaC: 6.4),
                AppHeatInfo(id: "docker", name: "Docker", bundlePath: nil, rootPid: 300, cpu: 0.11, processCount: 4, heatShare: 0.11, estimatedDeltaC: 3.1),
                AppHeatInfo(id: AppIdentity.macOS.id, name: "macOS", bundlePath: nil, rootPid: nil, cpu: 0.05, processCount: 120, heatShare: 0.18, estimatedDeltaC: 5.0),
                AppHeatInfo(id: AppIdentity.other.id, name: "Other", bundlePath: nil, rootPid: nil, cpu: 0.03, processCount: 8, heatShare: 0.10, estimatedDeltaC: 2.3),
            ],
            appsTotalDeltaC: 28.0,
            estimatedCelsius: 78.0
        ),
        iconProvider: { _ in nil },
        onQuit: { _ in }
    )
}
