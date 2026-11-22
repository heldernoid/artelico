import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import StudioCore

/// Enrols everyone in a set of photos at once: photos named after the person ("Ann Smith.jpg",
/// "Ann Smith 2.jpg") or a folder with a folder per person. Each person's photos are averaged into one
/// identity vector in the shared face list (Face check-in, Photos and Live). The face models must be
/// loaded (Face check-in running).
struct FacePhotoEnrolSheet: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    /// Photos or folders to start with (the `-enrolfolder` test flag); empty shows the file picker.
    var initial: [URL] = []
    /// Called with the names enrolled.
    var finished: ([String]) -> Void = { _ in }
    @State private var picking = false
    @State private var lines: [Line] = []
    @State private var working = false
    @State private var summary = ""

    struct Line: Identifiable {
        let id = UUID()
        let file: String
        let text: String
        let ok: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose photos named after the person (\"Ann Smith.jpg\", \"Ann Smith 2.jpg\"), or a folder of them, or a folder with a folder per person. Each photo should show one face.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button { picking = true } label: { Label("Choose photos or a folder…", systemImage: "folder.badge.person.crop") }
                        .disabled(working)
                    if working { ProgressView("Reading \(lines.count + 1)…") }
                    if !summary.isEmpty { Text(summary).bold() }
                }
                if !lines.isEmpty {
                    Section("Photos") {
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(line.ok ? .green : .orange)
                                VStack(alignment: .leading) {
                                    Text(line.file).font(.callout)
                                    Text(line.text).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Enrol from photos")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await enrol(urls) } }
            }
            .task { if !initial.isEmpty { await enrol(initial) } }
        }
    }

    private func enrol(_ picked: [URL]) async {
        working = true
        lines = []
        summary = ""
        // Files from the picker are only readable while their security scope is open.
        let opened = picked.filter { $0.startAccessingSecurityScopedResource() }
        var samples: [String: [[Float]]] = [:]
        var order: [String] = []
        defer {
            opened.forEach { $0.stopAccessingSecurityScopedResource() }
            working = false
            finished(order)
        }
        let photos = FaceEnrolment.photos(in: picked)
        for (url, name) in photos {
            let file = url.lastPathComponent
            guard let name else {
                lines.append(Line(file: file, text: "No name in the file name: rename it after the person", ok: false))
                continue
            }
            guard let image = Self.load(url) else {
                lines.append(Line(file: file, text: "Could not be opened as a picture", ok: false))
                continue
            }
            do {
                let found = try await FaceRecognition.describe(image, device: studio.device).filter { !$0.embedding.isEmpty }
                switch FaceEnrolment.decide(boxes: found.map(\.face.boundingBox)) {
                case .noFace:
                    lines.append(Line(file: file, text: "No face found", ok: false))
                case .severalFaces(let count):
                    lines.append(Line(file: file, text: "\(count) faces of similar size: crop it to \(name) alone", ok: false))
                case .enrol(let index):
                    if samples[name] == nil { order.append(name) }
                    samples[name, default: []].append(found[index].embedding)
                    let note = found.count > 1 ? " (the largest of \(found.count) faces)" : ""
                    lines.append(Line(file: file, text: "\(name)\(note)", ok: true))
                }
            } catch {
                lines.append(Line(file: file, text: "\(error)", ok: false))
            }
        }
        for name in order {
            if let vector = FaceGallery.average(samples[name] ?? []) { studio.enroll(name, embedding: vector) }
        }
        let refused = lines.filter { !$0.ok }.count
        summary = photos.isEmpty ? "No pictures found in what was chosen."
            : "Enrolled \(order.count) \(order.count == 1 ? "person" : "people") from \(photos.count - refused) of \(photos.count) photos."
        // `-livelog`-style output for checking from the Mac.
        if CommandLine.arguments.contains("-enrolfolder") {
            for line in lines { FileHandle.standardError.write(Data("ENROL \(line.ok ? "ok" : "--") \(line.file): \(line.text)\n".utf8)) }
            FileHandle.standardError.write(Data("ENROL \(summary)\n".utf8))
        }
    }

    /// The photo upright (EXIF orientation applied), at most 1600 pixels on its longer side.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1600]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
