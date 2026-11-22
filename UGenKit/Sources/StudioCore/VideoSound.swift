import AVFoundation
import Foundation

/// The sound of a video file whose frames are shown one by one (PacedVideoReader), so it is not played by a
/// player: an audio-only player plays the file in real time and is moved back to the frame shown whenever
/// they drift apart by more than a quarter of a second. The pacer keeps the frames in real time, so that
/// is rare. (Web counterpart: `VideoSound` in web/js/ui/runner.js.)
///
/// - On or off for every video: `VideoSound.isOn` (the "video.sound" setting, on by default). Off, it keeps
///   playing silently, so turning it on needs no seek.
/// - When frames stop coming (paused, or the model is busy for more than a second), the sound pauses too.
public final class VideoSound: @unchecked Sendable {
    /// The setting behind the sound button of every video screen.
    public static let settingKey = "video.sound"
    public static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    /// Whether the file at `url` has a sound track.
    public static func hasSound(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty == false) ?? false
    }

    private let player: AVPlayer
    private let lock = NSLock()
    private var lastFollow = 0.0
    private var watchdog: DispatchSourceTimer?

    /// The sound of the video file at `url`, or nil when it has none.
    public init?(url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration) else { return nil }
        // Only the sound track, so the player does not decode the video a second time.
        let composition = AVMutableComposition()
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? audio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)) != nil else { return nil }
        nonisolated(unsafe) let soundOnly = composition
        player = await MainActor.run { AVPlayer(playerItem: AVPlayerItem(asset: soundOnly)) }
        player.isMuted = !Self.isOn
        player.actionAtItemEnd = .pause   // the frames say when to loop
        Self.preparePlayback()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = ProcessInfo.processInfo.systemUptime - self.lock.withLock { self.lastFollow }
            if idle > 1.0, self.player.rate != 0 { self.player.pause() }
        }
        timer.resume()
        watchdog = timer
    }

    deinit { stop() }

    /// Keeps the sound at `seconds` into the file (the time of the frame being shown) and playing.
    public func follow(_ seconds: Double) {
        lock.withLock { lastFollow = ProcessInfo.processInfo.systemUptime }
        player.isMuted = !Self.isOn
        let now = player.currentTime().seconds
        if !now.isFinite || abs(now - seconds) > 0.25 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if player.rate == 0 { player.play() }
    }

    public func stop() {
        watchdog?.cancel()
        watchdog = nil
        player.pause()
    }

    /// On iPhone and iPad the speech screens leave the audio session set for recording; video sound needs it
    /// set for playback (mixed with other apps' sound, as the demos' beeps are).
    public static func preparePlayback() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        }
        try? session.setActive(true)
        #endif
    }
}
