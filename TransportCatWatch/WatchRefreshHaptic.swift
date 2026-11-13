import WatchKit

/// The tap feedback of the reload row (reviews W12, W17).
///
/// watchOS has no pull-to-refresh and the row lives at the bottom of the list, so
/// the wrist has to say what happened without asking the rider to read: the
/// numbers moved, the answer was the same as before, or the feeds could not be
/// reached at all (review W3).
enum WatchRefreshHaptic {
    static func play(changed: Bool, failed: Bool) {
        if failed {
            WKInterfaceDevice.current().play(.failure)
        } else {
            WKInterfaceDevice.current().play(changed ? .success : .click)
        }
    }
}
