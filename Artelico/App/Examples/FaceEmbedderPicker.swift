import SwiftUI
import StudioCore

/// Which ArcFace model describes faces for recognition (Photos, Live and Face check-in). Each one
/// keeps its own list of people: their vectors cannot be compared with the other model's.
struct FaceEmbedderPicker: View {
    @EnvironmentObject private var studio: StudioModel
    var disabled = false

    var body: some View {
        Picker("Recognition model", selection: $studio.faceEmbedder) {
            ForEach(FaceRecognition.embedderNames, id: \.self) { name in
                Text(Self.title(name)).tag(name)
            }
        }
        .disabled(disabled)
        Text("Each recognition model keeps its own list of people.").font(.caption).foregroundStyle(.secondary)
    }

    static func title(_ embedder: String) -> String {
        switch embedder {
        case "arcface_mobilefacenet": return "MobileFaceNet (fast)"
        case "arcface_r50": return "ResNet-50 (more accurate)"
        default: return embedder
        }
    }
}
