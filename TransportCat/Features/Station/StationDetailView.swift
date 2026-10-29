import SwiftUI

/// Detail of one station: live arrivals polled directly from i-Metro.
struct StationDetailView: View {
    let station: Station
    let line: MetroLine

    @State private var arrivals: [Arrival] = []
    @State private var errorMessage: String?
    /// Distinguishes "fetch still running" from "fetch done, no trains".
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                ForEach(arrivals) { arrival in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(arrival.destination.isEmpty ? "—" : arrival.destination)
                                .font(.body.weight(.medium))
                            Text(arrival.rawText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let seconds = arrival.seconds {
                            Text(Arrival.countdownText(seconds: seconds))
                                .font(.title3.bold().monospacedDigit())
                                .foregroundStyle(Color(hex: line.colorHex))
                        }
                    }
                }
                if arrivals.isEmpty && errorMessage == nil {
                    if hasLoaded {
                        // Five lines (L9N, L9S, L10N, L10S, FM) report no
                        // arrivals at all: say so instead of spinning forever.
                        ContentUnavailableView(
                            "Sense dades en temps real",
                            systemImage: "clock.badge.exclamationmark",
                            description: Text("Aquesta línia no publica arribades ara mateix.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ProgressView("Consultant arribades…")
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(station.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
            .task {
                await refresh()
            }
            .refreshable {
                await refresh()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func refresh() async {
        do {
            let client = try TMBClient.fromBundle()
            let fetched = try await client.metroArrivals(lineCode: line.code, stationCodes: [station.code])
            arrivals = fetched[station.code] ?? []
            errorMessage = nil
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
