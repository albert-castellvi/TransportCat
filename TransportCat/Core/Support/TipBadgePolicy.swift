import Foundation

/// The three dates the Explora heart icon is decided on (unit `support`).
///
/// Plain values so the rule is a function, not a screen: the policy never
/// reads a clock or a store on its own.
struct TipBadgeDates: Equatable {
    /// When the app was first launched on this device. Recorded at launch, so
    /// the seven days count from the rider installing the app, not from the
    /// first time they open Explora.
    var firstLaunch: Date? = nil
    /// When the icon was last put on screen. `nil` until the first time.
    var lastShown: Date? = nil
    /// When a tip was last bought. Any value silences the icon for good.
    var lastTip: Date? = nil
}

/// When the Explora toolbar may show its occasional heart (unit `support`).
///
/// The rules, in order:
/// 1. Never before seven days since the first launch: a brand-new rider gets
///    the app, not a request.
/// 2. Never again after a tip was bought. The product choice is permanent
///    rather than the alternative 30-day quiet period: someone who already
///    supported the work is not asked a second time.
/// 3. After it has been shown, it stays away for fourteen days.
///
/// Pure: `(firstLaunch, lastShown, lastTip, now)` in, one `Bool` out, so every
/// boundary is an XCTest without a store or a screen.
enum TipBadgePolicy {
    /// Seven days before the first possible appearance.
    static let firstLaunchDelay: TimeInterval = 7 * 24 * 60 * 60
    /// Fourteen days of silence after each appearance.
    static let quietInterval: TimeInterval = 14 * 24 * 60 * 60

    static func isVisible(_ dates: TipBadgeDates, now: Date) -> Bool {
        // No recorded first launch means no basis for the seven days: stay
        // hidden rather than guess.
        guard let firstLaunch = dates.firstLaunch else { return false }
        // Also covers a clock that reads earlier than the recorded launch.
        guard now.timeIntervalSince(firstLaunch) >= firstLaunchDelay else { return false }
        guard dates.lastTip == nil else { return false }
        if let lastShown = dates.lastShown, now.timeIntervalSince(lastShown) < quietInterval {
            return false
        }
        return true
    }
}

/// Persists the three dates `TipBadgePolicy` reads (unit `support`).
///
/// Same storage pattern as the rest of the app's small flags: plain
/// `UserDefaults`, versioned keys, injectable suite. These dates are app-only
/// (no widget or watch reads them), so they live in `.standard`, like
/// `hasSeenOnboarding` and `appMode`, instead of the App Group the favorites
/// use.
///
/// The first launch is written the first time the store is built, which
/// `AppDelegate` does at launch. `shouldShow` writes "shown" only on its first
/// positive answer, so the icon is not re-recorded on every redraw.
final class TipBadgeStore {
    static let shared = TipBadgeStore()

    static let firstLaunchKey = "tipBadge.firstLaunch.v1"
    static let lastShownKey = "tipBadge.lastShown.v1"
    static let lastTipKey = "tipBadge.lastTip.v1"

    /// Debug-only launch argument that replaces the three dates, so a simulator
    /// tour can prove the policy without waiting days:
    ///
    ///     -tipBadgeProbe fresh     (first launch today → hidden)
    ///     -tipBadgeProbe eligible  (first launch eight days ago → visible)
    ///     -tipBadgeProbe recent    (shown yesterday → hidden)
    ///     -tipBadgeProbe tipped    (already supported → hidden)
    ///
    /// A probe never writes to the store: it only answers for that launch.
    static let probeKey = "tipBadgeProbe"

    private let defaults: UserDefaults
    /// A probe answers from memory only; nothing is persisted over it.
    private let isProbe: Bool
    /// Once shown in this run, the icon stays for the run even though the
    /// fourteen-day clock has started.
    private var shownInThisProcess = false

    private(set) var dates: TipBadgeDates

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults

        #if DEBUG
        // The argument domain is shared by every `UserDefaults` instance, so
        // `-tipBadgeProbe eligible` reaches the app whichever suite it uses.
        if let probe = UserDefaults.standard.string(forKey: Self.probeKey),
           let probed = Self.probeDates(probe, now: now) {
            dates = probed
            isProbe = true
            return
        }
        #endif

        isProbe = false
        if let stored = defaults.object(forKey: Self.firstLaunchKey) as? Date {
            dates = TipBadgeDates(
                firstLaunch: stored,
                lastShown: defaults.object(forKey: Self.lastShownKey) as? Date,
                lastTip: defaults.object(forKey: Self.lastTipKey) as? Date
            )
        } else {
            // First launch on this device: record it and stay hidden.
            dates = TipBadgeDates(firstLaunch: now, lastShown: nil, lastTip: nil)
            defaults.set(now, forKey: Self.firstLaunchKey)
        }
    }

    /// Whether Explora may draw the heart now, recording the appearance when
    /// the answer is yes.
    func shouldShow(now: Date = Date()) -> Bool {
        // A bought tip wins over everything, including an icon already shown
        // in this run.
        guard dates.lastTip == nil else { return false }
        if shownInThisProcess { return true }
        guard TipBadgePolicy.isVisible(dates, now: now) else { return false }

        shownInThisProcess = true
        dates.lastShown = now
        if !isProbe {
            defaults.set(now, forKey: Self.lastShownKey)
        }
        return true
    }

    /// Records a completed tip: from here on the icon never comes back.
    func recordTip(now: Date = Date()) {
        dates.lastTip = now
        shownInThisProcess = false
        if !isProbe {
            defaults.set(now, forKey: Self.lastTipKey)
        }
    }

    /// The probe vocabulary, pure so a test can pin every scenario. `nil` for
    /// anything else, which leaves the stored dates in charge.
    static func probeDates(_ probe: String, now: Date) -> TipBadgeDates? {
        let day: TimeInterval = 24 * 60 * 60
        switch probe {
        case "fresh":
            return TipBadgeDates(firstLaunch: now, lastShown: nil, lastTip: nil)
        case "eligible":
            return TipBadgeDates(firstLaunch: now - 8 * day, lastShown: nil, lastTip: nil)
        case "recent":
            return TipBadgeDates(firstLaunch: now - 8 * day, lastShown: now - day, lastTip: nil)
        case "tipped":
            return TipBadgeDates(firstLaunch: now - 8 * day, lastShown: nil, lastTip: now - day)
        default:
            return nil
        }
    }
}
