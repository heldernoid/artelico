import PhotosUI
import SwiftUI
import StudioCore
import UIKit

// MARK: Sample pictures

/// A picture shipped with the app, with the tasks it shows off best.
struct SamplePicture: Identifiable, Hashable {
    let file: String
    let title: String
    let tasks: Set<String>

    var id: String { file }

    static let all: [SamplePicture] = [
        SamplePicture(file: "bus.jpg", title: "Street with bus", tasks: ["detection", "pose", "instance_segmentation", "segment_everything", "semantic_segmentation", "classification", "depth", "face", "clip", "ask",
                                                                         "face_attribute", "face_landmarks", "person_attribute", "person_re_id",
                                                                         "zero_shot_object_detection", "object_clip"]),
        SamplePicture(file: "dog_bicycle.jpg", title: "Dog and bicycle", tasks: ["detection", "instance_segmentation", "segment_everything", "clip", "classification", "ask",
                                                                                 "zero_shot_object_detection", "object_clip"]),
        SamplePicture(file: "apple.jpg", title: "Apple", tasks: ["classification", "depth", "clip", "ask"]),
        SamplePicture(file: "room.png", title: "Living room", tasks: ["clip", "depth", "detection", "instance_segmentation", "segment_everything", "ask",
                                                                       "zero_shot_object_detection"]),
        SamplePicture(file: "ocr_img1.png", title: "Product label", tasks: ["ocr", "ask"]),
        SamplePicture(file: "ocr_img2.png", title: "Medicine box", tasks: ["ocr", "ask"]),
        SamplePicture(file: "plate_sample.png", title: "Licence plate", tasks: ["ocr", "ask"]),
        SamplePicture(file: "dota_image.png", title: "Aerial view", tasks: ["oriented_detection", "detection"]),
        SamplePicture(file: "lane.png", title: "Highway", tasks: ["lane_detection", "detection", "depth", "semantic_segmentation"]),
        SamplePicture(file: "input_image.png", title: "Small photo", tasks: ["super_resolution"]),
        SamplePicture(file: "stereo_left.jpg", title: "Street, left view", tasks: ["stereo_depth"]),
        SamplePicture(file: "stereo_right.jpg", title: "Street, right view", tasks: ["stereo_depth"]),
    ]

    /// Samples that suit `key` first, then the rest.
    static func ordered(for key: String) -> [SamplePicture] {
        all.filter { $0.tasks.contains(key) } + all.filter { !$0.tasks.contains(key) }
    }

    var url: URL? {
        let parts = file.split(separator: ".")
        return Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1]))
    }

    func load(maxSide: Int = 2048) -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSide]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Decodes picture data the way photos should be shown: orientation applied, size capped.
func decodePicture(_ data: Data, maxSide: Int = 2048) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: maxSide]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Thumbnails for the sample strip, decoded once.
@MainActor
final class SampleThumbnails: ObservableObject {
    static let shared = SampleThumbnails()
    @Published private(set) var images: [String: CGImage] = [:]

    func image(for sample: SamplePicture) -> CGImage? {
        if let cached = images[sample.file] { return cached }
        guard let loaded = sample.load(maxSide: 240) else { return nil }
        images[sample.file] = loaded
        return loaded
    }
}

/// A strip to pick a picture: the samples, your photo library, or the camera.
struct PictureChooser: View {
    /// Task key used to put the most relevant samples first ("detection", "ocr", "ask", …).
    let key: String
    let selected: String?
    let choose: (CGImage, String) -> Void
    @StateObject private var thumbnails = SampleThumbnails.shared
    @State private var pickedItem: PhotosPickerItem?
    @State private var takingPhoto = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    ChooserTile(systemImage: "photo.on.rectangle.angled", title: "Your photos")
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { takingPhoto = true } label: { ChooserTile(systemImage: "camera", title: "Take photo") }
                }
                Divider().frame(height: 64)
                ForEach(SamplePicture.ordered(for: key)) { sample in
                    Button {
                        if let image = sample.load() { choose(image, sample.file) }
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if let thumbnail = thumbnails.image(for: sample) {
                                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.2)
                                }
                            }
                            .frame(width: 96, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected == sample.file ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                             lineWidth: selected == sample.file ? 3 : 1))
                            Text(sample.title).font(.caption2).lineLimit(1).frame(width: 96)
                                .foregroundStyle(sample.tasks.contains(key) ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .onChange(of: pickedItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let image = decodePicture(data) {
                    choose(image, "photo")
                }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraCapture { image in
                takingPhoto = false
                if let image { choose(image, "camera") }
            }
            .ignoresSafeArea()
        }
    }
}

