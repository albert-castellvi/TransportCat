import SwiftUI

/// The "Avisa'm de les incidències de les meves línies" switch (spec S14), in
/// one place because two screens show it: the Avisos tab and Configuració.
///
/// The switch owns its own `@AppStorage` binding on the key `IncidentWatcher`
/// read, so both copies stay in agreement without any wiring, and the side
/// effects — asking for the notification permission, scheduling or cancelling
/// the background refresh — run here instead of in each screen.
struct IncidentAlertsToggle: View {
    @AppStorage(IncidentWatcher.enabledKey) private var incidentAlertsEnabled = false

    var body: some View {
        Toggle(isOn: $incidentAlertsEnabled) {
            Text("Avisa'm de les incidències de les meves línies")
                .font(.footnote)
        }
        .onChange(of: incidentAlertsEnabled) { _, enabled in
            Task { @MainActor in
                if enabled {
                    // The switch asks for notification permission (S14);
                    // a denial flips it back off.
                    let granted = await ArrivalReminder.shared.ensurePermissionGranted()
                    if granted {
                        IncidentWatcher.scheduleNextRefresh()
                    } else {
                        incidentAlertsEnabled = false
                    }
                } else {
                    await ArrivalReminder.shared.cancelPendingNotifications(
                        withPrefix: IncidentWatcher.notificationIDPrefix
                    )
                }
            }
        }
    }
}
