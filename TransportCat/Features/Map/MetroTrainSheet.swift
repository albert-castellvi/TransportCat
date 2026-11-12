import SwiftUI

/// Sheet of one metro train (spec S10), opened by tapping its marker on the
/// map or by an `AppRouter` `.vehicle` focus.
///
/// Like `FGCTrainSheet` it reads the train from the line state by id instead
/// of showing the snapshot taken at tap time, so the destination, the next
/// station and the countdown keep updating while the sheet is open. The
/// camera mechanics stay in `MapScreen`; the sheet only flips
/// `followingTrainID`, exactly as the FGC sheet does.
@MainActor
struct MetroTrainSheet: View {
    /// `TrainPosition.id` of the train on screen.
    let trainID: String
    /// The live state of the line the train runs on.
    let state: LineState
    /// The train the map camera follows, or nil. Bound to the map's state;
    /// closing the sheet stops the follow there, not here.
    @Binding var followingTrainID: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let train = state.vehiclePosition(id: trainID) {
                        trainContent(train)
                    } else {
                        // The feed dropped this train while the sheet was open.
                        Text("El tren ja no circula per la línia ara mateix.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Tren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
    }

    /// Badge, direction, next station with its countdown and the follow
    /// button (spec S10).
    private func trainContent(_ train: TrainPosition) -> some View {
        let line = MetroLine.line(forCode: train.lineCode) ?? state.line
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                // The same pre-rendered badge the line picker shows.
                Image("badge-\(line.assetKey)")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 32)
                    .accessibilityLabel("Línia \(line.displayName)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(train.destination.isEmpty ? "Destí desconegut" : "Cap a \(train.destination)")
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    // A marker from the timetable must never read as live (S7).
                    if train.isTheoretical {
                        Text("Posició teòrica segons l'horari")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let station = state.station(forCode: train.nextStationCode) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pròxima estació")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: line.colorHex))
                            .frame(width: 8, height: 8)
                        Text(station.name)
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        let seconds = train.secondsToArrival
                        let time = seconds <= ParadesTimeline.imminentThresholdSeconds
                            ? ParadesTimeText.now
                            : ParadesTimeText.minutes(Arrival.countdownText(seconds: seconds))
                        Text(time.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(time.isImminent ? Color(hex: "30D158") : .secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Pròxima estació \(station.name), arriba en \(time.text)"
                    )
                }
            }

            Button {
                withAnimation {
                    followingTrainID = followingTrainID == trainID ? nil : trainID
                }
                .sensoryFeedback(.selection, followingTrainID == train ? nil : .selection)
            } label: {
                Label(
                    followingTrainID == trainID ? "Deixar de seguir" : "Seguir",
                    systemImage: followingTrainID == trainID ? "location.slash.fill" : "location.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: line.colorHex))
        }
    }
}
