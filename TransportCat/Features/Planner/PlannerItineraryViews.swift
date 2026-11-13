import MapKit
import SwiftUI

// MARK: - Results list

/// One itinerary as a row: total minutes, time range, transfers/walking
/// summary and the leg badges in their line colors (spec S16).
struct PlannerItineraryRow: View {
    let itinerary: Itinerary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(PlannerFormat.totalLabel(seconds: itinerary.duration))
                    .font(.headline)
                Spacer(minLength: 8)
                Text(PlannerFormat.timeRangeLabel(
                    start: itinerary.startTime,
                    end: itinerary.endTime
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { _, leg in
                    PlannerLegBadge(leg: leg)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        "\(PlannerFormat.transfersLabel(itinerary.transfers)) · \(PlannerFormat.walkingLabel(seconds: itinerary.walkTime))"
    }
}

/// One leg in the results badges: the walk pictogram, or the line pill in the
/// colors OTP published (spec S16).
@MainActor
struct PlannerLegBadge: View {
    let leg: Leg

    var body: some View {
        if leg.isWalk {
            Image(systemName: "figure.walk")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .accessibilityLabel("A peu")
        } else {
            ExploreLineBadge(
                label: badgeLabel,
                colorHex: leg.badgeColorHex,
                textColorHex: leg.routeTextColorHex
            )
        }
    }

    /// The bus catalog knows the commercial name behind a published line
    /// description, so "Districte Gran Via l'Hospitalet / Av. Esplugues"
    /// reads "V1" on the badge (#96).
    private var badgeLabel: String {
        guard let route = leg.route,
              let name = PlannerFormat.shortLineName(for: route, in: BusCatalogStore.shared.lines) else {
            return leg.badgeText
        }
        return name
    }
}

// MARK: - Detail

/// Itinerary detail (spec S16): the route map on top, then one row per leg
/// with its stops.
struct PlannerItineraryDetail: View {
    let itinerary: Itinerary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlannerRouteMap(itinerary: itinerary)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Mapa del trajecte de \(PlannerFormat.totalLabel(seconds: itinerary.duration))")

                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { _, leg in
                        PlannerLegRow(leg: leg)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(PlannerFormat.totalLabel(seconds: itinerary.duration))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summary: String {
        "\(PlannerFormat.timeRangeLabel(start: itinerary.startTime, end: itinerary.endTime)) · \(PlannerFormat.transfersLabel(itinerary.transfers)) · \(PlannerFormat.walkingLabel(seconds: itinerary.walkTime))"
    }
}

/// One leg: time, badge, headsign and endpoints, with the intermediate stops
/// listed underneath transit legs (spec S16).
struct PlannerLegRow: View {
    let leg: Leg

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(PlannerFormat.timeLabel(leg.startTime))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                Text(String(localized: "\(PlannerFormat.minutes(seconds: leg.duration)) min"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, alignment: .trailing)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PlannerLegBadge(leg: leg)
                    if let headsign = leg.headsign {
                        // The headsign is the leg's identity, so it wraps like
                        // the from→to line underneath (UX-09).
                        Text("cap a \(headsign)")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if leg.isWalk {
                        Text(walkingDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(leg.from.name) → \(leg.to.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !leg.intermediateStops.isEmpty {
                    stopsColumn
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The stops passed through without getting off, as a dotted column.
    private var stopsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(leg.intermediateStops.enumerated()), id: \.offset) { _, stop in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 4, height: 4)
                    Text(stop.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(leg.intermediateStops.count) parades: \(leg.intermediateStops.map(\.name).joined(separator: ", "))")
    }

    private var walkingDetail: String {
        guard let distance = leg.distance else {
            return String(localized: "\(PlannerFormat.minutes(seconds: leg.duration)) min a peu")
        }
        return String(
            localized: "\(PlannerFormat.minutes(seconds: leg.duration)) min · \(Int(distance.rounded())) m"
        )
    }
}

// MARK: - Route map

/// The itinerary drawn as leg polylines: walking dashed gray, transit in the
/// route's color (spec S16). Framed on the route bounds, so the rider sees
/// the whole trip at once.
struct PlannerRouteMap: View {
    let itinerary: Itinerary

    var body: some View {
        Map(position: .constant(.region(region))) {
            ForEach(Array(itinerary.legs.enumerated()), id: \.offset) { _, leg in
                let coordinates = routeCoordinates(of: leg)
                if coordinates.count >= 2 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            leg.isWalk ? Color.gray.opacity(0.7) : Color(hex: leg.badgeColorHex),
                            style: leg.isWalk
                                ? StrokeStyle(lineWidth: 3, dash: [6, 4])
                                : StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            if let firstLeg = itinerary.legs.first, let lastLeg = itinerary.legs.last {
                Annotation(String(localized: "Inici"), coordinate: coordinate(firstLeg.from.position)) {
                    endpointDot(color: .green, label: String(localized: "Inici del trajecte"))
                }
                .annotationTitles(.hidden)
                Annotation(String(localized: "Final"), coordinate: coordinate(lastLeg.to.position)) {
                    endpointDot(color: .red, label: String(localized: "Final del trajecte"))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    /// A leg's decoded geometry, falling back to its endpoints so short
    /// walking legs without a published polyline still connect the map.
    private func routeCoordinates(of leg: Leg) -> [CLLocationCoordinate2D] {
        let points = leg.geometry.count >= 2
            ? leg.geometry
            : [leg.from.position, leg.to.position]
        return points.map(coordinate)
    }

    private func coordinate(_ point: GeoPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    /// Bounds over every drawn point with a little air; a degenerate route
    /// still gets a readable neighborhood span.
    private var region: MKCoordinateRegion {
        let points = itinerary.legs.flatMap { leg in
            leg.geometry.count >= 2 ? leg.geometry : [leg.from.position, leg.to.position]
        }
        let center: GeoPoint
        let span = (latitude: 0.012, longitude: 0.012)
        if let bounds = PlannerParser.bounds(of: points) {
            center = GeoPoint(
                latitude: (bounds.minLatitude + bounds.maxLatitude) / 2,
                longitude: (bounds.minLongitude + bounds.maxLongitude) / 2
            )
            let latitudeDelta = max((bounds.maxLatitude - bounds.minLatitude) * 1.3, 0.008)
            // Widen the longitude by the latitude cosine so the padding is
            // equal on screen, not just in degrees.
            let cosLatitude = max(0.2, cos(center.latitude * .pi / 180))
            let longitudeDelta = max((bounds.maxLongitude - bounds.minLongitude) * 1.3 / cosLatitude, 0.008 / cosLatitude)
            return MKCoordinateRegion(
                center: coordinate(center),
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
        }
        center = itinerary.legs.first?.from.position ?? GeoPoint(latitude: 41.3874, longitude: 2.1686)
        return MKCoordinateRegion(center: coordinate(center), span: MKCoordinateSpan(latitudeDelta: span.latitude, longitudeDelta: span.longitude))
    }

    private func endpointDot(color: Color, label: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .accessibilityLabel(label)
    }
}
