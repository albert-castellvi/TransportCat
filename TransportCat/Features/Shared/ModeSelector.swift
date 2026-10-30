import SwiftUI

/// What a tab shows: the existing metro screens or the new bus ones (spec S1).
///
/// Persisted as its raw value in `UserDefaults` under "appMode", so the app
/// reopens on the mode the rider used last. Both `RootView` and `ModeSelector`
/// read that same key through `@AppStorage`, which is what makes the label of
/// the chip and the screen behind it agree without any explicit wiring.
enum AppMode: String {
    case metro
    case bus
}

/// Capsule row "Metro | Bus" (spec S1), the selected one in the prototype's
/// white-on-black style. The caller's header supplies the horizontal padding.
struct ModeSelector: View {
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One capsule. Unselected chips are dimmed by their dark background
    /// instead of being hidden, so the rider always sees both modes.
    private func chip(_ title: String, _ selection: AppMode) -> some View {
        let isSelected = mode == selection
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
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
