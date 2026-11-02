import AppIntents
import Foundation

/// "Properes arribades" (spec S15): answers the next three arrivals of a
/// place with a spoken dialog. It runs headless from Siri, Shortcuts and the
/// future widget, so it touches nothing but Core types and the bundle's own
/// TMB credentials.
struct NextArrivalsIntent: AppIntent {
    static var title: LocalizedStringResource = "Properes arribades"
    static var description = IntentDescription(
        "Consulta les properes arribades a una estació de metro o FGC, o a una parada d'autobús."
    )

    /// The fetch needs no UI; running it without opening the app is the point.
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Lloc")
    var place: PlaceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        guard let client = try? TMBClient.fromBundle() else {
            // A build without TMB credentials cannot answer; the same calm
            // empty state the dialog uses for a feed with nothing incoming.
            return .result(dialog: NextArrivalsFetcher.noArrivalsText)
        }
        let arrivals = await NextArrivalsFetcher.nextArrivals(
            for: place.place,
            client: client,
            now: now
        )
        return .result(
            dialog: NextArrivalsFetcher.dialog(for: place.place, arrivals: arrivals, now: now)
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Properes arribades a \(\.$place)")
    }
}
