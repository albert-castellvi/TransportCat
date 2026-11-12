import AppIntents
import Foundation

/// A transport place as an App Entity (spec S15): searchable in Shortcuts and
/// usable by the future widget extension. It carries the whole `Place` inside,
/// so resolving an arrival query never needs the catalog again, and nothing
/// here references the view layer.
struct PlaceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        TypeDisplayRepresentation(name: "Lloc")

    static let defaultQuery = PlaceEntityQuery()

    /// `Place.id`: "<kind>:<code>".
    var id: String
    var kind: PlaceKind
    var code: String
    var name: String
    var lineCodes: [String]
    var latitude: Double
    var longitude: Double

    init(place: Place) {
        id = place.id
        kind = place.kind
        code = place.code
        name = place.name
        lineCodes = place.lineCodes
        latitude = place.position.latitude
        longitude = place.position.longitude
    }

    var displayRepresentation: DisplayRepresentation {
        if lineCodes.isEmpty {
            return DisplayRepresentation(title: "\(name)")
        }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(lineCodes.joined(separator: " · "))"
        )
    }

    /// The Core value the fetchers work with.
    var place: Place {
        Place(
            kind: kind,
            code: code,
            name: name,
            position: GeoPoint(latitude: latitude, longitude: longitude),
            lineCodes: lineCodes,
            accessible: nil
        )
    }
}

/// Search over the place catalog with the favorite places as suggested values
/// (spec S15). The catalog is loaded lazily: warm in the app, and in an
/// extension falling back to its own cache and then to one network load.
struct PlaceEntityQuery: EntityStringQuery {
    private static let searchLimit = 10

    func entities(for identifiers: [PlaceEntity.ID]) async throws -> [PlaceEntity] {
        let places = await Self.readyPlaces()
        let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }.map(PlaceEntity.init(place:))
    }

    func entities(matching string: String) async throws -> [PlaceEntity] {
        let places = await Self.readyPlaces()
        return PlaceIndex
            .search(query: string, places: places, limit: Self.searchLimit)
            .map(PlaceEntity.init(place:))
    }

    func suggestedEntities() async throws -> [PlaceEntity] {
        // A fresh read of the shared group: the app mutates its own instance, so
        // this neither reuses a stale snapshot nor touches main-actor state.
        FavoritesStore().favoritePlaces
            .prefix(Self.searchLimit)
            .map(PlaceEntity.init(place:))
    }

    @MainActor
    private static func readyPlaces() async -> [Place] {
        let store = PlaceCatalogStore.shared
        if store.places.isEmpty {
            store.loadFromCache()
        }
        if store.places.isEmpty, let client = try? TMBClient.fromBundle() {
            await store.load(client: client)
        }
        return store.places
    }
}
