import Foundation

extension Error {
    /// A dropped, slow or cancelled connection: expected on a phone, so it is
    /// logged but not reported to Sentry.
    var isTransientNetworkFailure: Bool {
        guard let urlError = self as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .notConnectedToInternet, .networkConnectionLost,
             .cannotConnectToHost, .dnsLookupFailed, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// Hides TMB credentials: they travel in the query string, so any error that
/// embeds the failing URL would otherwise carry them into Sentry.
enum SecretRedactor {
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(app_id|app_key)=[^&\\s\"',)]+",
            with: "$1=[redacted]",
            options: .regularExpression
        )
    }
}

/// Errors surfaced by the TMB API layer.
enum TMBError: LocalizedError, Equatable {
    case missingCredentials
    case invalidURL
    case httpStatus(Int)
    case unexpectedPayload(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Falten les credencials TMB (TMBAppId/TMBAppKey). Comprova la configuració de build."
        case .invalidURL:
            return "URL de l'API TMB no vàlida."
        case .httpStatus(let status):
            return "L'API TMB ha respost amb l'estat \(status)."
        case .unexpectedPayload(let detail):
            return "Resposta de l'API TMB inesperada: \(detail)"
        }
    }
}
