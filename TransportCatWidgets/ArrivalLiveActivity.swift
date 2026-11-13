import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen and Dynamic Island views of the "Segueix en directe" activity
/// (spec S20). It reads the shared `ArrivalActivityAttributes`; the app owns
/// starting and refreshing it.
struct ArrivalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ArrivalActivityAttributes.self) { context in
            ArrivalActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(hex: "0B1220"))
                .activitySystemActionForegroundColor(.white)
                // Tapping the card opens the place it is tracking, not
                // whichever screen the app was last left on (F4).
                .widgetURL(context.attributes.placeURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ArrivalActivityBadge(attributes: context.attributes, size: 26)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ArrivalActivityCountdown(context: context)
                        .font(.title3.bold().monospacedDigit())
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.destination)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse")
                        Text(context.attributes.placeName)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if context.isStale {
                            Text("Actualitzant…")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                }
            } compactLeading: {
                ArrivalActivityBadge(attributes: context.attributes, size: 20)
            } compactTrailing: {
                ArrivalActivityCountdown(context: context)
                    .font(.caption.bold().monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                ArrivalActivityBadge(attributes: context.attributes, size: 20)
            }
            .keylineTint(Color(hex: context.attributes.lineColorHex))
        }
    }
}

/// Lock-screen card: line badge, destination, place and the countdown.
private struct ArrivalActivityLockScreenView: View {
    let context: ActivityViewContext<ArrivalActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArrivalActivityBadge(attributes: context.attributes, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cap a \(context.attributes.destination)")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                    Text(context.attributes.placeName)
                        .lineLimit(1)
                    // `context.isStale` flips on its own when the activity's
                    // `staleDate` passes; a flag stored in the state could
                    // only change with a push we may never send (F6).
                    if context.isStale {
                        Text("· Actualitzant…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Where the rider is, on a locked phone.
                .privacySensitive()
            }
            Spacer(minLength: 6)
            ArrivalActivityCountdown(context: context)
                .font(.title2.bold().monospacedDigit())
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ArrivalActivityStyle.spokenCard(context))
    }
}

/// The line code on its own color, the same badge as the widget and the app.
private struct ArrivalActivityBadge: View {
    let attributes: ArrivalActivityAttributes
    let size: CGFloat

    var body: some View {
        Text(attributes.lineName)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(Color(hex: attributes.textColorHex))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(minWidth: size * 1.25, minHeight: size)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color(hex: attributes.lineColorHex))
            )
    }
}

/// The countdown: "ara" once the arrival is due, otherwise a timer the system
/// ticks on its own.
///
/// A Live Activity is only re-rendered when the app updates it, which does not
/// happen in the background, so a static "N min" string froze on the lock
/// screen. A system minute offset ticks too, but it is worded in the phone's
/// language and ends on "0 minutos"; the m:ss timer is exact and reads the
/// same everywhere.
private struct ArrivalActivityCountdown: View {
    let context: ActivityViewContext<ArrivalActivityAttributes>

    var body: some View {
        Group {
            if ArrivalBoard.isDue(context.state.arrivalDate, now: Date()) {
                Text("ara")
                    .monospacedDigit()
            } else {
                Text(
                    timerInterval: Date()...max(Date(), context.state.arrivalDate),
                    countsDown: true,
                    showsHours: false
                )
                .monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .multilineTextAlignment(.trailing)
    }
}

/// Wording of the Live Activity that is read once instead of drawn: the
/// VoiceOver sentence below. The pixels come from `ArrivalActivityCountdown`,
/// which the system keeps current.
enum ArrivalActivityStyle {
    /// "ara" once the arrival is due, "N min" before it.
    static func countdown(
        _ context: ActivityViewContext<ArrivalActivityAttributes>,
        now: Date = Date()
    ) -> String {
        ArrivalBoard.minutesText(until: context.state.arrivalDate, now: now)
    }

    /// One sentence, with the number: "L1 cap a Fondo, estació Catalunya, 3 min".
    static func spokenCard(_ context: ActivityViewContext<ArrivalActivityAttributes>) -> String {
        let attributes = context.attributes
        return String(localized: "\(attributes.lineName) cap a \(attributes.destination), ")
            + String(localized: "\(attributes.placeWord) \(attributes.placeName), ")
            + countdown(context)
    }
}
