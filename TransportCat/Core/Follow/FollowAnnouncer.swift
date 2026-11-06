import Foundation

/// Speaks follow announcements in Catalan, in the foreground only (S10).
///
/// CONTRACT (T0): the members below are fixed. T2 implements them over
/// `AVSpeechSynthesizer` (`ca-ES` voice, `.playback` + `.duckOthers`).
@MainActor
final class FollowAnnouncer {
    static let shared = FollowAnnouncer()

    /// Speaks the sentence, interrupting any sentence still being spoken.
    func speak(_ text: String) {}

    /// Silences speech immediately (S9).
    func stop() {}
}
