import SwiftUI

/// Configuració reached from the map (spec S1): the Mapa tab has no navigation
/// bar, so the gear that Explora keeps in its toolbar lives here, next to the
/// location button, on every map screen.
///
/// One shared view instead of five copies: the button owns its sheet, so a map
/// screen only places it in its top-trailing chrome. `SettingsScreen` is
/// normally pushed inside a `NavigationStack`, so the sheet wraps it in one of
/// its own — that is what its title and its feedback `NavigationLink` need —
/// and adds the close button the pushed screen does not need.
struct MapSettingsButton: View {
    @State private var isSettingsPresented = false

    var body: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .glassEffect(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Configuració")
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Tancar") { isSettingsPresented = false }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
    }
}
