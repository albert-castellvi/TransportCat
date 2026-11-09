import SwiftUI

/// "A prop teu" list (spec S10, mockup `V4Tot`): the nearest stops with the
/// next arrivals per line, sorted by walking time, one card per stop.
///
/// Reusable by design: the Tot screen hosts it inline (S10) and the nearby
/// sheet hosts the same view (S13, T5). The caller supplies the places and
/// the arrival values; the list owns the loading of the places catalog and
/// the location start through the callbacks below, so the host decides the
/// poll lifecycle.
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

    /// Refresh period of the nearby arrivals (nanoseconds): the same 30 s the
    /// favorites' arrivals of Explora use.
    private static let arrivalsRefreshIntervalNanoseconds: UInt64 = 30_000_000_000

    init() {}

    var body: some View {
        Group {
            if let location = LocationService.shared.location {
                if entries.isEmpty {
                    emptyText(hasLoaded: arrivalsLoaded)
                } else {
                    ForEach(entries) { entry in
                        NearbyStopCard(entry: entry)
                    }
                }
            } else {
                // The fix has not landed yet (or the host shows its own denied
                // state): say what is happening instead of drawing nothing.
                ProgressView("Cercant la teva ubicació…")
            }
        }
        .task {
            await bootstrapAndRefresh()
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
            // Only a pass that had a location fix can tell "loading" from
            // "nothing around": on a cold start the first pass often runs
            // before the first fix and returns empty, which must not turn into
            // the definitive "no stop within a kilometre" (spec S10).
            if LocationService.shared.location != nil {
                arrivalsLoaded = true
            }
            do {
                try await Task.sleep(nanoseconds: Self.arrivalsRefreshIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    /// One refresh pass: re-sort the nearby entries and fetch their arrivals.
    @MainActor
    private func refresh() async {
        let nearby = NearbyStops.entries(
            userLocation: LocationService.shared.location,
            places: catalog.places
        )
        guard !nearby.isEmpty else {
            entries = []
            return
        }

        var withRows: [NearbyStopEntry] = []
        for var entry in nearby {
            let rows = await arrivalsRows(for: entry.place)
            entry = NearbyStopEntry(
                place: entry.place,
                distanceMeters: entry.distanceMeters,
                walkingMinutes: entry.walkingMinutes,
                rows: rows
            )
            withRows.append(entry)
        }
        entries = NearbyStops.sorted(withRows)
    }

    /// The arrival rows of one place, through the same fetchers Explora uses:
    /// metro per line in one call, bus per stop, FGC read-only from the shared
    /// state (no second poller, no new endpoint).
    @MainActor
    private func arrivalsRows(for place: Place) async -> [NearbyLineRow] {
        guard let client = app.client else { return [] }
        var metro: [Arrival] = []
        var bus: [BusArrival] = []
        var fgc: [FavoriteArrival] = []

        switch place.kind {
        case .metroStation:
            for lineCode in place.lineCodes {
                // Asked as a place: the client bridges the catalog's
                // `ID_ESTACIO` to the per-line `CODI_ESTACIO` the feed keys by.
                if let fetched = try? await client.metroArrivals(lineCode: lineCode, places: [place]) {
                    metro.append(contentsOf: fetched[place.id] ?? [])
                }
            }
        case .busStop:
            if let code = Int(place.code) {
                bus = (try? await client.busArrivals(stopCode: code)) ?? []
            }
        case .fgcStation:
            fgc = await ExploreArrivals.nextArrivals(
                for: [place],
                client: client,
                fgcState: FGCNetworkState.shared,
                busLines: busStore.lines
            )[place.id] ?? []
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
        } else {
            Text("No tens cap estació ni parada a menys d'un quilòmetre.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// One stop card of the list (mockup `V4Tot`): the place name with its
/// walking caption, and one row per line with the two next directions.
private struct NearbyStopCard: View {
    let entry: NearbyStopEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.place.name)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
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
                Text("Sense arribades")
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
        .accessibilityLabel("\(entry.place.name), \(ExploreFormatting.nearbyCaption(meters: entry.distanceMeters))")
    }
}

/// One arrival row of a stop card: line badge, then the two directions side
/// by side (destination over countdown, soonest first).
private struct NearbyLineRowView: View {
    let row: NearbyLineRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LineBadge(text: row.lineLabel, colorHex: row.colorHex, textColorHex: row.textColorHex)
            directionColumn(destination: row.firstDestination, time: row.firstTime)
            directionColumn(destination: row.secondDestination, time: row.secondTime)
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

    @ViewBuilder
    private func directionColumn(destination: String?, time: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(destination ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(time ?? "")
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(time == "ara" ? Color(hex: "30D158") : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        var parts = ["Línia \(row.lineLabel)"]
        if !row.firstDestination.isEmpty, !row.firstTime.isEmpty {
            parts.append("cap a \(row.firstDestination) en \(row.firstTime)")
        }
        if let destination = row.secondDestination, let time = row.secondTime, !destination.isEmpty, !time.isEmpty {
            parts.append("i cap a \(destination) en \(time)")
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
