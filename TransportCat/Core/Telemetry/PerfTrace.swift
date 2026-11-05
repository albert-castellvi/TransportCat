import Foundation
import os
import QuartzCore
import UIKit
import Darwin
#if canImport(Sentry)
import Sentry
#endif

/// Evaluated once at launch. Override with `-perfTelemetry YES|NO`; no UI needed.
enum PerfTelemetry {
    static let isEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "perfTelemetry") != nil {
            return UserDefaults.standard.bool(forKey: "perfTelemetry")
        }
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()
}

/// Main-actor interval handle. Independent handles may overlap; repeated end
/// calls are harmless. Names and tags must be static, non-sensitive telemetry.
@MainActor
final class PerfTrace: NSObject {
    private static let signposter = OSSignposter(subsystem: "TransportCat", category: "perf")
    private static let logger = Logger(subsystem: "TransportCat", category: "perf")
    private let enabled: Bool
    var isRunning: Bool { interval != nil || displayLink != nil }

    init(enabled: Bool = PerfTelemetry.isEnabled) {
        self.enabled = enabled
        super.init()
    }

    private var interval: OSSignpostIntervalState?
    private var displayLink: CADisplayLink?
    #if canImport(Sentry)
    private var span: (any Span)?
    #endif

    func begin(_ name: String, tags: [String: String] = [:]) {
        guard enabled else { return }
        end()
        interval = Self.signposter.beginInterval("perf", id: Self.signposter.makeSignpostID(), "\(name, privacy: .public)")
        #if canImport(Sentry)
        guard SentrySDK.isEnabled else { return }
        let transaction = SentrySDK.startTransaction(name: name, operation: "ui.performance", bindToScope: false)
        for (key, value) in tags {
            transaction.setTag(value: value, key: key)
        }
        span = transaction
        #endif
    }

    /// Ends at the next display opportunity, not GPU presentation or tile readiness.
    /// The link retains this handle until the callback invalidates it.
    func endOnNextFrame() {
        guard enabled else { return }
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(nextFrame))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func nextFrame(_ link: CADisplayLink) {
        end()
    }

    func end(tags: [String: String] = [:]) {
        guard enabled else { return }
        displayLink?.invalidate()
        displayLink = nil
        if let interval {
            Self.signposter.endInterval("perf", interval)
            self.interval = nil
        }
        #if canImport(Sentry)
        if let span {
            for (key, value) in tags {
                span.setTag(value: value, key: key)
            }
            span.finish()
            self.span = nil
        }
        #endif
    }

    /// Event, not a tracing span: safe on the map's high-frequency render path.
    /// Measures Swift MapContent construction, not MapKit layout or GPU work.
    static func mapBodyEvaluated(nanoseconds: UInt64) {
        guard PerfTelemetry.isEnabled else { return }
        signposter.emitEvent("map.global.body", "duration_ns=\(nanoseconds)")
    }

    /// Only called on zoom-band transitions, never on vehicle ticks.
    static func bandChanged(band: String, stationCount: Int, vehicleCount: Int) {
        guard PerfTelemetry.isEnabled else { return }
        logger.info("global map band changed band=\(band, privacy: .public) station_count=\(stationCount) vehicle_count=\(vehicleCount)")
        #if canImport(Sentry)
        guard SentrySDK.isEnabled else { return }
        // Breadcrumbs are supported in 8.0.0; structured logs are not.
        let crumb = Breadcrumb(level: .info, category: "perf")
        crumb.message = "global map band changed"
        crumb.data = ["band": band, "station_count": stationCount, "vehicle_count": vehicleCount]
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }
}

