import SwiftUI

/// Motion choices shared by the polish pass: one smooth curve everywhere, and
/// it disappears when the rider turned Reduce Motion on.
enum AppMotion {
    /// The `.smooth` curve the screens animate with, or `nil` under Reduce
    /// Motion: both `.animation(_:value:)` and `withAnimation(_:)` accept a
    /// nil animation and then apply the change instantly.
    static func smooth(duration: Double = 0.25, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: duration)
    }

    /// Fade with a slight shrink, for the header chips that come and go.
    static var chipTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.95))
    }
}

/// Loading state of the two map screens: three placeholder lines that pulse
/// gently while the line loads, above the same "Carregant…" the maps showed.
struct MapLoadingPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the opacity pulse: flipped once on appear, then eased back and
    /// forth forever by the repeat animation below.
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                placeholderLine(width: 150)
                placeholderLine(width: 100)
                placeholderLine(width: 130)
            }
            // Pure shapes, no text to redact: the pulse is what says "loading",
            // so VoiceOver never has to read the decoration.
            .accessibilityHidden(true)
            .opacity(reduceMotion ? 0.7 : (isPulsing ? 1 : 0.45))

            ProgressView("Carregant…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    /// One rounded bar of the placeholder group.
    private func placeholderLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.25))
            .frame(width: width, height: 10)
    }
}
