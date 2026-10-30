import SwiftUI

/// Detail of one station: active incidents of the line plus live arrivals
/// polled directly from i-Metro.
struct StationDetailView: View {
    let station: Station
    let line: MetroLine

    @EnvironmentObject private var app: AppModel
    @State private var arrivals: [Arrival] = []
    @State private var errorMessage: String?
    /// Distinguishes "fetch still running" from "fetch done, no trains".
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismiss

    /// Incidents of this station on this line, from the alerts feed (S4).
    private var incidents: [StationIncident] {
        IncidentIndex.incidents(
            for: app.alerts,
            stations: [station],
            lineCode: line.code
        )[station.code] ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if !incidents.isEmpty {
                    Section("Incidències") {
                        ForEach(incidents) { incident in
                            IncidentRow(incident: incident)
                        }
                    }
                }
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
                            description: Text("TMB no publica les arribades d'aquesta línia ara mateix.")
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

/// One incident of a station: kind icon, title and the full alert text (S4).
private struct IncidentRow: View {
    let incident: StationIncident

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(incident.kind.incidentIconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(Color(hex: "F59E0B"))
            VStack(alignment: .leading, spacing: 2) {
                Text(incident.title)
                    .font(.body.weight(.bold))
                if let text = incident.text, !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // Full text, never clipped by the row height (spec S9).
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
