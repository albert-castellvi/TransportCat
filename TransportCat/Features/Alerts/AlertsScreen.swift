import SwiftUI

/// How the Avisos screen reads the alerts feeds (spec S11): the "Tot
/// funciona" empty state appears when no SERVICE alert is shown by either
/// feed, and facility alerts stay reachable through a count row that leads to
/// them. Pure and Foundation-only so `NetworkArtTests` covers the decision.
struct AlertsStateSummary: Equatable {
    /// Metro alerts that interrupt the service, in feed order.
    let serviceAlerts: [ServiceAlert]
    /// Metro alerts for elevators, escalators and corridors, in feed order.
    let facilityAlerts: [ServiceAlert]
    /// Bus alerts in force at `now`, in feed order (UX-15). The bus feed keeps
    /// expired alerts in its payload, so the section lists only the active
    /// ones — the same rule `AppModel.activeBusAlerts(affecting:)` applies per
    /// line — and `showsEmptyState` reads this filtered list too.
    let busServiceAlerts: [ServiceAlert]

    /// - Parameters:
    ///   - alerts: the metro feed, as `AppModel.alerts` publishes it.
    ///   - busAlerts: the bus feed, as `AppModel.busAlerts` publishes it.
    ///   - now: the instant an alert must be in force at; tests pin it.
    init(alerts: [ServiceAlert], busAlerts: [ServiceAlert] = [], now: Date = Date()) {
        self.serviceAlerts = alerts.filter { $0.severity == .service }
        self.facilityAlerts = alerts.filter { $0.severity == .facility }
        // The bus feed publishes its disruptions under
        // `categories.messageType` (ALTERATION, SERVICE_MESSAGE), never the
        // metro feed's TRAFFIC / INFRASTRUCTURE pair, so `severity` would file
        // every bus alert as a facility notice. Every alert of that feed is a
        // trip-changing disruption (cancelled stops, detoured routes) and the
        // bus map treats it as one, so the screen lists them all as service.
        self.busServiceAlerts = busAlerts.filter { $0.isActive(now: now) }
    }

    /// No service alert across the shown operators, metro and bus alike: the
    /// screen shows the network motif instead of the alert list.
    var showsEmptyState: Bool {
        serviceAlerts.isEmpty && busServiceAlerts.isEmpty
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
            ? String(localized: "1 instal·lació fora de servei")
            : String(localized: "\(count) instal·lacions fora de servei")
    }

    /// Row subtitle, matching the `V5Empty` mockup.
    static let facilitySubtitle = String(localized: "No afecten la circulació")
}

/// Service status: active disruptions of the metro and the bus network.
@MainActor
struct AlertsScreen: View {
    @EnvironmentObject private var app: AppModel
    /// Incident alerts for the rider's favorite lines (spec S14), off by
    /// default. Same key the `IncidentWatcher` reads.
    @AppStorage(IncidentWatcher.enabledKey) private var incidentAlertsEnabled = false

    /// Catalog behind the bus rows' badges: a bus alert names its line by the
    /// numeric code, and the badge component needs the whole `BusLine`.
    private var busCatalog: BusCatalogStore { BusCatalogStore.shared }

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
                let summary = AlertsStateSummary(alerts: app.alerts, busAlerts: app.busAlerts)
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
                // The bus incidents the bus map's "Veure a Avisos" promises to
                // show (UX-15): metro first, then the bus feed under its own
                // header. Kept outside the state chain so a failed metro feed
                // never hides a bus disruption that did load.
                if !summary.busServiceAlerts.isEmpty {
                    Section("Bus") {
                        ForEach(summary.busServiceAlerts) { alert in
                            AlertRow(alert: alert, feed: .bus, busLines: busCatalog.lines)
                        }
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
                // The bus rows carry their line's badge, and the catalog is
                // the only source of that line's name and colours. Its own
                // once-per-launch guard makes this a no-op once any other
                // screen loaded it.
                if let client = app.client, !app.busAlerts.isEmpty {
                    await busCatalog.load(client: client)
                }
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
                // The screen reads the metro and bus feeds, so the copy claims
                // nothing about FGC, which has no alert channel of its own.
                Text("Cap incidència de servei al metro ni al bus.")
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

/// One alert of either feed. The two feeds identify their lines differently
/// (metro codes against the catalog's numeric bus codes), so the caller says
/// which feed the row belongs to and the badge reads the matching source.
private enum AlertRowFeed {
    case metro
    case bus
}

private struct AlertRow: View {
    let alert: ServiceAlert
    var feed: AlertRowFeed = .metro
    /// Bus catalog, the only source of a bus line's name and colours: the
    /// alert carries the numeric line code alone. Empty until it has loaded.
    var busLines: [BusLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                lineBadges
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

    /// The line badges of the row: the metro pill for the metro feed, the bus
    /// screens' own `BusBadge` for the bus feed. A code the catalog cannot
    /// resolve (the catalog has not loaded yet) renders no badge rather than a
    /// guessed one.
    @ViewBuilder
    private var lineBadges: some View {
        switch feed {
        case .metro:
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
        case .bus:
            ForEach(alert.lineCodes, id: \.self) { code in
                if let line = busLines.first(where: { String($0.code) == code }) {
                    BusBadge(line: line, width: 34)
                }
            }
        }
    }
}
