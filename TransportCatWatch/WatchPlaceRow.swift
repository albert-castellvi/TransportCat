import SwiftUI

/// One favourite place: its name and its next arrival (spec S22, reviews W3, W4,
/// W5, W8, W11, W14).
///
/// The row reads from the shared `WatchArrivalsStore`, which owns the network,
/// and redraws itself on a local tick so the countdown advances without a fetch.
/// The destination is shown because the soonest train at a station is often not
/// the one the rider wants, and when there is nothing to show the row says which
/// kind of nothing it is — still loading, no connection, nothing coming, or data
/// that has aged.
@MainActor
struct WatchPlaceRow: View {
    let place: Place

    @Environment(WatchArrivalsStore.self) private var arrivals

    var body: some View {
        TimelineView(.periodic(from: .now, by: WatchArrivalFormatting.tick)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let board = arrivals.board(for: place.id)
        let arrival = soonest(in: board, at: now)
        return VStack(alignment: .leading, spacing: 2) {
            Text(place.name)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Text(lead(board, arrival))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let arrival {
                    Text(WatchArrivalFormatting.countdown(until: arrival.date, now: now))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(
                            ArrivalBoard.isDue(arrival.date, now: now)
                                ? Color(hex: WatchLineColor.imminentHex)
                                : Color.primary
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(board: board, arrival: arrival, now: now))
    }

    private func soonest(in board: WatchArrivalsBoard?, at now: Date) -> NextArrival? {
        guard let board, let fetchedAt = board.fetchedAt else { return nil }
        return WatchArrivalFormatting.soonest(board.arrivals, fetched: fetchedAt, at: now)
    }

    /// The line and destination, or the reason there is no row: one of the four
    /// states `WatchBoardStatus` distinguishes.
    private func lead(_ board: WatchArrivalsBoard?, _ arrival: NextArrival?) -> String {
        guard let arrival else { return WatchBoardStatus.of(board).text }
        return WatchArrivalFormatting.lead(arrival)
    }

    private func accessibilityLabel(
        board: WatchArrivalsBoard?,
        arrival: NextArrival?,
        now: Date
    ) -> String {
        guard let arrival else { return "\(place.name). \(lead(board, arrival))" }
        let spoken = WatchArrivalFormatting.spokenCountdown(until: arrival.date, now: now)
        return "\(place.name). \(WatchArrivalFormatting.lead(arrival)), \(spoken)"
    }
}
