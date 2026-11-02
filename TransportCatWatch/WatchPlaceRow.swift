import SwiftUI

/// One favorite place: its name and its next two arrivals (spec S22).
///
/// The arrivals come from the shared `NextArrivalsFetcher`, and refresh when
/// the row appears and every 60 s while it is visible; pushing the detail or
/// leaving the list cancels the loop.
@MainActor
struct WatchPlaceRow: View {
    let place: Place

    @State private var arrivals: [NextArrival] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(place.name)
                .font(.headline)
                .lineLimit(1)
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .task { await refreshLoop() }
    }

    private var summary: String {
        let text = WatchArrivalFormatting.summary(arrivals)
        return text.isEmpty ? "Sense arribades" : text
    }

    private var accessibilityLabel: String {
        let text = WatchArrivalFormatting.summary(arrivals)
        return text.isEmpty ? "\(place.name), sense arribades" : "\(place.name), \(text)"
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
        guard let client = WatchServices.tmbClient() else { return }
        let next = await NextArrivalsFetcher.nextArrivals(for: place, client: client)
        arrivals = Array(next.prefix(2))
    }
}
