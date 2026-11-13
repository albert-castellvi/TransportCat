import SwiftUI
import UIKit
import CoreLocation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// The closing page's two optional permissions (unit `onboarding`).
///
/// Each row says what the permission is for, offers the button that asks for it
/// — through the services the app already uses, `LocationService` and
/// `ArrivalReminder`, so the tour never asks anything twice in a second way —
/// and shows the state the system reports afterwards. A refused permission
/// cannot be asked again, so there the button leads to the system Settings,
/// the same route the maps and Configuració take.
@MainActor
struct OnboardingPermissionsView: View {
    @State private var notificationPermission: SettingsSupport.Permission = .notAsked
    @Environment(\.openURL) private var openURL

    private var locationService: LocationService { LocationService.shared }

    /// Read in `body`, so the row follows the answer the rider gives in the
    /// system sheet without any extra plumbing.
    private var locationPermission: SettingsSupport.Permission {
        SettingsSupport.permission(for: locationService.authorization)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PermissionRow(
                icon: "location.fill",
                title: String(localized: "Ubicació"),
                state: locationPermission,
                askLabel: String(localized: "Activa la ubicació"),
                ask: { locationService.requestWhenInUse() },
                openSettings: openSettings
            )
            PermissionRow(
                icon: "bell.fill",
                title: String(localized: "Notificacions"),
                state: notificationPermission,
                askLabel: String(localized: "Activa les notificacions"),
                ask: { Task { await askNotifications() } },
                openSettings: openSettings
            )
        }
        .task { await loadNotificationPermission() }
    }

    // MARK: - Notifications

    /// One ask through the shared reminder service (the same call the reminder
    /// menu and the incident switch make), then the state as the system
    /// reports it.
    private func askNotifications() async {
        await ArrivalReminder.shared.ensurePermissionGranted()
        await loadNotificationPermission()
    }

    private func loadNotificationPermission() async {
        #if canImport(UserNotifications)
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationPermission = SettingsSupport.permission(for: status)
        #endif
    }

    /// The only way to a permission the rider already refused.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

/// One permission on a single line: icon, name, the state in words, and — while
/// it is not granted — a compact button that acts. The button's spoken label
/// says what the short visible one means.
private struct PermissionRow: View {
    let icon: String
    let title: String
    let state: SettingsSupport.Permission
    let askLabel: String
    let ask: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(SettingsSupport.permissionWording(state))
                .font(.caption)
                .foregroundStyle(stateColor)
            // A granted permission has nothing left to ask, so the row drops
            // the button and just reports it.
            if state != .granted {
                Button {
                    if state == .denied {
                        openSettings()
                    } else {
                        ask()
                    }
                } label: {
                    // The bordered style adds its own padding; these six points
                    // bring the control to the 44 pt target without a fat pill.
                    Text(state == .denied ? "Ajustos" : "Activa")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 6)
                        .frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(state == .denied ? String(localized: "Obre la Configuració de l'iPhone") : askLabel)
            }
        }
        .frame(minHeight: 44)
    }

    private var stateColor: Color {
        switch state {
        case .granted: return Color(hex: "30D158")
        case .denied: return Color(hex: "FF453A")
        case .notAsked: return .secondary
        }
    }
}
