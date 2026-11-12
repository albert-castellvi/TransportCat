import Foundation

/// Which station markers the metro map draws at a given camera zoom (issue
/// #93).
///
/// Two bands, decided by a pure threshold on the visible latitude span so the
/// rule is testable without SwiftUI or MapKit:
/// - wider than 0.12°: `dots` — stations are 10 pt dots in the line colour,
///   with no capsule and no name, so the default whole-line view of a long
///   line such as L1 (measured at about 0.22° of visible latitude in the
///   simulator on a portrait phone) does not stack the capsules over the
///   trains and the incident marks;
/// - below it: `capsules` — the interchange capsules and hollow dots the map
///   has always drawn.
enum MetroStationBand: Equatable {
    /// Zoomed out: stations as small dots, no capsules, no names.
    case dots
    /// Zoomed in: the full station markers (interchange capsule or hollow
    /// dot) with the annotation name.
    case capsules
}

/// The pure zoom rule behind the metro map's station markers (issue #93).
/// Same shape as `GlobalZoom`: a strict threshold plus a hysteresis margin,
/// so a camera span wobbling around the threshold cannot flip the band — and
/// rebuild the whole map content — on every camera frame.
enum MetroStationZoom {
    /// Above this visible latitude span the stations are dots (issue #93),
    /// calibrated from a simulator measurement (iPhone 17 Pro, portrait): the
    /// whole-line fit of L1 lands around 0.22°, well above it, and a view of
    /// about six stations lands around 0.10°, just below the capsule side of
    /// the hysteresis margin.
    static let dotsAboveDegrees: Double = 0.12

    /// How far past the threshold the span must travel before the band
    /// changes (issue #93): a 4 % margin on the threshold, the same rule
    /// `GlobalZoom` uses.
    static let hysteresisMargin: Double = 0.04

    /// The band for a camera latitude span. The edge itself (exactly 0.12°)
    /// belongs to the capsule band: "wider than" is a strict comparison.
    static func band(forLatitudeSpan span: Double) -> MetroStationBand {
        span > dotsAboveDegrees ? .dots : .capsules
    }

    /// The band for a camera latitude span with hysteresis (issue #93): the
    /// band only changes once the span moves past the crossed threshold by
    /// `hysteresisMargin`; while the span stays inside that margin band,
    /// `previous` wins. Far from the threshold this returns exactly what
    /// `band(forLatitudeSpan:)` returns.
    static func band(
        forLatitudeSpan span: Double,
        previous: MetroStationBand
    ) -> MetroStationBand {
        let dotsExit = dotsAboveDegrees * (1 - hysteresisMargin)
        let dotsEnter = dotsAboveDegrees * (1 + hysteresisMargin)
        switch previous {
        case .dots:
            // Zooming in: keep the dot band until the span is a clear margin
            // below the threshold.
            return span <= dotsExit ? .capsules : .dots
        case .capsules:
            // Zooming out: keep the capsule band until the span is a clear
            // margin above the threshold.
            return span > dotsEnter ? .dots : .capsules
        }
    }
}
