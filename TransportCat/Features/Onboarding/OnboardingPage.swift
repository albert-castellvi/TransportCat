import Foundation

/// One page of the first-run introduction (unit `onboarding`).
///
/// Plain data on purpose: the pages are an array, so changing the copy or the
/// order is an edit here and nothing else, and `OnboardingTests` can check
/// every page — title, bullets, order — without building a screen.
struct OnboardingPage: Identifiable, Equatable {
    /// Which illustration the page draws. The art is composed from pieces the
    /// app already has — `NetworkArt`, the metro badge images, the line colours
    /// and SF Symbols — so no page ships an image of its own.
    enum Artwork: String, Equatable {
        case network
        case map
        case follow
        case timeline
        case station
        case alerts
        case explore
        case widget
        case permissions
        case improving
    }

    /// One explained feature: an icon and one sentence that says what it is,
    /// where to tap and what happens.
    struct Bullet: Identifiable, Equatable {
        let systemImage: String
        let text: String

        var id: String { "\(systemImage)|\(text)" }
    }

    let id: String
    let title: String
    let artwork: Artwork
    let bullets: [Bullet]
    /// The closing page also asks for the two optional permissions inline.
    var requestsPermissions: Bool = false
}

extension OnboardingPage {
    /// The tour, in the order the rider sees it: the app itself, the map, one
    /// vehicle, the line timeline, a station, the alerts, Explora, the widget
    /// and the watch, what keeps the app improving, and finally the two
    /// permissions it may ask for.
    ///
    /// Every page explains; none asks for anything. Writing to the team and
    /// supporting the work live in Configuració, and the tour only says where
    /// they are.
    ///
    /// Every sentence is written against the real screens; when one of them
    /// changes its wording, this list changes with it.
    static let all: [OnboardingPage] = [
        OnboardingPage(
            id: "welcome",
            title: String(localized: "Metro, bus i FGC en un sol mapa"),
            artwork: .network,
            bullets: [
                Bullet(
                    systemImage: "map.fill",
                    text: String(localized: "Barcelona sencera en un mapa: metro, bus i FGC, cadascun amb el seu mode.")
                ),
                Bullet(
                    systemImage: "dot.radiowaves.left.and.right",
                    text: String(localized: "Les posicions i les arribades arriben en directe, cada pocs segons.")
                ),
                Bullet(
                    systemImage: "hand.tap.fill",
                    text: String(localized: "Toca una línia, una parada o un vehicle i veuràs què hi passa.")
                ),
                Bullet(
                    systemImage: "star.fill",
                    text: String(localized: "Marca com a preferit el que fas servir cada dia i ho tindràs a mà.")
                ),
            ]
        ),
        OnboardingPage(
            id: "live-map",
            title: String(localized: "El mapa, en directe"),
            artwork: .map,
            bullets: [
                Bullet(
                    systemImage: "line.3.horizontal",
                    text: String(localized: "El menú de baix canvia de mode (Metro, Bus, FGC o Tot) i el xip del costat tria la línia.")
                ),
                Bullet(
                    systemImage: "tram.fill",
                    text: String(localized: "Trens i busos es mouen al mapa a mesura que avancen.")
                ),
                Bullet(
                    systemImage: "clock",
                    text: String(localized: "La càpsula de dalt diu si vas en directe i fa quants segons s'ha actualitzat.")
                ),
                Bullet(
                    systemImage: "map",
                    text: String(localized: "Si allunyes, les estacions queden en punts; si t'hi acostes, surten amb el nom.")
                ),
                Bullet(
                    systemImage: "location.fill",
                    text: String(localized: "El botó de la ubicació et centra i obre «A prop teu», les parades que tens a mà.")
                ),
            ]
        ),
        OnboardingPage(
            id: "follow",
            title: String(localized: "Segueix un vehicle"),
            artwork: .follow,
            bullets: [
                Bullet(
                    systemImage: "hand.tap.fill",
                    text: String(localized: "Toca un tren o un bus al mapa i s'obre la seva fitxa.")
                ),
                Bullet(
                    systemImage: "info.circle",
                    text: String(localized: "A «Més detalls» tens la línia, el destí i la propera parada.")
                ),
                Bullet(
                    systemImage: "location.fill",
                    text: String(localized: "Amb «Seguir», el mapa acompanya el vehicle sense que l'hagis de moure.")
                ),
                Bullet(
                    systemImage: "person.3.fill",
                    text: String(localized: "Els trens de FGC també diuen quanta gent hi ha a cada cotxe.")
                ),
            ]
        ),
        OnboardingPage(
            id: "line",
            title: String(localized: "La línia, parada a parada"),
            artwork: .timeline,
            bullets: [
                Bullet(
                    systemImage: "list.bullet",
                    text: String(localized: "La pestanya Parades llista les estacions de la línia que tinguis triada.")
                ),
                Bullet(
                    systemImage: "arrow.left.arrow.right",
                    text: String(localized: "Cada parada porta les properes arribades dels dos sentits.")
                ),
                Bullet(
                    systemImage: "tram.fill",
                    text: String(localized: "Els trens que hi ha ara mateix es dibuixen sobre la línia.")
                ),
                Bullet(
                    systemImage: "exclamationmark.triangle.fill",
                    text: String(localized: "Les incidències de la línia surten al capdamunt, amb l'hora.")
                ),
            ]
        ),
        OnboardingPage(
            id: "station",
            title: String(localized: "Què hi ha dins d'una estació"),
            artwork: .station,
            bullets: [
                Bullet(
                    systemImage: "clock",
                    text: String(localized: "Les properes arribades, amb els minuts que falten i el primer i l'últim tren del dia.")
                ),
                Bullet(
                    systemImage: "bell.fill",
                    text: String(localized: "«Avisa'm» t'avisa 1, 3 o 5 minuts abans que arribi el tren.")
                ),
                Bullet(
                    systemImage: "dot.radiowaves.left.and.right",
                    text: String(localized: "«Segueix en directe» posa la compte enrere a la pantalla bloquejada i a la Dynamic Island.")
                ),
                Bullet(
                    systemImage: "figure.roll",
                    text: String(localized: "Si l'estació és accessible i quins accessos té.")
                ),
                Bullet(
                    systemImage: "star.fill",
                    text: String(localized: "L'estrella de dalt la guarda a preferits.")
                ),
            ]
        ),
        OnboardingPage(
            id: "alerts",
            title: String(localized: "Quan alguna cosa no va"),
            artwork: .alerts,
            bullets: [
                Bullet(
                    systemImage: "exclamationmark.triangle.fill",
                    text: String(localized: "Els avisos de servei del metro i del bus, amb les línies afectades.")
                ),
                Bullet(
                    systemImage: "figure.roll",
                    text: String(localized: "Els ascensors i les escales mecàniques fora de servei, amb l'estació.")
                ),
                Bullet(
                    systemImage: "bell.badge.fill",
                    text: String(localized: "Activa «Avisa'm de les incidències de les meves línies» i et notifiquem cada avís nou.")
                ),
            ]
        ),
        OnboardingPage(
            id: "explore",
            title: String(localized: "Cerca, guarda i planifica"),
            artwork: .explore,
            bullets: [
                Bullet(
                    systemImage: "magnifyingglass",
                    text: String(localized: "Cerca estacions, parades i línies pel nom.")
                ),
                Bullet(
                    systemImage: "star.fill",
                    text: String(localized: "Els preferits surten amb les properes arribades; pots canviar-los l'ordre i treure'ls.")
                ),
                Bullet(
                    systemImage: "location.circle",
                    text: String(localized: "«A prop» llista les parades més properes amb el temps real.")
                ),
                Bullet(
                    systemImage: "arrow.left.arrow.right",
                    text: String(localized: "El planificador et diu com anar d'un lloc a l'altre: origen, destinació i hora de sortida o d'arribada.")
                ),
            ]
        ),
        OnboardingPage(
            id: "out-of-app",
            title: String(localized: "Fora de l'app"),
            artwork: .widget,
            bullets: [
                Bullet(
                    systemImage: "square.grid.2x2.fill",
                    text: String(localized: "El widget «Properes arribades» a la pantalla d'inici, en tres mides i a la pantalla bloquejada.")
                ),
                Bullet(
                    systemImage: "hand.tap.fill",
                    text: String(localized: "Toca el widget i s'obre la parada que mostra.")
                ),
                Bullet(
                    systemImage: "applewatch",
                    text: String(localized: "L'app de l'Apple Watch amb els teus preferits i les properes arribades.")
                ),
            ]
        ),
        OnboardingPage(
            id: "improving",
            title: String(localized: "Sempre millorant"),
            artwork: .improving,
            bullets: [
                Bullet(
                    systemImage: "arrow.triangle.2.circlepath",
                    text: String(localized: "L'app millora amb les dades de TMB, FGC i Renfe, i s'afina amb l'ús que en fem tots.")
                ),
                Bullet(
                    systemImage: "envelope.fill",
                    text: String(localized: "Si hi ha res que no va o que hi falta, escriu-nos des de Configuració › Suport i millores.")
                ),
                Bullet(
                    systemImage: "heart.fill",
                    text: String(localized: "Si l'app et serveix bé, pots donar-li suport des de Configuració › Dona suport al desenvolupament.")
                ),
                Bullet(
                    systemImage: "hand.raised.fill",
                    text: String(localized: "És gratis, sense anuncis i sense compte.")
                ),
            ]
        ),
        OnboardingPage(
            id: "permissions",
            title: String(localized: "Dues coses que et podem demanar"),
            artwork: .permissions,
            bullets: [
                Bullet(
                    systemImage: "location.fill",
                    text: String(localized: "La ubicació centra el mapa i et diu quines parades tens a prop.")
                ),
                Bullet(
                    systemImage: "bell.fill",
                    text: String(localized: "Les notificacions porten els avisos d'arribada i les incidències de les teves línies.")
                ),
                Bullet(
                    systemImage: "hand.raised.fill",
                    text: String(localized: "Totes dues són opcionals: l'app funciona igual sense.")
                ),
            ],
            requestsPermissions: true
        ),
    ]
}

