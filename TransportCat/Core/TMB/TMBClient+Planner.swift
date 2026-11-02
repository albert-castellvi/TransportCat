import Foundation

/// Trip planner endpoint of the TMB API (spec S16).
///
/// The planner lives under `/v1/planner` (`DOC-TMB/planer.json`): the same
/// `app_id`/`app_key` credentials as every other TMB service, and OTP-style
/// query parameters documented in `PlannerParser.requestParameters`. It
/// travels through `TMBClient.get`, so timeouts, status mapping and credential
/// redaction are shared.
extension TMBClient {
    /// Itineraries from `from` to `to` around `date`.
    ///
    /// `arriveBy` flips the meaning of `date`: with `false` the rider
    /// departs at that time ("Surt a les…"), with `true` they must be there
    /// by then ("Arriba a les…"). "Surt ara" is simply `date: Date()` with
    /// `arriveBy: false`. The date and time are read in `date`'s calendar —
    /// the graph itself plans in Europe/Madrid, the only zone TMB covers.
    ///
    /// Throws `PlannerError.noRoute` when the network has no path, and
    /// `PlannerError.failed` when the planner service itself breaks; other
    /// errors (transport, bad payload) pass through untouched.
    func plan(
        from: GeoPoint,
        to: GeoPoint,
        date: Date,
        arriveBy: Bool
    ) async throws -> [Itinerary] {
        let query = PlannerParser.requestParameters(
            from: from,
            to: to,
            date: date,
            arriveBy: arriveBy
        )
        .map { "\($0.name)=\($0.value)" }
        .joined(separator: "&")
        // GET /planner/plan (OpenTripPlanner), on the shared /v1 base URL.
        let data = try await get(path: "planner/plan?\(query)")
        return try PlannerParser.itineraries(from: data)
    }
}
