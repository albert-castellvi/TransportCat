import SwiftUI

/// Sheet of one live FGC train (spec S8), opened by tapping its marker on the
/// map or a train badge in the lines list.
///
/// It reads the train from `FGCNetworkState.shared` by id instead of taking a
/// snapshot value, so the sheet stays live while it is open: the next poll
/// updates the destinations, the next stops and the occupancy in place.
struct FGCTrainSheet: View {
    /// `FGCTrain.id` of the train on screen.
    let trainID: String
    /// The map screen passes `true`; the lines list has no camera to drive,
    /// so it hides the follow button (spec S9).
    var allowFollow = false
    /// The id the map screen follows, or nil. Bound to the map's state when
    /// the sheet comes from there; a `.constant(nil)` otherwise.
    @Binding var followingVehicleID: String?

    @Environment(\.dismiss) private var dismiss

    private var state: FGCNetworkState { FGCNetworkState.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let train = state.trains.first(where: { $0.id == trainID }) {
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

    /// Everything the sheet shows for a train: badge, direction, punctuality,
    /// the optional "Aturat a", the follow button, next stops and occupancy.
    private func trainContent(_ train: FGCTrain) -> some View {
        let style = FGCNetwork.style(for: train.lineCode, in: state.lines)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(style.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: style.textColorHex))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(hex: style.colorHex)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading(for: train))
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(train.isOnTime ? "Puntual" : "Amb retard")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(train.isOnTime ? Color.green : Color(hex: "F59E0B"))
                }
                Spacer(minLength: 0)
            }

            if let stopCode = train.stoppedAtStopCode {
                Label("Aturat a \(stationName(for: stopCode))", systemImage: "pause.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if allowFollow {
                Button {
                    withAnimation {
                        followingVehicleID = followingVehicleID == trainID ? nil : trainID
                    }
                } label: {
                    Label(
                        followingVehicleID == trainID ? "Deixar de seguir" : "Seguir",
                        systemImage: followingVehicleID == trainID ? "location.slash.fill" : "location.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: style.colorHex))
                // The follow happens on the map behind the sheet, so confirm it here (UX-20).
                .sensoryFeedback(.selection, trigger: followingVehicleID)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Properes parades")
                    .font(.headline)
                if train.nextStopCodes.isEmpty {
                    Text("Cap pròxima parada anunciada.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(train.nextStopCodes, id: \.self) { code in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: style.colorHex))
                            .frame(width: 8, height: 8)
                        Text(stationName(for: code))
                            .font(.subheadline)
                    }
                }
            }

            // Only when the feed actually measures a car: most trains report
            // no occupancy at all and the block would be an empty frame (S8).
            if !train.occupancy.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ocupació")
                        .font(.headline)
                    ForEach(train.occupancy, id: \.car) { car in
                        occupancyRow(car, style: style)
                    }
                }
            }
        }
    }

    /// One car: its feed code, a small bar filled to the percentage and the
    /// number itself.
    private func occupancyRow(_ car: FGCCarOccupancy, style: FGCLineStyle) -> some View {
        let percent = min(max(car.percent ?? 0, 0), 100)
        return HStack(spacing: 10) {
            Text(car.car)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color(hex: style.colorHex))
                        .frame(width: max(4, proxy.size.width * Double(percent) / 100))
                }
            }
            .frame(height: 8)
            Text("\(percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cotxe \(car.car), ocupació \(percent) per cent")
    }

    /// The destination name the feed carried; the raw code as fallback.
    private func destination(of train: FGCTrain) -> String {
        train.destinationName ?? train.destinationCode
    }

    /// The sheet's big line: "Cap a Terrassa", or an honest statement when the
    /// feed names no destination at all.
    private func heading(for train: FGCTrain) -> String {
        let destination = destination(of: train)
        return destination.isEmpty ? "Destí desconegut" : "Cap a \(destination)"
    }

    /// Station name of a stop code, falling back to the code when the catalog
    /// does not know it.
    private func stationName(for code: String) -> String {
        state.stations.first { $0.code == code }?.name ?? code
    }
}
