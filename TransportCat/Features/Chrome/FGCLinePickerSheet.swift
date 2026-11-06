import SwiftUI

/// Sheet that picks an FGC line (redesign spec S4), opened from the bottom
/// accessory's FGC line chip. The line data is the same source
/// `FGCLinePicker` uses: the selectable layers of the shared FGC network
/// state, resolved through its own rule.
struct FGCLinePickerSheet: View {
    /// The code of the line currently selected, for the checkmark row.
    private let selectedLineCode: String
    /// Called with the row the rider tapped. The sheet dismisses itself after
    /// it, so a presenter only has to remember the selection.
    private let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var fgc: FGCNetworkState { FGCNetworkState.shared }

    init(selectedLineCode: String, onSelect: @escaping (String) -> Void) {
        self.selectedLineCode = selectedLineCode
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(selectableLayers) { layer in
                    lineRow(layer)
                }
            }
            .navigationTitle("Línia de FGC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The drawable lines, exactly the set the map's chips show (spec S7 of
    /// the previous design): at least one polyline, shuttle road routes out.
    private var selectableLayers: [MapLineLayer] {
        FGCLinePicker.selectableLayers(from: fgc.lineLayers)
    }

    /// `route_long_name` for the code, when the loaded catalog has the line.
    private func lineName(for layer: MapLineLayer) -> String? {
        fgc.lines.first { $0.code == layer.code }?.name
    }

    /// Code badge in the line colors, name and the checkmark of the shown line.
    private func lineRow(_ layer: MapLineLayer) -> some View {
        Button {
            onSelect(layer.code)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(layer.code)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: layer.textColorHex))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(Color(hex: layer.colorHex)))
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                Text(lineName(for: layer) ?? layer.operator)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if layer.code == selectedLineCode {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Línia \(layer.code)")
        .accessibilityAddTraits(layer.code == selectedLineCode ? .isSelected : [])
    }
}
