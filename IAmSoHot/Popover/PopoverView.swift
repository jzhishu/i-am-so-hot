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
            baselineRow
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("I AM SO HOT")
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
        return temp - snapshot.baselineCelsius > 10 ? "Warm" : "Normal"
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

    private func appRow(_ app: AppHeatInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            appIcon(app)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                Text(String(format: "CPU %.0f%%", app.cpu * 100))
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

    // MARK: - Baseline

    private var baselineRow: some View {
        VStack(spacing: 4) {
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
            apps: [
                AppHeatInfo(id: "chrome", name: "Google Chrome", bundlePath: nil, rootPid: 100, cpu: 0.38, processCount: 17, heatShare: 0.39, estimatedDeltaC: 11.2),
                AppHeatInfo(id: "cursor", name: "Cursor", bundlePath: nil, rootPid: 200, cpu: 0.21, processCount: 9, heatShare: 0.22, estimatedDeltaC: 6.4),
                AppHeatInfo(id: "docker", name: "Docker", bundlePath: nil, rootPid: 300, cpu: 0.11, processCount: 4, heatShare: 0.11, estimatedDeltaC: 3.1),
                AppHeatInfo(id: AppIdentity.macOS.id, name: "macOS", bundlePath: nil, rootPid: nil, cpu: 0.05, processCount: 120, heatShare: 0.18, estimatedDeltaC: 5.0),
                AppHeatInfo(id: AppIdentity.other.id, name: "Other", bundlePath: nil, rootPid: nil, cpu: 0.03, processCount: 8, heatShare: 0.10, estimatedDeltaC: 2.3),
            ]
        ),
        iconProvider: { _ in nil },
        onQuit: { _ in }
    )
}
