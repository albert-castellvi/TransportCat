import SwiftUI

/// What a tab shows: the existing metro screens, the bus ones, the FGC ones
/// or all operators at once (spec S1, S6, S8).
///
/// Persisted as its raw value in `UserDefaults` under "appMode", so the app
/// reopens on the mode the rider used last. Both `RootView` and `ModeSelector`
/// read that same key through `@AppStorage`, which is what makes the label of
/// the chip and the screen behind it agree without any explicit wiring.
enum AppMode: String {
    case metro
    case bus
    /// Ferrocarrils de la Generalitat (spec S6). Its screens read
    /// `FGCNetworkState.shared` instead of the TMB model.
    case fgc
    /// The global mode (spec S8): metro, FGC and the favorite bus routes on
    /// one map. Its screens read `GlobalNetworkState.shared` for the metro
    /// side and `FGCNetworkState.shared` for the FGC side.
    case global
}

/// Capsule row "Metro | Bus | FGC | Tot" (spec S1, S6, S8), the selected one
/// in the prototype's white-on-black style. The caller's header supplies the
/// horizontal padding.
struct ModeSelector: View {
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Height of the capsules, shared with the chips row of the header.
    private static let chipHeight: CGFloat = 36
    /// Point size of the chip labels.
    private static let fontSize: CGFloat = 15

    private var mode: AppMode {
        AppMode(rawValue: modeRaw) ?? .metro
    }

    var body: some View {
        HStack(spacing: 8) {
            chip("Metro", .metro)
            chip("Bus", .bus)
            chip("FGC", .fgc)
            chip("Tot", .global)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A tap on the other mode is a choice, so it clicks (polish pass).
        // Fires on the value change, not on first appearance.
        .sensoryFeedback(.selection, trigger: modeRaw)
    }

    /// One capsule. Unselected chips are dimmed by their dark background
    /// instead of being hidden, so the rider always sees every mode.
    private func chip(_ title: String, _ selection: AppMode) -> some View {
        let isSelected = mode == selection
        return Button {
            withAnimation(AppMotion.smooth(duration: 0.2, reduceMotion: reduceMotion)) {
                modeRaw = selection.rawValue
            }
        } label: {
            Text(title)
                .font(.system(size: Self.fontSize, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(height: Self.chipHeight)
                .background(Capsule().fill(isSelected ? Color.white : Color(white: 0.17)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
