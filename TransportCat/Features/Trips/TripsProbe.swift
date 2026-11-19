#if DEBUG
import Foundation
import OSLog
import SwiftUI

/// Debug-only launch probes that put the trips feature on screen for a
/// simulator tour, so every surface can be looked at without driving the
/// planner's place pickers by hand. Compiled out of release builds.
///
/// Launch arguments (iOS turns each `-key value` into a default):
///
///     -tripProbe seed    real planner Rocafort → Sant Cugat; starts the first
///                        itinerary with an FGC leg (else the first) and also
///                        adds one habitual (the FGC answer to Sants → Aeroport
///                        T1, else its first answer) and one saved trip
///                        (first non-FGC answer for Rocafort → Pl. Catalunya,
///                        else its first)
///     -tripProbe plan    the same trip started, without the two extra trips
///     -tripsSheet open   presents the trips sheet at launch (`large`: large detent)
///     -plannerProbe open opens the planner on Explora with Rocafort → Sant
///                        Cugat filled in and the search already run
///
/// A seed launch clears its own three seed trips first, so it can run again;
/// the start instant is fresh on every launch.
@MainActor
enum TripsProbe {
    static let tripKey = "tripProbe"
    static let sheetKey = "tripsSheet"
    static let plannerKey = "plannerProbe"

    static let rocafort = GeoPoint(latitude: 41.3787, longitude: 2.1546)
    static let santCugat = GeoPoint(latitude: 41.4730, longitude: 2.0817)
    static let sants = GeoPoint(latitude: 41.3792, longitude: 2.1402)
    static let aeroportT1 = GeoPoint(latitude: 41.2878, longitude: 2.0726)
    static let plazaCatalunya = GeoPoint(latitude: 41.3870, longitude: 2.1701)

    /// Names of the three seed trips, so a later seed launch replaces them.
    static let mainName = "Rocafort → Sant Cugat Centre"
    static let aeroportName = "Sants → Aeroport T1"
    static let catalunyaName = "Rocafort → Pl. Catalunya"

    /// Runs the trip probe. Called once from `RootView`.
    static func runAtLaunch() async {
        guard let probe = arguments[tripKey] else { return }
        guard probe == "seed" || probe == "plan" else {
            note("trips probe: unknown mode \(probe)")
            return
        }
        guard let client = AppModel.shared.client else {
            note("trips probe: no TMB client")
            return
        }

        let store = TripsStore.shared
        // The seed trips are the probe's own: cleared on every launch, so the
        // planner runs again and the sheet shows them fresh. The active trip
        // goes first, since removing it would end the follow anyway.
        store.endActive()
        for trip in store.trips where [mainName, aeroportName, catalunyaName].contains(trip.name) {
            store.remove(id: trip.id)
        }

        do {
            let itineraries = try await client.plan(
                from: rocafort,
                to: santCugat,
                date: Date(),
                arriveBy: false
            )
            let itinerary = itineraries.first(where: { hasFGCLeg($0) }) ?? itineraries.first
            guard let itinerary,
                  let trip = SavedTrip(
                      itinerary: itinerary,
                      originName: "Rocafort",
                      destinationName: "Sant Cugat Centre",
                      origin: rocafort,
                      destination: santCugat,
                      kind: .recent,
                      now: Date()
                  ) else {
                note("trips probe: no itinerary")
                return
            }
            // The active trip is kept as habitual, so the sheet has it in a
            // section of its own once it is no longer the one in course.
            store.save(trip, as: .habitual)
            store.start(trip: trip)
            AppRouter.shared.showActiveTripOnMap()
            note("trips probe started \(trip.name) with \(trip.legs.count) legs")
        } catch {
            note("trips probe: planner failed \(error.localizedDescription)")
            return
        }

        guard probe == "seed" else { return }
        await seedExtras(client: client, store: store)
    }

    /// One more habitual (the FGC answer to Sants → Aeroport T1) and one more
    /// saved trip, so the trips sheet has a row in every section.
    private static func seedExtras(client: TMBClient, store: TripsStore) async {
        if let answer = try? await client.plan(from: sants, to: aeroportT1, date: Date(), arriveBy: false),
           let itinerary = answer.first(where: { hasFGCLeg($0) }) ?? answer.first,
           let trip = SavedTrip(
               itinerary: itinerary,
               originName: "Sants",
               destinationName: "Aeroport T1",
               origin: sants,
               destination: aeroportT1,
               kind: .habitual,
               now: Date()
           ) {
            store.save(trip, as: .habitual)
        } else {
            note("trips probe: no habitual itinerary")
        }

        // A non-FGC answer where there is one: it gives the "Desats i recents"
        // row a different pair of badges from the two FGC ones.
        if let answer = try? await client.plan(from: rocafort, to: plazaCatalunya, date: Date(), arriveBy: false),
           let itinerary = answer.first(where: { !hasFGCLeg($0) }) ?? answer.first,
           let trip = SavedTrip(
               itinerary: itinerary,
               originName: "Rocafort",
               destinationName: "Pl. Catalunya",
               origin: rocafort,
               destination: plazaCatalunya,
               kind: .saved,
               now: Date()
           ) {
            store.save(trip, as: .saved)
        } else {
            note("trips probe: no saved itinerary")
        }
        note("trips probe seeded \(store.trips.count) trips")
    }


    private static func hasFGCLeg(_ itinerary: Itinerary) -> Bool {
        itinerary.legs.contains { leg in
            !leg.isWalk && SavedTrip.operatorKind(agencyName: leg.agencyName, mode: leg.mode) == .fgc
        }
    }

    /// `-tripsSheet open|large`: the trips sheet opens at launch, at that
    /// detent (`open` is medium).
    static var tripsSheetMode: String? {
        arguments[sheetKey]
    }

    /// The pre-filled planner endpoints of `-plannerProbe`, nil without it.
    static var plannerEndpoints: (origin: PlannerEndpoint, destination: PlannerEndpoint)? {
        guard arguments[plannerKey] != nil else { return nil }
        return (
            PlannerEndpoint(label: "Rocafort", position: rocafort),
            PlannerEndpoint(label: "Sant Cugat Centre", position: santCugat)
        )
    }

    private static let log = Logger(subsystem: "cat.transport.app", category: "tripsProbe")

    /// Timestamped breadcrumb in a file inside the app's container, which a
    /// simulator tour's launch cannot lose the way the unified log can.
    private static func note(_ message: String) {
        log.info("\(message)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trips-probe.log")
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? message.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: Data("\(Date().ISO8601Format())  \(message)\n".utf8))
    }

    /// The probe arguments. iOS turns `-key value` into a default only when a
    /// value follows, so the usage above always passes one.
    private static var arguments: [String: String] {
        let defaults = UserDefaults.standard
        var values: [String: String] = [:]
        for key in [tripKey, sheetKey, plannerKey] {
            if let value = defaults.string(forKey: key) {
                values[key] = value
            }
        }
        return values
    }
}

/// What the debug `-plannerProbe` pushes on Explora's stack: the planner with
/// both endpoints filled in, so its search runs on appear.
struct PlannerProbeRoute: Hashable {
    let origin: PlannerEndpoint
    let destination: PlannerEndpoint
}
#endif
