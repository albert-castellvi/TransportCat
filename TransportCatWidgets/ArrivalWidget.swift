import AppIntents
import SwiftUI
import WidgetKit

/// Configuration of the "Properes arribades" widget: places chosen with the
/// same `PlaceEntity` Shortcuts uses (spec S20).
struct ArrivalWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Properes arribades"
    static var description = IntentDescription(
        "Tria estacions de metro o FGC, o parades d'autobús."
    )

    @Parameter(title: "Estació o parada")
    var place: PlaceEntity?

    /// Extra places for the medium and large sizes. `place` stays as the
    /// first one so widgets configured before keep their station.
    @Parameter(title: "Més parades")
    var morePlaces: [PlaceEntity]?
}

/// Reloads the widget from its own button. Running any intent from a widget
/// makes WidgetKit ask for a new timeline, so `perform` has nothing to do.
struct ReloadArrivalsIntent: AppIntent {
    static var title: LocalizedStringResource = "Actualitza les arribades"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// One place of the widget with what the feeds answered for it.
struct PlaceBoard: Hashable {
    let place: Place
    /// Nil when no feed could be reached: a different statement from an empty
    /// list, which means the feeds answered and nothing is coming (F2).
    let arrivals: [NextArrival]?

    var name: String { place.name }
}

/// One widget render: the boards as fetched at `fetched`, drawn for `date`.
/// A fetch yields many entries with the same boards, so the rows advance as
/// trains leave without another fetch.
struct ArrivalEntry: TimelineEntry {
    let date: Date
    let fetched: Date
    /// Empty until the rider configures the widget and has no favourite places
    /// to stand in for the configuration.
    let boards: [PlaceBoard]

    /// Placeholder and preview data.
    static var sample: ArrivalEntry {
        let now = Date()
        func arrival(_ line: String, _ destination: String, _ minutes: Double) -> NextArrival {
            NextArrival(line: line, destination: destination, date: now.addingTimeInterval(minutes * 60))
        }
        return ArrivalEntry(
            date: now,
            fetched: now,
            boards: [
                PlaceBoard(
                    place: Place(
                        kind: .metroStation,
                        code: "128",
                        name: "Catalunya",
                        position: GeoPoint(latitude: 41.385, longitude: 2.170),
                        lineCodes: ["L1", "L3"],
                        accessible: nil
                    ),
                    arrivals: [
                        arrival("L1", "Fondo", 2),
                        arrival("L3", "Zona Universitària", 4),
                        arrival("L1", "Fondo", 6),
                        arrival("L3", "Zona Universitària", 9),
                    ]
                ),
                PlaceBoard(
                    place: Place(
                        kind: .metroStation,
                        code: "127",
                        name: "Diagonal",
                        position: GeoPoint(latitude: 41.395, longitude: 2.160),
                        lineCodes: ["L3", "L5"],
                        accessible: nil
                    ),
                    arrivals: [
                        arrival("L5", "Vall d'Hebron", 3),
                        arrival("L3", "Trinitat Nova", 5),
                        arrival("L5", "Vall d'Hebron", 8),
                    ]
                ),
            ]
        )
    }

    /// The shape shown before a place is chosen.
    static var needsPlace: ArrivalEntry {
        let now = Date()
        return ArrivalEntry(date: now, fetched: now, boards: [])
    }
}

/// Fetches arrivals for the configured places and refreshes every five
/// minutes (spec S20). The widget talks to TMB and FGC directly, with the
/// credentials injected into its own Info.plist.
struct ArrivalTimelineProvider: AppIntentTimelineProvider {
    /// Spec S20: the widget refreshes itself every five minutes.
    static let refreshInterval: TimeInterval = 5 * 60
    /// Arrivals asked per place: enough for a next and a following train on
    /// every line and direction of a big interchange.
    static let arrivalsPerPlace = 16

    /// One client per process. It caches the per-line station feed the
    /// place-code bridge needs, so a reload does not download the same
    /// topology again for every place and line (F11).
    private static let client: TMBClient? = try? TMBClient.fromBundle()

    /// Places a family has room for.
    static func maxPlaces(for family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: return 2
        case .systemLarge: return 4
        default: return 1
        }
    }

    func placeholder(in context: Context) -> ArrivalEntry {
        .sample
    }

    func snapshot(for configuration: ArrivalWidgetConfiguration, in context: Context) async -> ArrivalEntry {
        if context.isPreview { return .sample }
        return await entry(for: configuration, family: context.family)
    }

    func timeline(for configuration: ArrivalWidgetConfiguration, in context: Context) async -> Timeline<ArrivalEntry> {
        let first = await entry(for: configuration, family: context.family)
        let entries = ArrivalBoard.entryDates(from: first.fetched).map {
            ArrivalEntry(date: $0, fetched: first.fetched, boards: first.boards)
        }
        return Timeline(
            entries: entries,
            policy: .after(first.fetched.addingTimeInterval(Self.refreshInterval))
        )
    }

    /// Boards of the places the rider chose, in that order, or of their
    /// favourite places until they choose one (F10).
    private func entry(for configuration: ArrivalWidgetConfiguration, family: WidgetFamily) async -> ArrivalEntry {
        let now = Date()
        let places = Self.places(for: configuration, family: family)
        guard !places.isEmpty else { return .needsPlace }

        guard let client = Self.client else {
            // A build without credentials cannot answer at all; say so instead
            // of claiming there is nothing coming (F2).
            return ArrivalEntry(
                date: now,
                fetched: now,
                boards: places.map { PlaceBoard(place: $0, arrivals: nil) }
            )
        }

        var boards: [PlaceBoard] = []
        for place in places {
            let outcome = await NextArrivalsFetcher.outcome(
                for: place,
                client: client,
                now: now,
                limit: Self.arrivalsPerPlace
            )
            switch outcome {
            case .answered(let arrivals):
                boards.append(PlaceBoard(place: place, arrivals: arrivals))
            case .unreachable:
                boards.append(PlaceBoard(place: place, arrivals: nil))
            }
        }
        return ArrivalEntry(date: now, fetched: now, boards: boards)
    }

    /// The configured places, deduplicated and cut to what the family draws.
    /// The rider's favourite places stand in until a place is configured, so a
    /// freshly added widget shows real arrivals instead of an instruction.
    private static func places(for configuration: ArrivalWidgetConfiguration, family: WidgetFamily) -> [Place] {
        var seen: Set<String> = []
        let configured = ([configuration.place].compactMap { $0 } + (configuration.morePlaces ?? []))
            .filter { seen.insert($0.id).inserted }
            .map(\.place)
        let chosen = configured.isEmpty
            ? FavoritesStore().favoritePlaces.filter { seen.insert($0.id).inserted }
            : configured
        return Array(chosen.prefix(maxPlaces(for: family)))
    }
}

/// The "Properes arribades" widget (spec S20): small, medium, large and
/// lock-screen rectangular.
struct ArrivalWidget: Widget {
    static let kind = "ArrivalWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: ArrivalWidgetConfiguration.self,
            provider: ArrivalTimelineProvider()
        ) { entry in
            ArrivalWidgetView(entry: entry)
        }
        .configurationDisplayName("Properes arribades")
        .description("Les properes arribades a les teves estacions i parades.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}
