import Foundation

/// Pure decision of where the metro markers come from (schedule S6 extended
/// by spec S21): the timetable draws the fleet when the live feed has no
/// trains *or* the device is offline, but only when there actually is a
/// timetable and a geometry to place trains on.
///
/// Kept free of actors and frameworks so the rule itself runs in the
/// Foundation-only test harness; `LineState` supplies the inputs.
enum FleetSourceRule {
    static func useTheoreticalFleet(
        isFeedEmpty: Bool,
        isOffline: Bool,
        hasSchedule: Bool,
        hasEngine: Bool
    ) -> Bool {
        (isFeedEmpty || isOffline) && hasSchedule && hasEngine
    }
}
