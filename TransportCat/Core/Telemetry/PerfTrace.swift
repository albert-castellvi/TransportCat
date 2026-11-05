import Foundation
import os
import QuartzCore
#if canImport(Sentry)
import Sentry
#endif

/// Main-actor interval handle. Independent handles may overlap; repeated end
/// calls are harmless. Names and tags must be static, non-sensitive telemetry.
@MainActor
final class PerfTrace: NSObject {
    private static let signposter = OSSignposter(subsystem: "TransportCat", category: "perf")
    private static let logger = Logger(subsystem: "TransportCat", category: "perf")
    private var interval: OSSignpostIntervalState?
    private var displayLink: CADisplayLink?
    #if canImport(Sentry)
    private var span: (any Span)?
    #endif

    func begin(_ name: String, tags: [String: String] = [:]) {
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
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(nextFrame))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func nextFrame(_ link: CADisplayLink) {
        end()
    }

    func end(tags: [String: String] = [:]) {
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
        signposter.emitEvent("map.global.body", "duration_ns=\(nanoseconds)")
    }

    /// Only called on zoom-band transitions, never on vehicle ticks.
    static func bandChanged(band: String, stationCount: Int, vehicleCount: Int) {
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
