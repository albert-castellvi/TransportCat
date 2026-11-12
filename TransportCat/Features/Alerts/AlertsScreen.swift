import SwiftUI

/// How the Avisos screen reads one alerts feed snapshot (spec S11): the
/// "Tot funciona" empty state appears when no SERVICE alert is shown, and
/// facility alerts stay reachable through a count row that leads to them.
/// Pure and Foundation-only so `NetworkArtTests` covers the decision.
struct AlertsStateSummary: Equatable {
    /// Alerts that interrupt the service, in feed order.
    let serviceAlerts: [ServiceAlert]
    /// Alerts for elevators, escalators and corridors, in feed order.
    let facilityAlerts: [ServiceAlert]

    init(alerts: [ServiceAlert]) {
        self.serviceAlerts = alerts.filter { $0.severity == .service }
        self.facilityAlerts = alerts.filter { $0.severity == .facility }
    }

    /// No service alert across the shown operators: the screen shows the
    /// network motif instead of the alert list.
    var showsEmptyState: Bool {
        serviceAlerts.isEmpty
    }

    /// How many facility alerts the count row leads to.
    var facilityCount: Int {
        facilityAlerts.count
    }

    /// Row title, after the `V5Empty` mockup: "3 instal·lacions fora de
    /// servei". Generic on purpose: facility alerts also cover corridors and
    /// accesses (e.g. PP2), not only elevators and escalators.
    static func facilityTitle(count: Int) -> String {
        count == 1
            ? "1 instal·lació fora de servei"
            : "\(count) instal·lacions fora de servei"
    }

    /// Row subtitle, matching the `V5Empty` mockup.
    static let facilitySubtitle = "No afecten la circulació"
}

/// Service status: active disruptions across the whole metro network.
struct AlertsScreen: View {
    @EnvironmentObject private var app: AppModel
    /// Incident alerts for the rider's favorite lines (spec S14), off by
    /// default. Same key the `IncidentWatcher` reads.
    @AppStorage(IncidentWatcher.enabledKey) private var incidentAlertsEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Toggle(isOn: $incidentAlertsEnabled) {
                    Text("Avisa'm de les incidències de les meves línies")
                        .font(.footnote)
                }
                .onChange(of: incidentAlertsEnabled) { _, enabled in
                    Task { @MainActor in
                        if enabled {
                            // The switch asks for notification permission (S14);
                            // a denial flips it back off.
                            let granted = await ArrivalReminder.shared.ensurePermissionGranted()
                            if granted {
                                IncidentWatcher.scheduleNextRefresh()
                            } else {
                                incidentAlertsEnabled = false
                            }
                        } else {
                            await ArrivalReminder.shared.cancelPendingNotifications(
                                withPrefix: IncidentWatcher.notificationIDPrefix
                            )
                        }
                    }
                }
                let summary = AlertsStateSummary(alerts: app.alerts)
                if let message = app.missingCredentialsMessage {
                    ConfigurationNotice(message: message)
                        .listRowBackground(Color.clear)
                } else if let error = app.alertsErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if summary.showsEmptyState {
                    emptyState
                } else {
                    // Service alerts first; facility notices stay behind the
                    // count row instead of joining this list (#95).
                    ForEach(summary.serviceAlerts) { alert in
                        AlertRow(alert: alert)
                    }
                }
                // The count row leads to the facility notices in every state.
                if summary.facilityCount > 0 {
                    NavigationLink {
                        FacilityAlertsScreen(alerts: summary.facilityAlerts)
                    } label: {
                        FacilityAlertsRow(count: summary.facilityCount)
                    }
                }
            }
            .navigationTitle("Avisos")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await app.refreshAlerts()
            }
            .task {
                await app.refreshAlerts()
            }
        }
    }

    /// The "Tot funciona" empty state (spec S11, `V5Empty` mockup): the icon's
    /// network in full colour. The facility-alert count row follows in the
    /// list, in this state and in the service-alert state alike (#95).
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 20) {
            NetworkArt(.illustration, accessibilityLabel: Text("Il·lustració de la xarxa de metro"))
                .frame(height: 254)
                .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                Text("Tot funciona")
                    .font(.title2.weight(.bold))
                // This screen reads the metro alerts feed only, so the copy
                // claims nothing about bus or FGC.
                Text("Cap incidència de servei al metro.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// The facility-alert count row of the empty state (spec S11, `V5Empty`):
/// grey mark, the count, and "No afecten la circulació".
private struct FacilityAlertsRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.roll")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(AlertsStateSummary.facilityTitle(count: count))
                    .font(.body.weight(.semibold))
                Text(AlertsStateSummary.facilitySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// The facility alerts behind the count row: the same rows the full list
/// uses, with no extra data loading.
private struct FacilityAlertsScreen: View {
    let alerts: [ServiceAlert]

    var body: some View {
        List {
            ForEach(alerts) { alert in
                AlertRow(alert: alert)
            }
        }
        .navigationTitle(Text("Instal·lacions"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AlertRow: View {
    let alert: ServiceAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(alert.lineCodes, id: \.self) { code in
                    if let line = MetroLine.line(forCode: code) {
                        Text(line.displayName)
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(hex: line.colorHex)))
                    }
                }
                Spacer()
                if let end = alert.endDate {
                    (Text("fins al ") + Text(end, style: .date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // Cleaned copy: the feeds ship HTML in the alert text (S15).
            if let text = AlertText.cleaned(alert.text) {
                Text(text)
                    .font(.footnote)
            }
            if !alert.stationNames.isEmpty {
                Text(alert.stationNames.prefix(6).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
