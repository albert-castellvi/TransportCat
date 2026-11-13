import SwiftUI

/// The next five arrivals of one favourite place (spec S22, reviews W1, W2, W3,
/// W4, W12).
///
/// The list re-evaluates itself on a local tick, so a train that has left drops
/// off and the countdowns advance without a network call. The network is the
/// shared `WatchArrivalsStore`: one pass on appear, one every 60 s while the
/// screen is up, and one whenever the app comes back to the foreground.
///
/// When what is on screen is not a live answer, the screen says so: no
/// connection, the age of the data, or which kind of empty this is.
@MainActor
struct WatchPlaceDetailView: View {
    let place: Place

    @Environment(WatchArrivalsStore.self) private var arrivals

    var body: some View {
        TimelineView(.periodic(from: .now, by: WatchArrivalFormatting.tick)) { context in
            List {
                arrivalRows(now: context.date)
                if let caption = freshnessCaption(now: context.date) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                reloadRow
            }
        }
        .navigationTitle(place.name)
        .task(id: arrivals.generation) { await refreshLoop() }
    }

    @ViewBuilder
    private func arrivalRows(now: Date) -> some View {
        let board = arrivals.board(for: place.id)
        let visible = board.flatMap { board in
            board.fetchedAt.map {
                WatchArrivalFormatting.visible(
                    board.arrivals,
                    fetched: $0,
                    at: now,
                    limit: WatchArrivalsStore.boardLimit
                )
            }
        } ?? []

        if visible.isEmpty {
            Text(WatchBoardStatus.of(board).text)
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

    /// What the screen is not saying with its rows (review W3): whether the last
    /// attempt reached the feeds, and how old the shown data is. Same wording as
    /// the widget's footer.
    private func freshnessCaption(now: Date) -> String? {
        guard let board = arrivals.board(for: place.id),
              let fetchedAt = board.fetchedAt,
              !board.arrivals.isEmpty
        else { return nil }

        let age = Freshness.ageText(since: fetchedAt, now: now)
        if board.lastAttemptFailed {
            return String(localized: "Sense connexió · dades de \(age)")
        }
        if board.freshness(now: now) == .stale {
            return String(localized: "Dades de \(age)")
        }
        return nil
    }

    /// Review W12: the schedule can be a minute old when the rider needs it now,
    /// and watchOS has no pull-to-refresh. The haptic is the only confirmation
    /// the tap did something: it also says whether the numbers changed, and
    /// whether the watch could reach the feeds at all (review W17).
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
        WatchRefreshHaptic.play(
            changed: changed,
            failed: arrivals.board(for: place.id)?.lastAttemptFailed ?? true
        )
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
