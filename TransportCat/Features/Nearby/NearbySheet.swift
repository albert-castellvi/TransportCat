import SwiftUI

/// The "A prop teu" sheet over the map (spec S13, mockup `V6Nearby`): the
/// reusable nearby list (`NearbyStopsList`, the same component the Tot screen
/// hosts) under its own header, with medium and large detents so the map
/// stays visible behind at medium.
///
/// Hosted by `RootView`, bound to `AppRouter.shared.isNearbyPresented`; the
/// map screens draw the location button filled while the binding is on.
struct NearbySheet: View {
    // Injected explicitly by the host (RootView): the list reads `AppModel`
    // through `@EnvironmentObject`, and sheet content must never rely on the
    // presenting hierarchy's environment.
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    private var location: LocationService { LocationService.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isLocationDenied {
                // Same wording the Tot screen shows: a denied permission is a
                // normal state, never a prompt loop.
                Text("Activa la ubicació a Configuració per veure què tens a prop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        NearbyStopsList()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        // The list only reads the service: the sheet owns the decision to
        // start location, because a quick action can open it without the map
        // button having run first.
        .task {
            if location.authorization == .notDetermined {
                location.requestWhenInUse()
            }
            location.start()
        }
    }

    /// Header of the mockup: title, subtitle and a 44 pt close button.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("A prop teu")
                    .font(.title2.weight(.bold))
                Text("Parades a menys de 15 min a peu")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tancar")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var isLocationDenied: Bool {
        location.authorization == .denied || location.authorization == .restricted
    }
}
