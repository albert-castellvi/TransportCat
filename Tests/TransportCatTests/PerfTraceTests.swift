import XCTest
#if canImport(Sentry)
import Sentry
#endif
@testable import TransportCat

final class PerfTraceTests: XCTestCase {
    @MainActor
    func testWorksWithoutSentryStarted() {
        #if canImport(Sentry)
        XCTAssertFalse(SentrySDK.isEnabled, "Run this test without a configured DSN")
        #endif
        let trace = PerfTrace()
        trace.begin("test.perf", tags: ["mode": "metro"])
        trace.end()
        trace.end()
    }

    @MainActor
    func testNestedAndUnbalancedCallsAreSafe() {
        let outer = PerfTrace()
        let inner = PerfTrace()
        outer.end()
        outer.begin("test.outer")
        inner.begin("test.inner")
        // Reusing an active handle closes the previous interval first.
        inner.begin("test.replacement")
        outer.end()
        inner.end()
        inner.end()
    }
}
