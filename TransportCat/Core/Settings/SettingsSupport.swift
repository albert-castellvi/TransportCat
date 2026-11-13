import Foundation

/// The pure logic behind the Configuració screen: how a permission state is
/// worded, how the app's current language is named, and the version row.
///
/// Foundation-only on purpose, so `SettingsTests` covers it without a screen
/// and the wording cannot drift between the two rows that show a permission.
enum SettingsSupport {
    /// One permission as the screen reports it. The two system statuses the
    /// screen reads — location authorization and notification settings — both
    /// fold into these three: a rider only needs to know whether it is on,
    /// refused, or still to be asked.
    enum Permission: String, CaseIterable {
        case granted
        case denied
        case notAsked
    }

    /// Wording of a permission row: "Permesa", "Denegada" or "Sense demanar".
    static func permissionWording(_ permission: Permission) -> String {
        switch permission {
        case .granted: return String(localized: "Permesa")
        case .denied: return String(localized: "Denegada")
        case .notAsked: return String(localized: "Sense demanar")
        }
    }

    /// The language code of a localization identifier: "ca-ES" and "ca_ES"
    /// both read "ca". Nil when the identifier starts with a separator, so
    /// "-ES" is not mistaken for a language.
    static func languageCode(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first != "-", first != "_" else { return nil }
        let code = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return code.isEmpty ? nil : code
    }

    /// The app's current language as a capitalised name in the device's own
    /// language ("Català"), or nil when the bundle reports no localization.
    ///
    /// - Parameters:
    ///   - identifier: `Bundle.main.preferredLocalizations.first`.
    ///   - locale: injected so a test can pin the wording.
    static func languageName(forPreferredLanguage identifier: String?, locale: Locale = .current) -> String? {
        guard let identifier, let code = languageCode(from: identifier) else { return nil }
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else { return nil }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The version row: "Versió 0.1.0 (101)" from the bundle's short version
    /// and build number. A missing value is left out instead of printed as
    /// "nil"; with neither, the row says so rather than showing an empty gap.
    static func versionString(shortVersion: String?, build: String?) -> String {
        let short = nonEmpty(shortVersion)
        let buildNumber = nonEmpty(build)
        switch (short, buildNumber) {
        case let (short?, buildNumber?):
            return String(localized: "Versió \(short) (\(buildNumber))")
        case let (short?, nil):
            return String(localized: "Versió \(short)")
        case (nil, let buildNumber?):
            return String(localized: "Versió (\(buildNumber))")
        case (nil, nil):
            return String(localized: "Versió desconeguda")
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
