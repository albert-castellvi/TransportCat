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

/// Loading state of the map screens (spec S11): the icon's network draws its
/// lines in and pops its interchange rings, above "Carregant la xarxa…" and
/// "Metro · Bus · FGC" per the `V5Loading` mockup. The animation is internal
/// to `NetworkArt(.drawing)`, which turns static under Reduce Motion.
struct MapLoadingPlaceholder: View {
    var body: some View {
        VStack(spacing: 22) {
            // Pure decoration: the loop is what says "loading", so VoiceOver
            // never reads the art.
            NetworkArt(.drawing)
                .frame(width: 270, height: 208)
                .accessibilityHidden(true)

            // role "status" of the mockup: the rider hears the state, and the
            // two lines are read as one element.
            VStack(spacing: 6) {
                Text("Carregant la xarxa…")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Metro · Bus · FGC")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
