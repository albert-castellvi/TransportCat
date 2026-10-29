import Foundation

/// A service disruption from the TMB alerts feed
/// (`/v1/alerts/metro/channels/WEB`).
struct ServiceAlert: Identifiable, Hashable {
    let id: String
    /// Affected line codes, normalized to strings ("2", "9N", ...).
    let lineCodes: [String]
    /// Affected station names as listed by TMB.
    let stationNames: [String]
    let beginDate: Date?
    let endDate: Date?
    /// Description text when TMB provides one.
    let text: String?
}