/// One monitor for the selected map, owned by RootView's visibility lifecycle.
/// No observable state: frame callbacks never invalidate SwiftUI views.
@MainActor
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()

    struct Sample {
        var tags: [String: String]
        let measurements: [String: Double]
    }

    private static let signposter = OSSignposter(subsystem: "TransportCat", category: "perf")
    private let enabled: Bool
    private let usesDisplayLink: Bool
    private var displayLink: CADisplayLink?
    private var mode: String?
    private var globalTags: [String: String] = [:]
    private var startTags: [String: String] = [:]
    private var firstTimestamp: Double?
    private var previousTimestamp: Double?
    private var lastCameraTimestamp: Double?
    private var globalLatitudeSpan: Double?
    private var frameCount = 0
    private var over33 = 0
    private var over100 = 0
    private var maxMS = 0.0
    private var movingOver33 = 0
    private var idleOver33 = 0
    private var movingMaxMS = 0.0
    private var cameraCount = 0
    private var bandChangeCount = 0
    // A 15 s observation window survives band flushes, exposing threshold oscillation.
    private var bandWindowStart: Double?
    private var bandChanges15s = 0
    private(set) var lastSample: Sample?
    var isRunning: Bool { mode != nil }
    var hasDisplayLink: Bool { displayLink != nil }

    init(enabled: Bool = PerfTelemetry.isEnabled, usesDisplayLink: Bool = true) {
        self.enabled = enabled
        self.usesDisplayLink = usesDisplayLink
        super.init()
    }

    func begin(mode: String) {
        guard enabled, self.mode != mode else { return }
        end()
        self.mode = mode
        reset()
        if usesDisplayLink {
            let link = CADisplayLink(target: self, selector: #selector(nextFrame))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    /// Global hooks annotate the active monitor; they never activate a hidden map.
    func updateGlobal(tags: [String: String], bandChanged: Bool) {
        guard enabled else { return }
        if mode == "global", bandChanged {
            bandChangeCount += 1
            bandChanges15s += 1
            flush()
        }
        globalTags = tags
        if mode == "global", bandChanged { reset() }
    }

    func cameraChanged(timestamp: Double = CACurrentMediaTime(), latitudeSpan: Double? = nil) {
        guard enabled, mode == "global" else { return }
        if let latitudeSpan { globalLatitudeSpan = latitudeSpan }
        lastCameraTimestamp = timestamp
        cameraCount += 1
    }

    @objc private func nextFrame(_ link: CADisplayLink) {
        recordFrame(timestamp: link.timestamp)
    }

    /// O(1) arithmetic per frame; system queries and export occur at boundaries only.
    /// Counts observed frame intervals, not estimated missing refresh opportunities.
    func recordFrame(timestamp: Double) {
        guard enabled, mode != nil, timestamp.isFinite else { return }
        guard let previous = previousTimestamp, let first = firstTimestamp else {
            firstTimestamp = timestamp
            previousTimestamp = timestamp
            if bandWindowStart == nil { bandWindowStart = timestamp }
            return
        }
        guard timestamp > previous else { return }
        let milliseconds = (timestamp - previous) * 1_000
        previousTimestamp = timestamp
        frameCount += 1
        maxMS = max(maxMS, milliseconds)
        if milliseconds > 33 { over33 += 1 }
        if milliseconds > 100 { over100 += 1 }
        // The latest camera callback marks the following 300 ms as moving.
        if let camera = lastCameraTimestamp, timestamp - camera <= 0.3, timestamp >= camera {
            if milliseconds > 33 { movingOver33 += 1 }
            movingMaxMS = max(movingMaxMS, milliseconds)
        } else if milliseconds > 33 {
            idleOver33 += 1
        }
        if timestamp - first >= 15 {
            flush()
            reset()
            firstTimestamp = timestamp
            previousTimestamp = timestamp
        }
        if let window = bandWindowStart, timestamp - window >= 15 {
            bandWindowStart = timestamp
            bandChanges15s = 0
        }
    }

    @discardableResult
    func end(ifMode expectedMode: String? = nil) -> Sample? {
        guard enabled, let mode, expectedMode == nil || expectedMode == mode else { return nil }
        let sample = flush()
        displayLink?.invalidate()
        displayLink = nil
        self.mode = nil
        firstTimestamp = nil
        previousTimestamp = nil
        lastCameraTimestamp = nil
        globalLatitudeSpan = nil
        bandWindowStart = nil
        bandChanges15s = 0
        return sample
    }

    private func reset() {
        firstTimestamp = nil
        previousTimestamp = nil
        frameCount = 0
        over33 = 0
        over100 = 0
        maxMS = 0
        movingOver33 = 0
        idleOver33 = 0
        movingMaxMS = 0
        cameraCount = 0
        bandChangeCount = 0
        startTags = boundaryTags(suffix: "start")
        startTags["maximum_frames_per_second"] = String(UIScreen.main.maximumFramesPerSecond)
    }

    @discardableResult
    private func flush() -> Sample? {
        guard let mode, let firstTimestamp, let previousTimestamp,
              previousTimestamp - firstTimestamp >= 1, frameCount >= 30 else { return nil }
        let measurements: [String: Double] = [
            "wall_duration_s": previousTimestamp - firstTimestamp,
            "frame_count": Double(frameCount),
            "frames_over_33ms": Double(over33),
            "frames_over_100ms": Double(over100),
            "max_frame_ms": maxMS,
            "frames_over_33ms_moving": Double(movingOver33),
            "frames_over_33ms_idle": Double(idleOver33),
            "max_frame_ms_moving": movingMaxMS,
            "camera_interaction_count": Double(cameraCount),
            "band_change_count": Double(bandChangeCount),
            "band_changes_15s": Double(bandChanges15s)
        ]
        var tags = startTags.merging(boundaryTags(suffix: "end")) { _, end in end }
        tags["screen"] = mode
        tags["mode"] = mode
        if mode == "global" {
            tags.merge(globalTags) { _, global in global }
            if let globalLatitudeSpan {
                tags["latitude_span"] = String(format: "%.3f", globalLatitudeSpan)
            }
        }
        for (key, value) in measurements { tags[key] = String(value) }
        let sample = Sample(tags: tags, measurements: measurements)
        lastSample = sample
        Self.signposter.emitEvent("map.global.frames", "\(tags.description, privacy: .public)")
        #if canImport(Sentry)
        if SentrySDK.isEnabled {
            // Export at flush so discarded noise never creates a transaction.
            // wall_duration_s is the display-link window, not this export's duration.
            let transaction = SentrySDK.startTransaction(
                name: "map.global.frames", operation: "ui.performance", bindToScope: false
            )
            for (key, value) in tags { transaction.setTag(value: value, key: key) }
            for (key, value) in measurements {
                transaction.setMeasurement(name: key, value: NSNumber(value: value))
            }
            transaction.finish()
        }
        #endif
        return sample
    }

    private func boundaryTags(suffix: String) -> [String: String] {
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return [
            "thermal_state_\(suffix)": thermal,
            "low_power_mode_\(suffix)": String(process.isLowPowerModeEnabled),
            "memory_mb_\(suffix)": Self.memoryMB().map { String(format: "%.2f", $0) } ?? "unavailable"
        ]
    }

    private static func memoryMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}
