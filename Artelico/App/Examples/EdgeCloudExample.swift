import Network
import SwiftUI
import StudioCore

// EdgeVsCloud (UGen300 demo): the camera picture detected here, measured, next to an estimate of
// sending every frame to a cloud vision API. Numbers in StudioCore/EdgeCloud.swift.

/// Measures how long opening a connection to a cloud address takes, every 2 seconds (as the demo:
/// 1.1.1.1 port 443). Nothing is sent; the connection is closed as soon as it is open.
@MainActor
final class NetworkProbe: ObservableObject {
    @Published var connectMilliseconds: Double?
    @Published var online = false
    private var loop: Task<Void, Never>?
    static let host = "1.1.1.1"

    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                let measured = await Self.measure()
                connectMilliseconds = measured
                online = measured != nil
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private static func measure() async -> Double? {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)
        let started = Date()
        return await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: Date().timeIntervalSince(started) * 1000) }
                    connection.cancel()
                case .failed, .waiting:
                    once.run { continuation.resume(returning: nil) }
                    connection.cancel()
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                once.run { continuation.resume(returning: nil) }
                connection.cancel()
            }
        }
    }

    /// Runs its closure the first time only (the continuation must be resumed once).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}

struct EdgeCloudExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner(task: .detection, source: .back)
    @StateObject private var probe = NetworkProbe()
    @State private var objects: [Detection] = []
    @State private var recentMilliseconds: [Double] = []
    @State private var frames = 0

    private var comparison: EdgeCloudComparison {
        EdgeCloudComparison(edgeMilliseconds: recentMilliseconds.isEmpty ? 0 : recentMilliseconds.reduce(0, +) / Double(recentMilliseconds.count),
                            framesPerSecond: runner.framesPerSecond, frames: frames, connectMilliseconds: probe.connectMilliseconds)
    }

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, sources: [.back, .front, .video, .stream, .picture], samples: [("Street with people", "bus.jpg"), SampleMedia.street, SampleMedia.office], start: start)
            ExampleLayout(panelWidth: 420) {
                PoseStage(runner: runner, placeholder: "Tap Start: every frame is detected \(StudioModel.examplesRunOn), and compared with sending it to the cloud.") { size in
                    BoxLayer(items: objects.map { .init(box: $0.boundingBox, label: $0.label, color: .green) }, size: size)
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Edge vs cloud")
        .onAppear { probe.start() }
        .onDisappear { runner.stop(); probe.stop() }
        .modifier(AutoStart(start: start))
    }

    @ViewBuilder private var panel: some View {
        let c = comparison
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("")
                Label("Here", systemImage: "cpu").font(.headline).foregroundStyle(.green)
                Label("Cloud API", systemImage: "cloud").font(.headline).foregroundStyle(.orange)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("Time per picture", here: String(format: "%.0f ms", c.edgeMilliseconds),
                cloud: c.cloudMilliseconds.map { String(format: "%.0f ms (estimate)", $0) } ?? "offline: not available",
                hereBar: c.edgeMilliseconds / 1000, cloudBar: (c.cloudMilliseconds ?? 1000) / 1000)
            row("of which network", here: "0 ms (no network)",
                cloud: c.cloudNetworkMilliseconds.map { String(format: "%.0f ms (measured)", $0) } ?? "—",
                hereBar: 0, cloudBar: (c.cloudNetworkMilliseconds ?? 0) / 1000)
            row("Speed", here: String(format: "%.0f pictures/s", c.framesPerSecond),
                cloud: c.cloudFramesPerSecond.map { String(format: "%.1f pictures/s", $0) } ?? "—",
                hereBar: min(1, c.framesPerSecond / 60), cloudBar: min(1, (c.cloudFramesPerSecond ?? 0) / 60))
            row("Pictures so far", here: c.frames.formatted(), cloud: c.frames.formatted())
            row("Cost so far", here: "0 (paid once)", cloud: c.cloudDollarsSoFar.formatted(.currency(code: "USD")),
                hereBar: 0, cloudBar: min(1, c.cloudDollarsSoFar / 5))
            row("A month at this speed", here: "0", cloud: c.cloudDollarsPerMonth.formatted(.currency(code: "USD").precision(.fractionLength(0))))
            row("Power (reference)", here: StudioModel.examplesRunOn.contains("stick") ? String(format: "about %.1f W", EdgeCloudComparison.stickWatts) : "a few W",
                cloud: String(format: "about %.0f W (GPU)", EdgeCloudComparison.cloudWatts))
            row("Where the picture goes", here: "stays on this \(StudioModel.deviceKind)", cloud: "uploaded to someone else's server")
        }
        if let speedup = c.speedup, c.edgeMilliseconds > 0 {
            Text(String(format: "%.0f× faster per picture here", speedup)).font(.title3.bold()).foregroundStyle(.green)
        }
        Button("Reset counters") { frames = 0 }
        Text(String(format: "Network: %@. The cloud's server time (%.0f ms) and price (US$%.1f per 1000 pictures) are typical reference values; the network time is measured every 2 s by opening a connection to %@ (nothing is sent). A month = 8 h a day, 22 days.",
                    probe.online ? "online" : "offline", EdgeCloudComparison.cloudServerMilliseconds, EdgeCloudComparison.cloudDollarsPerThousand, NetworkProbe.host))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func row(_ title: String, here: String, cloud: String, hereBar: Double? = nil, cloudBar: Double? = nil) -> some View {
        GridRow(alignment: .top) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(here).font(.callout.monospacedDigit().bold())
                if let hereBar { ProgressView(value: max(0, min(1, hereBar))).tint(.green) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(cloud).font(.callout.monospacedDigit().bold())
                if let cloudBar { ProgressView(value: max(0, min(1, cloudBar))).tint(.orange) }
            }
        }
    }

    private func start() {
        frames = 0; recentMilliseconds = []
        runner.start(studio: studio) { frame in
            objects = frame.detections.filter { $0.confidence >= 0.4 }
            recentMilliseconds = Array((recentMilliseconds + [frame.inferenceMilliseconds]).suffix(30))
            frames += 1
        }
    }
}
