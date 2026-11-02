import Foundation

/// Decoder for the Google encoded polyline format at precision 5, the format
/// the TMB planner sends in `legGeometry.points` (spec S16).
///
/// Each coordinate is a delta from the running sum, zig-zag encoded in 5-bit
/// chunks ordered least significant first; every chunk is stored as
/// `chunk + 63`, and a chunk with bit 0x20 set means "another chunk follows".
/// Invalid bytes end the scan silently: a broken tail still yields the points
/// decoded before it, which is what a map overlay wants.
enum PolylineDecoder {
    /// Precision 5: one unit is 1e-5 degrees, the Google default and the
    /// format OTP encodes with.
    static let coordinateScale = 1e5

    static func decode(_ encoded: String) -> [GeoPoint] {
        let bytes = Array(encoded.utf8)
        var points: [GeoPoint] = []
        var index = 0
        var latitude = 0
        var longitude = 0

        /// Reads one zig-zag delta, or nil at a truncated or invalid tail.
        func nextDelta() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let chunk = Int(bytes[index]) - 63
                index += 1
                // More than six chunks would overflow the Int32 a precision-5
                // coordinate needs; treat it as corruption.
                guard chunk >= 0, shift < 32 else { return nil }
                // Bit 0x20 is the "another chunk follows" flag, not data.
                result |= (chunk & 0x1F) << shift
                if chunk < 0x20 {
                    // Odd low bit is the sign: odd values are inverted back.
                    let negative = (result & 1) != 0
                    let value = result >> 1
                    return negative ? ~value : value
                }
                shift += 5
            }
            return nil
        }

        while true {
            guard let latitudeDelta = nextDelta() else { break }
            latitude += latitudeDelta
            guard let longitudeDelta = nextDelta() else { break }
            longitude += longitudeDelta
            points.append(
                GeoPoint(
                    latitude: Double(latitude) / coordinateScale,
                    longitude: Double(longitude) / coordinateScale
                )
            )
        }
        return points
    }
}
