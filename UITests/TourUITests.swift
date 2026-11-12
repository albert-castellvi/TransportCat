import XCTest

/// Remote hands for a headless dev Mac: drives the real app in the simulator
/// from a step list, so a change can be looked at over SSH. Local only — the
/// `TransportCatTour` scheme is never run by CI.
///
/// Steps come from the `TOUR` environment variable (pass it to `xcodebuild`
/// as `TEST_RUNNER_TOUR`), separated by `;`:
///
///     tap:<label or identifier>   tap the first element whose label contains the text
///     tapxy:<x>,<y>               tap a normalized screen point (0...1)
///     press:<x>,<y>               long-press a normalized screen point
///     sbtap:<label>               tap a SpringBoard element (permission alert, banner)
///     home / notifications / activate   go home, pull the notification centre, return to the app
///     pinch:<scale>               pinch the map (above 1 zooms in)
///     type:<text>                 type into the focused field
///     swipe:<up|down|left|right>  swipe the middle of the screen
///     wait:<seconds>
///     shot:<name>                 PNG into TOUR_DIR (default /tmp/tc-tour)
///     tree:<name>                 accessibility tree into TOUR_DIR, to find labels
///
/// `TOUR_ARGS` holds launch arguments, e.g. `-appMode bus`.
final class TourUITests: XCTestCase {
    func testTour() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = (environment["TOUR_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launch()

        let directory = URL(fileURLWithPath: environment["TOUR_DIR"] ?? "/tmp/tc-tour")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for step in (environment["TOUR"] ?? "wait:3;shot:launch").split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "tap":
                // Buttons first: a label is often repeated by a container.
                let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier == %@", argument, argument)
                let button = app.buttons.matching(predicate).firstMatch
                let element = button.waitForExistence(timeout: 5)
                    ? button
                    : app.descendants(matching: .any).matching(predicate).firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 10), "no element matching '\(argument)'")
                // By coordinate: a live map never goes idle, and an element
                // tap waits for idle before it resolves the hit point.
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            case "tapxy":
                point(argument, in: app).tap()
            case "press":
                point(argument, in: app).press(forDuration: 1)
            case "sbtap":
                // System alerts (permissions) and notification banners live in SpringBoard.
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let target = springboard.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", argument)).firstMatch
                XCTAssertTrue(target.waitForExistence(timeout: 10), "no SpringBoard element matching '\(argument)'")
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            case "home":
                XCUIDevice.shared.press(.home)
            case "notifications":
                // Pull the notification centre down over whatever is on screen.
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
                    .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            case "activate":
                app.activate()
            case "pinch":
                app.windows.firstMatch.pinch(withScale: CGFloat(Double(argument) ?? 2), velocity: 2)
            case "type":
                app.typeText(argument)
            case "swipe":
                switch argument {
                case "up": app.swipeUp()
                case "down": app.swipeDown()
                case "left": app.swipeLeft()
                default: app.swipeRight()
                }
            case "wait":
                Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "shot":
                try XCUIScreen.main.screenshot().pngRepresentation
                    .write(to: directory.appendingPathComponent("\(argument).png"))
            case "tree":
                try app.debugDescription
                    .write(to: directory.appendingPathComponent("\(argument).txt"), atomically: true, encoding: .utf8)
            default:
                XCTFail("unknown tour step '\(step)'")
            }
        }
    }

    private func point(_ text: String, in app: XCUIApplication) -> XCUICoordinate {
        let values = text.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 2, "expected x,y in '\(text)'")
        return app.coordinate(withNormalizedOffset: CGVector(dx: values.first ?? 0.5, dy: values.last ?? 0.5))
    }
}
