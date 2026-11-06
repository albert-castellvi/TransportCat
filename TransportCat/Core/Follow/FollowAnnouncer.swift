import Foundation

#if canImport(AVFoundation)
import AVFoundation

/// Speaks follow announcements in Catalan, in the foreground only (S10).
///
/// The app declares no background audio mode, so speech stays foreground:
/// the audio session is activated per utterance with `.playback` +
/// `.duckOthers` so the rider's music dips, and deactivated with
/// `.notifyOthersOnDeactivation` when the utterance ends so other apps
/// resume. Every activation is best effort — the announcement is also on the
/// card, so a refused session costs nothing.
@MainActor
final class FollowAnnouncer {
    static let shared = FollowAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate: SpeechDelegate
    /// Whether the session was activated and still needs deactivation.
    private var isSessionActive = false

    private init() {
        let delegate = SpeechDelegate { [weak self] in self?.sessionDidFinish() }
        self.delegate = delegate
        synthesizer.delegate = delegate
    }

    /// Speaks the sentence, interrupting any sentence still being spoken.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        activateSession()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        // Catalan when the system provides it; otherwise the default voice.
        utterance.voice = AVSpeechSynthesisVoice(language: "ca-ES")
            ?? AVSpeechSynthesisVoice(language: nil)
        synthesizer.speak(utterance)
    }

    /// Silences speech immediately (S9).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
    }

    // MARK: - Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            isSessionActive = true
        } catch {
            isSessionActive = false
        }
    }

    private func deactivateSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func sessionDidFinish() {
        // An interrupted utterance is followed by the next one when the next
        // stop announces mid-speech; only a silent synthesizer releases the
        // session so other apps resume.
        guard !synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        deactivateSession()
    }
}

/// `AVSpeechSynthesizerDelegate` calls its methods off the main actor, so the
/// delegate is its own object and hops back for the announcer's finish work.
/// `AVSpeechSynthesizer` holds its delegate weakly; the announcer keeps the
/// strong reference alive.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @MainActor @escaping () -> Void) {
        self.onFinish = onFinish
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in onFinish() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in onFinish() }
    }
}
#endif
