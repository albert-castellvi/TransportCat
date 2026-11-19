import SwiftUI

/// The glass card of the trip being followed (spec S4): per leg, the line
/// badge, the ride ("Rocafort → Catalunya · direcció Fondo") and the honest
/// live wording, the walk between legs, a phase strip, the estimated arrival,
/// the line alerts with a re-plan jump, and "Finalitza". It collapses to a
/// one-line capsule by tapping the grabber.
struct ActiveTripCard: View {
    let trip: SavedTrip
    let startedAt: Date
    /// Whether a vehicle or incident card is open on the map: then the trip
    /// card shows only its capsule, never the full body.
    var isDimmedBySelection = false

    @State private var isExpanded = true
    @State private var isReplanningPresented = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: TripLiveState { TripLiveState.shared }
    private var trips: TripsStore { TripsStore.shared }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded && !isDimmedBySelection {
                fullCard
            } else {
                capsule
            }
        }
        .sheet(isPresented: $isReplanningPresented) {
            NavigationStack {
                PlannerScreen(
                    initialOrigin: PlannerEndpoint(label: trip.originName, position: trip.origin),
                    initialDestination: PlannerEndpoint(label: trip.destinationName, position: trip.destination)
                )
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Full card

    private var fullCard: some View {
        MapGlassCard(
            badgeText: firstBadgeText,
            badgeColorHex: trip.legs.first?.colorHex ?? "8E8E93",
            title: trip.name,
            onClose: { withAnimation(AppMotion.smooth(reduceMotion: reduceMotion)) { isExpanded = false } }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                legRows
                TripPhaseStrip(phase: live.phase)
                arrivalRow
                if let alert = firstAlertTitle {
                    alertBanner(title: alert)
                }
                actionRow
            }
        }
    }

    /// One row per ride, and the walk between rides ("Transbord a X · N min a
    /// peu"). The wording comes from `TripLegWording`, so the honesty rules
    /// ("segons horari", FGC positions) are the tested ones.
    private var legRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let timeline = TripTiming.plannedTimeline(trip: trip, startedAt: startedAt)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(trip.legs.enumerated()), id: \.offset) { index, leg in
                        if index > 0 {
                            walkRow(before: trip.legs[index])
                        }
                        legRow(leg, status: live.statuses.indices.contains(index) ? live.statuses[index] : nil,
                               plannedDeparture: timeline.departures.indices.contains(index) ? timeline.departures[index] : nil,
                               now: context.date)
                    }
                }
            }
        }
    }

    private func legRow(_ leg: SavedTripLeg, status: TripLegStatus?, plannedDeparture: Date?, now: Date) -> some View {
        let wording = TripLegWording.wording(
            for: status?.live ?? .planned,
            now: now,
            plannedDeparture: plannedDeparture
        )
        return HStack(spacing: 10) {
            ExploreLineBadge(
                label: leg.lineName,
                colorHex: leg.colorHex ?? "8E8E93",
                textColorHex: leg.textColorHex
            )
            VStack(alignment: .leading, spacing: 1) {
                Text("\(leg.fromName) → \(leg.toName) · direcció \(leg.headsign ?? leg.toName)")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(wording.small)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(wording.big)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(leg.lineName), de \(leg.fromName) a \(leg.toName), \(wording.big)")
    }

    /// The walk before a ride, as the mockup reads it.
    private func walkRow(before leg: SavedTripLeg) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Transbord a \(leg.fromName) · \(Self.walkMinutes(leg.walkSecondsBefore)) a peu")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var arrivalRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(arrivalText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var arrivalText: String {
        if let arrival = live.estimatedArrival {
            return String(localized: "Arribada aprox. \(TripLegWording.clock(arrival, timeZone: .current))")
        }
        return String(localized: "Arribada per calcular")
    }

    /// Orange banner with the first alert title of any leg of the trip, and
    /// the jump to the planner with the trip's own endpoints.
    private var firstAlertTitle: String? {
        live.statuses.flatMap(\.alertTitles).first
    }

    private func alertBanner(title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.bold))
            Text(title)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Torna a planificar") {
                isReplanningPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .foregroundStyle(Color(hex: "1C1C1E"))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "FF9F0A").opacity(0.9)))
    }

    /// Arrived: "Has arribat", the retag when the trip is not habitual yet,
    /// and the close that ends the follow. Otherwise the single "Finalitza".
    private var actionRow: some View {
        Group {
            if live.phase == .arrived {
                HStack(spacing: 10) {
                    Text("Has arribat")
                        .font(.headline)
                    Spacer(minLength: 8)
                    if !isHabitual {
                        Button("Fes-lo habitual") {
                            trips.setKind(id: trip.id, .habitual)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("Tanca", role: .destructive) {
                        trips.endActive()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button(role: .destructive) {
                    trips.endActive()
                } label: {
                    Label("Finalitza", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var isHabitual: Bool {
        trips.ordered.contains { $0.signature == trip.signature && $0.kind == .habitual }
    }

    // MARK: - Capsule

    /// The collapsed one-liner: the lines' badges, the phase and the arrival.
    /// Tapping it re-expands the card.
    private var capsule: some View {
        Button {
            guard !isDimmedBySelection else { return }
            withAnimation(AppMotion.smooth(reduceMotion: reduceMotion)) { isExpanded = true }
        } label: {
            HStack(spacing: 10) {
                TripLineBadges(legs: trip.legs)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(phaseCaption)
                    .font(.footnote.weight(.semibold))
                if let arrival = live.estimatedArrival {
                    Text(TripLegWording.clock(arrival, timeZone: .current))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .glassEffect(in: Capsule())
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trip.name). \(phaseCaption), \(arrivalText)")
    }

    // MARK: - Helpers

    private var firstBadgeText: String {
        trip.legs.first?.lineName ?? "·"
    }

    private var phaseCaption: String {
        TripPhaseStrip.caption(for: live.phase)
    }

    /// Walk seconds as "4 min" (a single minute keeps "1 min").
    private static func walkMinutes(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return String(localized: "\(minutes) min")
    }
}

/// The phase strip of the trip card (spec S4): Esperant · A bord · Transbord
/// · Arribat, the rider's current phase in the accent color, the rest dim.
struct TripPhaseStrip: View {
    let phase: TripPhase

    var body: some View {
        HStack(spacing: 12) {
            ForEach(TripPhaseStrip.stageCaptions, id: \.self) { caption in
                Text(caption)
                    .font(.caption.weight(caption == TripPhaseStrip.caption(for: phase) ? .bold : .medium))
                    .foregroundStyle(caption == TripPhaseStrip.caption(for: phase) ? Color.accentColor : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Fase del trajecte: \(TripPhaseStrip.caption(for: phase))"))
    }

    /// The four stages in travel order, as captions: Esperant · A bord ·
    /// Transbord · Arribat.
    static let stageCaptions: [String] = [
        String(localized: "Esperant"),
        String(localized: "A bord"),
        String(localized: "Transbord"),
        String(localized: "Arribat")
    ]

    static func caption(for phase: TripPhase) -> String {
        switch phase {
        case .waiting: return String(localized: "Esperant")
        case .riding: return String(localized: "A bord")
        case .transfer: return String(localized: "Transbord")
        case .arrived: return String(localized: "Arribat")
        }
    }
}
