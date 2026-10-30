import SwiftUI

/// Capsule with how many incidents the line has right now, and a loading state
/// while the alerts feed has not answered for the first time (spec S7).
///
/// It replaces the red `AlertBanner` on the map: the count is all the map needs
/// to stay readable, and the full text is one tap away.
struct IncidentsChip: View {
    let lineCode: String
    let lineDisplayName: String

    @EnvironmentObject private var app: AppModel
    @State private var showIncidents = false

    var body: some View {
        if app.alertsUpdatedAt == nil, app.isLoadingAlerts || app.alertsErrorMessage == nil {
            loadingCapsule
        } else {
            let active = app.activeAlerts(affecting: lineCode)
            if active.isEmpty {
                // Nothing known about this line: show no chip at all.
                EmptyView()
            } else {
                chip(active: active)
            }
        }
    }

    /// Spinner capsule shown until the first successful alerts load.
    private var loadingCapsule: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Actualitzant incidències…")
                .font(.caption2.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Actualitzant incidències…")
    }

    /// Tappable count capsule; the sheet is its only navigation.
    private func chip(active: [ServiceAlert]) -> some View {
        Button {
            showIncidents = true
        } label: {
            Label(countText(active.count), image: "icon-alert")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(incidentsColor(for: active)))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showIncidents) {
            IncidentListSheet(
                lineDisplayName: lineDisplayName,
                alerts: active,
                updatedAt: app.alertsUpdatedAt
            )
            .presentationDetents([.medium, .large])
        }
    }

    /// "1 incidència" / "4 incidències".
    private func countText(_ count: Int) -> String {
        count == 1 ? "1 incidència" : "\(count) incidències"
    }
}

/// Orange when the worst incident is a facility problem, red when the service
/// itself is affected (spec S7).
private func incidentsColor(for alerts: [ServiceAlert]) -> Color {
    alerts.map(\.severity).max() == .service ? Color(hex: "D92D20") : Color(hex: "F59E0B")
}

/// List of the active alerts of one line, opened from `IncidentsChip` (spec S7).
private struct IncidentListSheet: View {
    let lineDisplayName: String
    let alerts: [ServiceAlert]
    /// When the alerts feed last answered; nil only if it never did.
    let updatedAt: Date?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(alerts) { alert in
                        IncidentDetailRow(alert: alert)
                    }
                } header: {
                    headerText
                }
            }
            .navigationTitle("Incidències a \(lineDisplayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
    }

    /// "Actualitzat fa 3 min", ticking with the clock of the sheet.
    @ViewBuilder
    private var headerText: some View {
        if let updatedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Actualitzat \(Freshness.ageText(since: updatedAt, now: context.date))")
            }
        }
    }
}

/// One alert of the sheet: severity icon, text and validity dates (spec S7).
private struct IncidentDetailRow: View {
    let alert: ServiceAlert

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image("icon-alert")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(incidentsColor(for: [alert]))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.subheadline)
                    // Never truncate: the rider needs the whole notice (S9).
                    .fixedSize(horizontal: false, vertical: true)
                if let dates = datesText {
                    Text(dates)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        if let text = alert.text, !text.isEmpty { return text }
        return "Servei afectat"
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

    private static func day(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()
}
