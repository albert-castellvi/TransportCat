import SwiftUI

/// The next five arrivals of one favorite place (spec S22).
///
/// Refreshes on appear and every 60 s while visible, like the favorite row.
@MainActor
struct WatchPlaceDetailView: View {
    let place: Place

    @State private var arrivals: [NextArrival] = []
    @State private var hasLoaded = false

    var body: some View {
        List {
            Section("Properes arribades") {
                if arrivals.isEmpty {
                    Text(hasLoaded ? "Sense arribades" : "Carregant…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(arrivals) { arrival in
                        WatchArrivalRow(arrival: arrival)
                    }
                }
            }
        }
        .navigationTitle(place.name)
        .task { await refreshLoop() }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private func refresh() async {
        guard let client = WatchServices.tmbClient() else {
            hasLoaded = true
            return
        }
        arrivals = await WatchArrivalsProvider.arrivals(
            for: place,
            client: client,
            limit: WatchArrivalsProvider.detailLimit
        )
        hasLoaded = true
    }
}
