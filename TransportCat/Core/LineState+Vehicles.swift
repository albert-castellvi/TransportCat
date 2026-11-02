import Foundation

/// Vehicle lookups over the live line state, for the train sheet and the
/// follow (spec S10). `LineState` already publishes `positions` and `stations`
/// read-only, so this adds only the lookup syntax the sheet needs — it does
/// not change metro behavior and does not touch AppModel.swift.
extension LineState {
    /// The current position of one train by its `TrainPosition.id`, or nil
    /// when the feed no longer reports it. The sheet reads through this on
    /// every render, so it stays live while it is open instead of showing a
    /// snapshot of the tap.
    func vehiclePosition(id: String) -> TrainPosition? {
        positions.first { $0.id == id }
    }

    /// The station of the line with this TMB code, or nil. A line can list
    /// one station twice; the first occurrence in line order answers.
    func station(forCode code: Int) -> Station? {
        stations.first { $0.code == code }
    }
}