/// Presentation rules of the introduction, kept out of the view so the flag and
/// the page arithmetic are testable without a screen.
enum OnboardingFlow {
    /// `@AppStorage` key of "the rider has already seen the introduction".
    static let hasSeenKey = "hasSeenOnboarding"

    /// The tour is a first-run thing: it shows while the flag is false.
    static func isPresented(hasSeen: Bool) -> Bool { !hasSeen }

    /// Index of the last page. An empty page list answers 0 instead of −1, so
    /// no caller has to guard against a negative index.
    static func lastIndex(count: Int) -> Int { max(count - 1, 0) }

    /// Whether `index` is the page whose button says "Comença".
    static func isLast(_ index: Int, count: Int) -> Bool { index >= lastIndex(count: count) }

    /// The next page, clamped to the last one, so a second tap on "Continua"
    /// never runs past it.
    static func next(after index: Int, count: Int) -> Int {
        min(max(index, 0) + 1, lastIndex(count: count))
    }

    static func hasSeen(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: hasSeenKey)
    }

    /// Skipping and finishing do the same thing: the tour never comes back on
    /// its own.
    static func markSeen(in defaults: UserDefaults) {
        defaults.set(true, forKey: hasSeenKey)
    }

    /// Configuració's "Torna a veure la introducció": the flag goes back to
    /// false and the cover appears again.
    static func reopen(in defaults: UserDefaults) {
        defaults.set(false, forKey: hasSeenKey)
    }
}
