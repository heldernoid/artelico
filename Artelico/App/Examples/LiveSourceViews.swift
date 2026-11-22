import PhotosUI
import SwiftUI
import StudioCore

/// A Live source after the first one: a stream address, the user's video or one of Hailo's demo videos.
/// (Only the first source can be a camera: iPhones and iPads run one camera session at a time.)
struct ExtraLiveSource: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case stream = "Stream address"
        case video = "Video file"
        var id: String { rawValue }
    }

    let id = UUID()
    var kind: Kind = .stream
    var address = ""
    var videoURL: URL?
    /// The demo video chosen, for its title and credit tag.
    var sample: String?

    var title: String {
        switch kind {
        case .stream: return LiveComposer.shortName(address)
        case .video: return sample.flatMap { file in SampleMedia.allVideos.first { $0.file == file }?.title } ?? videoURL?.lastPathComponent ?? "Video"
        }
    }
}

/// The controls of one extra source.
struct ExtraSourceRow: View {
    let number: Int
    @Binding var source: ExtraLiveSource
    let recents: [String]
    let roadCameras: () -> Void
    let remove: () -> Void
    @State private var picked: PhotosPickerItem?
    @State private var downloading = false
    @State private var problem = ""

    var body: some View {
        HStack {
            Text("\(number)").font(.callout.monospacedDigit().bold()).frame(minWidth: 16)
            Picker("Source \(number)", selection: $source.kind) {
                ForEach(ExtraLiveSource.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            switch source.kind {
            case .stream:
                TextField("Stream address", text: $source.address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Road cameras", action: roadCameras)
                if !recents.isEmpty {
                    Menu("Recent") {
                        ForEach(recents, id: \.self) { address in Button(address) { source.address = address } }
                    }
                }
            case .video:
                PhotosPicker(source.videoURL == nil ? "Choose a video" : "Another video", selection: $picked, matching: .videos)
                Menu("Samples") {
                    ForEach(SampleMedia.allVideos, id: \.file) { sample in
                        Button(sample.title) { useSample(sample.file) }
                    }
                }
                if downloading { ProgressView().controlSize(.small) }
                Text(problem.isEmpty ? (source.videoURL == nil ? "" : source.title) : problem)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this source")
        }
        .onChange(of: picked) { _, item in
            Task {
                if let movie = try? await item?.loadTransferable(type: PickedMovie.self) {
                    source.videoURL = movie.url
                    source.sample = nil
                }
            }
        }
    }

    private func useSample(_ file: String) {
        Task {
            downloading = true
            defer { downloading = false }
            do {
                source.videoURL = try await SampleMedia.localVideo(file)
                source.sample = file
                problem = ""
            } catch {
                problem = "\(error)"
            }
        }
    }
}

/// Lays out 1 to 4 panes: one alone, two side by side (stacked on a narrow screen), three or four as a 2 x 2 grid.
struct LivePaneGrid<Pane: View>: View {
    let count: Int
    let narrow: Bool
    @ViewBuilder let pane: (Int) -> Pane

    var body: some View {
        if count <= 2 {
            if narrow {
                VStack(spacing: 6) { ForEach(0..<count, id: \.self, content: pane) }
            } else {
                HStack(spacing: 6) { ForEach(0..<count, id: \.self, content: pane) }
            }
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 6) { pane(0); pane(1) }
                HStack(spacing: 6) {
                    pane(2)
                    if count > 3 { pane(3) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        }
    }
}

/// The source's number, name and frame rate, shown in the corner of its pane.
struct LivePaneBadge: View {
    let number: Int
    let title: String
    let framesPerSecond: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)").bold()
            Text(title).lineLimit(1)
            if let framesPerSecond { Text(String(format: "%.1f FPS", framesPerSecond)).bold() }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
    }
}

enum LiveComposer {
    /// Joins the sources' pictures for a recording: side by side for two, a 2 x 2 grid for three or four,
    /// each cell scaled to a common height (at most 720 pixels per row).
    static func grid(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        guard images.count > 1 else { return first }
        let rows = images.count > 2 ? [Array(images.prefix(2)), Array(images.dropFirst(2))] : [images]
        let height = min(first.height, 720)
        let widths = rows.map { row in row.map { Int(Double($0.width) * Double(height) / Double($0.height)) } }
        let width = widths.map { $0.reduce(0, +) }.max() ?? 0
        guard width > 0, let context = CGContext(data: nil, width: width, height: height * rows.count, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height * rows.count))
        for (rowIndex, row) in rows.enumerated() {
            // CGContext's origin is bottom-left: the first row goes at the top.
            let y = (rows.count - 1 - rowIndex) * height
            var x = 0
            for (image, cellWidth) in zip(row, widths[rowIndex]) {
                context.draw(image, in: CGRect(x: x, y: y, width: cellWidth, height: height))
                x += cellWidth
            }
        }
        return context.makeImage()
    }

    /// A stream's server name, or a file's name, for the pane's badge.
    static func shortName(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Stream" }
        if let url = URL(string: trimmed), let host = url.host { return host }
        return (trimmed as NSString).lastPathComponent
    }

    /// How many sources this device runs at once (LiveSources.limit).
    static var sourceLimit: Int {
        LiveSources.limit(physicalMemory: ProcessInfo.processInfo.physicalMemory, isMac: ProcessInfo.processInfo.isMacCatalystApp)
    }
}
