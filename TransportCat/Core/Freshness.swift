import Foundation

/// How old the data on screen is, from the rider's point of view (spec S2).
///
/// The app polls i-Metro every 20 s, so a feed that has not answered for a
/// while still shows plausible markers. The level tells the difference between
/// "live" and "what you see is the last thing we got".
enum DataFreshness: Equatable {
    /// A successful update within the last 30 s.
    case live
    /// An update between 30 and 90 s old, or a failed attempt after a live one.
    case delayed
    /// 90 s or more without an update.
    case stale
    /// No successful update yet, or no feed for this line at all.
    case unavailable
}

/// Thresholds and wording for `DataFreshness` (spec S2, S3).
///
/// Foundation only on purpose: the rules decide what the map and the diagram
/// claim about the data, so they are tested without a UI.
enum Freshness {
    /// Age from which a successful update stops counting as live.
    static let delayedAfter: TimeInterval = 30
    /// Age from which data is considered stale.
    static let staleAfter: TimeInterval = 90

    /// Level for the given last successful update.
    ///
    /// - `lastUpdate` nil means no update has ever arrived: `.unavailable`.
    /// - A failed last attempt only downgrades, and only `.live` to `.delayed`:
    ///   one dropped poll is not evidence that the data went away, so
    ///   `.stale` and `.unavailable` keep saying what the age already says.
    static func level(lastUpdate: Date?, now: Date, lastAttemptFailed: Bool) -> DataFreshness {
        guard let lastUpdate else { return .unavailable }
        let age = now.timeIntervalSince(lastUpdate)
        let level: DataFreshness
        if age < delayedAfter {
            level = .live
        } else if age < staleAfter {
            level = .delayed
        } else {
            level = .stale
        }
        if lastAttemptFailed, level == .live {
            return .delayed
        }
        return level
    }

    /// Human age in Catalan for the freshness chip (spec S7), e.g. "ara mateix",
    /// "fa 12 s", "fa 2 min", "fa 1 h".
    ///
    /// Whole units, truncated: 59.9 s reads "fa 59 s", never a rounded "fa 1 min".
    /// A clock skew that puts `since` in the future counts as 0, not negative.
    static func ageText(since: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(since))
        if age < 5 {
            return "ara mateix"
        }
        if age < 60 {
            return "fa \(Int(age)) s"
        }
        if age < 3600 {
            return "fa \(Int(age / 60)) min"
        }
        return "fa \(Int(age / 3600)) h"
    }
}
