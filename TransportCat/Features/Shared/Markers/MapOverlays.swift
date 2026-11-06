import SwiftUI

// Shared overlay pieces of the four map screens (redesign specs S6, S7,
// mockups `V3Markers`, `V3Metro`, `V3Bus`, `V3Tot`). One definition each, so
// metro, bus, FGC and Tot draw the same badge, station icon and card.

/// Amber badge of a service alert on the map (spec S7): a warning glyph and
/// the line code ("L2"), or a grouped count ("2 línies") in Tot. One badge per
/// affected run, never one per station. The 44 pt frame is the touch target;
/// the visible capsule is 30 pt tall.
struct IncidentBadge: View, Equatable {
    /// "L2", "H12" or "2 línies".
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color(hex: "1C1C1E"))
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(Capsule().fill(Color(hex: "FF9F0A")))
        .overlay(Capsule().stroke(Color.white, lineWidth: 2))
        .shadow(color: Color.black.opacity(0.45), radius: 6, y: 3)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Small grey icon of a facility alert (lift, escalator, closed access) next
/// to its station (spec S7). Single-line map modes only, never in Tot.
struct FacilityStationIcon: View, Equatable {
    let kind: IncidentKind

    var body: some View {
        Image(kind.incidentIconAssetName)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(Color.white)
            .frame(width: 13, height: 13)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: "3A3D44")))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white, lineWidth: 1.5))
    }
}

/// Glass card the maps show above the bottom accessory when the rider taps a
/// vehicle or an incident badge (specs S6, S7): the line badge, a title, a
/// close button, then the caller's rows.
struct MapGlassCard<Content: View>: View {
    /// Line badge text ("L2", "H12", "S1").
    let badgeText: String
    /// Line colour hex without "#"; the badge text picks dark or white ink.
    let badgeColorHex: String
    /// "Servei afectat", "Cap a Paral·lel"...
    let title: String
    let onClose: () -> Void
    private let content: Content

    init(
        badgeText: String,
        badgeColorHex: String,
        title: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.badgeText = badgeText
        self.badgeColorHex = badgeColorHex
        self.title = title
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(badgeText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HexLuminance.isLight(badgeColorHex) ? Color(hex: "1C1C1E") : Color.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 36, minHeight: 30)
                    .background(Capsule().fill(Color(hex: badgeColorHex)))
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tancar")
            }
            content
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// Where a vehicle's position comes from, the last row of the vehicle card
/// (spec S6): a green dot and "Posició en directe", or a dashed ring and the
/// caller's estimate wording (metro timetable, bus arrivals).
struct VehiclePositionSource: View, Equatable {
    let isEstimated: Bool
    /// Wording when estimated, e.g. "Posició estimada a partir de l'horari".
    let estimatedText: String

    var body: some View {
        HStack(spacing: 7) {
            if isEstimated {
                Circle()
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, dash: [2.4, 2]))
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(Color(hex: "30D158"))
                    .frame(width: 8, height: 8)
            }
            Text(isEstimated ? estimatedText : "Posició en directe")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
