import Darwin
import SwiftUI

/// How much memory the app uses and how much it may still use (shared by Artelico and Hailo Studio).
enum MemoryInfo {
    /// What the app uses now: the same figure Xcode's memory gauge and the system's limits count
    /// ("physical footprint"): loaded models, pictures, buffers.
    static var used: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The device's memory.
    static var total: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// On iPhone and iPad: how much more the app may use before the system closes it. nil on a Mac,
    /// where apps have no such limit.
    static var available: UInt64? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        let value = os_proc_available_memory()
        return value > 0 ? UInt64(value) : nil
        #endif
    }

    static func text(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
}

/// Rows for a settings list: memory in use (updated every 2 seconds), what is left, and the device's total.
struct MemoryRows: View {
    /// Names of what is loaded now (vision model, language model…), shown under the figures.
    var loaded: [String] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let used = MemoryInfo.used, total = MemoryInfo.total
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Memory used by the app", value: MemoryInfo.text(used))
                ProgressView(value: Double(used), total: Double(MemoryInfo.available.map { used + $0 } ?? total))
                    .tint(MemoryInfo.available.map { $0 < 300_000_000 ? .red : .accentColor } ?? .accentColor)
                if let left = MemoryInfo.available {
                    Text("\(MemoryInfo.text(left)) more before iOS closes the app · \(MemoryInfo.text(total)) in this device")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(MemoryInfo.text(total)) in this Mac").font(.caption).foregroundStyle(.secondary)
                }
                if !loaded.isEmpty {
                    Text("Loaded: \(loaded.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
