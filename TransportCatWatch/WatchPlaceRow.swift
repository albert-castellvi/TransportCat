import SwiftUI

/// One favourite place: its name and its next arrival (spec S22, reviews W4,
/// W5, W8, W11, W14).
///
/// The row reads from the shared `WatchArrivalsStore`, which owns the network,
/// and redraws itself on a local tick so the countdown advances without a
/// fetch. The destination is shown because the soonest train at a station is
/// often not the one the rider wants.
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
        let arrival = soonest(at: now)
        return VStack(alignment: .leading, spacing: 2) {
            Text(place.name)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Text(lead(arrival))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let arrival {
                    Text(WatchArrivalFormatting.countdown(until: arrival.date, now: now))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(
                            arrival.date <= now
                                ? WatchLineColor.color(WatchLineColor.imminentHex)
                                : Color.primary
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(arrival: arrival, now: now))
    }

    private func soonest(at now: Date) -> NextArrival? {
        guard let board = arrivals.board(for: place.id) else { return nil }
        return WatchArrivalFormatting.soonest(board.arrivals, fetched: board.fetchedAt, at: now)
    }

    private func lead(_ arrival: NextArrival?) -> String {
        guard arrivals.board(for: place.id) != nil else { return "Carregant…" }
        guard let arrival else { return "Sense arribades ara mateix" }
        return WatchArrivalFormatting.lead(arrival)
    }

    private func accessibilityLabel(arrival: NextArrival?, now: Date) -> String {
        guard let arrival else { return "\(place.name). \(lead(arrival))" }
        let spoken = WatchArrivalFormatting.spokenCountdown(until: arrival.date, now: now)
        return "\(place.name). \(WatchArrivalFormatting.lead(arrival)), \(spoken)"
    }
}
