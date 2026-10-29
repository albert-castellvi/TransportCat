import SwiftUI

/// Horizontal selector of metro lines, styled as TMB-like line chips.
struct LinePicker: View {
    @Binding var selectedLineCode: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MetroLine.allLines) { line in
                    let isSelected = line.code == selectedLineCode
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedLineCode = line.code
                        }
                    } label: {
                        Text(line.displayName)
                            .font(.subheadline.bold())
                            .foregroundColor(isSelected ? .white : Color(hex: line.colorHex))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(isSelected ? Color(hex: line.colorHex) : Color(hex: line.colorHex).opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Línia \(line.displayName)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
