import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen and Dynamic Island views of the follow activity (S8, mockup
/// V7Lock). It reads the shared `FollowActivityAttributes`; the app owns
/// starting and refreshing it.
struct FollowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FollowActivityAttributes.self) { context in
            FollowActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(hex: "0B1220"))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FollowActivityBadge(attributes: context.attributes, size: 26)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FollowActivityCountdown(state: context.state)
                        .font(.title3.bold().monospacedDigit())
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Cap a \(context.attributes.terminus)")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        FollowActivityProgressBar(state: context.state, attributes: context.attributes)
                        HStack(spacing: 5) {
                            FollowActivityAlightLabel(state: context.state)
                            Spacer(minLength: 0)
                            if context.state.isStale {
                                Text("Actualitzant…")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    FollowActivityBadge(attributes: context.attributes, size: 20)
                    Text(context.state.nextStopName ?? context.attributes.terminus)
                        .font(.caption)
                        .lineLimit(1)
                }
            } compactTrailing: {
                FollowActivityMinutesLeft(state: context.state)
                    .font(.caption.bold().monospacedDigit())
            } minimal: {
                FollowActivityBadge(attributes: context.attributes, size: 20)
            }
            .keylineTint(Color(hex: context.attributes.lineColorHex))
        }
    }
}

/// Lock-screen card: line badge, next stop with its countdown, the progress
/// towards the alight stop and the "Baixes a" line (mockup V7Lock).
private struct FollowActivityLockScreenView: View {
    let context: ActivityViewContext<FollowActivityAttributes>

    private var nextStopName: String {
        context.state.nextStopName ?? context.attributes.terminus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                FollowActivityBadge(attributes: context.attributes, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pròxima parada")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(nextStopName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                FollowActivityCountdown(state: context.state)
                    .font(.title3.bold().monospacedDigit())
            }
            VStack(alignment: .leading, spacing: 6) {
                FollowActivityProgressBar(state: context.state, attributes: context.attributes)
                HStack(spacing: 5) {
                    FollowActivityAlightLabel(state: context.state)
                    Spacer(minLength: 0)
                    if context.state.isStale {
                        Text("Actualitzant…")
                    }
                }
                .font(.caption)
            }
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Seguint \(context.attributes.lineDisplayName) cap a \(context.attributes.terminus), "
                + "pròxima parada \(nextStopName)"
        )
    }
}

/// The line code on its own color, the same badge as the arrival activity.
private struct FollowActivityBadge: View {
    let attributes: FollowActivityAttributes
    let size: CGFloat

    var body: some View {
        Text(attributes.lineDisplayName)
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

/// `Text(timerInterval:)` countdown to the next stop, "Ara" once it has
/// passed or the feed went stale, and nothing when the feed has no ETA
/// (FGC, D1).
private struct FollowActivityCountdown: View {
    let state: FollowActivityAttributes.ContentState

    var body: some View {
        if let arrivalDate = state.nextArrival {
            if state.isStale || arrivalDate <= Date() {
                Text("Ara")
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            } else {
                Text(timerInterval: Date.now...arrivalDate, countsDown: true)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// The compact-trailing minutes: "<n>′" while an ETA exists, nothing otherwise.
private struct FollowActivityMinutesLeft: View {
    let state: FollowActivityAttributes.ContentState

    var body: some View {
        if let arrivalDate = state.nextArrival {
            if state.isStale || arrivalDate <= Date() {
                Text("Ara")
            } else {
                Text("\(max(0, Int(arrivalDate.timeIntervalSinceNow / 60)))′")
            }
        }
    }
}

/// 0...1 progress towards the alight stop, hidden without a choice, in the
/// line color.
private struct FollowActivityProgressBar: View {
    let state: FollowActivityAttributes.ContentState
    let attributes: FollowActivityAttributes

    var body: some View {
        if let progress = state.progress {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color(hex: attributes.lineColorHex))
        }
    }
}

/// The green "Baixes a <stop> · <countdown>" line, omitted without a choice.
private struct FollowActivityAlightLabel: View {
    let state: FollowActivityAttributes.ContentState

    var body: some View {
        if let alightStopName = state.alightStopName {
            HStack(spacing: 4) {
                Image(systemName: "figure.walk.departure")
                Text("Baixes a \(alightStopName)")
                    .lineLimit(1)
                if let alightArrival = state.alightArrival, !state.isStale,
                   alightArrival > Date() {
                    Text("·")
                    Text(timerInterval: Date.now...alightArrival, countsDown: true)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.green)
        }
    }
}
