import SwiftUI

/// The Línies tab of the global mode (spec S8): every line of every operator,
/// grouped in three sections — Metro, FGC and the favorite Bus lines. A row
/// is a colored badge plus the line name, and tapping it hands the rider to
/// that operator's own map on that line through `AppRouter.open(.line(...))`
/// (S5), exactly like the Explora results do.
///
/// The header carries the mode selector so the rider can leave the global
/// mode from here, as on the other Línies screens.
@MainActor
struct GlobalLinesScreen: View {
    @EnvironmentObject private var app: AppModel

    init() {}

    private var fgc: FGCNetworkState { FGCNetworkState.shared }
    private var busCatalog: BusCatalogStore { BusCatalogStore.shared }

    /// The FGC lines on screen: the same selection the FGC line picker
    /// offers — at least one polyline, no `Bus…` shuttle routes (spec S8).
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

    /// Empty-state wording for the Bus section: nothing starred is one case,
    /// starred lines the catalog has not resolved (yet) is another.
    private var busEmptyText: String {
        if busCatalog.favorites.isEmpty {
            return "Encara no has marcat cap línia d'autobús. Estrella-les a la pantalla Bus."
        }
        return busCatalog.errorMessage ?? "Carregant la xarxa d'autobusos…"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ModeSelector()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                List {
                    Section("Metro") {
                        ForEach(MetroLine.allLines) { line in
                            lineRow(
                                badge: line.displayName,
                                colorHex: line.colorHex,
                                textColorHex: Self.textColor(forMetroHex: line.colorHex),
                                name: line.displayName,
                                detail: nil,
                                accessibilityName: "Línia \(line.displayName)"
                            ) {
                                AppRouter.shared.open(.line(operator: AppModeCode.metro, code: line.code))
                            }
                        }
                    }
                    Section("FGC") {
                        if shownFGCLines.isEmpty {
                            Text(fgc.errorMessage ?? "Carregant la xarxa FGC…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(shownFGCLines) { line in
                                lineRow(
                                    badge: line.code,
                                    colorHex: line.colorHex,
                                    textColorHex: line.textColorHex,
                                    name: line.code,
                                    detail: line.name,
                                    accessibilityName: "Línia \(line.code)"
                                ) {
                                    AppRouter.shared.open(.line(operator: AppModeCode.fgc, code: line.code))
                                }
                            }
                        }
                    }
                    Section("Bus preferits") {
                        if favoriteBusLines.isEmpty {
                            Text(busEmptyText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(favoriteBusLines) { line in
                                lineRow(
                                    badge: line.name,
                                    colorHex: line.colorHex,
                                    textColorHex: line.textColorHex,
                                    name: line.name,
                                    detail: line.description,
                                    accessibilityName: "Línia \(line.name)"
                                ) {
                                    AppRouter.shared.open(.line(operator: AppModeCode.bus, code: String(line.code)))
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Línies")
            .navigationBarTitleDisplayMode(.inline)
            // The bus section needs the catalog; `load` is the store's own
            // once-per-launch guard, so visiting global never re-requests it.
            .task {
                if let client = app.client {
                    await busCatalog.load(client: client)
                }
            }
        }
    }

    /// One tappable row: badge, name and the optional operator description.
    private func lineRow(
        badge: String,
        colorHex: String,
        textColorHex: String,
        name: String,
        detail: String?,
        accessibilityName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LineBadge(text: badge, colorHex: colorHex, textColorHex: textColorHex)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
        }
        .buttonStyle(.plain)
    }

    /// Metro badges carry no published text color, so the choice follows the
    /// WCAG luminance rule used by the arrival pills.
    private static func textColor(forMetroHex hex: String) -> String {
        HexLuminance.isLight(hex) ? "111111" : "FFFFFF"
    }
}

/// The colored capsule with the line code inside, shared by the three
/// sections so a metro, FGC or bus row always reads the same way (spec S8).
private struct LineBadge: View {
    let text: String
    let colorHex: String
    let textColorHex: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(hex: textColorHex))
            .padding(.horizontal, 8)
            .frame(minWidth: 34, minHeight: 26)
            .background(Capsule().fill(Color(hex: colorHex)))
            .accessibilityHidden(true)
    }
}
