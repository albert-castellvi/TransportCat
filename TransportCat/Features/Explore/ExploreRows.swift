import SwiftUI

/// One line as an Explora search result or favorite row (spec S12), over the
/// three operator models. `rank` is the `ExploreFormatting.bestLineRank` score
/// used to sort results; favorite rows use rank 0 since their order is the
/// rider's.
struct ExploreLineResult: Identifiable {
    enum Kind {
        case metro(MetroLine)
        case fgc(FGCLine)
        case bus(BusLine)
    }

    let kind: Kind
    let rank: Int

    var id: String { "\(operatorName):\(routeCode)" }

    /// "metro" | "fgc" | "bus", the raw value `Destination` and `FavoriteLine`
    /// use.
    var operatorName: String {
        switch kind {
        case .metro: return AppModeCode.metro
        case .fgc: return AppModeCode.fgc
        case .bus: return AppModeCode.bus
        }
    }

    /// Badge text: "L1", "S1", "H12".
    var label: String {
        switch kind {
        case .metro(let line): return line.displayName
        case .fgc(let line): return line.code
        case .bus(let line): return line.name
        }
    }

    /// Secondary line text; the metro catalog carries no endpoints, so the
    /// metro subtitle stays empty.
    var subtitle: String {
        switch kind {
        case .metro: return ""
        case .fgc(let line): return line.name
        case .bus(let line): return "\(line.origin) – \(line.destination)"
        }
    }

    var colorHex: String {
        switch kind {
        case .metro(let line): return line.colorHex
        case .fgc(let line): return line.colorHex
        case .bus(let line): return line.colorHex
        }
    }

    var textColorHex: String? {
        switch kind {
        case .metro: return nil
        case .fgc(let line): return line.textColorHex
        case .bus(let line): return line.textColorHex
        }
    }

    /// The code `Destination.line` expects: metro "1", FGC "S1", bus "212".
    var routeCode: String {
        switch kind {
        case .metro(let line): return line.code
        case .fgc(let line): return line.code
        case .bus(let line): return String(line.code)
        }
    }

    @MainActor
    var isFavorite: Bool {
        switch kind {
        case .metro(let line):
            return FavoritesStore.shared.isFavorite(FavoriteLine(operator: FavoriteLine.metro, code: line.code))
        case .fgc(let line):
            return FavoritesStore.shared.isFavorite(FavoriteLine(operator: FavoriteLine.fgc, code: line.code))
        case .bus(let line):
            return BusCatalogStore.shared.isFavorite(line)
        }
    }

    /// Stars the line in the store its operator uses (S4): metro/FGC in
    /// `FavoritesStore`, bus in the catalog's own favorites.
    @MainActor
    func toggleFavorite() {
        switch kind {
        case .metro(let line):
            FavoritesStore.shared.toggle(FavoriteLine(operator: FavoriteLine.metro, code: line.code))
        case .fgc(let line):
            FavoritesStore.shared.toggle(FavoriteLine(operator: FavoriteLine.fgc, code: line.code))
        case .bus(let line):
            BusCatalogStore.shared.toggleFavorite(line)
        }
    }
}

/// Small line pill in the line's own colors (spec S12). The metro catalog
/// publishes no text color, so black or white is decided by luminance, exactly
/// as the arrival pills do.
struct ExploreLineBadge: View {
    let label: String
    let colorHex: String
    var textColorHex: String? = nil

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(textColor)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: colorHex)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Línia \(label)")
    }

    private var textColor: Color {
        if let textColorHex { return Color(hex: textColorHex) }
        return HexLuminance.isLight(colorHex) ? .black : .white
    }
}

/// Name, secondary line (search: served lines; nearby: distance caption),
/// wheelchair symbol when the place is accessible and a filled star when it is
/// a favorite (spec S12, S17 preview).
struct ExplorePlaceRow: View {
    let place: Place
    var caption: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                let secondary = caption ?? place.lineCodes.joined(separator: " · ")
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if place.accessible == true {
                Image(systemName: "figure.roll")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Accessible")
            }
            if FavoritesStore.shared.isFavorite(place) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("A preferits")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// One line row: tapping opens the operator's map, the context menu stars it
/// (spec S12).
struct ExploreLineRow: View {
    let result: ExploreLineResult

    var body: some View {
        Button {
            AppRouter.shared.open(.line(operator: result.operatorName, code: result.routeCode))
        } label: {
            HStack(spacing: 10) {
                ExploreLineBadge(label: result.label, colorHex: result.colorHex, textColorHex: result.textColorHex)
                // The badge already carries the code, so only the description
                // ("Barcelona – Vallès", "Zona Universitària – Can Buxeres")
                // earns a text row; metro lines have none in the catalog.
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if result.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("A preferits")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                result.toggleFavorite()
            } label: {
                Label(
                    result.isFavorite ? "Treu de preferits" : "Afegeix a preferits",
                    systemImage: result.isFavorite ? "star.slash" : "star"
                )
            }
        }
    }
}

/// One arrival under a favorite place: pill, destination and countdown or
/// punctuality label (spec S12).
struct ExploreFavoriteArrivalRow: View {
    let arrival: FavoriteArrival

    var body: some View {
        HStack(spacing: 10) {
            ExploreLineBadge(
                label: arrival.lineLabel,
                colorHex: arrival.colorHex,
                textColorHex: arrival.textColorHex
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.destination)
                    .font(.subheadline)
                    .lineLimit(1)
                if let status = arrival.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            Spacer(minLength: 0)
            if let countdown = arrival.countdown {
                Text(countdown)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    // The line colour made L1 minutes look like an error;
                    // only an imminent arrival is green (#97).
                    .foregroundStyle(countdown == "ara" ? Color(hex: "30D158") : Color.primary)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        arrival.statusIsOnTime == true ? .green : Color(hex: "F59E0B")
    }
}

/// The star toggle of a place detail (spec S12), used by the station sheet,
/// the bus stop sheet and `FGCStationSheet`.
struct FavoriteStarButton: View {
    let place: Place

    private var isFavorite: Bool { FavoritesStore.shared.isFavorite(place) }

    var body: some View {
        Button {
            FavoritesStore.shared.toggle(place)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
        }
        .accessibilityLabel(isFavorite ? "Treu de preferits" : "Afegeix a preferits")
    }
}