private struct ChooserTile: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title2)
                .frame(width: 96, height: 64)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.caption2)
        }
    }
}

/// The system camera, returning one photo with its orientation applied.
struct CameraCapture: UIViewControllerRepresentable {
    let finished: (CGImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (CGImage?) -> Void

        init(finished: @escaping (CGImage?) -> Void) {
            self.finished = finished
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let photo = info[.originalImage] as? UIImage
            finished(photo.flatMap { $0.jpegData(compressionQuality: 0.95) }.flatMap { decodePicture($0) })
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finished(nil)
        }
    }
}

// MARK: Small building blocks

/// A rounded panel with a title.
struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A small rounded label, e.g. "31.9 ms".
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint == .secondary ? Color.primary : tint)
    }
}

/// A label with a value and a bar, for confidences and probabilities.
struct ScoreRow: View {
    let label: String
    let value: Double
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                Text(String(format: "%.0f%%", value * 100)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint).frame(width: max(2, proxy.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 5)
        }
    }
}

/// The findings of one run as a readable list.
struct ResultList: View {
    let result: VisionResult

    private func tint(_ index: Int) -> Color { Color(cgColor: VisionRenderer.color(index)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch result {
            case .detections(let found):
                if found.isEmpty { Text("Nothing detected.").foregroundStyle(.secondary) }
                ForEach(Array(found.prefix(40).enumerated()), id: \.offset) { _, item in
                    ScoreRow(label: item.label, value: Double(item.confidence), tint: tint(item.classIndex))
                }
            case .instances(let found):
                if found.isEmpty { Text("Nothing detected.").foregroundStyle(.secondary) }
                ForEach(Array(found.prefix(40).enumerated()), id: \.offset) { index, item in
                    ScoreRow(label: item.detection.label, value: Double(item.detection.confidence), tint: tint(index))
                }
            case .classifications(let found):
                ForEach(Array(found.prefix(8).enumerated()), id: \.offset) { index, item in
                    ScoreRow(label: item.label.split(separator: ",").first.map(String.init) ?? item.label, value: Double(item.probability),
                             tint: index == 0 ? .green : .accentColor)
                }
            case .poses(let found):
                Text("\(found.count) \(found.count == 1 ? "person" : "people")").font(.title3.weight(.semibold))
                ForEach(Array(found.enumerated()), id: \.offset) { index, pose in
                    ScoreRow(label: pose.trackID.map { "Person #\($0)" } ?? "Person \(index + 1)", value: Double(pose.confidence), tint: tint(index))
                }
            case .faces(let found):
                if found.isEmpty { Text("No faces found.").foregroundStyle(.secondary) }
                ForEach(Array(found.enumerated()), id: \.offset) { index, face in
                    ScoreRow(label: face.name ?? "Unknown person", value: Double(face.confidence), tint: face.name == nil ? .orange : .green)
                }
            case .text(let found):
                let lines = found.map(\.text).filter { !$0.isEmpty }
                if lines.isEmpty { Text("\(found.count) text regions, none readable.").foregroundStyle(.secondary) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.body.monospaced()).textSelection(.enabled)
                }
            case .orientedDetections(let found):
                let groups = Dictionary(grouping: found, by: \.label).sorted { $0.value.count > $1.value.count }
                if found.isEmpty { Text("Nothing detected.").foregroundStyle(.secondary) }
                ForEach(groups, id: \.key) { label, items in
                    LabeledContent(label, value: "\(items.count)")
                }
            case .lanes(let found):
                Text("\(found.count) lane \(found.count == 1 ? "line" : "lines")").font(.title3.weight(.semibold))
            case .depth(let map):
                LabeledContent("Map size", value: "\(map.width) × \(map.height)")
                Text("Warm colours are near, cool colours are far.").font(.callout).foregroundStyle(.secondary)
            case .segmentation(let map):
                let present = Set(map.classes).sorted()
                ForEach(present, id: \.self) { index in
                    HStack {
                        let color = Int(index) < map.colors.count ? map.colors[Int(index)] : [0, 0, 0]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: Double(color[0]) / 255, green: Double(color[1]) / 255, blue: Double(color[2]) / 255))
                            .frame(width: 14, height: 14)
                        Text(Int(index) < map.labels.count ? map.labels[Int(index)] : "class \(index)")
                    }
                }
            case .image(let output):
                LabeledContent("New size", value: "\(output.image.width) × \(output.image.height)")
            case .described(let found):
                if found.isEmpty { Text("Nobody found.").foregroundStyle(.secondary) }
                ForEach(Array(found.prefix(10).enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name.map { name in item.similarity.map { String(format: "%@ (%.0f%% alike)", name, $0 * 100) } ?? "\(name) (new)" }
                             ?? item.label.map { String(format: "%@ %d (%.0f%%)", $0, index + 1, item.confidence * 100) }
                             ?? "#\(index + 1)").font(.headline)
                        ForEach(Array(item.attributes.prefix(6).enumerated()), id: \.offset) { _, attribute in
                            ScoreRow(label: attribute.label, value: Double(attribute.probability), tint: tint(index))
                        }
                    }
                }
            case .faceLandmarks(let found):
                if found.isEmpty { Text("No faces found.").foregroundStyle(.secondary) }
                ForEach(Array(found.enumerated()), id: \.offset) { index, face in
                    if let pose = face.headPose {
                        LabeledContent("Face \(index + 1)", value: String(format: "yaw %.0f°, pitch %.0f°, roll %.0f°", pose.yaw, pose.pitch, pose.roll))
                    } else {
                        ScoreRow(label: "Face \(index + 1), \(face.points.count) points", value: Double(face.confidence), tint: tint(index))
                    }
                }
            }
        }
    }
}

