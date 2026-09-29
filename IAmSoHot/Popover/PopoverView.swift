import SwiftUI
import ThermalCore

/// 下拉面板（PRD §6）。
///
/// UI 约束：
/// - 无动画、无实时火焰、无复杂渐变、无 60fps 图表。
/// - 列表 ~1Hz 刷新即可。
/// - 所有 +X°C 必须标注 Estimated。
///
/// 当前为 v0.1 骨架：使用演示数据走通布局，
/// 待 Phase 1-4 完成后由真实 ViewModel 驱动。
struct PopoverView: View {

    private let demo = DemoHeatData()

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
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Text("I AM SO HOT")
                .font(.headline)
            Spacer()
            Text(String(format: "%.0f°C", demo.currentCelsius))
                .font(.headline)
        }
    }

    private var temperatureSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Current Temperature")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f°C · %@", demo.currentCelsius, demo.thermalStateText))
                .font(.title3)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(demo.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                        Text(String(format: "CPU %.0f%%", row.cpuPercent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "Estimated +%.1f°C", row.estimatedDeltaC))
                        .font(.callout)
                        .monospacedDigit()
                    if row.canQuit {
                        Button("Quit") {
                            // TODO(Phase 6): NSRunningApplication.terminate()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var baselineRow: some View {
        HStack {
            Text("Baseline")
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f°C", demo.baselineCelsius))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - 演示数据（走通 ThermalEngine 链路）

private struct HeatRow: Identifiable {
    let id = UUID()
    let name: String
    let cpuPercent: Double
    let estimatedDeltaC: Double
    let canQuit: Bool
}

private struct DemoHeatData {
    let currentCelsius = 78.0
    let baselineCelsius = 50.0
    let thermalStateText = "Hot"
    let rows: [HeatRow]

    init() {
        // 用真实 ThermalEngine 计算 Heat Share -> Estimated +°C，
        // 验证 ThermalCore 链路在 App 内可用。
        var engine = ThermalEngine(tau: 60)
        engine.ingest(
            powerScores: [
                "chrome": 38,
                "cursor": 21,
                "docker": 11,
                "macos": 15,
                "other": 7,
            ],
            deltaTime: 1
        )
        let deltaCs = engine.estimatedDeltaCs(
            currentCelsius: currentCelsius,
            baselineCelsius: baselineCelsius
        )
        rows = [
            HeatRow(name: "Google Chrome", cpuPercent: 38, estimatedDeltaC: deltaCs["chrome"] ?? 0, canQuit: true),
            HeatRow(name: "Cursor", cpuPercent: 21, estimatedDeltaC: deltaCs["cursor"] ?? 0, canQuit: true),
            HeatRow(name: "Docker", cpuPercent: 11, estimatedDeltaC: deltaCs["docker"] ?? 0, canQuit: true),
            HeatRow(name: "macOS", cpuPercent: 0, estimatedDeltaC: deltaCs["macos"] ?? 0, canQuit: false),
            HeatRow(name: "Other", cpuPercent: 0, estimatedDeltaC: deltaCs["other"] ?? 0, canQuit: false),
        ]
    }
}

#Preview {
    PopoverView()
}
