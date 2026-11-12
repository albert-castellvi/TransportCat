import SwiftUI

/// The bottom accessory above the tab bar (redesign spec S4, mockup
/// `V2Main`): the mode menu plus one context control per mode, shown over the
/// Mapa and Parades tabs through `RootView`'s `tabViewBottomAccessory`.
///
/// It reads and writes the same state the screens read — the `appMode` key,
/// `metroSelectedLine`, the bus catalog's selection, `fgcSelectedLine` and the
/// global operators key — and runs no poller of its own: the labels come from
/// shared stores and static catalog data (the topology caches), never from a
/// second fetcher.
@MainActor
struct BottomAccessory: View {
    /// The `appMode` key every screen reads (spec S4), so the accessory's menu
    /// and the screens behind it agree without explicit wiring.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    @EnvironmentObject private var app: AppModel
    @ScaledMetric(relativeTo: .body) private var modeLabelSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var modeIconSize: CGFloat = 12

    private var mode: AppMode {
        AppMode(rawValue: modeRaw) ?? .metro
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                modeMenu
                switch mode {
                case .metro:
                    MetroLineChip()
                case .bus:
                    BusAccessoryControls()
                case .fgc:
                    FGCLineChip()
                case .global:
                    GlobalOperatorToggles()
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    // MARK: - Mode menu

    /// The four modes in the order the menu lists and the map draws them
    /// (spec S4): Metro, Bus, FGC and Tot.
    private static let modes: [(AppMode, String)] = [
        (.metro, "Metro"),
        (.bus, "Bus"),
        (.fgc, "FGC"),
        (.global, "Tot")
    ]

    /// Menu button labelled with the current mode and an up/down chevron; the
    /// checkmark marks the mode on screen. Writes `appMode` with the raw
    /// values the chips always used (spec S4).
    private var modeMenu: some View {
        Menu {
            ForEach(Self.modes, id: \.0) { option in
                Button {
                    modeRaw = option.0.rawValue
                } label: {
                    if option.0 == mode {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(option.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(for: mode))
                    .font(.system(size: modeLabelSize, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: modeIconSize, weight: .semibold))
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 46)
            .glassEffect()
            .accessibilityLabel("Mode: \(label(for: mode)). Canviar de mode")
        }
        .sensoryFeedback(.selection, trigger: modeRaw)
    }

    private func label(for mode: AppMode) -> String {
        switch mode {
        case .metro: return "Metro"
        case .bus: return "Bus"
        case .fgc: return "FGC"
        case .global: return "Tot"
        }
    }
}

// MARK: - Metro

/// Metro line chip of the accessory (spec S4): the TMB badge and the line's
/// termini, an amber mark while the line has a service alert, and the line
/// picker sheet behind the tap. Termini come from the topology cache, never a
/// second poll.
@MainActor
private struct MetroLineChip: View {
    /// The same key the metro screens read (spec S4): picking here moves the
    /// map too.
    @AppStorage("metroSelectedLine") private var selectedLineCode = MetroLine.allLines[0].code
    @EnvironmentObject private var app: AppModel
    @State private var showPicker = false
    /// Termini of the line on screen, from the cached topology; nil until the
    /// line has loaded once in the app's lifetime.
    @State private var termini: String?

    private var selectedLine: MetroLine {
        MetroLine.line(forCode: selectedLineCode) ?? MetroLine.allLines[0]
    }

    /// Whether the selected line has a service alert right now, from the same
    /// feed the former incidents chip read (spec S4).
    private var hasServiceAlert: Bool {
        app.activeAlerts(affecting: selectedLineCode).contains { $0.severity == .service }
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 8) {
                Image("badge-\(selectedLine.assetKey)")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 32)
                if let termini {
                    Text(termini)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if hasServiceAlert {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "FF9F0A"))
                        .accessibilityLabel("Servei afectat")
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 46)
            .glassEffect()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .sheet(isPresented: $showPicker) {
            MetroLinePickerSheet(selectedLineCode: selectedLineCode) { line in
                selectedLineCode = line.code
            }
        }
        // The termini are static catalog data: one cache read per selected
        // line, never while rendering. The read also repeats when a topology
        // lands, because this chip mounts before the line's own load writes
        // the cache and the line code alone never changes again (#55).
        .task(id: TopologyReadKey(
            lineCode: selectedLineCode,
            revision: app.topologyRevision
        )) {
            termini = MetroLineTermini.cachedTermini(lineCode: selectedLineCode)
        }
    }

    private var accessibilityText: String {
        var text = "Línia \(selectedLine.displayName)"
        if let termini {
            text += ", \(termini)"
        }
        if hasServiceAlert {
            text += ", 1 avís"
        }
        text += ". Canviar de línia"
        return text
    }
}

// MARK: - Bus

/// Bus controls of the accessory (spec S4): a line chip that opens the
/// existing `BusLinePickerSheet`, and a direction swap button shared with the
/// screens through `BusDirectionSelection`'s storage key.
@MainActor
private struct BusAccessoryControls: View {
    private var store: BusCatalogStore { BusCatalogStore.shared }
    /// Publishes `topologyRevision`, which the cache read below watches (#55).
    @EnvironmentObject private var app: AppModel
    /// The shared direction: the map and the Parades bus screen resolve it
    /// against the line's directions (spec S4).
    @AppStorage(BusDirectionSelection.storageKey) private var storedDirectionID = 1
    @State private var showPicker = false
    /// Directions of the line on screen, from the cached topology; empty until
    /// the line has loaded once, which hides the swap until it can act.
    @State private var availableDirections: [Int] = []
    @ScaledMetric(relativeTo: .footnote) private var swapIconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            lineChip
            if availableDirections.count > 1 {
                swapButton
            }
        }
        .sheet(isPresented: $showPicker) {
            BusLinePickerSheet(store: store) { line in
                store.selectedLineCode = line.code
            }
        }
        // The direction ids are static catalog data: one cache read per
        // selected line, never a poll (spec S4). The read repeats when a
        // topology lands, because the accessory mounts before the bus screen
        // writes the cache and the line code alone never changes again (#55).
        .task(id: TopologyReadKey(
            lineCode: store.selectedLine.map { String($0.code) } ?? "",
            revision: app.topologyRevision
        )) {
            guard let code = store.selectedLine?.code,
                  let topology = OfflineCache.loadBusTopology(lineCode: code) else {
                availableDirections = []
                return
            }
            availableDirections = Array(Set(topology.stops.map(\.directionID))).sorted()
        }
    }

