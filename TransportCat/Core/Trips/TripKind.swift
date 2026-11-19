import Foundation

/// How a saved trip earned its place (spec S4), from the most to the least
/// prominent in the trips pill: habitual trips are the ones the rider pinned,
/// saved ones the ones they kept, recent ones the planner recorded.
enum TripKind: String, Codable, CaseIterable {
    case habitual
    case saved
    case recent

    /// Position in the trips list; a trip never moves down on its own.
    var rank: Int {
        switch self {
        case .habitual: return 0
        case .saved: return 1
        case .recent: return 2
        }
    }
}
