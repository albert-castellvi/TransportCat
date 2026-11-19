import SwiftUI

/// Explora's "Els teus trajectes" section (spec S4): at most three trips, in
/// the store's own order, as plain list rows — the full list lives in the
/// trips pill on the maps, which another unit owns.
struct ExploreTripsSection: View {
    var body: some View {
        Section("Els teus trajectes") {
            ForEach(Array(TripsStore.shared.ordered.prefix(3))) { trip in
                ExploreTripRow(trip: trip)
            }
        }
    }
}

/// One trip row: name, its lines' badges, the kind · planned-minutes caption
/// and the "Inicia" capsule. A plain row like the favorites' ones, so it does
/// not look like a card inside the list.
private struct ExploreTripRow: View {
    let trip: SavedTrip

    private var trips: TripsStore { TripsStore.shared }

    /// The trip being followed on the maps: its capsule reads "En curs" and
    /// only brings the map up, never restarts it.
    private var isActive: Bool {
        trips.activeSavedTrip?.id == trip.id
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                TripLineBadges(legs: trip.legs)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                if isActive {
                    AppRouter.shared.showActiveTripOnMap()
                } else {
                    trips.start(id: trip.id)
                    AppRouter.shared.showActiveTripOnMap()
                }
            } label: {
                Text(isActive ? String(localized: "En curs") : String(localized: "Inicia"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if trip.kind == .habitual {
                Button {
                    trips.setKind(id: trip.id, .saved)
                } label: {
                    Label("Treu dels habituals", systemImage: "star.slash")
                }
            } else {
                Button {
                    trips.save(trip, as: .habitual)
                } label: {
                    Label("Fes-lo habitual", systemImage: "star")
                }
            }
            Button(role: .destructive) {
                trips.remove(id: trip.id)
            } label: {
                Label("Elimina", systemImage: "trash")
            }
        }
    }

    /// Kind word · planned minutes of the itinerary the trip was saved from.
    private var caption: String {
        let kind: String
        switch trip.kind {
        case .habitual: kind = String(localized: "Habitual")
        case .saved: kind = String(localized: "Desat")
        case .recent: kind = String(localized: "Recent")
        }
        let minutes = Int((Double(trip.plannedDurationSeconds) / 60).rounded())
        return "\(kind) · \(minutes) min"
    }
}
