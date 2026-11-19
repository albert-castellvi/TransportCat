import SwiftUI

/// The trips sheet the pill opens (spec S4): the active trip first ("En
/// curs"), then "Habituals", then "Desats i recents", with the actions to
/// retag, rename and delete. Starting a trip jumps to the global map, where
/// the trip is pinned.
struct TripsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Rename alert state: the trip being renamed and the text field's draft.
    @State private var renaming: SavedTrip?
    @State private var renameDraft = ""

    private var trips: TripsStore { TripsStore.shared }

    var body: some View {
        Group {
            if trips.trips.isEmpty {
                emptyState
            } else {
                tripList
            }
        }
        .navigationTitle("Trajectes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Tancar") { dismiss() }
            }
        }
        // A trip started from the sheet hands the rider to the map, so the
        // sheet closes the moment the active trip changes (the planner's
        // "Segueix-lo al mapa" starts one too).
        .onChange(of: trips.activeTrip) { _, active in
            if active != nil { dismiss() }
        }
        .alert(
            "Canvia el nom",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )
        ) {
            TextField("Nom del trajecte", text: $renameDraft)
            Button("Desa") {
                if let renaming { trips.rename(id: renaming.id, to: renameDraft) }
                renaming = nil
            }
            Button("Cancel·la", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Lists

    private var tripList: some View {
        List {
            if let active = trips.activeSavedTrip {
                Section("En curs") {
                    activeRow(active)
                }
            }
            let habituals = trips.ordered.filter { $0.kind == .habitual && trips.activeTrip?.tripID != $0.id }
            let savedAndRecent = trips.ordered.filter { $0.kind != .habitual && trips.activeTrip?.tripID != $0.id }
            if !habituals.isEmpty {
                Section("Habituals") {
                    ForEach(habituals) { row($0) }
                }
            }
            if !savedAndRecent.isEmpty {
                Section("Desats i recents") {
                    ForEach(savedAndRecent) { row($0) }
                }
            }
        }
    }

    /// The active trip's row: no start action, only the way to stop following.
    private func activeRow(_ trip: SavedTrip) -> some View {
        HStack(spacing: 10) {
            tripRowContent(trip)
            Spacer(minLength: 8)
            Button("Finalitza", role: .destructive) {
                trips.endActive()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func row(_ trip: SavedTrip) -> some View {
        tripRowContent(trip)
            .contentShape(Rectangle())
            .onTapGesture {
                trips.start(id: trip.id)
                AppRouter.shared.showActiveTripOnMap()
                dismiss()
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    trips.remove(id: trip.id)
                } label: {
                    Label("Elimina", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    trips.setKind(id: trip.id, trip.kind == .habitual ? .saved : .habitual)
                } label: {
                    Label(
                        trip.kind == .habitual
                            ? String(localized: "Treu dels habituals")
                            : String(localized: "Fes-lo habitual"),
                        systemImage: trip.kind == .habitual ? "star.slash" : "star"
                    )
                    .tint(.accentColor)
                }
                Button {
                    renameDraft = trip.name
                    renaming = trip
                } label: {
                    Label("Canvia el nom", systemImage: "pencil")
                }
                .tint(.indigo)
            }
            .contextMenu { contextActions(trip) }
    }

    @ViewBuilder
    private func contextActions(_ trip: SavedTrip) -> some View {
        Button {
            trips.start(id: trip.id)
            AppRouter.shared.showActiveTripOnMap()
            dismiss()
        } label: {
            Label("Segueix-lo al mapa", systemImage: "map")
        }
        Button {
            trips.setKind(id: trip.id, trip.kind == .habitual ? .saved : .habitual)
        } label: {
            Label(
                trip.kind == .habitual
                    ? String(localized: "Treu dels habituals")
                    : String(localized: "Fes-lo habitual"),
                systemImage: trip.kind == .habitual ? "star.slash" : "star"
            )
        }
        Button {
            renameDraft = trip.name
            renaming = trip
        } label: {
            Label("Canvia el nom", systemImage: "pencil")
        }
        Button(role: .destructive) {
            trips.remove(id: trip.id)
        } label: {
            Label("Elimina", systemImage: "trash")
        }
    }

    /// Shared row content: the trip's name and its lines' badges, plus the
    /// kind caption ("Habitual", "Desat", "Recent").
    private func tripRowContent(_ trip: SavedTrip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            // Fixed size: next to the active row's Finalitza the badges were
            // squeezed to a zero-width column.
            TripLineBadges(legs: trip.legs)
                .fixedSize()
            Text(kindCaption(trip.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func kindCaption(_ kind: TripKind) -> String {
        switch kind {
        case .habitual: return String(localized: "Habitual")
        case .saved: return String(localized: "Desat")
        case .recent: return String(localized: "Recent")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Cap trajecte desat", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        } description: {
            Text("Planifica un viatge i desa’l per tenir-lo aquí.")
        } actions: {
            NavigationLink {
                PlannerScreen()
            } label: {
                Label("Planifica’n un", systemImage: "arrow.up.right.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
