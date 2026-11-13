import SwiftUI

/// Sheet of one live Rodalies train, opened from the map's selection card or
/// from a train marker on the Parades timeline.
///
/// It reads the train from `RodaliesNetworkState.shared` by id instead of taking
/// a snapshot, so the sheet stays live while it is open: the next poll updates
/// the destination, the next stop and the punctuality in place.
struct RodaliesTrainSheet: View {
    /// `MapVehicle.id` of the train on screen.
    let vehicleID: String
    /// The map passes `true`; the Parades timeline has no camera to drive, so it
    /// hides the follow button.
    var allowFollow = false
    /// The id the map follows, or nil. Bound to the map's state when the sheet
    /// comes from there; a `.constant(nil)` otherwise.
    @Binding var followingVehicleID: String?

    @Environment(\.dismiss) private var dismiss

    private var state: RodaliesNetworkState { RodaliesNetworkState.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let train = state.liveTrain(id: vehicleID) {
                        trainContent(train)
                    } else {
                        // The feed dropped this train while the sheet was open.
                        Text("El tren ja no circula per la xarxa ara mateix.")
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

    private func trainContent(_ train: RodaliesLiveTrain) -> some View {
        let colorHex = state.colorHex(for: train.lineCode)
        let textColorHex = state.lines.first { $0.code == train.lineCode }?.textColorHex
            ?? FGCNetwork.neutralTextColorHex
        let status = RodaliesDepartureText.delay(seconds: train.delaySeconds)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RodaliesLineBadge(
                    code: train.lineCode,
                    colorHex: colorHex,
                    textColorHex: textColorHex
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading(for: train))
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status.text)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(delayColor(status))
                }
                Spacer(minLength: 0)
            }

            if let stopID = train.currentStopID, train.status == "STOPPED_AT" {
                Label(
                    "Aturat a \(state.stationName(id: stopID))",
                    systemImage: "pause.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if let stopID = train.nextStopID {
                Label(
                    "Pròxima: \(state.stationName(id: stopID))",
                    systemImage: "arrow.right.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if allowFollow {
                Button {
                    withAnimation {
                        followingVehicleID = followingVehicleID == vehicleID ? nil : vehicleID
                    }
                } label: {
                    Label(
                        followingVehicleID == vehicleID ? "Deixar de seguir" : "Seguir",
                        systemImage: followingVehicleID == vehicleID ? "location.slash.fill" : "location.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: colorHex))
                // The follow happens on the map behind the sheet, so confirm it
                // here, as the FGC sheet does.
                .sensoryFeedback(.selection, trigger: followingVehicleID)
            }

            // Renfe positions are GPS fixes: never an estimate.
            VehiclePositionSource(isEstimated: false, estimatedText: "")
        }
    }

    /// The sheet's big line: "Cap a Sants", or an honest statement when the
    /// timetable does not know the trip's destination.
    private func heading(for train: RodaliesLiveTrain) -> String {
        guard let headsign = train.headsign, !headsign.isEmpty else {
            return String(localized: "Destí desconegut")
        }
        return String(localized: "Cap a \(headsign)")
    }

    /// Amber for a delay, green for a train the feed confirms on time, and the
    /// secondary ink when the feed says nothing about this one.
    private func delayColor(_ status: RodaliesDelayStatus) -> Color {
        if status.isDelayed { return Color(hex: "F59E0B") }
        if case .onTime = status { return .green }
        return .secondary
    }
}
