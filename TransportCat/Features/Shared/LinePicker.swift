import SwiftUI

extension MetroLine {
    /// Lowercased asset key shared by the `train-`, `badge-`, `station-` and
    /// `terminal-` image sets produced by `scripts/render-assets.sh` (S7):
    /// "L9N" is `badge-l9n`, "FM" is `train-fm`.
    var assetKey: String { displayName.lowercased() }
}

/// Horizontal selector of metro lines, one pre-rendered TMB-style badge per
/// line (S5).
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
                        // The badge image already carries the line color and
                        // its label, so unselected lines are only dimmed.
                        Image("badge-\(line.assetKey)")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 32)
                            .opacity(isSelected ? 1 : 0.45)
                            .overlay {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.white, lineWidth: 2)
                                }
                            }
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
