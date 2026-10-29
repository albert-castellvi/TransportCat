import Foundation

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
