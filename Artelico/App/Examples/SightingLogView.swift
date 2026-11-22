import SwiftUI
import StudioCore

/// Live's "Seen on camera X" log: everyone recognised or re-identified during the run, with the sources
/// they appeared on, first and last seen, and a timeline strip coloured by source.
struct SightingLogView: View {
    let log: SightingLog
    /// The sources' names, by index.
    let sourceNames: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if log.people.isEmpty {
                    Text("Nobody yet. Run Live with Face recognition (Number unknown people on, or people in Known people) or Person re-identification.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(log.people) { person in row(person) }
                    } header: {
                        legend
                    }
                    Section("Timeline, newest first") {
                        ForEach(Array(log.timeline.prefix(200).enumerated()), id: \.offset) { _, entry in
                            HStack {
                                Circle().fill(Self.color(entry.visit.source)).frame(width: 8, height: 8)
                                Text(entry.name).bold()
                                Text("on \(name(entry.visit.source))")
                                Spacer()
                                Text("\(Self.clock(entry.visit.start)) – \(Self.clock(entry.visit.end))").monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .navigationTitle("Seen on camera")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: log.csv(), preview: SharePreview("Sightings.csv")) { Label("Share as CSV", systemImage: "square.and.arrow.up") }
                        .disabled(log.people.isEmpty)
                }
            }
        }
    }

    private func row(_ person: SightingLog.Person) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let thumbnail = person.thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.square").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(person.name).font(.headline)
                    ForEach(person.sources, id: \.self) { source in
                        Text("\(source + 1)").font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Self.color(source), in: Capsule())
                    }
                }
                Text("First seen \(Self.clock(person.firstSeen)) on \(name(person.firstSource)) · last seen \(Self.clock(person.lastSeen)) on \(name(person.lastSource))")
                    .font(.caption).foregroundStyle(.secondary)
                strip(person)
            }
        }
    }

    /// The person's visits, one lane per source, on a common axis from the first sighting of anyone to the latest.
    private func strip(_ person: SightingLog.Person) -> some View {
        let start = log.people.map(\.firstSeen).min() ?? Date()
        let end = log.people.map(\.lastSeen).max() ?? start
        let span = max(end.timeIntervalSince(start), 1)
        return VStack(spacing: 2) {
            ForEach(person.sources, id: \.self) { source in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        ForEach(Array(person.visits.filter { $0.source == source }.enumerated()), id: \.offset) { _, visit in
                            let x = visit.start.timeIntervalSince(start) / span * geometry.size.width
                            let width = max(visit.end.timeIntervalSince(visit.start) / span * geometry.size.width, 3)
                            Rectangle().fill(Self.color(source)).frame(width: width).offset(x: x)
                        }
                    }
                }
                .frame(height: 5)
                .clipShape(Capsule())
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Array(sourceNames.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(index)).frame(width: 8, height: 8)
                    Text("\(index + 1) \(title)").lineLimit(1)
                }
            }
        }
        .textCase(nil)
    }

    private func name(_ source: Int) -> String {
        sourceNames.indices.contains(source) ? "\(source + 1) (\(sourceNames[source]))" : "\(source + 1)"
    }

    static func color(_ source: Int) -> Color { [Color.blue, .orange, .green, .purple][source % 4] }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
}

/// Holds Live's sighting log by reference, so recording a frame does not invalidate the view.
final class SightingRecorder {
    var log = SightingLog()
    private var lastSnapshot = Date.distantPast

    /// The log when at least `seconds` passed since the last copy, else nil.
    func snapshot(every seconds: TimeInterval) -> SightingLog? {
        guard Date().timeIntervalSince(lastSnapshot) >= seconds else { return nil }
        lastSnapshot = Date()
        return log
    }
}
