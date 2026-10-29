import SwiftUI

/// Detail of one station: live arrivals polled directly from iBus.
struct StationDetailView: View {
    let station: Station
    let line: MetroLine

    @State private var arrivals: [Arrival] = []
    @State private var errorMessage: String?
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
                            Text(countdown(seconds: seconds))
                                .font(.title3.bold().monospacedDigit())
                                .foregroundStyle(Color(hex: line.colorHex))
                        }
                    }
                }
                if arrivals.isEmpty && errorMessage == nil {
                    ProgressView("Consultant arribades…")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
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
            arrivals = try await client.arrivals(lineCode: line.code, stopCode: station.code)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func countdown(seconds: Int) -> String {
        seconds < 60 ? "<1 min" : "\(seconds / 60) min"
    }
}
