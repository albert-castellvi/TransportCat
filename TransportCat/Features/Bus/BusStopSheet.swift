import SwiftUI

/// Sheet of one bus stop (spec S6), opened from a stop dot on the bus map: the
/// stop's address, its incidents and every bus the iBus feed expects next, of
/// any line, refreshed while the sheet stays open.
@MainActor
struct BusStopSheet: View {
    let stop: BusStop
    /// Line the rider was looking at: it colors the countdowns and owns the
    /// incidents, but the arrivals listed below are all lines of the stop.
    let line: BusLine
    let incidents: [StationIncident]
    /// Delay against the timetable of the buses already on screen, keyed by
    /// `busID` (spec S7). Empty when the caller has no schedule to compare with.
    let delays: [Int: DelayEstimate]

    @EnvironmentObject private var app: AppModel
    @State private var arrivals: [BusArrival] = []
    @State private var errorMessage: String?
    /// Distinguishes "fetch still running" from "fetch done, no buses".
    @State private var hasLoaded = false
    /// Time of the last successful arrival load, for the footer.
    @State private var updatedAt: Date?
    /// Reminder ids of spec S13 scheduled for the arrivals on screen; re-synced
    /// from `ArrivalReminder` after every load so the bell survives a relaunch.
    @State private var scheduledReminderIDs: Set<String> = []
    @State private var reminderPermissionMissing = false
    /// Timetable of the line on screen at this stop (spec S19); empty until it
    /// loads, and the section stays hidden while it is.
    @State private var timetableDirections: [TimetableDirection] = []
    @State private var timetableDepartures: [TimetableDeparture] = []
    @State private var timetableTimeZone = TimeZone.autoupdatingCurrent
    @Environment(\.dismiss) private var dismiss

    /// Minutes before the arrival the rider may be warned by (spec S13).
    private static let reminderMinutesBefore = [1, 3, 5]

    /// Refresh period while the sheet is open, in nanoseconds (spec S6). Shorter
    /// than the map poll: a rider waiting at a stop wants the countdown to move.
    private static let refreshIntervalNanoseconds: UInt64 = 15_000_000_000

    init(stop: BusStop, line: BusLine, incidents: [StationIncident], delays: [Int: DelayEstimate] = [:]) {
        self.stop = stop
        self.line = line
        self.incidents = incidents
        self.delays = delays
    }

    /// The stop as a favoritable place (spec S12 star).
    private var favoritePlace: Place {
        ExplorePlaceBridge.place(for: stop, line: line)
    }

