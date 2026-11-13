import SwiftUI

/// Parades, Tot (spec S10, mockup `V4Tot`): "A prop teu" — the nearest stops
/// with the next arrivals per line, sorted by walking time — and "Estat de
/// les línies", a wrap grid of line badges with an amber dot on the affected
/// ones. Tapping a badge selects that mode and line so Parades shows its
/// timeline.
///
/// This replaces the old "L1 · L1" list. The header moved to the bottom
/// accessory (T1); the screen keeps only the status capsule.
@MainActor
struct GlobalLinesScreen: View {
    @EnvironmentObject private var app: AppModel

    init() {}

    private var fgc: FGCNetworkState { FGCNetworkState.shared }
    private var busCatalog: BusCatalogStore { BusCatalogStore.shared }

    /// The FGC lines on screen: the same selection the FGC line picker
    /// offers — at least one polyline, no `Bus…` shuttle routes (spec S10).
    private var shownFGCLines: [FGCLine] {
        FGCLinePicker.selectableLayers(from: fgc.lineLayers).compactMap { layer in
            fgc.lines.first { $0.code == layer.code }
        }
    }

    /// The starred bus lines in the order they were starred (spec S2).
    private var favoriteBusLines: [BusLine] {
        busCatalog.favorites.compactMap { code in
            busCatalog.lines.first { $0.code == code }
        }
    }

