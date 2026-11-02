import AppIntents
import SwiftUI
import WidgetKit

/// Configuration of the "Properes arribades" widget: one place chosen with the
/// same `PlaceEntity` Shortcuts uses (spec S20).
struct ArrivalWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Properes arribades"
    static var description = IntentDescription(
        "Tria una estació de metro o FGC, o una parada d'autobús."
    )

    @Parameter(title: "Estació o parada")
    var place: PlaceEntity?
}

/// One widget render: the place, the arrivals already fetched, and whether a
/// place has been chosen at all (spec S20).
struct ArrivalEntry: TimelineEntry {
    let date: Date
    /// nil until the rider configures the widget.
    let placeName: String?
    let arrivals: [NextArrival]

    var hasPlace: Bool { placeName != nil }

    /// Placeholder and preview data: a station with two sample trains.
    static let sample = ArrivalEntry(
        date: Date(),
        placeName: "Catalunya",
        arrivals: [
            NextArrival(
                line: "L1",
                destination: "Fondo",
                date: Date().addingTimeInterval(2 * 60)
            ),
            NextArrival(
                line: "L3",
                destination: "Zona Universitària",
                date: Date().addingTimeInterval(5 * 60)
            ),
        ]
    )

    /// The shape shown before a place is chosen.
    static let needsPlace = ArrivalEntry(date: Date(), placeName: nil, arrivals: [])
}

/// Fetches arrivals for the configured place and refreshes every five minutes
/// (spec S20). The widget talks to TMB and FGC directly, with the credentials
/// injected into its own Info.plist; no App Group is involved.
struct ArrivalTimelineProvider: AppIntentTimelineProvider {
    /// Spec S20: the widget refreshes itself every five minutes.
    static let refreshInterval: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> ArrivalEntry {
        .sample
    }

    func snapshot(for configuration: ArrivalWidgetConfiguration, in context: Context) async -> ArrivalEntry {
        if context.isPreview { return .sample }
        return await entry(for: configuration)
    }

    func timeline(for configuration: ArrivalWidgetConfiguration, in context: Context) async -> Timeline<ArrivalEntry> {
        let entry = await entry(for: configuration)
        return Timeline(
            entries: [entry],
            policy: .after(Date().addingTimeInterval(Self.refreshInterval))
        )
    }

    /// Arrivals of the configured place. A build without credentials, a
    /// failing feed or an unresolved entity all land on the same empty state.
    private func entry(for configuration: ArrivalWidgetConfiguration) async -> ArrivalEntry {
        guard let entity = configuration.place else { return .needsPlace }
        let place = entity.place
        let now = Date()

        var arrivals: [NextArrival] = []
        if let client = try? TMBClient.fromBundle() {
            arrivals = await NextArrivalsFetcher.nextArrivals(
                for: place,
                client: client,
                now: now
            )
        }
        return ArrivalEntry(date: now, placeName: place.name, arrivals: arrivals)
    }
}

/// The "Properes arribades" widget (spec S20): small, medium and lock-screen
/// rectangular.
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
        .description("Les properes arribades a una estació o parada.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
