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
        XCTAssertFalse(trace.isRunning)
    }

    @MainActor
    func testFrameCountsAndInteractionThresholds() throws {
        let monitor = FrameMonitor(enabled: true, usesDisplayLink: false)
        monitor.begin(mode: "global")
        monitor.recordFrame(timestamp: 0)
        for index in 1...60 { monitor.recordFrame(timestamp: Double(index) / 60) }
        monitor.cameraChanged(timestamp: 1)
        monitor.recordFrame(timestamp: 1.05)
        monitor.recordFrame(timestamp: 1.2)
        monitor.recordFrame(timestamp: 1.6)
        let sample = try XCTUnwrap(monitor.end())
        XCTAssertEqual(sample.measurements["frame_count"], 63)
        XCTAssertEqual(sample.measurements["frames_over_33ms"], 3)
        XCTAssertEqual(sample.measurements["frames_over_100ms"], 2)
        XCTAssertEqual(sample.measurements["frames_over_33ms_moving"], 2)
        XCTAssertEqual(sample.measurements["frames_over_33ms_idle"], 1)
        XCTAssertEqual(sample.measurements["frames_over_33ms_moving"]! + sample.measurements["frames_over_33ms_idle"]!, sample.measurements["frames_over_33ms"]!)
        XCTAssertEqual(try XCTUnwrap(sample.measurements["max_frame_ms"]), 400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sample.measurements["max_frame_ms_moving"]), 150, accuracy: 0.001)
        XCTAssertEqual(sample.measurements["camera_interaction_count"], 1)
        XCTAssertEqual(sample.measurements["wall_duration_s"], 1.6)
        XCTAssertEqual(sample.tags["mode"], "global")
        for (name, value) in sample.measurements {
            XCTAssertEqual(sample.tags[name], String(value))
        }
        for key in ["thermal_state_start", "thermal_state_end", "low_power_mode_start",
                    "low_power_mode_end", "maximum_frames_per_second", "memory_mb_start", "memory_mb_end"] {
            XCTAssertNotNil(sample.tags[key], key)
        }
    }

    @MainActor
    func testShortOrSparseFrameSegmentsAreDropped() {
        let monitor = FrameMonitor(enabled: true, usesDisplayLink: false)
        monitor.begin(mode: "metro")
        for index in 0...60 { monitor.recordFrame(timestamp: Double(index) / 120) }
        XCTAssertNil(monitor.end()) // Plenty of frames, less than one second.
        monitor.begin(mode: "bus")
        for index in 0...29 { monitor.recordFrame(timestamp: Double(index) / 20) }
        XCTAssertNil(monitor.end()) // Long enough, fewer than 30 deltas.
        monitor.begin(mode: "fgc")
        for index in 0...30 { monitor.recordFrame(timestamp: Double(index) / 30) }
        XCTAssertEqual(monitor.end()?.measurements["frame_count"], 30)
    }

    @MainActor
    func testFrameRolloverAndUnbalancedLifecycle() {
        let monitor = FrameMonitor(enabled: true, usesDisplayLink: false)
        XCTAssertNil(monitor.end())
        monitor.recordFrame(timestamp: 0)
        monitor.begin(mode: "metro")
        monitor.begin(mode: "metro") // Idempotent lifecycle updates do not reset.
        for index in 0...150 { monitor.recordFrame(timestamp: Double(index) / 10) }
        XCTAssertEqual(monitor.lastSample?.measurements["frame_count"], 150)
        XCTAssertEqual(monitor.lastSample?.measurements["wall_duration_s"], 15)
        for index in 151...180 { monitor.recordFrame(timestamp: Double(index) / 10) }
        XCTAssertEqual(monitor.end()?.measurements["frame_count"], 30)
        XCTAssertNil(monitor.end())
        XCTAssertFalse(monitor.isRunning)
    }

    @MainActor
    func testGlobalBandChangesFlushAndModeChangesDoNotLeakTags() {
        let monitor = FrameMonitor(enabled: true, usesDisplayLink: false)
        monitor.updateGlobal(tags: ["band": "lines", "station_count": "0"], bandChanged: false)
        monitor.begin(mode: "global")
        for index in 0...60 { monitor.recordFrame(timestamp: Double(index) / 60) }
        monitor.updateGlobal(tags: ["band": "stations", "station_count": "263"], bandChanged: true)
        XCTAssertEqual(monitor.lastSample?.tags["band"], "lines")
        XCTAssertEqual(monitor.lastSample?.measurements["band_change_count"], 1)
        XCTAssertEqual(monitor.lastSample?.measurements["band_changes_15s"], 1)
        for index in 60...120 { monitor.recordFrame(timestamp: Double(index) / 60) }
        monitor.end(ifMode: "metro") // An inactive retained view cannot stop another mode.
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(monitor.end()?.tags["station_count"], "263")
        monitor.begin(mode: "bus")
        for index in 0...60 { monitor.recordFrame(timestamp: Double(index) / 60) }
        XCTAssertNil(monitor.end()?.tags["band"])
    }

    @MainActor
    func testDisabledTelemetryIsInert() {
        let trace = PerfTrace(enabled: false)
        trace.begin("test.disabled")
        trace.endOnNextFrame()
        trace.end()
        XCTAssertFalse(trace.isRunning)
        let monitor = FrameMonitor(enabled: false)
        monitor.begin(mode: "global")
        monitor.updateGlobal(tags: ["band": "stations"], bandChanged: true)
        monitor.cameraChanged(timestamp: 0)
        for index in 0...120 { monitor.recordFrame(timestamp: Double(index)) }
        XCTAssertNil(monitor.end())
        XCTAssertNil(monitor.lastSample)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(monitor.hasDisplayLink)
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
