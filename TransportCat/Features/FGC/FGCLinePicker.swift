import SwiftUI

/// Horizontal capsule chips of the drawable FGC lines (spec S7, S9).
///
/// A chip is filled with the line's own colour and labelled in its text
/// colour, exactly as the `gtfs_routes` payload publishes them; the selected
/// chip carries a white outline. The selection is the caller's binding — both
/// FGC screens wire it to the same `@AppStorage("fgcSelectedLine")` key, so
/// the map and the lines list always show the same line.
struct FGCLinePicker: View {
    /// The line the app opens with, and the default of the persisted key.
    static let defaultLineCode = "S1"

    /// The lines a rider can pick: at least one polyline, and not one of the
    /// `Bus…` shuttle routes, which are road services, not the rail network
    /// this mode draws. The API's order is kept (spec S7).
    static func selectableLayers(from layers: [MapLineLayer]) -> [MapLineLayer] {
        layers.filter { !$0.polylines.isEmpty && !$0.code.hasPrefix("Bus") }
    }

    /// The code actually shown for a stored one: the stored code when it is
    /// selectable, otherwise the first selectable line, otherwise the stored
    /// code itself (nothing to choose yet).
    static func resolve(selected code: String, from layers: [MapLineLayer]) -> String {
        let selectable = selectableLayers(from: layers)
        return selectable.first { $0.code == code }?.code ?? selectable.first?.code ?? code
    }

    let layers: [MapLineLayer]
    @Binding var selectedLineCode: String
    @ScaledMetric(relativeTo: .footnote) private var chipCodeSize: CGFloat = 14

    var body: some View {
        let selectable = Self.selectableLayers(from: layers)
        let shownCode = Self.resolve(selected: selectedLineCode, from: layers)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectable) { layer in
                    chip(layer, isSelected: layer.code == shownCode)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// One capsule. The fill is the line colour, so the outline is the only
    /// selection cue that survives two lines with similar colours.
    private func chip(_ layer: MapLineLayer, isSelected: Bool) -> some View {
        Button {
            selectedLineCode = layer.code
        } label: {
            Text(layer.code)
                .font(.system(size: chipCodeSize, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(Color(hex: layer.textColorHex))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Color(hex: layer.colorHex)))
                .overlay(Capsule().stroke(.white, lineWidth: isSelected ? 2.5 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Línia \(layer.code)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