    var body: some View {
        NavigationStack {
            List {
                Text("Parada \(String(stop.code)) · \(stop.address)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !incidents.isEmpty {
                    Section("Incidències") {
                        ForEach(incidents) { incident in
                            StopIncidentRow(incident: incident)
                        }
                    }
                }
                Section {
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
                    ForEach(sortedArrivals) { arrival in
                        arrivalRow(arrival)
                    }
                    if arrivals.isEmpty && errorMessage == nil {
                        if hasLoaded {
                            // The feed answered and no bus is expected: say so
                            // instead of spinning forever (spec S6).
                            Text("Cap bus previst a aquesta parada.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView("Consultant arribades…")
                        }
                    }
                } header: {
                    Text("Propers busos")
                } footer: {
                    footerText
                }
                timetableSection
            }
            .navigationTitle(stop.name)
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
            // The sheet's own task: it is cancelled when the sheet goes away, so
            // the refresh loop never outlives the stop on screen (spec S6).
            .task {
                await loadTimetable()
                while !Task.isCancelled {
                    await refresh()
                    do {
                        try await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    /// Every line of the stop, soonest bus first (spec S6).
    private var sortedArrivals: [BusArrival] {
        arrivals.sorted { $0.seconds < $1.seconds }
    }

    /// "Actualitzat fa 12 s · TMB iBus", counting inside the clock of the sheet.
    @ViewBuilder
    private var footerText: some View {
        if let updatedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Actualitzat \(Freshness.ageText(since: updatedAt, now: context.date)) · TMB iBus")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One arrival: badge, destination, bus id, ramp state and countdown.
    private func arrivalRow(_ arrival: BusArrival) -> some View {
        HStack(alignment: .top, spacing: 10) {
            badge(for: arrival)
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.destination.isEmpty ? "—" : arrival.destination)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let busID = arrival.busID {
                    Text("bus \(String(busID))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let delay = delayLine(for: arrival) {
                    Text(delay.text)
                        .font(.caption)
                        .foregroundStyle(delay.color)
                }
                if let rampOperational = arrival.rampOperational {
                    Text(rampOperational ? "rampa operativa" : "rampa amb incidència")
                        .font(.caption)
                        .foregroundStyle(rampOperational ? Color.green : Color(hex: "F59E0B"))
                }
            }
            Spacer(minLength: 0)
            Text(ParadesTimeline.busTimeText(seconds: arrival.seconds))
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(arrival.seconds <= ParadesTimeline.imminentThresholdSeconds
                    ? Color(hex: "30D158") : .primary)
            if hasReminder(arrival) {
                Image(systemName: "bell.fill")
                    .font(.subheadline)
                    .foregroundStyle(lineColor(for: arrival))
                    .accessibilityLabel("Avís programat")
            }
            // Spec S20: start the lock-screen / Dynamic Island countdown.
            Button {
                startLiveActivity(arrival)
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(lineColor(for: arrival))
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
        .padding(.vertical, 2)
    }

    /// The delay of one arrival against the timetable, as a small line under
    /// the bus id. A low-confidence estimate is not something to tell a rider
    /// waiting at the stop, so it is left out (spec S7).
    private func delayLine(for arrival: BusArrival) -> (text: String, color: Color)? {
        guard let busID = arrival.busID,
              let estimate = delays[busID],
              estimate.confidence != .low else { return nil }
        let seconds = estimate.seconds
        if abs(seconds) < 60 {
            return (String(localized: "En hora"), .green)
        }
        // Never "0 min": a bus rounded to zero minutes is "En hora" above.
        let minutes = max(1, Int((Double(abs(seconds)) / 60).rounded()))
        if seconds > 0 {
            return (String(localized: "+\(minutes) min tard · estimat"), Color(hex: "F59E0B"))
        }
        return (String(localized: "\(minutes) min d'avanç · estimat"), .secondary)
    }

    /// The badge of the arriving line, from the catalog when it holds it. The
    /// feed lists lines the catalog request has not returned yet (or that it
    /// does not publish at all), and a nameless dot tells the rider nothing, so
    /// those get a neutral badge with the name the feed carries.
    @ViewBuilder
    private func badge(for arrival: BusArrival) -> some View {
        if let catalogLine = catalogLine(for: arrival) {
            BusBadge(line: catalogLine, width: 34)
        } else {
            NeutralBusBadge(name: arrival.lineName)
        }
    }

    /// The countdown keeps the color of its own line when the catalog knows it,
    /// and the color of the line on screen otherwise.
    private func lineColor(for arrival: BusArrival) -> Color {
        Color(hex: catalogLine(for: arrival)?.colorHex ?? line.colorHex)
    }

    /// The catalog is the only source of line colors, and it is shared with the
    /// map that opened this sheet.
    private func catalogLine(for arrival: BusArrival) -> BusLine? {
        BusCatalogStore.shared.lines.first { $0.code == arrival.lineCode }
    }

    // MARK: - Arrival reminders (S13)

    /// `"<placeId>|<línia>|<destí>|<n>"` — one reminder id per arrival and
    /// lead time (spec S13). The line is the arriving bus's own commercial
    /// name, which may differ from the line the map is showing.
    private func reminderID(_ arrival: BusArrival, minutesBefore: Int) -> String {
        "\(favoritePlace.id)|\(arrival.lineName)|\(arrival.destination)|\(minutesBefore)"
    }

    /// When the rider wants to be warned, or nil when that moment already
    /// passed; the countdown is the only clock the arrival carries.
    private func reminderDate(_ arrival: BusArrival, minutesBefore: Int) -> Date? {
        guard arrival.seconds > minutesBefore * 60 else { return nil }
        return Date().addingTimeInterval(TimeInterval(arrival.seconds - minutesBefore * 60))
    }

    private func hasReminder(_ arrival: BusArrival) -> Bool {
        Self.reminderMinutesBefore.contains { scheduledReminderIDs.contains(reminderID(arrival, minutesBefore: $0)) }
    }

    /// Asks `ArrivalReminder` (shared with the station sheet, spec S13) and
    /// shows the bell when the schedule succeeded.
    private func scheduleReminder(_ arrival: BusArrival, minutesBefore: Int) {
        guard let at = reminderDate(arrival, minutesBefore: minutesBefore) else { return }
        let id = reminderID(arrival, minutesBefore: minutesBefore)
        let title = String(localized: "Arribada a \(stop.name)")
        let body = String(localized: "El \(arrival.lineName) cap a \(arrival.destination) arriba a \(stop.name) en \(minutesBefore) min")
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

    /// Starts tracking one bus on the lock screen.
    private func startLiveActivity(_ arrival: BusArrival) {
        let arrivalDate = Date().addingTimeInterval(TimeInterval(arrival.seconds))
        let destination = arrival.destination.isEmpty ? arrival.lineName : arrival.destination
        let colorHex = catalogLine(for: arrival)?.colorHex ?? line.colorHex
        Task {
            await ArrivalActivityController.shared.start(
                placeID: favoritePlace.id,
                placeName: stop.name,
                lineCode: String(arrival.lineCode),
                lineName: arrival.lineName,
                lineColorHex: colorHex,
                destination: destination,
                arrivalDate: arrivalDate,
                minutes: max(0, Int(ceil(TimeInterval(arrival.seconds) / 60)))
            )
        }
    }

    /// Moves the running activity to the refreshed arrival of the same line
    /// and destination, so the lock-screen countdown follows the iBus feed.
    /// No fallback to an unrelated bus of the same line (same destination
    /// match as the station sheet; spec S20).
    private func refreshLiveActivity() {
        guard let running = ArrivalActivityController.shared.runningActivity(forPlace: favoritePlace.id) else {
            return
        }
        let matching = arrivals.first {
            String($0.lineCode) == running.lineCode && $0.destination == running.destination
        }
        guard let arrival = matching else { return }
        ArrivalActivityController.shared.update(
            id: running.id,
            arrivalDate: Date().addingTimeInterval(TimeInterval(arrival.seconds))
        )
    }

    // MARK: - Timetable (S19)

    /// First and last departure per direction of this line at this stop, plus
    /// the remaining departures of the day under "Horari". Hidden until the
    /// schedule pack answers.
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

    /// Loads the day's timetable once per presentation. A pack that is
    /// unavailable simply leaves the section hidden (spec S19).
    private func loadTimetable() async {
        guard let schedule = await ScheduleStore.shared.line(mode: .bus, code: line.code) else { return }
        timetableTimeZone = schedule.timeZone
        let now = Date()
        timetableDirections = ScheduleTimetable.firstLast(line: schedule, stopCode: stop.code, date: now)
        timetableDepartures = ScheduleTimetable.departures(line: schedule, stopCode: stop.code, from: now)
    }

    private func refresh() async {
        guard let client = app.client else { return }
        do {
            let fetched = try await client.busArrivals(stopCode: stop.code)
            arrivals = fetched
            updatedAt = Date()
            errorMessage = nil
            hasLoaded = true
            syncScheduledReminders()
            refreshLiveActivity()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Neutral badge for a line the catalog does not hold: the name on a gray tile,
/// the same shape as `BusBadge` so the column still reads as a list of lines.
private struct NeutralBusBadge: View {
    let name: String

    private static let width: CGFloat = 34
    private static let cornerRadius: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color(white: 0.32))
            .frame(width: Self.width, height: Self.width * 0.58)
            .overlay {
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Línia \(name)")
    }
}

/// One incident of the stop: kind icon, title and the full alert text (S6, S7).
private struct StopIncidentRow: View {
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
