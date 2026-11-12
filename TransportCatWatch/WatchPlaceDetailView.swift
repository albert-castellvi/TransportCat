import SwiftUI
import WatchKit

/// The next five arrivals of one favourite place (spec S22, reviews W1, W2,
/// W4, W12).
///
/// The list re-evaluates itself on a local tick, so a train that has left drops
/// off and the countdowns advance without a network call. The network is the
/// shared `WatchArrivalsStore`: one pass on appear, one every 60 s while the
/// screen is up, and one whenever the app comes back to the foreground.
@MainActor
struct WatchPlaceDetailView: View {
    let place: Place

    @Environment(WatchArrivalsStore.self) private var arrivals

    var body: some View {
        TimelineView(.periodic(from: .now, by: WatchArrivalFormatting.tick)) { context in
            List {
                arrivalRows(now: context.date)
                reloadRow
            }
        }
        .navigationTitle(place.name)
        .task(id: arrivals.generation) { await refreshLoop() }
    }

    @ViewBuilder
    private func arrivalRows(now: Date) -> some View {
        let board = arrivals.board(for: place.id)
        let visible = board.map {
            WatchArrivalFormatting.visible(
                $0.arrivals,
                fetched: $0.fetchedAt,
                at: now,
                limit: WatchArrivalsStore.boardLimit
            )
        } ?? []

        if visible.isEmpty {
            Text(board == nil ? "Carregant…" : "Sense arribades ara mateix")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            // Identified by the position in this fetch, not by
            // `NextArrival.id`: the FGC open feed has no minutes, so every train
            // of one fetch shares line, destination and date, and two trains of
            // one line to the same terminus would repeat the id inside this
            // `ForEach` (bug #41).
            ForEach(Array(visible.enumerated()), id: \.offset) { pair in
                WatchArrivalRow(
                    arrival: pair.element,
                    colorHex: WatchLineColor.hex(forLine: pair.element.line, in: place),
                    now: now
                )
            }
        }
    }

    /// Review W12: the schedule can be a minute old when the rider needs it now,
    /// and watchOS has no pull-to-refresh. The haptic is the only confirmation
    /// the tap did something: two different ones, so it also says whether the
    /// numbers changed.
    private var reloadRow: some View {
        Button {
            Task { await reload() }
        } label: {
            Label("Recarrega", systemImage: "arrow.clockwise")
        }
        .disabled(arrivals.isRefreshing)
    }

    private func reload() async {
        let changed = await arrivals.refresh([place], maxAge: 0)
        WKInterfaceDevice.current().play(changed ? .success : .click)
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await arrivals.refresh([place])
            do {
                try await Task.sleep(nanoseconds: UInt64(WatchArrivalsStore.refreshInterval * 1_000_000_000))
            } catch {
                return
            }
        }
    }
}
