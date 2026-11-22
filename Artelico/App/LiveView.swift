import AVFoundation
import PhotosUI
import SwiftUI
import StudioCore

enum LiveSourceKind: String, CaseIterable, Identifiable {
    case backCamera = "Back camera"
    case frontCamera = "Front camera"
    case stream = "Stream address"
    case video = "Video file"

    var id: String { rawValue }
}

/// A video picked from the photo library, copied into the app's temporary folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// What one source is currently showing.
struct LivePane {
    var frame: CGImage?
    var overlay: CGImage?
    var result: VisionResult?
}

/// Runs a task continuously on up to four cameras, streams or videos (one model, taking turns), keeping two
/// frames in flight on the stick.
struct LiveView: View {
    @EnvironmentObject private var studio: StudioModel
    @AppStorage("live.streamAddress") private var streamAddress = ""
    @AppStorage("live.recentStreams") private var recentStreams = ""
    @AppStorage("live.tracking") private var tracking = true
    @AppStorage("live.tiles") private var tiles = 1
    @AppStorage("live.numberFaces") private var numberFaces = true
    @AppStorage("clip.prompts") private var promptText = "car, truck, bus, person, bicycle, -empty road"
    @State private var task: VisionTask = .detection
    @State private var modelName = "yolov8s"
    @State private var sourceKind: LiveSourceKind = .backCamera
    /// Sources 2 to 4.
    @State private var extras: [ExtraLiveSource] = []
    @State private var pickedVideo: PhotosPickerItem?
    @State private var videoURL: URL?
    /// The demo video playing (for its credit tag), nil for the user's own video.
    @State private var sampleVideo: String?
    @State private var downloadingSample = false
    @State private var panes = [LivePane](repeating: LivePane(), count: LiveSources.maximum)
    @State private var framesPerSecond = 0.0
    @State private var sourceRates: [Double] = []
    @State private var message = ""
    @State private var loop: Task<Void, Never>?
    @State private var recording = false
    @State private var wantsRecording = false
    @State private var recordedFrames = 0
    @State private var showRecordings = false
    @State private var showCameras = false
    /// Who was seen on which source (face recognition and re-identification). Kept outside SwiftUI's state
    /// so a frame does not redraw the open log; `shownSightings` is its copy, refreshed once a second.
    @State private var sightings = SightingRecorder()
    @State private var shownSightings = SightingLog()
    @State private var showSightings = false
    /// The extra source the road-camera list fills in, nil for the first source.
    @State private var choosingExtra: ExtraLiveSource.ID?
    @StateObject private var catalog = StreamCatalog()
    @EnvironmentObject private var studioState: StudioModel
    @Environment(\.horizontalSizeClass) private var widthClass
    /// iPhone in portrait: controls stack instead of sitting in wide rows.
    private var narrow: Bool { widthClass == .compact }

    private var running: Bool { loop != nil }
    private var recents: [String] { recentStreams.split(separator: "\n").map(String.init) }
    private var sourceCount: Int { 1 + extras.count }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    TaskModelPicker(task: $task, modelName: $modelName, live: true)
                    TaskOptions(task: task, tiles: $tiles, promptText: $promptText)
                    Picker("Source", selection: $sourceKind) {
                        ForEach(LiveSourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.horizontal)
            }
            .disabled(running)

