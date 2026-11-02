import Foundation
import Observation

#if canImport(CoreLocation)
import CoreLocation

/// Device location for the maps and the nearby list (spec S6).
///
/// When-in-use only: the app never asks for background location. The service
/// keeps the last valid point and the current authorization, and every map can
/// read them without owning a `CLLocationManager`. A denied permission is a
/// normal state, never an error: the maps keep working without the blue dot.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// Last valid device position, or nil before the first fix.
    private(set) var location: GeoPoint?
    /// Current when-in-use authorization.
    private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Metro station scale: tens of meters are enough, and the coarser
        // filter saves battery.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
    }

    /// Asks for when-in-use permission once. Repeating it after a decision has
    /// no effect, which is exactly what the system wants.
    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Starts updates. Only useful once authorized; the system ignores it
    /// otherwise.
    func start() {
        manager.startUpdatingLocation()
    }

    /// Stops updates; the last known `location` stays available.
    func stop() {
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self?.start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0 else { return }
        let point = GeoPoint(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        Task { @MainActor [weak self] in
            self?.location = point
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed fix is not fatal: the maps hide the dot and keep working.
    }
}

#else

/// Fallback for targets without CoreLocation (the Linux test harness), so the
/// Core sources still compile there. It reports "not determined" and never
/// produces a location.
@MainActor
@Observable
final class LocationService {
    static let shared = LocationService()

    private(set) var location: GeoPoint?
    /// Mirrors the leading cases of `CLAuthorizationStatus`.
    private(set) var authorization: LocationAuthorization = .notDetermined

    init() {}

    func requestWhenInUse() {}
    func start() {}
    func stop() {}
}

/// Platform-free stand-in for `CLAuthorizationStatus`.
enum LocationAuthorization {
    case notDetermined
    case denied
    case restricted
    case authorized
}

#endif