    private var lineChip: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 8) {
                if let line = store.selectedLine {
                    BusBadge(line: line, width: 46)
                    Text(line.description)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 46)
            .glassEffect()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lineAccessibilityText)
    }

    /// 46 pt glass button that swaps the direction of the line on screen
    /// through the shared key (spec S4). Hidden while the line cannot offer
    /// two directions — the rule `BusDirectionSelection.swapped` encodes.
    private var swapButton: some View {
        Button {
            storedDirectionID = BusDirectionSelection.swapped(
                current: storedDirectionID,
                available: availableDirections
            )
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: swapIconSize, weight: .semibold))
                .frame(width: 46, height: 46)
                .glassEffect()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Invertir la direcció")
    }

    private var lineAccessibilityText: String {
        guard let line = store.selectedLine else { return "Canviar de línia" }
        return "Línia \(line.name). Canviar de línia"
    }
}

// MARK: - FGC

/// FGC line chip of the accessory (spec S4): the line's code badge in its own
/// colors, resolved with the same rule the map's chips use, and the FGC line
/// sheet behind the tap.
@MainActor
private struct FGCLineChip: View {
    /// The same key the FGC screens read (spec S4).
    @AppStorage("fgcSelectedLine") private var selectedLineCode = FGCLinePicker.defaultLineCode
    @State private var showPicker = false
    @ScaledMetric(relativeTo: .footnote) private var fgcCodeSize: CGFloat = 14

