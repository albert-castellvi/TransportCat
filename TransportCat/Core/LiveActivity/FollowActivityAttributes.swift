import ActivityKit
import Foundation

/// The Live Activity of one followed vehicle (S8).
///
/// Like `ArrivalActivityAttributes`, this file is compiled into both the app
/// and the widget extension: the app starts and updates the activity, the
/// extension draws its lock-screen and Dynamic Island views. Plain value
/// types only — the widget target does not compile Core/Follow, so the mode
/// travels as its raw string and `FollowPlan` is never referenced here.
struct FollowActivityAttributes: ActivityAttributes {
    /// Everything a plan update can change: the next stop with its predicted
    /// arrival, the alight stop with its own arrival, the progress towards
    /// the alight stop, and whether the feed has gone stale.
    struct ContentState: Codable, Hashable {
        /// Name of the next stop; nil once the vehicle has none ahead.
        var nextStopName: String?
        /// Predicted arrival of the next stop; nil without an ETA (FGC, D1).
        var nextArrival: Date?
        /// Name of the chosen alight stop; nil without a choice.
        var alightStopName: String?
        /// Predicted arrival of the alight stop; nil without an ETA (FGC, D1).
        var alightArrival: Date?
        /// 0...1 progress towards the alight stop, by stop count.
        var progress: Double?
        /// The app has stopped confirming the plan; the UI says so instead of
        /// pretending the countdown is live.
        var isStale: Bool
    }

    /// Display line name ("L2", "H12", "S1").
    let lineDisplayName: String
    /// Line color as hex without "#", the same value the app draws.
    let lineColorHex: String
    /// Color that reads on `lineColorHex` ("000000" or "FFFFFF").
    let textColorHex: String
    /// Head sign of the followed vehicle, shown as the terminus.
    let terminus: String
    /// Raw value of the mode ("metro", "bus" or "fgc").
    let mode: String
}
