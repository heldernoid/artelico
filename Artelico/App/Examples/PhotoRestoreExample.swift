import PhotosUI
import SwiftUI
import StudioCore

/// PhotoRestore (UGen300 demo): brighten, remove noise and upscale ×2 an old or dark photo, then compare
/// before and after with a slider. All on this device.
struct PhotoRestoreExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @State private var picked: PhotosPickerItem?
    @State private var original: CGImage?
    @State private var restored: CGImage?
    @State private var steps: Set<PhotoRestore.Step> = [.brighten, .denoise]
    @AppStorage("restore.brighten") private var brightenStrength = 1.0
    @AppStorage("restore.denoise") private var denoiseStrength = 1.0
    @State private var split = 0.5
    @State private var status = ""
    @State private var working = false
    @State private var seconds = 0.0

    /// Working size: photos are reduced to this longest side first (upscaling then gives up to 2048).
    private static let maxSide = 1024

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                PhotosPicker(original == nil ? "Choose a photo" : "Another photo", selection: $picked, matching: .images)
                Menu("Samples") {
                    Button("Dark room") { load(sample: "room", ext: "png") }
                    Button("Small picture") { load(sample: "input_image", ext: "png") }
                    Button("Street") { load(sample: "bus", ext: "jpg") }
                }
                Spacer()
                if let restored {
                    ShareLink(item: Image(decorative: restored, scale: 1), preview: SharePreview("Restored photo", image: Image(decorative: restored, scale: 1))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button { UIImageWriteToSavedPhotosAlbum(UIImage(cgImage: restored), nil, nil, nil); status = "Saved to Photos." } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .padding(.horizontal)
            ExampleLayout(panelWidth: 300) {
                compare
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Photo restore")
        .onChange(of: picked) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data)?.uprightCGImage { set(image) }
            }
        }
        .onAppear {
            if CommandLine.arguments.contains("-autostart"), original == nil { load(sample: "room", ext: "png"); Task { await run() } }
        }
    }

    @ViewBuilder private var compare: some View {
        if let original {
            GeometryReader { geometry in
                let aspect = CGFloat(original.width) / CGFloat(original.height)
                let size = aspect > geometry.size.width / geometry.size.height
                    ? CGSize(width: geometry.size.width, height: geometry.size.width / aspect)
                    : CGSize(width: geometry.size.height * aspect, height: geometry.size.height)
                ZStack(alignment: .leading) {
                    Image(decorative: original, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                    if let restored {
                        Image(decorative: restored, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                            .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
                        Rectangle().fill(.white).frame(width: 3, height: size.height).offset(x: size.width * split - 1.5).shadow(radius: 3)
                        Image(systemName: "arrow.left.and.right.circle.fill").font(.system(size: 36)).foregroundStyle(.white, .black.opacity(0.5))
                            .offset(x: size.width * split - 18)
                        VStack {
                            HStack {
                                Text("After").font(.caption.bold()).padding(6).background(.black.opacity(0.55), in: Capsule())
                                Spacer()
                                Text("Before").font(.caption.bold()).padding(6).background(.black.opacity(0.55), in: Capsule())
                            }
                            .foregroundStyle(.white).padding(8)
                            Spacer()
                        }
                        .frame(width: size.width, height: size.height)
                    }
                    if working {
                        ProgressView(status).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .frame(width: size.width, height: size.height)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in split = min(1, max(0, value.location.x / size.width)) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("No photo", systemImage: "photo.badge.plus", description: Text("Choose a photo or a sample. Dark, noisy or small pictures show the difference best."))
        }
    }

    @ViewBuilder private var panel: some View {
        Text("Steps").font(.headline)
        ForEach(PhotoRestore.Step.allCases, id: \.self) { step in
            let here = studio.canUse(step.modelName)
            Toggle(isOn: Binding(get: { steps.contains(step) && here }, set: { on in if on { steps.insert(step) } else { steps.remove(step) } })) {
                VStack(alignment: .leading) {
                    Text(step.title)
                    Text(studio.modelLabel(step.modelName)).font(.caption).foregroundStyle(here ? Color.secondary : Color.red)
                }
            }
            .disabled(!here)
            if step == .brighten && steps.contains(.brighten) && here {
                Slider(value: $brightenStrength, in: 0.1...1) { Text("Strength") }
                Text("Brightening is limited on pictures that are already bright.").font(.caption2).foregroundStyle(.secondary)
            }
            if step == .denoise && steps.contains(.denoise) && here {
                Slider(value: $denoiseStrength, in: 0.1...1) { Text("Strength") }
            }
        }
        Button { Task { await run() } } label: { Label("Restore", systemImage: "wand.and.stars") }
            .buttonStyle(.borderedProminent).disabled(original == nil || working || steps.isEmpty)
        if !status.isEmpty { Text(status).font(.callout) }
        if let original {
            Text("\(original.width) × \(original.height)\(restored.map { " → \($0.width) × \($0.height)" } ?? "")").font(.caption).foregroundStyle(.secondary)
        }
        Text("Drag across the picture to compare. Photos larger than \(Self.maxSide) pixels are reduced first.").font(.caption).foregroundStyle(.secondary)
    }

    private func load(sample: String, ext: String) {
        guard let url = Bundle.main.url(forResource: sample, withExtension: ext), let image = UIImage(contentsOfFile: url.path)?.uprightCGImage else { return }
        set(image)
    }

    private func set(_ image: CGImage) {
        let longest = max(image.width, image.height)
        if longest > Self.maxSide, let small = try? ImagePrep.prepare(image, width: image.width * Self.maxSide / longest, height: image.height * Self.maxSide / longest, mode: .stretch),
           let reduced = VisionRenderer.makeImage(Self.rgba(small.rgb), width: small.width, height: small.height) {
            original = reduced
        } else {
            original = image
        }
        restored = nil
        split = 0.5
        status = ""
    }

    static func rgba(_ rgb: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: rgb.count / 3 * 4)
        for i in 0..<(rgb.count / 3) { out[i * 4] = rgb[i * 3]; out[i * 4 + 1] = rgb[i * 3 + 1]; out[i * 4 + 2] = rgb[i * 3 + 2] }
        return out
    }

    private func run() async {
        guard let original, !working else { return }
        working = true
        defer { working = false }
        let started = Date()
        do {
            let source = try ImagePrep.prepare(original, width: original.width, height: original.height, mode: .stretch)
            var rgb = source.rgb, width = source.width, height = source.height
            for step in PhotoRestore.Step.allCases where steps.contains(step) {
                guard let model = ModelCatalog.model(named: step.modelName), studio.canUse(model.name) else { continue }
                status = "\(step.title): loading…"
                try await studio.loadAlone(model)
                let result = try await PhotoRestore.run(rgb, width: width, height: height, model: model, device: studio.exampleEngine) { done, total in
                    Task { @MainActor in status = "\(step.title): \(done)/\(total) tiles" }
                }
                var strength = 1.0
                if step == .brighten { strength = PhotoRestore.brightenStrength(meanBrightness: PhotoRestore.meanBrightness(rgb), user: brightenStrength) }
                if step == .denoise { strength = denoiseStrength }
                rgb = PhotoRestore.blend(original: rgb, width: width, height: height, processed: result.rgb, outWidth: result.width, outHeight: result.height, strength: strength)
                width = result.width; height = result.height
            }
            restored = VisionRenderer.makeImage(Self.rgba(rgb), width: width, height: height)
            seconds = Date().timeIntervalSince(started)
            status = String(format: "Done in %.1f s.", seconds)
        } catch {
            status = "Stopped: \(error)"
        }
    }
}
