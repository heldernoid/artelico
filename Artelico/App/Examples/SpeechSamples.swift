import AVFoundation
import SwiftUI
import StudioCore

/// Spoken samples bundled with both apps (Samples/), for trying speech to text without recording.
/// 10–17 s cuts from public-domain recordings, as 48 kb/s mono MP3; the same files and credits as the web
/// edition's (web/samples/speech, SPEECH_SAMPLES in web/js/ui/credits.js).
struct SpeechSample: Identifiable, Hashable {
    let file: String
    /// Whisper's code for the spoken language.
    let language: String
    let title: String
    let credit: String
    let link: URL?
    var id: String { file }

    var url: URL? { Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: (file as NSString).pathExtension) }

    private static func librivox(_ item: String) -> URL? { URL(string: "https://archive.org/details/\(item)") }
    private static let librivoxCredit = "LibriVox recording · public domain"

    static let all: [SpeechSample] = [
        SpeechSample(file: "speech_sample.wav", language: "en", title: "English · a short test sentence",
                     credit: "Made for this project with macOS speech", link: nil),
        SpeechSample(file: "kennedy_en.mp3", language: "en", title: "English · John F. Kennedy, 1961",
                     credit: "Inaugural address, 20 January 1961 · public domain (US government)",
                     link: URL(string: "https://www.jfklibrary.org/learn/about-jfk/historic-speeches/inaugural-address")),
        SpeechSample(file: "assis_pt.mp3", language: "pt", title: "Portuguese · Machado de Assis, A Mão e a Luva",
                     credit: librivoxCredit, link: librivox("a_mao_e_a_luva_1401_librivox")),
        SpeechSample(file: "cervantes_es.mp3", language: "es", title: "Spanish · Cervantes, Don Quijote",
                     credit: librivoxCredit, link: librivox("don_quijote_vol1_0706_librivox")),
        SpeechSample(file: "verne_fr.mp3", language: "fr", title: "French · Jules Verne, Le Tour du monde en 80 jours",
                     credit: librivoxCredit, link: librivox("tour_du_monde_en_80_jours_librivox")),
        SpeechSample(file: "collodi_it.mp3", language: "it", title: "Italian · Collodi, Pinocchio",
                     credit: librivoxCredit, link: librivox("avventure_pinocchio_librivox")),
        SpeechSample(file: "kafka_de.mp3", language: "de", title: "German · Kafka, Die Verwandlung",
                     credit: librivoxCredit, link: librivox("verwandlung_mw_0811_librivox")),
    ]
}

/// The audio a speech screen is working on (a sample, a file or a recording), playable. Remembers whether
/// it was muted ("audio.muted").
@MainActor
final class AudioClip: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var caption = ""
    @Published private(set) var sample: SpeechSample?
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published var muted = UserDefaults.standard.bool(forKey: "audio.muted") {
        didSet { player.isMuted = muted; UserDefaults.standard.set(muted, forKey: "audio.muted") }
    }
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        player.isMuted = muted
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                self.playing = self.player.rate != 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
    }

    /// Shows `url` in the player; plays it at once when `play` (a sample or a file: not a recording the
    /// user has just heard themselves say).
    func use(_ url: URL, caption: String, sample: SpeechSample? = nil, play: Bool) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.playing = false
            }
        }
        self.url = url
        self.caption = caption
        self.sample = sample
        position = 0
        duration = 0
        if play { self.play() }
    }

    func play() {
        VideoSound.preparePlayback()
        player.play()
        playing = true
    }

    func pause() {
        player.pause()
        playing = false
    }

    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
}

/// A small player for an AudioClip: play / pause, position, mute, and where the audio comes from.
struct AudioClipView: View {
    @ObservedObject var clip: AudioClip

    var body: some View {
        if clip.url != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Button { clip.playing ? clip.pause() : clip.play() } label: {
                        Image(systemName: clip.playing ? "pause.fill" : "play.fill").frame(width: 20)
                    }
                    .accessibilityLabel(clip.playing ? "Pause" : "Play")
                    Slider(value: Binding(get: { clip.position }, set: { clip.seek($0) }), in: 0...max(clip.duration, 0.1))
                    Text(String(format: "%.0f / %.0f s", clip.position, clip.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { clip.muted.toggle() } label: {
                        Image(systemName: clip.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(clip.muted ? "Sound off" : "Sound on")
                }
                .buttonStyle(.borderless)
                HStack(spacing: 4) {
                    if let sample = clip.sample {
                        Text(sample.title).bold()
                        Text("·")
                        if let link = sample.link { Link(sample.credit, destination: link) } else { Text(sample.credit) }
                    } else {
                        Text(clip.caption)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// The Samples menu of the speech screens.
struct SpeechSampleMenu: View {
    let choose: (SpeechSample) -> Void

    var body: some View {
        Menu("Samples") {
            ForEach(SpeechSample.all) { sample in
                Button(sample.title) { choose(sample) }
            }
        }
    }
}
