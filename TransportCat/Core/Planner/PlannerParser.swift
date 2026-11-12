import Foundation

/// Parses the TMB planner response and builds its request parameters
/// (`DOC-TMB/planer.json`, spec S16).
///
/// Pure over `Data` and `Date`: no networking, no clock, no locale magic —
/// the request formatting takes the calendar the client passes, so tests pin
/// one. Tolerant like the other TMB parsers: optional documented fields never
/// fail the decode, and one broken leg or itinerary is dropped instead of
/// failing the whole plan.
enum PlannerParser {
    /// Both the transit modes and walking: the planner must be free to chain
    /// metro, bus and tram legs and to walk to and between them.
    static let modes = "TRANSIT,WALK"

    /// OTP error codes that mean "this pair has no route", as opposed to a
    /// server-side failure. Everything else in the documented enum is a
    /// `failed`.
    static let noRouteErrorMessages: Set<String> = [
        "OUTSIDE_BOUNDS",
        "PATH_NOT_FOUND",
        "NO_TRANSIT_TIMES",
        "GEOCODE_FROM_NOT_FOUND",
        "GEOCODE_TO_NOT_FOUND",
        "GEOCODE_FROM_TO_NOT_FOUND",
        "TOO_CLOSE",
        "LOCATION_NOT_ACCESSIBLE",
        "GEOCODE_FROM_AMBIGUOUS",
        "GEOCODE_TO_AMBIGUOUS",
        "GEOCODE_FROM_TO_AMBIGUOUS",
    ]

    // MARK: - Response

