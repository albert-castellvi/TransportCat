import SwiftUI

// CONTRACT (T0) for the follow UI (S2–S7, mockups docs/design/follow-vehicle).
// The initializers below are fixed: the map screens (T4, T5) build these
// views in parallel with T3, which implements their bodies (and may move each
// type to its own file under Features/Follow/, keeping the same declaration).

/// Top HUD while following (S4): "Seguint · cap a <terminus>", the source,
/// the voice toggle, the stop button, the 2D/3D toggle and, while a pan paused
/// the camera, "Tornar al tren".
struct FollowHUD: View {
    let plan: FollowPlan
    let isVoiceEnabled: Bool
    let is3D: Bool
    let isCameraPaused: Bool
    let onToggleVoice: () -> Void
    let onToggle3D: () -> Void
    let onRecenter: () -> Void
    let onStop: () -> Void

    var body: some View {
        EmptyView()
    }
}

/// Bottom panel while following (S5): next stop and countdown, the stop
/// strip, and the "Baixo a <stop>" picker over `plan.upcoming`.
struct FollowPanel: View {
    let plan: FollowPlan
    /// The rider picked an alight stop code, or cleared it with nil.
    let onPickAlight: (String?) -> Void

    var body: some View {
        EmptyView()
    }
}

/// The announce card ("Pròxima parada · X") or the green alight card ("Baixa
/// a la pròxima: X") (S6, S7).
struct FollowEventCard: View {
    let event: FollowEvent
    /// The followed line's colour hex without "#".
    let lineColorHex: String
    let onDismiss: () -> Void

    var body: some View {
        EmptyView()
    }
}

/// The label a map draws above one of `plan.mapLabels` (S3): the stop name and
/// its countdown, the next stop emphasised, the alight stop green with a flag.
struct FollowStopLabel: View, Equatable {
    let name: String
    /// `FollowSession.etaText(for:)`; nil hides the countdown (FGC).
    let etaText: String?
    let isNext: Bool
    let isAlight: Bool
    /// The followed line's colour hex without "#".
    let lineColorHex: String

    var body: some View {
        Text(name)
    }
}
