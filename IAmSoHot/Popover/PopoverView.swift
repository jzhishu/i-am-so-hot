import SwiftUI
import ThermalCore

/// 下拉面板（PRD §6 / 热模型 v2 §12.3）。
///
/// UI 约束：
/// - 无动画、无实时火焰、无复杂渐变、无 60fps 图表。
/// - 列表 ~1Hz 刷新即可（由 MonitorService 驱动，快照替换）。
/// - 所有 +X°C 必须标注 Estimated。
///
/// 展示层恒等式（硬性设计原则：用户看到的账必须平）：
///
///     Baseline（残差）+ Σ 全部行项目 = Current
///
/// - 列表完整化：前 8 名 + 「N more apps」聚合行，无截断差
/// - Baseline 显示残差（T − ΣΔT_i），不是模型估计值，
///   因此恒等式必然成立、Baseline 也不可能高于 Current
struct PopoverView: View {

    let snapshot: MonitorSnapshot
    let iconProvider: (AppHeatInfo) -> NSImage?
    let onQuit: (AppHeatInfo) -> Void

    /// 命名行数量，超出部分聚合为「N more apps」行（保证列表完整）
    private let maxNamedRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            sectionTitle("HEATING YOUR MAC")
            appList
            Divider().padding(.vertical, 8)
            bottomEquation
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Header

    /// 展示口径的 baseline：残差优先，模型值兜底
    private var displayedBaseline: Double {
        snapshot.residualBaselineCelsius ?? snapshot.baselineCelsius
    }

    /// 顶部文案随温度状态变化。
    /// 句式大小写用于动态状态；产品名 I AM SO HOT 全大写保留给真正高热状态，
    /// 文案本身就是状态指示器。
    private var headline: String {
        guard let temp = snapshot.temperatureCelsius else { return "I AM SO HOT" }
        let delta = temp - displayedBaseline
        if snapshot.thermalStateElevated && delta > 15 { return "I'm on Fire" }
        if delta > 15 { return "I AM SO HOT" }
        if delta > 5 { return "Getting Warm" }
        return "I'm Cool"
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
        if let temp = snapshot.temperatureCelsius {
            String(format: "%.0f°C", temp)
        } else {
            "--°C"
        }
    }

    /// 恒等式区域的 Current：与 Baseline / 行项目同精度（0.1°C），
    /// 避免整数舍入造成「加起来不等」的视觉误差（菜单栏与头部仍为整数）。
    private var currentPreciseText: String {
        if let temp = snapshot.temperatureCelsius {
            String(format: "%.1f°C", temp)
        } else {
            "--°C"
        }
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

    /// 行内副标题：CPU + Heat Share（排序依据对用户可见）
    private func subtitle(_ app: AppHeatInfo) -> String {
        String(format: "CPU %@ · Heat %.0f%%", cpuText(app.cpu), app.heatShare * 100)
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
        let sumShare = tail.reduce(0) { $0 + $1.heatShare }
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(tail.count) more apps")
                    .foregroundStyle(.secondary)
                Text(String(format: "CPU %@ · Heat %.0f%%", cpuText(sumCPU), sumShare * 100))
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
            Image(systemName: app.id == AppIdentity.macOS.id ? "cpu" : "questionmark.app")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 底部恒等式（Baseline + ΣApps = Current）

    private var bottomEquation: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Baseline")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f°C", displayedBaseline))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Text("Current")
                Spacer()
                Text(currentPreciseText)
                    .monospacedDigit()
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
            estimatedCelsius: 78.0,
            residualBaselineCelsius: 50.0
        ),
        iconProvider: { _ in nil },
        onQuit: { _ in }
    )
}
