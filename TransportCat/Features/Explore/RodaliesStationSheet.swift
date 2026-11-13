import SwiftUI

/// The sheet of a Rodalies station place (part 1 of the operator).
///
/// It shows only what the bundled topology already knows: the station, the
/// lines that call there and its accessibility. The live board and the
/// timetable arrive with part 2, so this sheet never claims a departure it
/// cannot back with data.
struct RodaliesStationSheet: View {
    let place: Place

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(place.lineCodes, id: \.self) { code in
                        lineRow(code)
                    }
                } header: {
                    Text("Línies")
                }
                if let accessible = place.accessible {
                    Section("Accessibilitat") {
                        Label(
                            accessible ? "Accessible" : "No accessible",
                            systemImage: "figure.roll"
                        )
                        .foregroundStyle(accessible ? Color.green : Color(hex: "F59E0B"))
                        .accessibilityLabel(accessible ? "Estació accessible" : "Estació no accessible")
                    }
                }
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Line pill with the line's own colour, exactly as the maps draw it.
    private func lineRow(_ code: String) -> some View {
        let line = RodaliesTopology.bundled?.line(code: code)
        let colorHex = line?.colorHex ?? FGCNetwork.neutralColorHex
        let textColorHex = line?.textColorHex ?? FGCNetwork.neutralTextColorHex
        return HStack(spacing: 10) {
            Text(code)
                .font(.caption2.bold())
                .foregroundStyle(Color(hex: textColorHex))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(hex: colorHex)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Línia \(code)")
            Text(line?.name ?? code)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
