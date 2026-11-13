import SwiftUI

/// Sheet of one live bus (spec S10), opened by tapping its marker on the bus
/// map or by an `AppRouter` vehicle focus.
///
/// It mirrors `FGCTrainSheet`: the bus is read from the line's state by id
/// instead of taken as a snapshot, so the sheet stays live while it is open —
/// the next poll updates the next stop and the countdown in place. The
/// "Seguir" button writes the same `followingVehicleID` binding the FGC map
/// uses, and the map owns the camera bookkeeping.
@MainActor
struct BusVehicleSheet: View {
    /// Live state of the line the bus runs on. A `BusLineState` is per screen
    /// (unlike `FGCNetworkState.shared`), so the map hands its own over.
    let state: BusLineState
    /// `BusPosition.id` of the bus on screen.
    let positionID: String
    /// The map passes `true`; a screen without a camera hides the follow
    /// button, exactly as the FGC lines list does for its trains.
    var allowFollow = false
    /// The id the map camera follows, or nil. Bound to the map's state when
    /// the sheet comes from there; a `.constant(nil)` otherwise.
    @Binding var followingVehicleID: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let position = state.positions.first(where: { $0.id == positionID }) {
                        busContent(position)
                    } else {
                        // The feed dropped this bus while the sheet was open.
                        Text("El bus ja no circula per la línia ara mateix.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Bus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
    }

    /// Everything the sheet shows for a bus: badge, direction and destination,
    /// the next stop with its estimated arrival, and the follow button.
    private func busContent(_ position: BusPosition) -> some View {
        let line = state.line
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(line.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: line.textColorHex))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(hex: line.colorHex)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading(for: position))
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let direction = direction(for: position) {
                        Text("\(direction.name) · cap a \(direction.destinationName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pròxima parada")
                    .font(.headline)
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(hex: line.colorHex))
                        .frame(width: 8, height: 8)
                    Text(stopName(for: position))
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Text(arrivalText(for: position))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(position.train.isDwelling ? Color.green : Color.primary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pròxima parada \(stopName(for: position)), \(arrivalText(for: position))")

            if allowFollow {
                Button {
                    withAnimation {
                        followingVehicleID = followingVehicleID == positionID ? nil : positionID
                    }
                } label: {
                    Label(
                        followingVehicleID == positionID ? "Deixar de seguir" : "Seguir",
                        systemImage: followingVehicleID == positionID ? "location.slash.fill" : "location.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: line.colorHex))
                // The follow happens on the map behind the sheet, so confirm it here (UX-20).
                .sensoryFeedback(.selection, trigger: followingVehicleID)
            }
        }
    }

    /// The sheet's big line: "Cap a <caps>", the live headsign the engine
    /// carries, falling back to the direction's own destination when the feed
    /// named none.
    private func heading(for position: BusPosition) -> String {
        if !position.train.destination.isEmpty {
            return "Cap a \(position.train.destination)"
        }
        if let destination = direction(for: position)?.destinationName, !destination.isEmpty {
            return "Cap a \(destination)"
        }
        return "Destí desconegut"
    }

    /// The direction the bus travels, or nil when the feed placed it on one
    /// the topology no longer lists.
    private func direction(for position: BusPosition) -> BusDirection? {
        state.directions.first { $0.id == position.directionID }
    }

    /// Name of the stop the bus is approaching: `nextStationCode` is a bus
    /// stop code here, resolved against the bus's own direction first.
    private func stopName(for position: BusPosition) -> String {
        let code = position.train.nextStationCode
        if let stop = direction(for: position)?.stops.first(where: { $0.code == code }) {
            return stop.name
        }
        if let stop = state.directions.flatMap(\.stops).first(where: { $0.code == code }) {
            return stop.name
        }
        return "Parada \(code)"
    }

    /// Countdown of the next stop, anchored to the poll that measured it: the
    /// feed's `seconds` are relative to the poll time, and the sheet re-renders
    /// on every 10 Hz position tick, so this stays honest while it is open.
    private func arrivalText(for position: BusPosition) -> String {
        let elapsed = state.arrivalsUpdatedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = max(0, Double(position.train.secondsToArrival) - elapsed)
        let seconds = Int(remaining)
        return ParadesTimeline.busTimeText(seconds: seconds)
    }
}
