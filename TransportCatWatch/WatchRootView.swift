import SwiftUI

/// The watch home: the favourite places received from the phone (spec S22,
/// reviews W2, W9, W12, W15, W16).
///
/// Search is the first row, not the last: with three favourites the list already
/// fills a 41 mm screen, and search is what a rider needs when the place is not
/// a favourite. The refresh loop is keyed on the store's generation, so coming
/// back to the app refetches instead of showing what was there an hour ago.
@MainActor
struct WatchRootView: View {
    @Environment(WatchFavoritesStore.self) private var favorites
    @Environment(WatchArrivalsStore.self) private var arrivals

    var body: some View {
        NavigationStack {
            Group {
                if favorites.places.isEmpty {
                    emptyState
                } else {
                    placesList
                }
            }
            .navigationTitle("Preferits")
        }
        .task(id: arrivals.generation) { await refreshLoop() }
    }

    private var placesList: some View {
        List {
            searchLink
            ForEach(favorites.places) { place in
                NavigationLink {
                    WatchPlaceDetailView(place: place)
                } label: {
                    WatchPlaceRow(place: place)
                }
            }
            reloadRow
        }
    }

    /// Spec S22: the empty state tells the rider where favorites come from, and
    /// review W16 makes it say which of the two empties this is — the phone has
    /// never synced, or the phone's list is empty.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(favorites.syncedAt == nil
                     ? "Obre TransportCat a l'iPhone per sincronitzar els preferits"
                     : "Marca preferits a l'iPhone")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                searchLink
            }
            .padding(.vertical)
        }
    }

    private var searchLink: some View {
        NavigationLink {
            WatchSearchView()
        } label: {
            Label("Cerca", systemImage: "magnifyingglass")
        }
    }

    /// Review W12: there is no pull-to-refresh on watchOS, so asking for fresh
    /// arrivals has to be a row. The haptic confirms the tap, says whether
    /// anything changed and whether the watch reached the feeds (review W17).
    private var reloadRow: some View {
        Button {
            Task { await reload() }
        } label: {
            Label("Recarrega", systemImage: "arrow.clockwise")
        }
        .disabled(arrivals.isRefreshing)
    }

    private func reload() async {
        let changed = await arrivals.refresh(favorites.places, maxAge: 0)
        WatchRefreshHaptic.play(
            changed: changed,
            failed: !favorites.places.isEmpty && favorites.places.allSatisfy { place in
                arrivals.board(for: place.id)?.lastAttemptFailed ?? true
            }
        )
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await arrivals.refresh(favorites.places)
            do {
                try await Task.sleep(nanoseconds: UInt64(WatchArrivalsStore.refreshInterval * 1_000_000_000))
            } catch {
                return
            }
        }
    }
}
