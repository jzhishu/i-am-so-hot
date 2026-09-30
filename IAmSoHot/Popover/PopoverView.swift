import SwiftUI
import ThermalCore

/// 下拉面板（PRD §6）。
///
/// UI 约束：
/// - 无动画、无实时火焰、无复杂渐变、无 60fps 图表。
/// - 列表 ~1Hz 刷新即可（由 MonitorService 驱动，快照替换）。
/// - 所有 +X°C 必须标注 Estimated。
struct PopoverView: View {

    let snapshot: MonitorSnapshot
    let iconProvider: (AppHeatInfo) -> NSImage?
    let onQuit: (AppHeatInfo) -> Void

    /// 面板最多展示的 App 行数（信息优先级高于完整性，PRD §4.2 克制）
    private let maxRows = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            temperatureSummary
            Divider().padding(.vertical, 8)
            sectionTitle("HEATING YOUR MAC")
            appList
            Divider().padding(.vertical, 8)
            bottomSummary
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Header

    /// 顶部文案随温度状态变化：44°C 时写 "I AM SO HOT" 是自相矛盾的。
    private var headline: String {
        guard let temp = snapshot.temperatureCelsius else { return "I AM SO HOT" }
        let delta = temp - snapshot.baselineCelsius
        if snapshot.thermalStateElevated && delta > 15 { return "I'M ON FIRE" }
        if delta > 15 { return "I AM SO HOT" }
        if delta > 5 { return "GETTING WARM" }
        return "I'M COOL"
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

    // MARK: - Temperature Summary

    private var temperatureSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Current Temperature")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(temperatureText) · \(stateText)")
                .font(.title3)
        }
    }

    private var stateText: String {
        if snapshot.thermalStateElevated { return "Hot" }
        guard let temp = snapshot.temperatureCelsius else { return "--" }
        let delta = temp - snapshot.baselineCelsius
        if delta > 15 { return "Hot" }
        if delta > 5 { return "Warm" }
        return "Normal"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    // MARK: - App List

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.apps.isEmpty {
                Text("No significant heat source")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.apps.prefix(maxRows)) { app in
                    appRow(app)
                }
            }
        }
    }

    /// CPU 展示精度：小于 1% 时显示 "<1%"，避免四拾五入成 "CPU 0%"
    ///（截图中 macOS CPU 0% 就是精度丢失造成的误解）。
    private func cpuText(_ cpu: Double) -> String {
        let percent = cpu * 100
        if percent < 1 && percent > 0 { return "<1%" }
        return String(format: "%.0f%%", percent)
    }

    /// 行内副标题：CPU + Heat Share。
    /// Heat Share 是排序依据（热记忆水库，而非瞬时 CPU），
    /// 必须展示出来，否则用户无法理解排名（PRD §13：最可信指标）。
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

    // MARK: - 底部汇总（热模型 v2 §12.3）

    private var bottomSummary: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Apps (sum)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "+%.1f°C", snapshot.appsTotalDeltaC))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Text("Baseline")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f°C", snapshot.baselineCelsius))
                    .foregroundStyle(.secondary)
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
            apps: [                AppHeatInfo(id: "chrome", name: "Google Chrome", bundlePath: nil, rootPid: 100, cpu: 0.38, processCount: 17, heatShare: 0.39, estimatedDeltaC: 11.2),
                AppHeatInfo(id: "cursor", name: "Cursor", bundlePath: nil, rootPid: 200, cpu: 0.21, processCount: 9, heatShare: 0.22, estimatedDeltaC: 6.4),
                AppHeatInfo(id: "docker", name: "Docker", bundlePath: nil, rootPid: 300, cpu: 0.11, processCount: 4, heatShare: 0.11, estimatedDeltaC: 3.1),
                AppHeatInfo(id: AppIdentity.macOS.id, name: "macOS", bundlePath: nil, rootPid: nil, cpu: 0.05, processCount: 120, heatShare: 0.18, estimatedDeltaC: 5.0),
                AppHeatInfo(id: AppIdentity.other.id, name: "Other", bundlePath: nil, rootPid: nil, cpu: 0.03, processCount: 8, heatShare: 0.10, estimatedDeltaC: 2.3),
            ],
            appsTotalDeltaC: 23.0,
            estimatedCelsius: 73.0
        ),
        iconProvider: { _ in nil },
        onQuit: { _ in }
    )
}
