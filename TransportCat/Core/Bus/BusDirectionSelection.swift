import Foundation

/// The direction a bus mode shows, lifted out of the map and diagram screens
/// into one shared storage key (redesign spec S4): the map and the Parades
/// screen now read the same direction the bottom accessory swaps.
///
/// Pure and Foundation-only on purpose: the rule is tested without a UI, and
/// both screens and the accessory call it instead of keeping a second copy of
/// the direction logic (the same pattern `GlobalOperatorSelection` uses for
/// the operator chips).
///
/// The value is persisted as an `Int` under `UserDefaults` key
/// "busDirectionID", holding a TMB `ID_SENTIT` (1 = Anada, 2 = Tornada).
enum BusDirectionSelection {
    /// UserDefaults key of the shared direction (spec S4).
    static let storageKey = "busDirectionID"

    /// The stored direction when it is one of `available`, else the first
    /// available one, else nil.
    static func resolve(stored: Int, available: [Int]) -> Int? {
        if available.contains(stored) { return stored }
        return available.first
    }

    /// The other direction of a two-direction line (the next one in
    /// `available`, wrapping), or `current` when there is only one.
    static func swapped(current: Int, available: [Int]) -> Int {
        // The next entry of `available` after `current`, wrapping around; with
        // `current` not in the list, the first other direction; with nothing
        // else to choose (one direction, or none known yet) the value stays.
        if let index = available.firstIndex(of: current) {
            let next = available[(index + 1) % available.count]
            return next == current ? current : next
        }
        return available.first { $0 != current } ?? current
    }
}