            if sourceKind == .stream {
                Group {
                    if narrow {
                        VStack(alignment: .leading, spacing: 6) {
                            streamField
                            HStack(spacing: 16) { streamButtons }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack { streamField; streamButtons }
                    }
                }
                .disabled(running)
                .padding(.horizontal)
            } else if sourceKind == .video {
                HStack {
                    PhotosPicker(videoURL == nil ? "Choose a video" : "Choose another video", selection: $pickedVideo, matching: .videos)
                    Menu("Samples") {
                        ForEach(SampleMedia.allVideos, id: \.file) { sample in
                            Button(sample.title) { useSampleVideo(sample.file) }
                        }
                    }
                    if downloadingSample { ProgressView().controlSize(.small); Text("Downloading…").font(.caption) }
                    if let videoURL { Text(sampleTitle ?? videoURL.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                }
                .disabled(running)
                .padding(.horizontal)
            }

            extraSourceControls
                .disabled(running)
                .padding(.horizontal)

            LivePaneGrid(count: sourceCount, narrow: narrow) { pane($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if running {
                    HStack(spacing: 10) {
                        if recording {
                            Label("\(recordedFrames)", systemImage: "record.circle.fill").foregroundStyle(.red)
                        }
                        Text(String(format: "%.1f FPS", framesPerSecond)).bold()
                        VideoSoundButton(file: soundSource.file, stream: soundSource.stream).labelStyle(.iconOnly)
                    }
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                }
            }

            Text(panes[0].result?.summary ?? " ").font(.callout).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
        }
        .navigationTitle("Live")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showRecordings = true } label: { Label("Recordings", systemImage: "film.stack") }
                if Self.logsSightings(task) {
                    Button { shownSightings = sightings.log; showSightings = true } label: { Label("Seen on camera", systemImage: "person.crop.rectangle.stack") }
                        .help("Who was seen on which source, first and last seen")
                }
                Toggle(isOn: $tracking) { Label("Track", systemImage: "number") }
                    .toggleStyle(.button)
                    .help("Give each detected object, person or mask a number that follows it")
                Toggle(isOn: $wantsRecording) { Label("Record", systemImage: "record.circle") }
                    .toggleStyle(.button)
                    .tint(.red)
                Button(running ? "Stop" : "Start") { running ? stop() : start() }
                    .buttonStyle(.borderedProminent)
                    .tint(running ? .red : .accentColor)
                    .disabled(modelName.isEmpty)
            }
        }
        .sheet(isPresented: $showRecordings) { RecordingsView() }
        .sheet(isPresented: $showSightings) {
            SightingLogView(log: shownSightings, sourceNames: (0..<sourceCount).map(sourceTitle))
        }
        .sheet(isPresented: $showCameras) {
            CameraListView(catalog: catalog) { camera in
                if let index = extras.firstIndex(where: { $0.id == choosingExtra }) { extras[index].address = camera.url } else { streamAddress = camera.url }
            }
        }
        .onAppear {
            // Prefer a model that is on this device.
            if !studioState.installed.contains(modelName),
               let available = ModelCatalog.models(for: task.rawValue).first(where: { studioState.installed.contains($0.name) && VisionPipeline.supports(task, model: $0) }) {
                modelName = available.name
            }
            // `-stream <address>` lets the Mac start a live run for testing; `-stream2`, `-stream3` and `-stream4`
            // add sources. An address can also be a file path (a video that loops).
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "-stream"), index + 1 < arguments.count, !running {
                sourceKind = .stream
                streamAddress = arguments[index + 1]
                extras = (2...LiveSources.maximum).compactMap { number in
                    guard let flag = arguments.firstIndex(of: "-stream\(number)"), flag + 1 < arguments.count else { return nil }
                    return ExtraLiveSource(address: arguments[flag + 1])
                }
                if let chosen = arguments.firstIndex(of: "-task"), chosen + 2 < arguments.count,
                   let wanted = VisionTask(rawValue: arguments[chosen + 1]) {
                    task = wanted
                    modelName = arguments[chosen + 2]
                }
                start()
                // `-sightings` opens the "Seen on camera" log after 20 seconds (checking it from the Mac).
                if arguments.contains("-sightings") {
                    Task { try? await Task.sleep(for: .seconds(20)); shownSightings = sightings.log; showSightings = true }
                }
            }
        }
        .onChange(of: pickedVideo) { _, item in
            Task {
                if let movie = try? await item?.loadTransferable(type: PickedMovie.self) { videoURL = movie.url; sampleVideo = nil }
            }
        }
        .onDisappear { stop() }
    }

    private var streamField: some View {
        TextField("https://…/stream.m3u8, rtsp://…, an MJPEG address, or a camera image address", text: $streamAddress)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
    }

    @ViewBuilder
    private var streamButtons: some View {
        Button("Road cameras") { choosingExtra = nil; showCameras = true }
        if !recents.isEmpty {
            Menu("Recent") {
                ForEach(recents, id: \.self) { address in
                    Button(address) { streamAddress = address }
                }
            }
        }
    }

    /// Sources 2 to 4 (streams or videos), the button that adds one, and face numbering.
    private var extraSourceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($extras) { $extra in
                ExtraSourceRow(number: (extras.firstIndex { $0.id == extra.id } ?? 0) + 2, source: $extra, recents: recents,
                               roadCameras: { choosingExtra = extra.id; showCameras = true },
                               remove: { extras.removeAll { $0.id == extra.id } })
            }
            HStack {
                Button { extras.append(ExtraLiveSource()) } label: { Label("Add a source", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(sourceCount >= LiveComposer.sourceLimit)
                    .help(LiveComposer.sourceLimit < LiveSources.maximum
                          ? "This device runs at most \(LiveComposer.sourceLimit) sources: each video player needs about 80 MB, and this device has 3 GB of memory"
                          : "Up to \(LiveSources.maximum) sources share the model")
                if task == .face {
                    Toggle("Number unknown people", isOn: $numberFaces).fixedSize()
                        .help("Gives each unnamed face a label that stays the same across frames and across all sources")
                }
                Spacer()
            }
        }
    }

    /// Tasks whose results carry people's names or numbers.
    private static func logsSightings(_ task: VisionTask) -> Bool { task == .face || task == .personReID }

    private func sourceTitle(_ index: Int) -> String {
        guard index > 0 else {
            switch sourceKind {
            case .stream: return LiveComposer.shortName(streamAddress)
            case .video: return sampleTitle ?? videoURL?.lastPathComponent ?? "Video"
            default: return sourceKind.rawValue
            }
        }
        return extras.indices.contains(index - 1) ? extras[index - 1].title : ""
    }

    private func sampleFile(_ index: Int) -> String? {
        if index == 0 { return sourceKind == .video ? sampleVideo : nil }
        guard extras.indices.contains(index - 1), extras[index - 1].kind == .video else { return nil }
        return extras[index - 1].sample
    }

    @ViewBuilder
    private func pane(_ index: Int) -> some View {
        ZStack {
            if let frame = panes[index].frame {
                Image(decorative: frame, scale: 1).resizable().scaledToFit()
                    .overlay {
                        if let overlay = panes[index].overlay {
                            Image(decorative: overlay, scale: 1).resizable().interpolation(.medium).opacity(task == .depth ? 1 : 0.55)
                        }
                    }
                    .overlay { ResultOverlay(result: panes[index].result) }
                    .overlay(alignment: .bottomLeading) {
                        if let file = sampleFile(index) { CreditTag(file: file) }
                    }
            } else if running {
                ProgressView("Starting…")
            } else {
                ContentUnavailableView("Not running", systemImage: "video.slash",
                                       description: Text(message.isEmpty || index > 0 ? "Choose a task, a model and a source, then tap Start." : message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if sourceCount > 1 {
                LivePaneBadge(number: index + 1, title: sourceTitle(index),
                              framesPerSecond: running && sourceRates.indices.contains(index) ? sourceRates[index] : nil)
            }
        }
    }

    private func address(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A video file on this computer (the Mac, for testing): played in a loop.
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) { return URL(fileURLWithPath: trimmed) }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw SourceError(description: "Enter a full address starting with https://, http:// or rtsp://.")
        }
        recentStreams = ([trimmed] + recents.filter { $0 != trimmed }).prefix(8).joined(separator: "\n")
        return url
    }

    private var sampleTitle: String? {
        guard let sampleVideo else { return nil }
        return SampleMedia.allVideos.first { $0.file == sampleVideo }?.title
    }

    /// Plays one of Hailo's demo videos (downloaded the first time).
    private func useSampleVideo(_ file: String) {
        Task {
            downloadingSample = true
            defer { downloadingSample = false }
            do {
                videoURL = try await SampleMedia.localVideo(file)
                sampleVideo = file
            } catch {
                message = "\(error)"
            }
        }
    }

    /// The source whose sound plays (the first video or stream; see makeSources), for the sound button.
    private var soundSource: (file: URL?, stream: Bool) {
        switch sourceKind {
        case .video: return (videoURL, false)
        case .stream: return (nil, true)
        default:
            guard let first = extras.first else { return (nil, false) }
            return first.kind == .video ? (first.videoURL, false) : (nil, true)
        }
    }

    private func makeSources() throws -> [FrameSource] {
        var sources: [FrameSource] = []
        switch sourceKind {
        case .backCamera: sources.append(CameraSource(position: .back))
        case .frontCamera: sources.append(CameraSource(position: .front))
        case .stream: sources.append(StreamSource(url: try address(streamAddress)))
        case .video:
            guard let videoURL else { throw SourceError(description: "Choose a video first.") }
            sources.append(StreamSource(url: videoURL))
        }
        // Only one source plays its sound: the first video or stream.
        var soundTaken = sourceKind == .stream || sourceKind == .video
        for (offset, extra) in extras.enumerated() {
            switch extra.kind {
            case .stream: sources.append(StreamSource(url: try address(extra.address), sound: !soundTaken))
            case .video:
                guard let url = extra.videoURL else { throw SourceError(description: "Choose a video for source \(offset + 2) first.") }
                sources.append(StreamSource(url: url, sound: !soundTaken))
            }
            soundTaken = true
        }
        return sources
    }

    private func stop() {
        loop?.cancel()
    }

    private func start() {
        guard let model = ModelCatalog.model(named: modelName) else { return }
        let task = self.task
        message = ""
        loop = Task {
            var sources: [FrameSource] = []
            var recorder: Recorder?
            do {
                sources = try makeSources()
                studio.liveRunning = true
                try await studio.prepare(model, task: task)
                studio.forgetSessionFaces()
                sightings.log = SightingLog()
                for source in sources { try await source.start() }
                try await run(model: model, task: task, sources: sources, recorder: &recorder)
            } catch is CancellationError {
            } catch {
                message = "Stopped: \(error)"
            }
            sources.forEach { $0.stop() }
            // Collect anything still on the stick so the next start begins clean.
            while await studio.device.framesInFlight > 0 { _ = try? await studio.device.collect() }
            if let finished = await recorder?.finish() {
                message = "Saved \(finished.lastPathComponent). Open Recordings to share it or save it to Photos."
            }
            recording = false
            panes = [LivePane](repeating: LivePane(), count: LiveSources.maximum)
            sourceRates = []
            studio.liveRunning = false
            loop = nil
        }
    }

    private func run(model: ModelInfo, task: VisionTask, sources: [FrameSource], recorder: inout Recorder?) async throws {
        let device = studio.device
        var inFlight: [(source: Int, image: CGImage, prepared: PreparedFrame)] = []
        var meter = FrameRateMeter(sources: sources.count)
        var trackers = sources.map { _ in ObjectTracker() }
        var rendered = [CGImage?](repeating: nil, count: sources.count)
        var nextSource = 0
        let tiles = task == .detection ? self.tiles : 1
        let stepwise = studio.needsPipeline(task, tiles: tiles)
        let prompts = promptText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let numberFaces = self.numberFaces
        let logsResults = CommandLine.arguments.contains("-livelog")
        let logsSightings = Self.logsSightings(task)

        /// Shows one result and, when recording, adds a frame to the video.
        func publish(_ index: Int, _ image: CGImage, _ raw: VisionResult) async throws {
            let decoded = tracking ? trackers[index].track(raw) : raw
            // `-livelog` prints each result (checking live runs from the Mac).
            if logsResults { FileHandle.standardError.write(Data("LIVE \(task.rawValue) [\(index)]: \(decoded.summary)\n".utf8)) }
            var pane = LivePane(frame: image, overlay: nil, result: decoded)
            switch decoded {
            case .detections, .poses, .classifications:
                break  // drawn over the picture by ResultOverlay
            case .depth(let map):
                pane.overlay = VisionRenderer.depthImage(map)
            case .segmentation(let map):
                pane.overlay = VisionRenderer.segmentationImage(map)
            default:
                // Masks, rotated boxes, lanes, faces, text and generated pictures are drawn into the frame.
                pane.frame = VisionRenderer.render(decoded, over: image) ?? image
            }
            panes[index] = pane
            if logsSightings {
                for name in sightings.log.record(decoded, source: index, at: Date(), frame: image) where logsResults {
                    FileHandle.standardError.write(Data("SEEN \(name) on source \(index + 1)\n".utf8))
                }
                if let snapshot = sightings.snapshot(every: 1) { shownSightings = snapshot }
            }

            // Recording draws the result into the picture, so the saved video looks like the screen.
            if wantsRecording {
                rendered[index] = VisionRenderer.render(decoded, over: image)
                if let composed = LiveComposer.grid(rendered.compactMap { $0 }) {
                    if recorder == nil {
                        recorder = try Recorder(firstFrame: composed, name: "\(task.rawValue)_\(model.name)")
                        recording = true
                    }
                    recorder?.append(composed)
                    recordedFrames = recorder?.frameCount ?? 0
                }
            } else if let active = recorder {
                recorder = nil
                recording = false
                if let finished = await active.finish() { message = "Saved \(finished.lastPathComponent)." }
            }

            if meter.tick(source: index, at: ProcessInfo.processInfo.systemUptime) {
                framesPerSecond = meter.total
                sourceRates = meter.perSource
                if logsResults {
                    let each = meter.perSource.map { String(format: "%.1f", $0) }.joined(separator: " ")
                    FileHandle.standardError.write(Data(String(format: "LIVE FPS %.1f [%@]\n", meter.total, each).utf8))
                }
            }
        }

        func checkSources() throws {
            for source in sources {
                if let problem = source.failure { throw SourceError(description: problem) }
            }
        }

        while !Task.isCancelled {
            // Tasks with several steps per picture (reading text, naming faces, tagging, tiling,
            // upscaling) handle one frame at a time.
            if stepwise {
                var worked = false
                for (index, source) in sources.enumerated() {
                    guard let image = source.takeLatest() else { continue }
                    worked = true
                    let result = try await studio.runPipeline(task, on: image, tiles: tiles, prompts: prompts, numberUnknownFaces: numberFaces, liveSource: index)
                    try await publish(index, image, result)
                }
                if !worked {
                    try checkSources()
                    try await Task.sleep(for: .milliseconds(2))
                }
                continue
            }

            // Keep up to two frames on the stick; that is what reaches full throughput. Several sources
            // take turns, so each gets an equal share.
            if inFlight.count < 2 {
                var submitted = false
                for offset in 0..<sources.count {
                    let index = (nextSource + offset) % sources.count
                    guard let image = sources[index].takeLatest() else { continue }
                    let prepared = try VisionPipeline.prepare(image, for: model, task: task)
                    try await device.submit(inputs: [prepared.rgb])
                    inFlight.append((index, image, prepared))
                    nextSource = (index + 1) % sources.count
                    submitted = true
                    break
                }
                if submitted, inFlight.count < 2 { continue }
            }
            guard !inFlight.isEmpty else {
                try checkSources()
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            let tensors = try await device.collect()
            let (index, image, prepared) = inFlight.removeFirst()
            try await publish(index, image, VisionPipeline.decode(tensors, task: task, model: model, frame: prepared))
        }
    }
}

/// Saved recordings: share, save to Photos, delete.
struct RecordingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var note = ""

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    Text("No recordings yet. Turn on Record while a live view is running.").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { file in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(file.lastPathComponent).font(.callout)
                            Text(formatBytes(((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                        Button {
                            UISaveVideoAtPathToSavedPhotosAlbum(file.path, nil, nil, nil)
                            note = "Sent \(file.lastPathComponent) to Photos."
                        } label: { Image(systemName: "photo.badge.arrow.down") }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            try? FileManager.default.removeItem(at: file)
                            files = Recorder.recordings()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Recordings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { files = Recorder.recordings() }
        }
    }
}

/// Boxes and skeletons drawn over the displayed frame. Coordinates are normalized to the frame.
struct ResultOverlay: View {
    let result: VisionResult?

    var body: some View {
        Canvas { context, size in
            func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
            func rect(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
            }
            func tint(_ index: Int) -> Color { Color(cgColor: VisionRenderer.color(index)) }

            switch result {
            case .detections(let detections):
                for detection in detections {
                    let box = rect(detection.boundingBox)
                    context.stroke(Path(box), with: .color(tint(detection.classIndex)), lineWidth: 3)
                    let label = Text("\(detection.label) \(String(format: "%.2f", detection.confidence))").font(.caption.bold()).foregroundColor(.white)
                    let resolved = context.resolve(label)
                    let textSize = resolved.measure(in: size)
                    let tag = CGRect(x: box.minX, y: max(box.minY - textSize.height - 4, 0), width: textSize.width + 8, height: textSize.height + 4)
                    context.fill(Path(tag), with: .color(tint(detection.classIndex)))
                    context.draw(resolved, at: CGPoint(x: tag.minX + 4, y: tag.minY + 2), anchor: .topLeading)
                }
            case .poses(let poses):
                for (index, pose) in poses.enumerated() {
                    var bones = Path()
                    for (a, b) in Pose.skeleton where pose.keypoints[a].confidence > 0.5 && pose.keypoints[b].confidence > 0.5 {
                        bones.move(to: point(pose.keypoints[a].position))
                        bones.addLine(to: point(pose.keypoints[b].position))
                    }
                    context.stroke(bones, with: .color(tint(index)), lineWidth: 3)
                    for keypoint in pose.keypoints where keypoint.confidence > 0.5 {
                        let p = point(keypoint.position)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white))
                    }
                    if let id = pose.trackID {
                        let box = rect(pose.boundingBox)
                        let resolved = context.resolve(Text("#\(id)").font(.caption.bold()).foregroundColor(.white))
                        let textSize = resolved.measure(in: size)
                        let tag = CGRect(x: box.minX, y: max(box.minY - textSize.height - 4, 0), width: textSize.width + 8, height: textSize.height + 4)
                        context.fill(Path(tag), with: .color(tint(index)))
                        context.draw(resolved, at: CGPoint(x: tag.minX + 4, y: tag.minY + 2), anchor: .topLeading)
                    }
                }
            case .classifications(let classes):
                var y: CGFloat = 12
                for item in classes.prefix(3) {
                    let name = item.label.split(separator: ",").first.map(String.init) ?? item.label
                    let label = Text(String(format: "%@  %.0f%%", name, item.probability * 100)).font(.title3.bold()).foregroundColor(.white)
                    let resolved = context.resolve(label)
                    let textSize = resolved.measure(in: size)
                    context.fill(Path(CGRect(x: 12, y: y, width: textSize.width + 12, height: textSize.height + 6)), with: .color(.black.opacity(0.6)))
                    context.draw(resolved, at: CGPoint(x: 18, y: y + 3), anchor: .topLeading)
                    y += textSize.height + 10
                }
            default:
                break
            }
        }
        .allowsHitTesting(false)
    }
}
