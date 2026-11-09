import SwiftUI

/// Detail of one station: active incidents of the line plus live arrivals
/// polled directly from i-Metro, the arrival reminders of spec S13, the
/// accessibility state and named accesses of spec S17, and the theoretical
/// timetable and interchanges of spec S19.
@MainActor
struct StationDetailView: View {
    let station: Station
    let line: MetroLine

    @EnvironmentObject private var app: AppModel
    @State private var arrivals: [Arrival] = []
    @State private var errorMessage: String?
    /// Distinguishes "fetch still running" from "fetch done, no trains".
    @State private var hasLoaded = false
    /// Reminder ids of spec S13 scheduled for the arrivals on screen, so the
    /// row can show its bell. Re-synced from `ArrivalReminder` after every
    /// arrivals load.
    @State private var scheduledReminderIDs: Set<String> = []
    @State private var reminderPermissionMissing = false
    /// The station's named accesses (spec S17); empty until they arrive, and
    /// kept empty when the feed or the credentials fail.
    @State private var accesses: [TMBStationAccess] = []
    /// Timetable from the schedule pack (spec S19); the arrays stay empty when
    /// the pack has nothing for this station, which hides the section.
    @State private var timetableDirections: [TimetableDirection] = []
    @State private var timetableDepartures: [TimetableDeparture] = []
    @State private var timetableTimeZone = TimeZone.autoupdatingCurrent
    @Environment(\.dismiss) private var dismiss

    /// Minutes before the arrival the rider may be warned by (spec S13).
    private static let reminderMinutesBefore = [1, 3, 5]

    /// Incidents of this station on this line, from the alerts feed (S4).
    private var incidents: [StationIncident] {
        IncidentIndex.incidents(
            for: app.alerts,
            stations: [station],
            lineCode: line.code
        )[station.code] ?? []
    }

    /// The station as a favoritable place (spec S12 star).
    private var favoritePlace: Place {
        ExplorePlaceBridge.place(for: station, line: line)
    }