    private var fgc: FGCNetworkState { FGCNetworkState.shared }

    /// The line actually selectable: the stored code when it is one of the
    /// drawable layers, otherwise the first drawable one, else the stored code
    /// while the topology has not arrived.
    private var selectableLayers: [MapLineLayer] {
        FGCLinePicker.selectableLayers(from: fgc.lineLayers)
    }

    private var shownCode: String {
        FGCLinePicker.resolve(selected: selectedLineCode, from: selectableLayers)
    }

    private var shownLayer: MapLineLayer? {
        selectableLayers.first { $0.code == shownCode }
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 8) {
                Text(shownCode)
                    .font(.system(size: fgcCodeSize, weight: .bold))
                    .foregroundStyle(
                        shownLayer.map { Color(hex: $0.textColorHex) } ?? Color.white
                    )
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        Capsule().fill(
                            shownLayer.map { Color(hex: $0.colorHex) } ?? Color(white: 0.25)
                        )
                    )
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 46)
            .glassEffect()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Línia \(shownCode). Canviar de línia")
        .sheet(isPresented: $showPicker) {
            FGCLinePickerSheet(selectedLineCode: shownCode) { code in
                selectedLineCode = code
            }
        }
    }
}

// MARK: - Tot

/// Metro / Bus / FGC toggles of the accessory in the Tot mode (spec S4): the
/// same logic the global map's `operatorChips` used, moved off the removed
/// header and kept over the shared `GlobalOperatorSelection` key.
@MainActor
private struct GlobalOperatorToggles: View {
    /// The same key the global map reads (spec S4): toggling here redraws the
    /// global map through `@AppStorage`.
    @AppStorage(GlobalOperatorSelection.storageKey) private var operatorsRaw = GlobalOperatorSelection.defaultRaw
    @ScaledMetric(relativeTo: .footnote) private var opLabelSize: CGFloat = 14

    private var selectedOperators: Set<GlobalOperator> {
        GlobalOperatorSelection.decode(operatorsRaw)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(GlobalOperator.allCases, id: \.self) { operatorKind in
                toggle(operatorKind)
            }
        }
        .padding(4)
        .glassEffect(in: Capsule())
        // Toggling an operator is a selection, so it clicks — the same feedback
        // the old global map chips gave (spec S4).
        .sensoryFeedback(.selection, trigger: operatorsRaw)
    }

    /// One toggle: an operator-colored dot when on, the operator label, and
    /// the selected trait for VoiceOver. The selection may run empty, exactly
    /// as the old chips allowed.
    private func toggle(_ operatorKind: GlobalOperator) -> some View {
        let isSelected = selectedOperators.contains(operatorKind)
        return Button {
            var selection = selectedOperators
            if isSelected {
                selection.remove(operatorKind)
            } else {
                selection.insert(operatorKind)
            }
            operatorsRaw = GlobalOperatorSelection.encode(selection)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? Self.operatorColor(operatorKind) : .clear)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Self.operatorColor(operatorKind), lineWidth: 1.5))
                Text(operatorKind.label)
                    .font(.system(size: opLabelSize, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(operatorKind.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Chrome colors of the three operators, from the mode-menu mockup (the
    /// screens draw the lines in their own line colors; these are identity
    /// colors for the toggles).
    private static func operatorColor(_ operatorKind: GlobalOperator) -> Color {
        switch operatorKind {
        case .metro: return Color(hex: "E3242B")
        case .bus: return Color(hex: "1F5BEF")
        case .fgc: return Color(hex: "F39200")
        }
    }
}

// MARK: - Cache reads

/// Inputs of an accessory cache read (#55): the line on screen plus the
/// revision a finished topology load bumps. A control that mounted before the
/// cache had its copy therefore reads it again when the copy lands, instead of
/// showing an empty label until the control remounts.
private struct TopologyReadKey: Equatable {
    let lineCode: String
    let revision: Int
}