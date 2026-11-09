import XCTest
@testable import TransportCat

/// Arrival reminder identifiers (spec S13): one id per train and lead time, so
/// two trains of one line to the same destination never replace each other's
/// pending notification.
final class ArrivalReminderTests: XCTestCase {
    private func id(serviceCode: String?, minutesBefore: Int = 5) -> String {
        ArrivalReminder.reminderID(
            placeID: "metroStation:101",
            lineLabel: "L3",
            destination: "Fondo",
            serviceCode: serviceCode,
            minutesBefore: minutesBefore
        )
    }

    /// #46: "Fondo 2 min" and "Fondo 12 min" on one line are two trains. Their
    /// reminders must coexist, and a reminder of the same train at another lead
    /// time must stay a different reminder.
    func testTwoTrainsToTheSameDestinationGetDifferentIDs() {
        XCTAssertNotEqual(id(serviceCode: "120"), id(serviceCode: "121"))
        XCTAssertNotEqual(id(serviceCode: "120"), id(serviceCode: "120", minutesBefore: 3))
    }

    /// The id is stable for the same train, so the bell of the row and the
    /// notification it mirrors always agree.
    func testTheSameTrainAndLeadTimeKeepTheSameID() {
        XCTAssertEqual(id(serviceCode: "120"), id(serviceCode: "120"))
        XCTAssertEqual(id(serviceCode: "120"), "metroStation:101|L3|Fondo|120|5")
    }

    /// No train code in the feed: the destination and the lead time are all
    /// there is to tell the reminders apart.
    func testReminderWithoutATrainCodeStillCarriesTheLeadTime() {
        XCTAssertEqual(id(serviceCode: nil), "metroStation:101|L3|Fondo|-|5")
    }
}
