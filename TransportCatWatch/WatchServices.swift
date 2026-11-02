import Foundation

/// Services the watch app builds for itself (spec S22).
///
/// The watch fetches its own arrivals: it has no App Group and no access to
/// the phone's clients, so it reads the TMB credentials injected into its own
/// Info.plist, exactly like the app and the widget extension do.
enum WatchServices {
    /// TMB client, or nil when the build injected no credentials (arrivals
    /// then read as empty instead of failing the screen).
    static func tmbClient() -> TMBClient? {
        guard let credentials = try? TMBCredentials.fromBundle() else { return nil }
        return TMBClient(credentials: credentials)
    }
}
