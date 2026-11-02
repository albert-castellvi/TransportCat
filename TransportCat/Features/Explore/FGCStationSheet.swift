import SwiftUI

/// FGC station detail opened from Explora (spec S12): the live trains stopped
/// at this station or announcing it as a next stop, each as line badge,
/// destination and punctuality. It reads the shared `FGCNetworkState`, exactly
/// like the map's train sheet, so the data never forks.
@MainActor
struct FGCStationSheet: View {
    let place: Place

    @Environment(\.dismiss) private var dismiss

    private var state: FGCNetworkState { FGCNetworkState.shared }

    /// Trains at or heading to the station (feed order).
    private var trainsHere: [FGCTrain] {
        state.trains.filter {
            $0.stoppedAtStopCode == place.code || $0.nextStopCodes.contains(place.code)
        }
    }

    var body: some View {
        NavigationStack {
            List {
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
            // One-off catch-up when the app has never run the FGC poller: the
            // RootView keeps the single poller loop while an FGC screen is
            // visible (spec S6), so this sheet only tops the state up when it
            // has never answered. `run()` is deliberately not called here.
            .task {
                if state.lines.isEmpty {
                    await state.loadTopology()
                }
                if state.arrivalsUpdatedAt == nil && !state.lastPollFailed {
                    await state.poll()
                }
            }
        }
    }

    /// An honest statement per stage: nothing loaded yet, or the feed answered
    /// and no train is near.
    private var emptyText: String {
        state.arrivalsUpdatedAt == nil ? "Carregant dades FGC…" : "Cap tren proper ara mateix."
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
