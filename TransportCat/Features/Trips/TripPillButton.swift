import SwiftUI

/// The "Trajectes" pill on every map (spec S1, S4): a 44 pt glass circle next
/// to Configuració, like `MapSettingsButton`. It owns the trips sheet, and it
/// is visibly "on" — filled with the accent tint and a white glyph — while a
/// trip is being followed.
struct TripPillButton: View {
    @State private var isSheetPresented = false

    private var trips: TripsStore { TripsStore.shared }

    var body: some View {
        Button {
            isSheetPresented = true
        } label: {
            if trips.activeSavedTrip != nil {
                Image(systemName: Self.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
            } else {
                Image(systemName: Self.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .glassEffect(in: Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Trajectes")
        .sheet(isPresented: $isSheetPresented) {
            NavigationStack {
                TripsSheet()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// The planned-route glyph of the mockup.
    private static let symbol = "point.topleft.down.to.point.bottomright.curvepath"
}
