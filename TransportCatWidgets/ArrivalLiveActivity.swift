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
                        if context.state.isStale {
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
                    if context.state.isStale {
                        Text("· Actualitzant…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            ArrivalActivityCountdown(context: context)
                .font(.title2.bold().monospacedDigit())
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(context.attributes.lineName) cap a \(context.attributes.destination), "
                + "a \(context.attributes.placeName)"
        )
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

/// `Text(timerInterval:)` countdown to the arrival, replaced by "Ara" once it
/// has passed or the feed went stale (spec S20).
private struct ArrivalActivityCountdown: View {
    let context: ActivityViewContext<ArrivalActivityAttributes>

    var body: some View {
        if context.state.isStale || context.state.arrivalDate <= Date() {
            Text("Ara")
                .monospacedDigit()
        } else {
            Text(timerInterval: Date.now...context.state.arrivalDate, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}
