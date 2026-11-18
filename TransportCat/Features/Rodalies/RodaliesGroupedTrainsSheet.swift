import SwiftUI

/// The sheet behind the "+N" pill of a Rodalies row: every live train the feed
/// places at that station, with its destination and the delay the feed reports.
///
/// The row draws ONE marker per station, so this list is the only place the
/// rider can tell the trains apart. It is read-only: the picker already shows
/// which line and direction each train belongs to, and the delay is the same
/// wording the station board uses.
@MainActor
struct RodaliesGroupedTrainsSheet: View {
    let stationName: String
    let trains: [RodaliesLiveTrain]

    @Environment(\.dismiss) private var dismiss

    private var state: RodaliesNetworkState { RodaliesNetworkState.shared }

    var body: some View {
        NavigationStack {
            List {
                ForEach(trains) { train in
                    row(train)
                }
            }
            .navigationTitle(String(localized: "Trens a \(stationName)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
    }

    /// Line badge, destination and realtime caption of one train, the same
    /// reading order as the station board.
    private func row(_ train: RodaliesLiveTrain) -> some View {
        let status = RodaliesDepartureText.delay(seconds: train.delaySeconds)
        let destination = train.headsign ?? String(localized: "Destí desconegut")
        return HStack(spacing: 10) {
            RodaliesLineBadge(
                code: train.lineCode,
                colorHex: state.colorHex(for: train.lineCode),
                textColorHex: textColorHex(for: train.lineCode)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Cap a \(destination)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(statusColor(status))
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }

    /// Ink of the line badge, from the same catalog the map and the chip read.
    private func textColorHex(for code: String) -> String {
        state.lines.first { $0.code == code }?.textColorHex ?? FGCNetwork.neutralTextColorHex
    }

    /// Amber for a delay, green for a train the feed confirms on time, and the
    /// secondary ink when the sheet only knows the timetable.
    private func statusColor(_ status: RodaliesDelayStatus) -> Color {
        if status.isDelayed { return Color(hex: "F59E0B") }
        if case .onTime = status { return .green }
        return .secondary
    }
}
