import SwiftUI
import StudioCore

/// The sound button of every screen that runs video: on or off for all videos (`VideoSound.isOn`, on by
/// default), shown for a video file that has a sound track and for stream addresses (which may have one).
/// Shared by both apps. (Web counterpart: the 🔊 / 🔇 button of web/js/ui/runner.js.)
struct VideoSoundButton: View {
    /// The video file chosen, or nil.
    var file: URL?
    /// True for a stream address: shown without checking the file.
    var stream = false
    @AppStorage(VideoSound.settingKey) private var on = true
    @State private var fileHasSound = false

    var body: some View {
        Group {
            if stream || fileHasSound {
                Button { on.toggle() } label: {
                    Label(on ? "Sound" : "Muted", systemImage: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .help(on ? "Turn the video's sound off" : "Play the video's sound")
                .accessibilityLabel(on ? "Sound on" : "Sound off")
            } else {
                // Something to attach the check to: SwiftUI runs no .task on an empty view.
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .task(id: file) {
            fileHasSound = false
            if let file { fileHasSound = await VideoSound.hasSound(file) }
        }
    }
}