/// The prompt box of "Find anything" and "Describe each object" (Photos and Live), with example prompts; for
/// describing also what to describe and the detector that finds it (kept in `StudioModel.objectSettings`).
struct PromptOptions: View {
    let task: VisionTask
    @Binding var promptText: String
    @EnvironmentObject private var studio: StudioModel

    static let examples: [VisionTask: [String]] = [
        .findAnything: ["bus, person, handbag, sunglasses", "dog, bicycle, car", "red backpack, dog, bicycle", "cup, laptop, mobile phone, book"],
        .describeObjects: ["wearing sunglasses, not wearing sunglasses", "wearing a hat, wearing a backpack, on a phone",
                           "red car, white car, black car", "smiling, not smiling"],
    ]

    /// Detectors for the chosen objects, the ones on this device first.
    private var detectors: [ModelInfo] {
        let task: VisionTask = studio.objectSettings.objects == .faces ? .face : .detection
        let all = ModelCatalog.models(for: task.rawValue).filter { VisionPipeline.supports(task, model: $0) }
        return all.filter { studio.installed.contains($0.name) } + all.filter { !studio.installed.contains($0.name) }
    }

    private var detector: Binding<String> {
        Binding(get: { studio.objectSettings.detectorName }, set: { name in
            if studio.objectSettings.objects == .faces { studio.objectSettings.faceDetector = name } else { studio.objectSettings.detector = name }
        })
    }

    var body: some View {
        HStack {
            TextField(task == .findAnything ? "What to find, separated by commas" : "What to tell apart on each one, separated by commas; - for “not this”",
                      text: $promptText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240, maxWidth: 460)
            Menu("Examples") {
                ForEach(Self.examples[task] ?? [], id: \.self) { text in Button(text) { promptText = text } }
            }
            .fixedSize()
            if task == .describeObjects {
                Picker("Objects", selection: $studio.objectSettings.objects) {
                    ForEach(ObjectCLIP.Objects.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                Picker("Detector", selection: detector) {
                    ForEach(detectors) { model in
                        Text(studio.installed.contains(model.name) ? model.name : "\(model.name) (downloads when used)").tag(model.name)
                    }
                }
                .pickerStyle(.menu).fixedSize()
            }
        }
    }
}

/// Writes a picture to a temporary PNG so it can be shared or saved.
func temporaryPNG(_ image: CGImage, name: String = "hailo-studio-result") -> URL? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? url : nil
}

// MARK: Formatted text for model answers

/// Shows model output with basic Markdown: paragraphs, bold and italics, inline code, and fenced code
/// blocks in a monospaced panel with a copy button.
struct FormattedText: View {
    let text: String

    private struct Block: Identifiable {
        let id: Int
        let code: Bool
        let language: String
        let content: String
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var inCode = false
        var language = ""
        var current: [String] = []
        func flush() {
            let content = current.joined(separator: "\n")
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Block(id: result.count, code: inCode, language: language, content: inCode ? content : content.trimmingCharacters(in: .newlines)))
            }
            current = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
                language = inCode ? line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces) : ""
            } else {
                current.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                if block.code {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(block.language.isEmpty ? "code" : block.language).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { UIPasteboard.general.string = block.content } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12))
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(block.content).font(.callout.monospaced()).textSelection(.enabled).padding(10)
                        }
                    }
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(Self.attributed(block.content)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