    var body: some View {
        NavigationStack {
            List {
                if !incidents.isEmpty {
                    Section("Incidències") {
                        ForEach(incidents) { incident in
                            IncidentRow(incident: incident)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if reminderPermissionMissing {
                    Text("Activa les notificacions per rebre avisos d'arribada.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                ForEach(arrivals) { arrival in
                    arrivalRow(arrival)
                }
                if arrivals.isEmpty && errorMessage == nil {
                    if hasLoaded {
                        // Five lines (L9N, L9S, L10N, L10S, FM) report no
                        // arrivals at all: say so instead of spinning forever.
                        ContentUnavailableView(
                            "Sense dades en temps real",
                            systemImage: "clock.badge.exclamationmark",
                            description: Text("TMB no publica les arribades d'aquesta línia ara mateix.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ProgressView("Consultant arribades…")
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
                accessibilitySection
                accessesSection
                interchangesSection
                timetableSection
            }
            .navigationTitle(station.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
                // The favorite star of the place detail (spec S12).
                ToolbarItem(placement: .primaryAction) {
                    FavoriteStarButton(place: favoritePlace)
                }
            }
            .task {
                await refresh()
                await loadStationData()
            }
            .refreshable {
                await refresh()
            }
        }
    }

    // MARK: - Arrivals with the reminder menu (S13)

    /// One arrival row: destination, raw countdown, the colored countdown,
    /// the bell once a reminder is set and the "Avisa'm" menu (spec S13).
    private func arrivalRow(_ arrival: Arrival) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.destination.isEmpty ? "—" : arrival.destination)
                    .font(.body.weight(.medium))
                Text(arrival.rawText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let seconds = arrival.seconds {
                Text(Arrival.countdownText(seconds: seconds))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(Color(hex: line.colorHex))
            }
            if hasReminder(arrival) {
                Image(systemName: "bell.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: line.colorHex))
                    .accessibilityLabel("Avís programat")
            }
            // Spec S20: start the lock-screen / Dynamic Island countdown.
            Button {
                startLiveActivity(arrival)
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: line.colorHex))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Segueix en directe")
            Menu("Avisa'm") {
                ForEach(Self.reminderMinutesBefore, id: \.self) { minutes in
                    Button("\(minutes) min abans") {
                        scheduleReminder(arrival, minutesBefore: minutes)
                    }
                    // An option whose time has already passed is disabled
                    // (spec S13).
                    .disabled(reminderDate(arrival, minutesBefore: minutes) == nil)
                }
            }
        }
    }

    /// `"<placeId>|<línia>|<destí>|<n>"` — one reminder id per arrival and
    /// lead time (spec S13).
    private func reminderID(_ arrival: Arrival, minutesBefore: Int) -> String {
        "\(favoritePlace.id)|\(line.displayName)|\(arrival.destination)|\(minutesBefore)"
    }

    /// When the rider wants to be warned, or nil when that moment already
    /// passed: the countdown is the only clock the arrival carries.
    private func reminderDate(_ arrival: Arrival, minutesBefore: Int) -> Date? {
        guard let seconds = arrival.seconds, seconds > minutesBefore * 60 else { return nil }
        return Date().addingTimeInterval(TimeInterval(seconds - minutesBefore * 60))
    }

    private func hasReminder(_ arrival: Arrival) -> Bool {
        Self.reminderMinutesBefore.contains { scheduledReminderIDs.contains(reminderID(arrival, minutesBefore: $0)) }
    }

    /// Asks `ArrivalReminder` (shared with the bus sheet, spec S13) and shows
    /// the bell when the schedule succeeded.
    private func scheduleReminder(_ arrival: Arrival, minutesBefore: Int) {
        guard let at = reminderDate(arrival, minutesBefore: minutesBefore) else { return }
        let id = reminderID(arrival, minutesBefore: minutesBefore)
        let title = "Arribada a \(station.name)"
        let body = "El \(line.displayName) cap a \(arrival.destination) arriba a \(station.name) en \(minutesBefore) min"
        Task {
            if await ArrivalReminder.shared.schedule(id: id, title: title, body: body, at: at) {
                scheduledReminderIDs.insert(id)
            } else {
                reminderPermissionMissing = true
            }
        }
    }

    /// Reads back which of the visible arrivals already have a reminder, so
    /// the bell also reflects reminders set before a relaunch (S13).
    private func syncScheduledReminders() {
        var ids: Set<String> = []
        for arrival in arrivals {
            for minutes in Self.reminderMinutesBefore
            where ArrivalReminder.shared.isScheduled(id: reminderID(arrival, minutesBefore: minutes)) {
                ids.insert(reminderID(arrival, minutesBefore: minutes))
            }
        }
        scheduledReminderIDs = ids
    }

    // MARK: - Live Activity (S20)

    /// Starts tracking one arrival on the lock screen.
    private func startLiveActivity(_ arrival: Arrival) {
        guard let seconds = arrival.seconds else { return }
        let arrivalDate = Date().addingTimeInterval(TimeInterval(seconds))
        let destination = arrival.destination.isEmpty ? line.displayName : arrival.destination
        Task {
            await ArrivalActivityController.shared.start(
                placeID: favoritePlace.id,
                placeName: station.name,
                lineCode: line.code,
                lineName: line.displayName,
                lineColorHex: line.colorHex,
                destination: destination,
                arrivalDate: arrivalDate,
                minutes: max(0, Int(ceil(TimeInterval(seconds) / 60)))
            )
        }
    }

    /// Moves the running activity to the refreshed arrival of the same
    /// destination, so the lock-screen countdown follows the live feed. A
    /// sheet for another line at the same station leaves it alone.
    ///
    /// When no arrival matches any more the train the rider follows has left
    /// the feed, so the activity is left as it is: rebinding it to an unrelated
    /// train would count down to another destination while keeping the old
    /// label on the lock screen.
    private func refreshLiveActivity() {
        guard let running = ArrivalActivityController.shared.runningActivity(forPlace: favoritePlace.id),
              running.lineCode == line.code else {
            return
        }
        guard let arrival = arrivals.first(where: { $0.destination == running.destination }),
              let seconds = arrival.seconds else { return }
        ArrivalActivityController.shared.update(
            id: running.id,
            arrivalDate: Date().addingTimeInterval(TimeInterval(seconds))
        )
    }

    // MARK: - Accessibility and accesses (S17)

    /// "Accessible" / "No accessible" from the station feed itself; hidden
    /// when the feed says nothing.
    @ViewBuilder
    private var accessibilitySection: some View {
        if let accessible = station.accessible {
            Section("Accessibilitat") {
                Label(accessible ? "Accessible" : "No accessible", systemImage: "figure.roll")
                    .foregroundStyle(accessible ? Color.green : Color(hex: "F59E0B"))
            }
        }
    }

    /// The station's named accesses with their accessibility symbol (S17).
    @ViewBuilder
    private var accessesSection: some View {
        if !accesses.isEmpty {
            Section("Accessos") {
                ForEach(accesses) { access in
                    HStack(spacing: 10) {
                        Text(access.name)
                        Spacer()
                        Image(systemName: "figure.roll")
                            .foregroundStyle(Self.accessColor(access.kind))
                        Text(access.kind.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Accés \(access.name), \(access.kind.label)")
                }
            }
        }
    }

    private static func accessColor(_ kind: TMBAccessKind) -> Color {
        switch kind {
        case .accessible:
            return .green
        case .partiallyAccessible:
            return Color(hex: "F59E0B")
        case .notAccessible:
            return .red
        case .unknown:
            return .secondary
        }
    }

    // MARK: - Interchanges (S19)

    /// Badges of the other metro lines at the station and the FGC stations
    /// within the interchange radius, through the shared `PlaceIndex` rule
    /// over the place catalog (spec S1, S19).
    private var interchangeBadges: [StationInterchangeBadge] {
        let places = PlaceCatalogStore.shared.places
        guard !places.isEmpty else { return [] }
        let nearby = PlaceIndex.interchanges(for: favoritePlace, places: places)
        var badges: [StationInterchangeBadge] = []
        var seen: Set<String> = []

        // Metro: the catalog's merged place already lists every line that
        // serves the station; same-name metro places add nothing new today
        // but keep the rule honest if the catalog splits them again.
        for place in [favoritePlace] + nearby.filter({ $0.kind == .metroStation }) {
            for code in place.lineCodes where code != line.displayName && seen.insert("metro-\(code)").inserted {
                let metro = MetroLine.allLines.first { $0.displayName == code || $0.code == code }
                let colorHex = metro?.colorHex ?? "6B7280"
                badges.append(StationInterchangeBadge(
                    id: "metro-\(code)",
                    code: code,
                    colorHex: colorHex,
                    textColorHex: HexLuminance.isLight(colorHex) ? "000000" : "FFFFFF",
                    accessibilityLabel: "Correspondència, línia \(code)",
                    destination: .line(operator: AppModeCode.metro, code: metro?.code ?? code)
                ))
            }
        }
        // FGC: one badge per route code at the nearest matching station; the
        // tap focuses that station on the FGC map.
        let fgcLines = FGCNetworkState.shared.lines
        for place in nearby where place.kind == .fgcStation {
            for code in place.lineCodes where seen.insert("fgc-\(code)").inserted {
                let style = FGCNetwork.style(for: code, in: fgcLines)
                badges.append(StationInterchangeBadge(
                    id: "fgc-\(code)",
                    code: style.label,
                    colorHex: style.colorHex,
                    textColorHex: style.textColorHex,
                    accessibilityLabel: "Correspondència FGC, \(style.label) a \(place.name)",
                    destination: .place(place)
                ))
            }
        }
        return badges
    }

    @ViewBuilder
    private var interchangesSection: some View {
        if !interchangeBadges.isEmpty {
            Section("Correspondències") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(interchangeBadges) { badge in
                            Button {
                                AppRouter.shared.open(badge.destination)
                            } label: {
                                Text(badge.code)
                                    .font(.caption.bold())
                                    .foregroundStyle(Color(hex: badge.textColorHex))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color(hex: badge.colorHex)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(badge.accessibilityLabel)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Timetable (S19)

    /// First and last departure per direction for today, plus the remaining
    /// departures of the service day under the "Horari" disclosure. The whole
    /// section hides when the schedule pack has nothing for this station.
    @ViewBuilder
    private var timetableSection: some View {
        if !timetableDirections.isEmpty {
            Section {
                ForEach(timetableDirections) { service in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.headsign)
                            .font(.subheadline.weight(.medium))
                        Text(ScheduleTimetable.firstLastText(service, timeZone: timetableTimeZone))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !timetableDepartures.isEmpty {
                    DisclosureGroup("Horari") {
                        ForEach(timetableDepartures) { departure in
                            HStack {
                                Text(ScheduleTimetable.clockText(departure.time, timeZone: timetableTimeZone))
                                    .font(.body.monospacedDigit())
                                Spacer()
                                Text(departure.headsign)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } header: {
                Text("Primer i últim")
            }
        }
    }

    // MARK: - Loading

    private func refresh() async {
        do {
            let client = try TMBClient.fromBundle()
            // The sheet's code is the catalog's `ID_ESTACIO` when it came from a
            // place and the line feed's `CODI_ESTACIO` when it did not; asking
            // with the place lets the client bridge the two code spaces and
            // answer under the same place (spec S1).
            let fetched = try await client.metroArrivals(lineCode: line.code, places: [favoritePlace])
            arrivals = fetched[favoritePlace.id] ?? []
            errorMessage = nil
            hasLoaded = true
            syncScheduledReminders()
            refreshLiveActivity()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the slow-changing extras of the sheet once per presentation:
    /// the named accesses (S17) and the timetable (S19). Every failure is
    /// silent: the sections simply stay hidden.
    private func loadStationData() async {
        guard let client = try? TMBClient.fromBundle() else { return }
        // The sheet arrives with two kinds of station: the line feed's, whose
        // `code` is `CODI_ESTACIO`, and the place catalog's synthetic one,
        // whose `code` is the `ID_ESTACIO`. The accesses feed and the schedule
        // pack want `CODI_ESTACIO`, so resolve it against the line's stations.
        let feed = (try? await client.stations(lineCode: line.code)) ?? []
        let stationCode = TMBPlaceParser.stationCode(forStation: station, in: feed)

        // The access endpoint is keyed by `CODI_GRUP_ESTACIO`, one code per
        // physical station, so the line's own value wins over the per-line
        // offset: at an interchange the offset can only fit one of the lines
        // (spec S17).
        let feedGroupCode = feed.first { $0.code == stationCode }?.groupCode ?? station.groupCode
        let groupCode = TMBAccessParser.groupStationCode(
            forStationCode: stationCode,
            feedGroupCode: feedGroupCode
        )
        accesses = (try? await client.stationAccesses(groupStationCode: groupCode)) ?? []

        guard let lineCode = Int(line.code),
              let schedule = await ScheduleStore.shared.line(mode: .metro, code: lineCode) else { return }
        timetableTimeZone = schedule.timeZone
        let now = Date()
        timetableDirections = ScheduleTimetable.firstLast(line: schedule, stopCode: stationCode, date: now)
        timetableDepartures = ScheduleTimetable.departures(line: schedule, stopCode: stationCode, from: now)
    }
}

/// One tappable interchange badge row of the station sheet (spec S19).
private struct StationInterchangeBadge: Identifiable {
    let id: String
    let code: String
    let colorHex: String
    let textColorHex: String
    let accessibilityLabel: String
    let destination: Destination
}

/// One incident of a station: kind icon, title and the full alert text (S4).
private struct IncidentRow: View {
    let incident: StationIncident

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(incident.kind.incidentIconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(Color(hex: "F59E0B"))
            VStack(alignment: .leading, spacing: 2) {
                Text(incident.title)
                    .font(.body.weight(.bold))
                if let text = incident.text, !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // Full text, never clipped by the row height (spec S9).
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
