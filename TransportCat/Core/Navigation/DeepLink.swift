import Foundation

/// The app's one deep link (spec S20): `transportcat://place/<kind>/<code>?name=<name>`.
///
/// Foundation-only and UI-free, so the widget extension builds the URL, the
/// app parses it, and the rules are testable without either. The place catalog
/// is deliberately not consulted here: a widget tap must open a station on a
/// cold launch, before the catalog has loaded, so the name travels with the
/// link and the caller resolves the catalog copy when it has one.
enum DeepLink {
    static let scheme = "transportcat"
    /// Host of the one route there is. A host instead of a path prefix keeps
    /// `URL.host` a cheap first check while parsing.
    static let placeHost = "place"

    /// What a link asks the app to open.
    struct Target: Equatable {
        let kind: PlaceKind
        /// `Place.code`: the TMB `ID_ESTACIO`, the bus `CODI_PARADA` or the
        /// FGC initials.
        let code: String
        /// Station or stop name carried by the link, when it had one.
        let name: String?
    }

    /// The link of a place, for a widget row, a board or the Live Activity.
    static func url(for place: Place) -> URL? {
        url(kind: place.kind, code: place.code, name: place.name)
    }

    /// The link of a place identity. Nil only when the arguments cannot form a
    /// URL at all (an empty code), so callers can skip the `Link` instead of
    /// opening a wrong place.
    ///
    /// The code is a path component and the name a query item, never
    /// `Place.id`: the id is "<kind>:<code>" and a bare ":" in a URL host is
    /// not portable.
    static func url(kind: PlaceKind, code: String, name: String?) -> URL? {
        guard !code.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = placeHost
        components.path = "/\(kind.rawValue)/\(code)"
        if let name, !name.isEmpty {
            components.queryItems = [URLQueryItem(name: "name", value: name)]
        }
        return components.url
    }

    /// The target of a link, or nil when it is not one of ours.
    static func target(from url: URL) -> Target? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == placeHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, let kind = PlaceKind(rawValue: String(parts[0])) else {
            return nil
        }
        let code = String(parts[1])
        guard !code.isEmpty else { return nil }

        let name = components.queryItems?
            .first { $0.name == "name" }?
            .value
            .flatMap { $0.isEmpty ? nil : $0 }
        return Target(kind: kind, code: code, name: name)
    }
}
