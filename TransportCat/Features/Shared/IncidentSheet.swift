import SwiftUI

/// Detail sheet of one or more service alerts (spec S7).
///
/// Every map that marks incidents opens this sheet, so the alert copy, the
/// affected lines and stations, the validity dates and the effect read the same
/// everywhere. Presented at medium and large detents; the rider can pull it up
/// for the full text without losing the map behind it.
struct IncidentSheet: View {
    let alerts: [ServiceAlert]
    let title: String

    @Environment(\.dismiss) private var dismiss

    init(alerts: [ServiceAlert], title: String) {
        self.alerts = alerts
        self.title = title
    }

    var body: some View {
        NavigationStack {
            Group {
                if alerts.isEmpty {
                    ContentUnavailableView(
                        "Sense incidències",
                        systemImage: "checkmark.circle",
                        description: Text("Ara mateix no hi ha cap afectació activa.")
                    )
                } else {
                    List {
                        ForEach(alerts) { alert in
                            IncidentSheetRow(alert: alert)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One alert: effect, cleaned text, affected lines, stations and dates.
private struct IncidentSheetRow: View {
    let alert: ServiceAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image("icon-alert")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(severityColor)
                Text(effect ?? "Incidència")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let text {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !alert.lineCodes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(alert.lineCodes, id: \.self) { code in
                        LineTag(code: code)
                    }
                }
            }

            if !alert.stationNames.isEmpty {
                DetailLine(icon: "mappin.and.ellipse", text: alert.stationNames.joined(separator: ", "))
            }

            if let datesText {
                DetailLine(icon: "calendar", text: datesText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var text: String? {
        AlertText.cleaned(alert.text)
    }

    private var effect: String? {
        AlertText.effect(for: alert)
    }

    /// Red when the service itself is affected, orange for a facility.
    private var severityColor: Color {
        alert.severity == .service ? Color(hex: "D92D20") : Color(hex: "F59E0B")
    }

    /// Begin, end or the range between them, whichever the feed provides.
    private var datesText: String? {
        switch (alert.beginDate, alert.endDate) {
        case let (begin?, end?):
            return "\(Self.day(begin)) – \(Self.day(end))"
        case let (begin?, nil):
            return Self.day(begin)
        case let (nil, end?):
            return Self.day(end)
        case (nil, nil):
            return nil
        }
    }

    /// One spoken sentence with everything the row shows.
    private var accessibilityText: String {
        [effect ?? "Incidència", text, linesText, stationsText, datesText]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    private var linesText: String? {
        guard !alert.lineCodes.isEmpty else { return nil }
        return "Línies: " + alert.lineCodes.map(IncidentSheetRow.lineLabel).joined(separator: ", ")
    }

    private var stationsText: String? {
        guard !alert.stationNames.isEmpty else { return nil }
        return "Estacions: " + alert.stationNames.joined(separator: ", ")
    }

    /// Metro codes become their display name ("1" -> "L1"); every other code
    /// (bus line ids, FGC codes already human-readable) stays as delivered.
    static func lineLabel(_ code: String) -> String {
        MetroLine.line(forCode: code)?.displayName ?? code
    }

    private static func day(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()
}

/// Small line badge coloured with the metro colour when the code is a metro
/// line, neutral grey otherwise (bus and FGC codes have no colour here).
private struct LineTag: View {
    let code: String

    private var color: Color {
        if let line = MetroLine.line(forCode: code) {
            return Color(hex: line.colorHex)
        }
        return Color(white: 0.35)
    }

    private var textColor: Color {
        if let line = MetroLine.line(forCode: code) {
            return HexLuminance.isLight(line.colorHex) ? .black : .white
        }
        return .white
    }

    var body: some View {
        Text(IncidentSheetRow.lineLabel(code))
            .font(.caption2.bold())
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
            .accessibilityLabel("Línia \(IncidentSheetRow.lineLabel(code))")
    }
}

/// One secondary line of the row: icon plus text.
private struct DetailLine: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
