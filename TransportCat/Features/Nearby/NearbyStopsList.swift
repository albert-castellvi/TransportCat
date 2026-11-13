import SwiftUI

/// "A prop teu" list (spec S10, mockup `V4Tot`): the nearest stops with the
/// next arrivals per line, sorted by walking time, one card per stop.
///
/// Reusable by design: the Tot screen hosts it inline (S10), the nearby
/// sheet hosts the same view (S13, T5) and Explora embeds it under its
/// "A prop" section. The caller supplies the tap action; the list owns the
/// loading of the places catalog and the arrival refresh loop, so the host
/// decides the location poll lifecycle.
struct NearbyStopsList: View {
    @EnvironmentObject private var app: AppModel

    /// The place catalog (shared, once per launch).
    private var catalog: PlaceCatalogStore { PlaceCatalogStore.shared }
    private var busStore: BusCatalogStore { BusCatalogStore.shared }
    private var fgc: FGCNetworkState { FGCNetworkState.shared }

    /// Nearby entries with their arrival rows; rebuilt by the refresh loop.
    @State private var entries: [NearbyStopEntry] = []
    /// Whether the first arrivals refresh has finished, so the list can tell
    /// "loading" from "nothing around".
    @State private var arrivalsLoaded = false

    /// Called with the tapped place; nil (the default) keeps the router
    /// hand-off the sheet and the Tot screen use.
    private let onSelect: ((Place) -> Void)?

    /// Refresh period of the nearby arrivals (nanoseconds): the same 30 s the
    /// favorites' arrivals of Explora use.
    private static let arrivalsRefreshIntervalNanoseconds: UInt64 = 30_000_000_000

    init(onSelect: ((Place) -> Void)? = nil) {
        self.onSelect = onSelect
    }

