import SwiftUI

/// What the marker draws inside the circle (S6): the train or the bus
/// pictogram, or a short code ("L1") in place of a pictogram — what Tot uses.
enum VehicleGlyph: Equatable {
    case train
    case bus
    case code(String)
}

/// The unified vehicle marker (spec S6, mockup `V3Markers`): a solid circle in
/// the line colour with a white ring and an upright pictogram; a heading wedge
/// rotates around the circle while the pictogram stays upright; the ring is
/// dashed when the position is a timetable estimate; the selected vehicle gets
/// a halo.
///
/// A pure `View, Equatable`: every input is a value, so the map screens can
/// diff it on the 10 Hz path and skip identical markers (S15, nothing new on
/// the render path). It draws no label — the caller adds the selected
/// vehicle's destination chip.
struct VehicleMarkerView: View, Equatable {
    /// Line colour hex without "#" ("93248F").
    let colorHex: String
    let glyph: VehicleGlyph
    /// Heading in degrees clockwise from north; the wedge points this way.
    /// `nil` draws no wedge (a bus whose feed gave no bearing).
    let headingDegrees: Double?
    /// Dashed ring: metro `isTheoretical` (S6); D5 keeps bus markers solid.
    let isEstimated: Bool
    /// Blue halo behind the marker for the selected vehicle (S6).
    let isSelected: Bool
    /// Marker size in points; every proportion below scales with it.
    var size: CGFloat = 28

    /// The mockup is drawn in a 44x44 view box; every measurement below is
    /// stated in that space and scaled.
    private var scale: CGFloat { size / 44 }

    /// Ink of the pictogram: dark on a light fill, white otherwise — the same
    /// WCAG rule `HexLuminance` documents for the arrival pills.
    private var inkColor: Color {
        HexLuminance.isLight(colorHex)
            ? Color(hex: "1C1C1E")
            : Color.white
    }

    private var fillColor: Color { Color(hex: colorHex) }

    var body: some View {
        ZStack {
            if isSelected {
                halo
            }
            if let headingDegrees {
                wedgeGroup(headingDegrees: headingDegrees)
            }
            circle
            glyphContent
        }
        .frame(width: size, height: size)
        // Decorative on the rail and the map: the caller attaches the
        // accessibility label of the vehicle when one applies.
        .accessibilityHidden(true)
    }

    /// Halo of the selected vehicle: a translucent blue disc with a ring,
    /// behind the marker (mockup "Seleccionat").
    private var halo: some View {
        Circle()
            .fill(Color(hex: "409CFF").opacity(0.30))
            .overlay(Circle().stroke(Color(hex: "409CFF"), lineWidth: 2))
            .frame(width: size * 1.25, height: size * 1.25)
    }

    /// The direction wedge and its rotation pivot: the group fills the marker
    /// frame, so `rotationEffect` turns the wedge around the circle's center
    /// while the wedge itself sits at the top edge, overlapping the ring as the
    /// mockup does (its base reaches into the circle).
    private func wedgeGroup(headingDegrees: Double) -> some View {
        Wedge()
            .fill(fillColor)
            .overlay(Wedge().stroke(Color.white, lineWidth: 1.6 * scale))
            .frame(width: 12 * scale, height: 9 * scale)
            .offset(y: -13.5 * scale)
            .rotationEffect(.degrees(headingDegrees))
            .frame(width: size, height: size)
    }

    /// The solid circle with its white ring; dashed when the position is an
    /// estimate (S6: metro timetable, `stroke-dasharray: 3 2.6` in the mockup).
    private var circle: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 26 * scale, height: 26 * scale)
            .overlay(
                Circle().stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: 2.4 * scale,
                        dash: isEstimated ? [3 * scale, 2.6 * scale] : []
                    )
                )
            )
    }

    @ViewBuilder
    private var glyphContent: some View {
        switch glyph {
        case .train:
            Image(systemName: "tram.fill")
                .font(.system(size: 13 * scale, weight: .bold))
                .foregroundStyle(inkColor)
        case .bus:
            Image(systemName: "bus.fill")
                .font(.system(size: 12.5 * scale, weight: .bold))
                .foregroundStyle(inkColor)
        case .code(let text):
            Text(text)
                .font(.system(size: 11 * scale, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(inkColor)
                .padding(.horizontal, 2 * scale)
        }
    }
}

/// The triangle of the heading wedge (`M22 2.5 L28 10.5 L16 10.5 Z` in the
/// mockup's view box, drawn here in unit proportions of its own frame).
private struct Wedge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
