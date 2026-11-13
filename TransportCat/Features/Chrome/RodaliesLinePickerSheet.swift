import SwiftUI

/// Sheet that picks a Rodalies line, opened from the bottom accessory's chip.
///
/// The list is the whole nucleus — 19 lines today — with each line's code in its
/// own colours and its termini pair, which is the only long name the feed
/// publishes. The lines come from the caller, so the chip and this sheet show
/// the same set whether or not the mode has loaded its state yet.
struct RodaliesLinePickerSheet: View {
    /// The code of the line currently selected, for the checkmark row.
    private let selectedLineCode: String
    private let lines: [RodaliesLine]
    /// Called with the code of the row the rider tapped. The sheet dismisses
    /// itself after it, so a presenter only has to remember the selection.
    private let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        selectedLineCode: String,
        lines: [RodaliesLine],
        onSelect: @escaping (String) -> Void
    ) {
        self.selectedLineCode = selectedLineCode
        self.lines = lines
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(lines) { line in
                    lineRow(line)
                }
            }
            .navigationTitle("Línia de Rodalies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// Code badge, termini and the checkmark of the line on screen.
    private func lineRow(_ line: RodaliesLine) -> some View {
        Button {
            onSelect(line.code)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                RodaliesLineBadge(
                    code: line.code,
                    colorHex: line.colorHex,
                    textColorHex: line.textColorHex
                )
                Text(line.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if line.code == selectedLineCode {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Línia \(line.code), \(line.name)")
        .accessibilityAddTraits(line.code == selectedLineCode ? .isSelected : [])
    }
}