    var body: some View {
        // Read the catalog before the branches so the view keeps observing it
        // even while the location is still nil, and the `.onChange` below can
        // reload once it lands.
        let catalogPlacesEmpty = catalog.places.isEmpty
        let catalogLoading = catalog.isLoading && catalogPlacesEmpty
        return Group {
            if LocationService.shared.location == nil {
                // The fix has not landed yet (or the host shows its own denied
                // state): say what is happening instead of drawing nothing.
                ProgressView("Cercant la teva ubicació…")
                    .frame(maxWidth: .infinity)
                    .padding(16)
            } else if catalogLoading {
                // The catalog is still landing (possibly loaded by another
                // screen): keep the loading state instead of claiming there is
                // nothing around (#97).
                ProgressView("Cercant la teva ubicació…")
                    .frame(maxWidth: .infinity)
                    .padding(16)
            } else if entries.isEmpty {
                emptyText(hasLoaded: arrivalsLoaded)
            } else {
                ForEach(entries) { entry in
                    Button {
                        if let onSelect {
                            onSelect(entry.place)
                        } else {
                            // The router switches to the tab that is already on
                            // screen, so the sheet has to close for the map to
                            // handle the focus (#92).
                            AppRouter.shared.isNearbyPresented = false
                            AppRouter.shared.open(.place(entry.place))
                        }
                    } label: {
                        NearbyStopCard(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            await bootstrapAndRefresh()
        }
        .onChange(of: catalogPlacesEmpty) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: LocationService.shared.location) { _, _ in
            Task { await refresh() }
        }
    }

    /// Catalog load (the store's own once-per-launch guard), then a refresh
    /// loop while the host keeps the view alive. Location is started by the
    /// host screen (the map button / the sheet own that decision); this list
    /// only reads the service.
    @MainActor
    private func bootstrapAndRefresh() async {
        if let client = app.client, catalog.places.isEmpty {
            _ = await catalog.load(client: client)
        }
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(nanoseconds: Self.arrivalsRefreshIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    /// One refresh pass: fetch every stop's arrivals in parallel and re-sort
    /// the entries. The old loop awaited one stop after another, so the last
    /// card waited for every request above it (#92).
    @MainActor
    private func refresh() async {
        // Only a pass that had a location fix can tell "loading" from
        // "nothing around": on a cold start the first pass often runs before
        // the first fix and returns empty, which must not turn into the
        // definitive "no stop within a kilometre" (spec S10). The defer keeps
        // this true for the `.onChange`-driven passes too, not just the 30 s
        // loop.
        defer {
            if LocationService.shared.location != nil {
                arrivalsLoaded = true
            }
        }
        let nearby = NearbyStops.entries(
            userLocation: LocationService.shared.location,
            places: catalog.places
        )
        guard !nearby.isEmpty else {
            entries = []
            return
        }

        let rowsByPlace = await withTaskGroup(of: (id: String, rows: [NearbyLineRow]).self) { group in
            for entry in nearby {
                group.addTask {
                    let rows = await self.arrivalsRows(for: entry.place)
                    return (id: entry.place.id, rows: rows)
                }
            }
            var collected: [String: [NearbyLineRow]] = [:]
            for await result in group {
                collected[result.id] = result.rows
            }
            return collected
        }
        let withRows = nearby.map { entry in
            NearbyStopEntry(
                place: entry.place,
                distanceMeters: entry.distanceMeters,
                walkingMinutes: entry.walkingMinutes,
                rows: rowsByPlace[entry.place.id] ?? []
            )
        }
        entries = NearbyStops.sorted(withRows)
    }

    /// The arrival rows of one place, through the same fetchers Explora uses:
    /// metro one call per line in parallel, bus per stop, FGC read-only from
    /// the shared state (no second poller, no new endpoint).
    @MainActor
    private func arrivalsRows(for place: Place) async -> [NearbyLineRow] {
        guard let client = app.client else { return [] }
        var metro: [Arrival] = []
        var bus: [BusArrival] = []
        var fgc: [FavoriteArrival] = []

        switch place.kind {
        case .metroStation:
            // One request per line serving the stop, all in flight together.
            metro = await withTaskGroup(of: [Arrival].self) { group in
                for lineCode in place.lineCodes {
                    group.addTask {
                        // Asked as a place: the client bridges the catalog's
                        // `ID_ESTACIO` to the per-line `CODI_ESTACIO` the feed
                        // keys by.
                        let fetched = try? await client.metroArrivals(lineCode: lineCode, places: [place])
                        return fetched?[place.id] ?? []
                    }
                }
                var all: [Arrival] = []
                for await arrivals in group {
                    all.append(contentsOf: arrivals)
                }
                return all
            }
        case .busStop:
            if let code = Int(place.code) {
                bus = (try? await client.busArrivals(stopCode: code)) ?? []
            }
        case .fgcStation:
            let fetched = await ExploreArrivals.nextArrivals(
                for: [place],
                client: client,
                fgcState: FGCNetworkState.shared,
                busLines: busStore.lines
            )
            fgc = fetched.arrivals[place.id] ?? []
        }

        return NearbyStops.lineRows(
            metroArrivals: metro,
            busArrivals: bus,
            fgcArrivals: fgc,
            busLines: busStore.lines
        )
    }

    /// Empty wording: loading vs. genuinely nothing around.
    @ViewBuilder
    private func emptyText(hasLoaded: Bool) -> some View {
        if !hasLoaded {
            ProgressView("Cercant la teva ubicació…")
                    .frame(maxWidth: .infinity)
                    .padding(16)
        } else {
            Text("No tens cap estació ni parada a menys d'un quilòmetre.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

/// One stop card of the list (mockup `V4Tot`): the place name with its mode,
/// direction and walking captions, and one row per line with the next
/// directions.
private struct NearbyStopCard: View {
    let entry: NearbyStopEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.place.name)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(ExploreFormatting.nearbyCaption(meters: entry.distanceMeters))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: "409CFF"))
            }
            .padding(.bottom, 4)
            ForEach(entry.rows) { row in
                NearbyLineRowView(row: row)
            }
            if entry.rows.isEmpty {
                let text = NearbyStops.noArrivalsText
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(hex: "1C1D21")))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.place.name)
    }

    /// Mode cue ("Metro", "Bus", "FGC") and, once the arrivals are in, the
    /// direction served here: two bus stops called "Riera Blanca - Santa
    /// Eulàlia" are otherwise indistinguishable (#92).
    private var subtitle: String {
        let mode: String
        switch entry.place.kind {
        case .metroStation: mode = String(localized: "Metro")
        case .busStop: mode = String(localized: "Bus")
        case .fgcStation: mode = String(localized: "FGC")
        }
        guard let direction = entry.rows.first?.firstDestination,
              !direction.isEmpty, direction != "—" else { return mode }
        return String(localized: "\(mode) · cap a \(direction)")
    }
}

/// One arrival row of a stop card: line badge, then the two directions side
/// by side (destination over countdown, soonest first).
private struct NearbyLineRowView: View {
    let row: NearbyLineRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LineBadge(text: row.lineLabel, colorHex: row.colorHex, textColorHex: row.textColorHex)
            if repeatsDestination {
                // Two buses of this line head to the same place: one
                // destination, both countdowns side by side (#92).
                directionColumn(
                    destination: row.firstDestination,
                    times: [row.firstTime] + [row.secondTime].compactMap { $0 }
                )
            } else {
                directionColumn(destination: row.firstDestination, times: [row.firstTime])
                directionColumn(destination: row.secondDestination, times: row.secondTime.map { [$0] } ?? [])
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Whether both columns would repeat the same destination.
    private var repeatsDestination: Bool {
        guard let second = row.secondDestination, !second.isEmpty else { return false }
        return second == row.firstDestination
    }

    @ViewBuilder
    private func directionColumn(destination: String?, times: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(destination ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                ForEach(0..<times.count, id: \.self) { index in
                    Text(times[index])
                        .font(.callout.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(
                            // The same key `NearbyStops.timeText` renders, so the
                            // green dot survives translation.
                            times[index] == String(localized: "ara") ? Color(hex: "30D158") : Color.primary
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        var parts = [String(localized: "Línia \(row.lineLabel)")]
        if !row.firstDestination.isEmpty, !row.firstTime.isEmpty {
            parts.append(String(localized: "cap a \(row.firstDestination) en \(row.firstTime)"))
        }
        if let destination = row.secondDestination, let time = row.secondTime, !destination.isEmpty, !time.isEmpty {
            parts.append(destination == row.firstDestination
                ? String(localized: "i en \(time)")
                : String(localized: "i cap a \(destination) en \(time)"))
        }
        return parts.joined(separator: ", ")
    }
}

/// The colored capsule with the line code inside, shared by the nearby rows
/// and the line-status grid so every badge reads the same way.
struct NearbyLineBadge: View {
    let text: String
    let colorHex: String
    /// nil lets the badge pick black or white from `HexLuminance`.
    let textColorHex: String?

    init(text: String, colorHex: String, textColorHex: String? = nil) {
        self.text = text
        self.colorHex = colorHex
        self.textColorHex = textColorHex
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(minWidth: 36, minHeight: 26)
            .background(Capsule().fill(Color(hex: colorHex)))
            .accessibilityHidden(true)
    }

    /// Metro badges carry no published text color, so the choice follows the
    /// WCAG luminance rule used by the arrival pills.
    private var ink: Color {
        if let textColorHex { return Color(hex: textColorHex) }
        return HexLuminance.isLight(colorHex) ? Color(hex: "111111") : Color(hex: "FFFFFF")
    }
}

private typealias LineBadge = NearbyLineBadge
