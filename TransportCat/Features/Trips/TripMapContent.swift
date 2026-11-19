import MapKit
import SwiftUI

/// The pinned trip's own content on the global map (spec S4): the ride
/// polylines drawn strong on top of the dimmed network, plus the boarding,
/// transfer and destination markers with their station names as titles.
struct TripRouteContent: MapContent {
    let legs: [SavedTripLeg]

    /// Neutral fill for a leg the feed published without a color.
    private static let fallbackColorHex = "8E8E93"

    var body: some MapContent {
        ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
            tripPolyline(leg: leg)
        }
        ForEach(markers) { marker in
            Annotation(marker.title, coordinate: marker.coordinate) {
                TripStationMarkerView(kind: marker.kind)
                    .accessibilityLabel(marker.title)
            }
        }
    }

    /// One ride: a white casing (width + 4) under the line color (~6), so the
    /// route reads over every dimmed line beneath it.
    @MapContentBuilder
    private func tripPolyline(leg: SavedTripLeg) -> some MapContent {
        let coordinates = leg.geometry.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
        if coordinates.count >= 2 {
            MapPolyline(coordinates: coordinates)
                .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: coordinates)
                .stroke(
                    Color(hex: leg.colorHex ?? Self.fallbackColorHex),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                )
        }
    }

    /// Boarding, transfer and destination markers, in travel order: the start
    /// of every leg boards, the end of every leg but the last is a transfer,
    /// the last leg's end is the destination.
    private var markers: [TripStationMarker] {
        var result: [TripStationMarker] = []
        for (index, leg) in legs.enumerated() {
            // A later leg boards where the previous one ended: that point is
            // already the transfer marker.
            if index == 0 { result.append(TripStationMarker(
                kind: .boarding,
                coordinate: CLLocationCoordinate2D(
                    latitude: leg.fromPosition.latitude,
                    longitude: leg.fromPosition.longitude
                ),
                title: leg.fromName
            )) }
            let isLast = index == legs.count - 1
            result.append(TripStationMarker(
                kind: isLast ? .destination : .transfer,
                coordinate: CLLocationCoordinate2D(
                    latitude: leg.toPosition.latitude,
                    longitude: leg.toPosition.longitude
                ),
                title: leg.toName
            ))
        }
        return result
    }
}

/// One trip marker value (boarding, transfer or destination).
struct TripStationMarker: Identifiable {
    enum Kind: Equatable {
        case boarding
        case transfer
        case destination
    }

    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    let title: String

    var id: String {
        "\(kind)-\(title)-\(coordinate.latitude)-\(coordinate.longitude)"
    }
}

/// The marker glyph of the pinned trip (spec S4): a hollow circle at the
/// boarding station, a capsule at a transfer, a filled dark circle at the
/// destination.
struct TripStationMarkerView: View {
    let kind: TripStationMarker.Kind

    var body: some View {
        switch kind {
        case .boarding:
            Circle()
                .fill(.white)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color(hex: "1C1C1E"), lineWidth: 2.5))
        case .transfer:
            Capsule()
                .fill(.white)
                .frame(width: 16, height: 10)
                .overlay(Capsule().stroke(Color(hex: "1C1C1E"), lineWidth: 2))
        case .destination:
            Circle()
                .fill(Color(hex: "1C1C1E"))
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
    }
}

/// Geometry helpers of the pinned trip, kept out of the render path: the
/// camera fit and the "is this station on the trip" test the station-dot
/// filter uses.
enum TripMapGeometry {
    /// Map rect covering every trip coordinate, inflated so the bottom card
    /// and the map edges leave the route air. Nil with no geometry.
    static func cameraRect(of trip: SavedTrip) -> MKMapRect? {
        let points = trip.legs.flatMap { $0.geometry }
        guard let first = points.first else { return nil }
        var rect = MKMapRect(
            origin: MKMapPoint(CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)),
            size: MKMapSize(width: 0, height: 0)
        )
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(
                origin: MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)),
                size: MKMapSize(width: 0, height: 0)
            ))
        }
        // Not centred: the trip card covers the lower half of the screen,
        // so the route goes in the band above it — half its height of air
        // on top (status capsule, buttons), two and a half below for the card.
        let width = max(rect.width, rect.height * 0.5)
        return MKMapRect(
            x: rect.midX - width * 0.65,
            y: rect.minY - rect.height * 0.5,
            width: width * 1.3,
            height: rect.height * 4
        )
    }

    /// Whether a station belongs to the trip: by the stored station names,
    /// or — when the feed spelled it differently — by being within ~200 m of
    /// any trip coordinate. The map hides the rest of the dots while a trip
    /// is pinned (spec S4).
    static func isOnTrip(name: String, position: GeoPoint, trip: SavedTrip) -> Bool {
        if trip.legs.contains(where: { $0.fromName == name || $0.toName == name }) {
            return true
        }
        return trip.legs.contains { leg in
            isClose(position, leg.fromPosition) || isClose(position, leg.toPosition)
                || leg.geometry.contains { isClose(position, $0) }
        }
    }

    /// Rough distance test, ~200 m, good enough to keep the route's own dots.
    private static func isClose(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Bool {
        let dLat = (lhs.latitude - rhs.latitude) * 111_320
        let dLon = (lhs.longitude - rhs.longitude) * 111_320 * cos(lhs.latitude * .pi / 180)
        return (dLat * dLat + dLon * dLon) <= 200 * 200
    }
}
