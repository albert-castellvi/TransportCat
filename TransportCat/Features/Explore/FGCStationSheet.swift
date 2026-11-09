import SwiftUI

/// FGC station detail opened from Explora (spec S12): the live trains stopped
/// at this station or announcing it as a next stop, each as line badge,
/// destination and punctuality. It reads the shared `FGCNetworkState`, exactly
/// like the map's train sheet, so the data never forks.
@MainActor
struct FGCStationSheet: View {
    let place: Place

    @Environment(\.dismiss) private var dismiss
    /// The map mode that keeps the single `RootView` poller alive (spec S6):
    /// under metro and bus nothing polls FGC, so the sheet owns the refresh of
    /// the snapshot it reads.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    /// Whether the sheet's last refresh attempt failed. The shared flag says
    /// what happened to the polling loop, which is not running under every
    /// mode, so the sheet keeps its own answer and can offer a retry.
    @State private var didFail = false
    /// Whether a catch-up poll is in flight, so a retry cannot stack up.
    @State private var isRefreshing = false

    private var state: FGCNetworkState { FGCNetworkState.shared }

    /// Whether `RootView`'s `.task(id: mode)` is polling FGC right now (S6).
    private var mapPollsFGC: Bool {
        let mode = AppMode(rawValue: modeRaw) ?? .metro
        return mode == .fgc || mode == .global
    }

    /// Trains at or heading to the station (feed order).
    private var trainsHere: [FGCTrain] {
        state.trains.filter {
            $0.stoppedAtStopCode == place.code || $0.nextStopCodes.contains(place.code)
        }
    }

    /// The GTFS `wheelchair_boarding` state joined into the station catalog
    /// (spec S17). 0 and "no row at all" stay hidden: GTFS calls 0 "no
    /// information", and inventing a wheelchair verdict from silence is worse
    /// than saying nothing.
    @ViewBuilder
    private var accessibilitySection: some View {
        let boarding = state.stations.first(where: { $0.code == place.code })?.wheelchairBoarding
        if boarding == 1 || boarding == 2 {
            Section("Accessibilitat") {
                Label(boarding == 1 ? "Accessible" : "No accessible", systemImage: "figure.roll")
                    .foregroundStyle(boarding == 1 ? Color.green : Color(hex: "F59E0B"))
                    .accessibilityLabel(boarding == 1 ? "Estació accessible" : "Estació no accessible")
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                accessibilitySection
                refreshFailureSection
                Section {
                    if trainsHere.isEmpty {
                        Text(emptyText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(trainsHere) { train in
                        trainRow(train)
                    }
                } header: {
                    Text("Trens ara mateix")
                }
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
            // The sheet's own catch-up (the RootView poller is cancelled under
            // the metro and bus modes, spec S6): refresh on appear and then on
            // the same 30 s cadence, so a sheet left open never presents a
            // snapshot nothing refreshes. A failed poll surfaces the retry
            // section instead of the loading text.
            .task {
                while !Task.isCancelled {
                    await refreshIfStale()
                    do {
                        try await Task.sleep(
                            nanoseconds: FGCNetworkState.pollIntervalSeconds * 1_000_000_000
                        )
                    } catch {
                        return
                    }
                }
            }
        }
    }

    /// Surfaces a failed refresh with the action that retries it: the sheet
    /// must never fall back to an endless "Carregant dades FGC…".
    @ViewBuilder
    private var refreshFailureSection: some View {
        if didFail {
            Section {
                Label(
                    "No s'han pogut actualitzar les dades de FGC.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button("Torna-ho a provar") {
                    Task { await refresh() }
                }
                .disabled(isRefreshing)
            }
        }
    }

    /// Refreshes the shared snapshot when it is missing or older than one poll
    /// interval, and never while the map's poller owns it. A topology that
    /// never loads is a failure too: there is nothing to poll.
    private func refreshIfStale() async {
        if state.lines.isEmpty {
            await state.loadTopology()
        }
        guard !state.lines.isEmpty else {
            didFail = true
            return
        }
        guard !mapPollsFGC else {
            didFail = state.lastPollFailed
            return
        }
        let isStale = state.arrivalsUpdatedAt.map {
            Date().timeIntervalSince($0) >= TimeInterval(FGCNetworkState.pollIntervalSeconds)
        } ?? true
        guard isStale else {
            didFail = state.lastPollFailed
            return
        }
        await refresh()
    }

    /// One poll pass with the sheet's own failure flag. `poll()` keeps the
    /// previous trains on failure, so a stale snapshot stays readable.
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await state.poll()
        didFail = state.lastPollFailed
    }

    /// An honest statement per stage: nothing loaded yet, a failed refresh, or
    /// the feed answered and no train is near.
    private var emptyText: String {
        if didFail { return "No s'han pogut carregar les arribades de FGC." }
        return state.arrivalsUpdatedAt == nil ? "Carregant dades FGC…" : "Cap tren proper ara mateix."
    }

    /// Line pill, destination and the punctuality label (spec S12).
    private func trainRow(_ train: FGCTrain) -> some View {
        let style = FGCNetwork.style(for: train.lineCode, in: state.lines)
        let destination = train.destinationName ?? train.destinationCode
        return HStack(spacing: 10) {
            Text(style.label)
                .font(.caption2.bold())
                .foregroundStyle(Color(hex: style.textColorHex))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(hex: style.colorHex)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Línia \(style.label)")
            VStack(alignment: .leading, spacing: 2) {
                Text(train.stoppedAtStopCode == place.code
                    ? "Aturat a \(place.name)"
                    : "Cap a \(destination)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(train.isOnTime ? "Puntual" : "Amb retard")
                    .font(.caption)
                    .foregroundStyle(train.isOnTime ? Color.green : Color(hex: "F59E0B"))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
