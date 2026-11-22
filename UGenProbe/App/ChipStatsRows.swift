import SwiftUI
import UGenKit

/// The stick's health and load (hailort's query_health_stats and query_performance_stats), read every
/// 5 seconds while the device page is open. Power is not shown: the UGen300 has no power sensor and its
/// firmware refuses the power reading (HAILO_OPEN_FILE_FAILURE).
struct ChipStatsRows: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var stats: UGenDevice.ChipStats?
    @State private var note = ""

    var body: some View {
        Group {
            if let stats {
                if let temperature = stats.temperatureCelsius {
                    LabeledContent("Temperature", value: String(format: "%.1f °C", temperature))
                }
                if let millivolts = stats.coreMillivolts { LabeledContent("Core voltage", value: "\(millivolts) mV") }
                if let failures = stats.selfTestFailures {
                    LabeledContent("Self-test", value: failures == 0 ? "Passed" : String(format: "Failures 0x%X", failures))
                }
                if let cpu = stats.cpuPercent { LabeledContent("Stick CPU", value: String(format: "%.0f %%", cpu)) }
                if let used = stats.ramUsedBytes, let total = stats.ramTotalBytes {
                    LabeledContent("Stick memory", value: "\(formatBytes(Int(used))) of \(formatBytes(Int(total)))")
                }
                LabeledContent("Power", value: stats.powerWatts.map { String(format: "%.2f W", $0) } ?? "Not measured by this stick")
            }
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else if stats == nil {
                // Something must always show: an empty group never appears, and its task would never start.
                LabeledContent("Health", value: "Reading…")
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refresh() async {
        // The reading pauses the stick's connection for a moment: not while Live runs.
        guard studio.mode == .runtime, !studio.liveRunning else {
            note = studio.liveRunning ? "Readings pause while Live runs." : ""
            return
        }
        do {
            if let fresh = try await studio.device.chipStats(samplingMilliseconds: 300) {
                stats = fresh
                // The neural-core share is left out: the stick samples it while holding this app's connection,
                // so the app's own work never shows (always 0 %, also with a model running flat out).
                note = ""
            } else {
                note = "Readings pause while a language model or speech model is on the stick."
            }
        } catch {
            note = "No readings: \(error)"
        }
    }
}
