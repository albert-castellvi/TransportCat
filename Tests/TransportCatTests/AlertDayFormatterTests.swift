import XCTest
@testable import TransportCat

/// #54: the incident day formatters are pinned to the Gregorian calendar and a
/// fixed locale. Inheriting the device's calendar made a Thai Buddhist device
/// render the same validity window as "12/03/2569" instead of "12/03/2026".
///
/// The rendered string cannot show the inherited calendar on a Gregorian
/// device, so the rule is asserted on the formatter's own configuration, which
/// is what the fix sets. `MapScreen` is main-actor isolated, so its formatter
/// is only reachable from tests running on the main actor.
@MainActor
final class AlertDayFormatterTests: XCTestCase {
    func testTheFormatterPinsTheGregorianCalendarAndAFixedLocale() {
        let formatter = MapScreen.alertDayFormatter

        XCTAssertEqual(formatter.calendar.identifier, .gregorian)
        XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(formatter.dateFormat, "dd/MM/yyyy")
    }

    func testItRendersTheGregorianDay() throws {
        let formatter = MapScreen.alertDayFormatter
        // Built in the formatter's own calendar and time zone, so the day the
        // test names is the day it prints.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone ?? .current
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 12))
        )

        XCTAssertEqual(formatter.string(from: date), "12/03/2026")
    }
}
