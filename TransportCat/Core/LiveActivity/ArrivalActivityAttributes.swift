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
    /// Everything a refresh can change. The countdown is derived from the
    /// arrival date when the view is drawn, so it can never contradict the
    /// date a refresh moved.
    struct ContentState: Codable, Hashable {
        /// Expected arrival.
        var arrivalDate: Date
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

    // MARK: - The place, read back from its id

    /// What kind of place the activity tracks, parsed from `placeID`. Nil when
    /// the id is not one this build writes.
    var placeKind: PlaceKind? {
        guard let raw = placeID.split(separator: ":", maxSplits: 1).first else { return nil }
        return PlaceKind(rawValue: String(raw))
    }

    /// The operator code of the place (`ID_ESTACIO`, `CODI_PARADA`, FGC
    /// initials), parsed from `placeID`.
    var placeCode: String {
        guard let code = placeID.split(separator: ":", maxSplits: 1).last else { return placeID }
        return String(code)
    }

    /// Where tapping the activity takes the rider (F4).
    var placeURL: URL? {
        placeKind.flatMap { DeepLink.url(kind: $0, code: placeCode, name: placeName) }
    }

    /// "estació" or "parada", so the spoken sentence names the right thing.
    var placeWord: String {
        placeKind == .busStop ? "parada" : "estació"
    }
}