    /// Lines with a SERVICE alert in force right now, by (operator, code):
    /// the one source the grid's amber dots read (spec S10). Bus alerts are
    /// matched by the numeric `BusLine.code` string, metro and FGC by their
    /// own codes — exactly what `AlertsScreen` counts.
    private var affectedLineKeys: Set<String> {
        var result: Set<String> = []
        let now = Date()
        for alert in app.alerts where alert.severity == .service && alert.isActive(now: now) {
            for code in alert.lineCodes {
                result.insert("metro:\(code)")
            }
        }
        for alert in app.busAlerts where alert.severity == .service && alert.isActive(now: now) {
            for code in alert.lineCodes {
                result.insert("bus:\(code)")
            }
        }
        // FGC: the open-data feed carries no alert channel of its own (D2);
        // the metro feed never names FGC codes, so nothing is derived here.
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCapsule
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle(String(localized: "A prop teu"))
                        nearbySection
                        HStack(alignment: .firstTextBaseline) {
                            sectionTitle(String(localized: "Estat de les línies"))
                            Spacer()
                            affectedCountText
                        }
                        .padding(.top, 8)
                        lineStatusGrid
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
            }
            // The bottom accessory (T1) carries the mode menu and the operator
            // toggles; the screen keeps no title bar of its own (spec S5).
            // The icon's network behind the "Parades" title, fading out
            // (spec S11, mockup `V5Parades`).
            .networkHeaderBackground(opacity: 0.55)
            .navigationBarHidden(true)
            // The nearby list and the bus section need their catalogs; each
            // `load` is the store's own once-per-launch guard.
            .task {
                if let client = app.client {
                    await busCatalog.load(client: client)
                }
            }
        }
    }

    /// The status capsule, top-left (spec S2): the existing `FreshnessChip`
    /// explicit-values initializer, restyled by T1 — this screen only calls it.
    @ViewBuilder
    private var statusCapsule: some View {
        Group {
            if let global = globalFreshnessInputs {
                FreshnessChip(updatedAt: global.updatedAt, lastAttemptFailed: global.lastPollFailed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Freshness inputs of the metro network behind Tot: the newest successful
    /// poll and whether any line's last attempt failed — the same aggregate
    /// `GlobalMapScreen` shows. Nil until the global mode has run once.
    private var globalFreshnessInputs: (updatedAt: Date?, lastPollFailed: Bool)? {
        let states = GlobalNetworkState.shared.lineStates
        guard !states.isEmpty else { return nil }
        return (
            states.values.compactMap(\.arrivalsUpdatedAt).max(),
            states.values.contains { $0.lastPollFailed }
        )
    }

    /// "A prop teu" (spec S10): the reusable list, the same "Activa la
    /// ubicació" prompt Explora shows while nothing has been asked yet, or the
    /// location-denied explanation — never a permission prompt loop. Without
    /// the prompt the list would wait on a fix nobody requested (UX-18).
    @ViewBuilder
    private var nearbySection: some View {
        let service = LocationService.shared
        switch service.authorization {
        case .notDetermined:
            Button("Activa la ubicació") {
                service.requestWhenInUse()
            }
            .font(.footnote)
            .padding(.vertical, 8)
        case .denied, .restricted:
            Text("Activa la ubicació a Configuració per veure què tens a prop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        default:
            NearbyStopsList()
        }
    }

    /// "N afectades" next to the section title.
    private var affectedCountText: some View {
        let count = affectedLines.count
        return Text(count == 1 ? "1 afectada" : "\(count) afectades")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(hex: "FFB340"))
    }

    /// The badges of the grid, in a stable order: metro lines, FGC lines,
    /// then the favorite bus lines.
    private var affectedLines: [String] {
        let keys = affectedLineKeys
        var result: [String] = []
        for line in MetroLine.allLines where keys.contains("metro:\(line.code)") {
            result.append("metro:\(line.code)")
        }
        for line in shownFGCLines where keys.contains("fgc:\(line.code)") {
            result.append("fgc:\(line.code)")
        }
        for line in favoriteBusLines where keys.contains("bus:\(String(line.code))") {
            result.append("bus:\(String(line.code))")
        }
        return result
    }

    /// The wrap grid of line badges (spec S10): every metro and FGC line, and
    /// the favorite bus lines. Tapping a badge hands over through the existing
    /// storage keys via `AppRouter.open`, so Parades shows that timeline.
    private var lineStatusGrid: some View {
        let keys = affectedLineKeys
        return FlowLayoutCompat(spacing: 8) {
            ForEach(MetroLine.allLines) { line in
                statusBadge(
                    label: line.displayName,
                    colorHex: line.colorHex,
                    textColorHex: nil,
                    isAffected: keys.contains("metro:\(line.code)"),
                    accessibilityName: String(localized: "Línia \(line.displayName)"),
                    action: {
                        AppRouter.shared.open(.line(operator: AppModeCode.metro, code: line.code))
                    }
                )
            }
            ForEach(shownFGCLines) { line in
                statusBadge(
                    label: line.code,
                    colorHex: line.colorHex,
                    textColorHex: line.textColorHex,
                    isAffected: keys.contains("fgc:\(line.code)"),
                    accessibilityName: String(localized: "Línia \(line.code)"),
                    action: {
                        AppRouter.shared.open(.line(operator: AppModeCode.fgc, code: line.code))
                    }
                )
            }
            ForEach(favoriteBusLines) { line in
                statusBadge(
                    label: line.name,
                    colorHex: line.colorHex,
                    textColorHex: line.textColorHex,
                    isAffected: keys.contains("bus:\(String(line.code))"),
                    accessibilityName: String(localized: "Línia \(line.name)"),
                    action: {
                        AppRouter.shared.open(.line(operator: AppModeCode.bus, code: String(line.code)))
                    }
                )
            }
        }
    }

    /// One badge of the grid with its amber dot when the line has a SERVICE
    /// alert (spec S10), and its "afectada" accessibility wording.
    private func statusBadge(
        label: String,
        colorHex: String,
        textColorHex: String?,
        isAffected: Bool,
        accessibilityName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            NearbyLineBadge(text: label, colorHex: colorHex, textColorHex: textColorHex)
                .overlay(alignment: .topTrailing) {
                    if isAffected {
                        Circle()
                            .fill(Color(hex: "FF9F0A"))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Text("!")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(Color(hex: "1C1C1E"))
                            )
                            .offset(x: 5, y: -5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isAffected ? String(localized: "\(accessibilityName), servei afectat") : accessibilityName
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// A simple wrap layout for the badge grid (mockup `V4Tot`): rows of badges
/// that break when the next one would not fit. A minimal long-standing-API
/// flow, no iOS 26 layout protocol involved.
private struct FlowLayoutCompat: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
