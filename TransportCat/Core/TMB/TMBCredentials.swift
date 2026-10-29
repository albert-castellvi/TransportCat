import Foundation

/// TMB public API credentials, injected at build time via the `TMB_APP_ID` /
/// `TMB_APP_KEY` build settings mapped into Info.plist (`TMBAppId` /
/// `TMBAppKey`). Never committed with real values.
struct TMBCredentials: Equatable {
    let appId: String
    let appKey: String

    var isEmpty: Bool { appId.isEmpty || appKey.isEmpty }

    /// Reads the credentials from the given Info.plist dictionary.
    /// Passing `infoDictionary` explicitly keeps this testable.
    static func fromBundle(_ infoDictionary: [String: Any]? = Bundle.main.infoDictionary) throws -> TMBCredentials {
        let appId = (infoDictionary?["TMBAppId"] as? String) ?? ""
        let appKey = (infoDictionary?["TMBAppKey"] as? String) ?? ""
        let credentials = TMBCredentials(appId: appId, appKey: appKey)
        if credentials.isEmpty {
            throw TMBError.missingCredentials
        }
        return credentials
    }
}
