import SwiftUI

/// The watch home: the favorite places received from the phone (spec S22).
@MainActor
struct WatchRootView: View {
    @Environment(WatchFavoritesStore.self) private var favorites

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
    }

    private var placesList: some View {
        List {
            ForEach(favorites.places) { place in
                NavigationLink {
                    WatchPlaceDetailView(place: place)
                } label: {
                    WatchPlaceRow(place: place)
                }
            }
            searchLink
        }
    }

    /// Spec S22: the empty state tells the rider where favorites come from.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Afegeix preferits des de l'iPhone")
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
}
