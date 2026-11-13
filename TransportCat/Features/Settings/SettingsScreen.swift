import SwiftUI
import UIKit
import CoreLocation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Configuració (unit `settings`): the app's preferences in one place instead
/// of scattered across the tabs — the iPhone's per-app language, the favorites
/// with their order, the incident alert switch, the initial map mode, the two
/// permission states and the data notice.
///
/// It is pushed from Explora's gear button inside that screen's own
/// `NavigationStack`, so it takes no arguments and adds no new navigation. The
/// design is dark with the rest of the app: only system list styling is used,
/// no hard-coded fills.
@MainActor
struct SettingsScreen: View {
    /// Same key `RootView` and the bottom accessory's mode menu write, so
    /// picking a mode here and there are the same preference.
    @AppStorage("appMode") private var modeRaw = AppMode.metro.rawValue
    @Environment(\.openURL) private var openURL
    /// Notification authorization as the last `.task` read it. Location comes
    /// from the shared service, which already publishes it.
    @State private var notificationPermission: SettingsSupport.Permission = .notAsked

    private var favorites: FavoritesStore { FavoritesStore.shared }
    private var busStore: BusCatalogStore { BusCatalogStore.shared }
    private var locationService: LocationService { LocationService.shared }

    private var modes: [AppMode] { AppMode.allCases }

    var body: some View {
        List {
            languageSection
            favoritesSection
            alertsSection
            mapSection
            permissionSection
            dataSection
            introductionSection
        }
        .navigationTitle("Configuració")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadNotificationPermission() }
    }

    // MARK: - Idioma

    /// The per-app language iOS owns (Settings › TransportCat › Language). The
    /// app never switches language itself: the row names the current one and
    /// the button opens the page where it is chosen.
    private var languageSection: some View {
        Section {
            LabeledContent("Idioma actual", value: languageName)
            Button("Canvia l'idioma", action: openSettings)
        } header: {
            Text("Idioma")
        } footer: {
            Text("L'idioma es tria a la Configuració de l'iPhone. Disponible en català, castellà i anglès.")
        }
    }

    private var languageName: String {
        SettingsSupport.languageName(forPreferredLanguage: Bundle.main.preferredLocalizations.first)
            ?? String(localized: "Desconegut")
    }

    // MARK: - Preferits

    @ViewBuilder
    private var favoritesSection: some View {
        let lines = favoriteLineResults
        Section {
            if favorites.favoritePlaces.isEmpty && lines.isEmpty {
                Text("Encara no tens preferits. Toca l'estrella d'una estació o parada.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(favorites.favoritePlaces) { place in
                ExplorePlaceRow(place: place)
            }
            .onMove { source, destination in
                favorites.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                favorites.remove(atOffsets: offsets)
            }
        } header: {
            HStack {
                Text("Preferits")
                Spacer()
                if !favorites.favoritePlaces.isEmpty {
                    EditButton()
                }
            }
        }
        // Lines keep no editable order and are removed from their own screens,
        // so they read here read-only: the list must not offer a second,
        // half-working way to unstar them.
        if !lines.isEmpty {
            Section("Línies preferides") {
                ForEach(lines) { result in
                    ExploreLineRow(result: result)
                }
            }
        }
    }

    /// Metro, FGC and bus favourites, folded by the same helper Explora uses.
    private var favoriteLineResults: [ExploreLineResult] {
        FavoriteLineRows.results(
            favorites: favorites,
            fgcLines: FGCNetworkState.shared.lines,
            busStore: busStore
        )
    }

    // MARK: - Avisos

    /// The Avisos tab's own switch, shared so the two screens can never
    /// disagree about the preference or the permission behind it.
    private var alertsSection: some View {
        Section {
            IncidentAlertsToggle()
        } header: {
            Text("Avisos")
        }
    }

    // MARK: - Mapa

    private var mapSection: some View {
        Section {
            Picker("Mode inicial", selection: $modeRaw) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
        } header: {
            Text("Mapa")
        } footer: {
            Text("És el mode amb què s'obre el mapa. El pots canviar quan vulguis des del mapa.")
        }
    }

    // MARK: - Ubicació i notificacions

    private var permissionSection: some View {
        Section {
            LabeledContent("Ubicació") {
                Text(SettingsSupport.permissionWording(locationPermission))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Notificacions") {
                Text(SettingsSupport.permissionWording(notificationPermission))
                    .foregroundStyle(.secondary)
            }
            Button("Obre la Configuració de l'iPhone", action: openSettings)
        } header: {
            Text("Ubicació i notificacions")
        }
    }

    /// The when-in-use authorization, read from the shared service that already
    /// publishes it and worded by `SettingsSupport`, like the introduction's own
    /// permission page.
    private var locationPermission: SettingsSupport.Permission {
        SettingsSupport.permission(for: locationService.authorization)
    }

    /// Re-read on every visit: the rider may have changed it in the system
    /// Settings between two pushes of this screen.
    private func loadNotificationPermission() async {
        #if canImport(UserNotifications)
        notificationPermission = SettingsSupport.permission(
            for: await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        )
        #endif
    }

    // MARK: - Dades i privacitat

    private var dataSection: some View {
        Section {
            Text("Dades de TMB i FGC (CC BY 4.0)")
            Text("TransportCat no recull dades personals. La ubicació només es fa servir al dispositiu.")
            Text(versionString)
        } header: {
            Text("Dades i privacitat")
        }
    }

    /// "Versió 0.1.0 (101)" from the bundle, so the row follows the build.
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        return SettingsSupport.versionString(
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }

    // MARK: - Introducció

    /// Reopens the first-run tour (unit `onboarding`): the row writes the flag
    /// back to false, and `RootView` presents the cover again without a
    /// relaunch.
    private var introductionSection: some View {
        Section {
            Button("Torna a veure la introducció") {
                OnboardingFlow.reopen(in: .standard)
            }
        } header: {
            Text("Introducció")
        } footer: {
            Text("Torna a explicar què fa cada pantalla, pàgina a pàgina.")
        }
    }

    // MARK: - Actions

    /// Opens this app's page in the system Settings, the same call the maps
    /// use for a denied location permission. It is the only way to a per-app
    /// language or a permission the rider already refused.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
