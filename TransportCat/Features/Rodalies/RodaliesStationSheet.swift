import SwiftUI

/// The detail of a Rodalies station: the next departures of its board, its
/// accessibility when the topology publishes one, and the way to the map.
///
/// The departures come from the daily timetable pack and Renfe's realtime
/// delays, both behind `RodaliesNetworkState.shared`, so the sheet and the
/// Parades timeline can never disagree. The three empty states are distinct on
/// purpose: loading, "no departure expected", and a failed read with the action
/// that retries it.
@MainActor
struct RodaliesStationSheet: View {
    let place: Place
    /// "Veure al mapa": set by Explora, which routes the rider to the map. The
    /// map itself leaves it nil — the rider is already there.
    var onSeeOnMap: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    /// The map mode that keeps `RootView`'s single Rodalies poller alive. Under
    /// any other mode the sheet owns its own catch-up poll.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue

    /// What the board is showing right now.
    private enum Phase {
        case loading
        case ready
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var board: [RodaliesDeparture] = []
    /// The clock the countdowns are drawn against, advanced by the same loop
    /// that refreshes the board.
    @State private var now = Date()
    /// Whether a refresh is in flight, so a retry cannot stack up.
    @State private var isRefreshing = false

    /// Refresh period of the board: the same 30 s as the feeds.
    private static let refreshIntervalNanoseconds: UInt64 = 30_000_000_000

    private var state: RodaliesNetworkState { RodaliesNetworkState.shared }

    /// Whether `RootView`'s `.task(id: mode)` is polling Rodalies right now.
    private var mapPollsRodalies: Bool {
        (AppMode(rawValue: modeRaw) ?? .metro) == .rodalies
    }

    private var topology: RodaliesTopology? {
        state.topology ?? RodaliesTopology.bundled
    }

    /// The station as the topology knows it, for the accessibility flag.
    private var station: RodaliesStation? {
        topology?.station(id: place.code)
    }

    private var timeZone: TimeZone {
        state.schedule.map(RodaliesDepartures.timeZone(of:)) ?? .current
    }

    var body: some View {
        NavigationStack {
            List {
                accessibilitySection
                departuresSection
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    FavoriteStarButton(place: place)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { mapLinkBar }
            // Refresh on appear and then on the feed's own 30 s cadence, so a
            // sheet left open never presents a snapshot nothing refreshes.
            .task {
                while !Task.isCancelled {
                    await refresh()
                    do {
                        try await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    // MARK: - Sections

    /// The GTFS `wheelchair_boarding` state the topology publishes. 0 and "no
    /// row at all" stay hidden: inventing a verdict from silence is worse than
    /// saying nothing, exactly as `FGCStationSheet` does.
    @ViewBuilder
    private var accessibilitySection: some View {
        if let boarding = station?.wheelchairBoarding, boarding == 1 || boarding == 2 {
            Section("Accessibilitat") {
                Label(boarding == 1 ? "Accessible" : "No accessible", systemImage: "figure.roll")
                    .foregroundStyle(boarding == 1 ? Color.green : Color(hex: "F59E0B"))
                    .accessibilityLabel(boarding == 1 ? "Estació accessible" : "Estació no accessible")
            }
        }
    }

    private var departuresSection: some View {
        Section {
            switch phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Carregant els horaris…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "No s'han pogut carregar els horaris de Rodalies.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Button("Torna-ho a provar") {
                        Task { await refresh() }
                    }
                    .disabled(isRefreshing)
                }
            case .ready:
                if board.isEmpty {
                    Text("Cap sortida prevista")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(board) { departure in
                    departureRow(departure)
                }
            }
        } header: {
            Text("Properes sortides")
        }
    }

    /// Line badge, destination, countdown and the realtime caption of one
    /// departure.
    private func departureRow(_ departure: RodaliesDeparture) -> some View {
        let line = topology?.line(code: departure.lineCode)
        let time = RodaliesDepartureText.time(
            until: departure.expectedAt,
            now: now,
            timeZone: timeZone
        )
        let status = RodaliesDepartureText.delay(seconds: departure.delaySeconds)
        return HStack(spacing: 10) {
            RodaliesLineBadge(
                code: departure.lineCode,
                colorHex: line?.colorHex ?? FGCNetwork.neutralColorHex,
                textColorHex: line?.textColorHex ?? FGCNetwork.neutralTextColorHex
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Cap a \(departure.headsign)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(statusColor(status))
            }
            Spacer(minLength: 8)
            Text(time.text)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(time.isImminent ? Color(hex: "30D158") : Color.primary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Amber for a delay, green for a train the feed confirms on time, and the
    /// secondary ink when the row is only the timetable.
    private func statusColor(_ status: RodaliesDelayStatus) -> Color {
        if status.isDelayed { return Color(hex: "F59E0B") }
        if case .onTime = status { return .green }
        return .secondary
    }

    /// "Veure al mapa", provided by the screen that opened the sheet from
    /// outside the map.
    @ViewBuilder
    private var mapLinkBar: some View {
        if let onSeeOnMap {
            Button(action: onSeeOnMap) {
                Label("Veure al mapa", systemImage: "map.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }

    // MARK: - Loading

    /// One refresh pass: the topology (bundled, but the state may not have it
    /// yet), the timetable when it is missing, the realtime feeds when the map's
    /// poller is not the one running, and the board itself.
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if state.lines.isEmpty {
            state.loadTopology()
        }
        if state.schedule == nil {
            await state.loadSchedule()
        }
        guard state.schedule != nil else {
            phase = state.isLoadingSchedule ? .loading : .failed
            return
        }
        if !mapPollsRodalies {
            await state.poll()
        }
        now = Date()
        board = state.nextDepartures(stationID: place.code, now: now)
        phase = .ready
    }
}
