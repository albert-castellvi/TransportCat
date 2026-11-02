import ActivityKit
import Foundation

/// The Live Activity of one tracked arrival (spec S20).
///
/// The file is compiled into both the app and the widget extension: the app
/// starts and updates the activity, the extension draws its lock-screen and
/// Dynamic Island views. Everything that does not change while the activity
/// lives (line, colors, place and destination) is a static attribute; the
/// countdown itself lives in `ContentState`.
struct ArrivalActivityAttributes: ActivityAttributes {
    /// Everything a refresh can change: the expected arrival, its rounded
    /// countdown and whether the feed has gone stale.
    struct ContentState: Codable, Hashable {
        /// Expected arrival. The `Text(timerInterval:)` countdown ends here.
        var arrivalDate: Date
        /// Minutes left as the feed announced them, when it announces any.
        var minutes: Int?
        /// The app has stopped confirming the arrival; the UI says so instead
        /// of pretending the countdown is live.
        var isStale: Bool
    }

    /// `Place.id` ("metroStation:128"), so an update can find the activity of
    /// the place the rider is looking at.
    let placeID: String
    /// Station or stop name, e.g. "Catalunya".
    let placeName: String
    /// Map/API line code ("1", "212", "S1"), kept to match refreshed arrivals.
    let lineCode: String
    /// Display line name ("L1", "H12", "S1").
    let lineName: String
    /// Line color as hex without "#", the same value the app draws.
    let lineColorHex: String
    /// Color that reads on `lineColorHex` ("000000" or "FFFFFF").
    let textColorHex: String
    /// Head sign of the tracked train or bus.
    let destination: String
}