    /// Itineraries of a `/plan` response, most-direct-first as OTP orders them.
    ///
    /// Throws `PlannerError.noRoute` when the feed says no path exists (an
    /// error payload from `noRouteErrorMessages` or an empty itinerary list),
    /// `PlannerError.failed` for a server error, and `TMBError
    /// .unexpectedPayload` for a body that is not a planner answer at all.
    static func itineraries(from data: Data) throws -> [Itinerary] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TMBError.unexpectedPayload("planner: not json")
        }
        guard let dict = JSONValue.dictionary(from: root) else {
            throw TMBError.unexpectedPayload("planner: root is not an object")
        }

        // OTP answers 200 with an `error` field when the graph has no plan.
        if let error = JSONValue.dictionary(from: dict["error"]),
           let message = JSONValue.string(from: error["message"]) {
            if noRouteErrorMessages.contains(message) {
                throw PlannerError.noRoute
            }
            throw PlannerError.failed
        }

        guard let plan = JSONValue.dictionary(from: dict["plan"]),
              let rawItineraries = JSONValue.array(from: plan["itineraries"]) else {
            throw TMBError.unexpectedPayload("planner: missing plan")
        }

        let itineraries = rawItineraries.compactMap(itinerary(from:))
        guard !itineraries.isEmpty else {
            throw PlannerError.noRoute
        }
        return itineraries
    }

    private static func itinerary(from any: Any?) -> Itinerary? {
        guard let dict = JSONValue.dictionary(from: any),
              let startTime = JSONValue.dateMilliseconds(from: dict["startTime"]),
              let endTime = JSONValue.dateMilliseconds(from: dict["endTime"]),
              let rawLegs = JSONValue.array(from: dict["legs"]) else { return nil }
        let legs = rawLegs.compactMap(leg(from:))
        guard !legs.isEmpty else { return nil }

        return Itinerary(
            duration: JSONValue.double(from: dict["duration"])
                ?? endTime.timeIntervalSince(startTime),
            startTime: startTime,
            endTime: endTime,
            walkTime: JSONValue.double(from: dict["walkTime"]) ?? 0,
            transfers: JSONValue.int(from: dict["transfers"]) ?? 0,
            legs: legs
        )
    }

    private static func leg(from any: Any?) -> Leg? {
        guard let dict = JSONValue.dictionary(from: any),
              let startTime = JSONValue.dateMilliseconds(from: dict["startTime"]),
              let endTime = JSONValue.dateMilliseconds(from: dict["endTime"]),
              let mode = JSONValue.string(from: dict["mode"]),
              let from = legPlace(from: dict["from"]),
              let to = legPlace(from: dict["to"]) else { return nil }

        let stops = JSONValue.array(from: dict["intermediateStops"])?.compactMap(legStop(from:)) ?? []
        let geometry: [GeoPoint]
        if let geometryDict = JSONValue.dictionary(from: dict["legGeometry"]),
           let points = JSONValue.string(from: geometryDict["points"]) {
            geometry = PolylineDecoder.decode(points)
        } else {
            geometry = []
        }
        // OTP walks are mode "WALK"; every other mode in a TMB plan (SUBWAY,
        // BUS, TRAM, RAIL) is a ride. Reading the flag instead would need
        // boolean parsing, which the tolerant `JSONValue` helpers do not
        // cover portably.
        let transitLeg = mode != "WALK"

        return Leg(
            startTime: startTime,
            endTime: endTime,
            mode: mode,
            // `routeShortName` is the line code ("V1"); `route` can carry the
            // line description for bus legs, so it is only the fallback (#96).
            route: JSONValue.string(from: dict["routeShortName"])
                ?? JSONValue.string(from: dict["route"]),
            routeLongName: JSONValue.string(from: dict["routeLongName"]),
            routeColorHex: normalizedColor(JSONValue.string(from: dict["routeColor"])),
            routeTextColorHex: normalizedColor(JSONValue.string(from: dict["routeTextColor"])),
            headsign: JSONValue.string(from: dict["headsign"]),
            agencyName: JSONValue.string(from: dict["agencyName"]),
            distance: JSONValue.double(from: dict["distance"]),
            from: from,
            to: to,
            intermediateStops: stops,
            geometry: geometry,
            isTransit: transitLeg
        )
    }

    private static func legPlace(from any: Any?) -> LegPlace? {
        guard let dict = JSONValue.dictionary(from: any),
              let point = coordinate(from: dict) else { return nil }
        return LegPlace(name: JSONValue.string(from: dict["name"]) ?? "", position: point)
    }

    private static func legStop(from any: Any?) -> LegStop? {
        guard let dict = JSONValue.dictionary(from: any),
              let point = coordinate(from: dict) else { return nil }
        return LegStop(
            name: JSONValue.string(from: dict["name"]) ?? "",
            code: JSONValue.string(from: dict["stopCode"]),
            position: point
        )
    }

    private static func coordinate(from place: [String: Any]) -> GeoPoint? {
        guard let latitude = JSONValue.double(from: place["lat"]),
              let longitude = JSONValue.double(from: place["lon"]) else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// OTP publishes colors with a leading "#"; the app's `Color(hex:)` and
    /// `MetroLine.colorHex` shapes have none.
    private static func normalizedColor(_ hex: String?) -> String? {
        guard let hex else { return nil }
        return hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    }

    // MARK: - Request

    /// Query pairs for `GET /plan`, in the documented formats: coordinates as
    /// "lat,lon", the date as mm-DD-YYYY, the time as a 12-hour clock with a
    /// lowercase am/pm ("11:58am"), `arriveBy` as a "true"/"false" string and
    /// the modes as a comma-separated OTP list. All values are URL-safe by
    /// construction (digits, letters, dot, comma, hyphen, colon).
    static func requestParameters(
        from: GeoPoint,
        to: GeoPoint,
        date: Date,
        arriveBy: Bool,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [(name: String, value: String)] {
        var query: [(name: String, value: String)] = [
            ("fromPlace", placeString(from)),
            ("toPlace", placeString(to)),
            ("date", dateString(for: date, calendar: calendar)),
            ("time", timeString(for: date, calendar: calendar)),
            ("arriveBy", arriveBy ? "true" : "false"),
            ("mode", modes),
            // The itinerary detail lists the intermediate stops, so ask for
            // them up front instead of planning twice.
            ("showIntermediateStops", "true"),
        ]
        query.sort { $0.name < $1.name }
        return query
    }

    /// Locale that keeps `%f` a dot decimal: on the device's Catalan locale the
    /// default formatting would turn "41.387300" into "41,387300" and OTP
    /// would read the pair as garbage.
    private static let formatLocale = Locale(identifier: "en_US_POSIX")

    static func placeString(_ point: GeoPoint) -> String {
        String(format: "%.6f,%.6f", locale: Self.formatLocale, point.latitude, point.longitude)
    }

    static func dateString(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%02d-%02d-%04d",
            locale: Self.formatLocale,
            components.month ?? 1,
            components.day ?? 1,
            components.year ?? 1970
        )
    }

    /// 12-hour OTP clock: no leading zero on the hour, "12am" midnight and
    /// "12pm" noon, lowercase marker — the documented "11:58am" shape.
    static func timeString(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let marker = hour < 12 ? "am" : "pm"
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d%@", locale: Self.formatLocale, hour12, minute, marker)
    }

    // MARK: - Map

    /// Inclusive geographic bounds of a point set, used to frame the detail
    /// map around the whole route. Nil when there is nothing to frame.
    static func bounds(of points: [GeoPoint]) -> (
        minLatitude: Double, maxLatitude: Double,
        minLongitude: Double, maxLongitude: Double
    )? {
        guard let first = points.first else { return nil }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for point in points.dropFirst() {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
        return (minLatitude, maxLatitude, minLongitude, maxLongitude)
    }
}
