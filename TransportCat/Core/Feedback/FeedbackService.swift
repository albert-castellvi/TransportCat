import Foundation
@_spi(Private) import Sentry

/// One message a rider writes to the team (unit `support`).
///
/// Plain values on purpose: the submission seam carries no SDK type, so
/// `FeedbackServiceTests` drives the three outcomes without a Sentry hub and
/// the report body never leaks into a log line by accident.
struct FeedbackReport: Equatable {
    let message: String
    let name: String?
    let email: String?
}

/// What Sentry answered for one report.
///
/// Sentry 8.58.4's `SentrySDK.capture(feedback:)` returns `Void`
/// (`sentry-cocoa/Sources/Swift/Helper/SentrySDK.swift:261-267`), so the id the
/// feedback is shipped under is read from `SentryFeedback.eventId`
/// (`Sources/Swift/Integrations/UserFeedback/SentryFeedback.swift:33`) and
/// carried here as its string. The rule is MiJornada's: an empty id — or
/// Sentry's zero id — means the SDK accepted nothing, so the report never left
/// the device and the form must offer the retry instead of a false success.
struct FeedbackReceipt: Equatable {
    /// 32 zeroes, the string form of `SentryId.empty`.
    static let emptySentryId = String(repeating: "0", count: 32)

    /// Nothing was handed to Sentry: `SentrySDK` was not started (this build
    /// has no DSN) or the capture was refused.
    static let notDelivered = FeedbackReceipt(id: "")

    let id: String

    var isDelivered: Bool {
        !id.isEmpty && id != FeedbackReceipt.emptySentryId
    }
}

/// Seam over the report submission (unit `support`).
///
/// `SentrySDK` is a process-wide facade and cannot be replaced in a test, so the
/// form talks to this protocol instead: production resolves
/// `SentryFeedbackService`, tests inject a fake.
protocol FeedbackService {
    /// Sends one report.
    ///
    /// - Parameters:
    ///   - message: what the rider wrote.
    ///   - email: how to answer, when they want an answer. Blank means none.
    ///   - screen: identifier of the screen the form was opened from, so
    ///     triage can tell where the message started (today always
    ///     "settings"; the seam keeps the tag generic).
    ///
    /// Throws `FeedbackSubmissionException` when the report could not be handed
    /// to Sentry, so the caller shows its retry state. It never throws anything
    /// else and never crashes the process.
    func submit(message: String, email: String?, screen: String) async throws
}

/// Failure of a report submission, raised by `FeedbackService.submit`.
///
/// It carries only the cause: the report body and the reply address are user
/// data and must not end up in a crash log or a stack trace.
struct FeedbackSubmissionException: Error, CustomStringConvertible {
    /// The underlying error, kept for debugging. Never shown to the rider.
    let cause: Error

    var description: String {
        "FeedbackSubmissionException(\(String(describing: type(of: cause))))"
    }
}

/// Marker cause for the "Sentry accepted nothing" outcome: there is no
/// underlying error to carry and no traceback worth showing.
struct FeedbackNotDelivered: Error, CustomStringConvertible {
    var description: String { "FeedbackNotDelivered()" }
}

/// Signature of the SDK call the service makes, injectable so a test can drive
/// its outcome. It throws only for a substituted capture: the real one returns
/// a receipt and never throws.
typealias FeedbackCapture = (FeedbackReport, String) throws -> FeedbackReceipt

/// Sends the report as Sentry user feedback (sentry-cocoa 8.58.4).
struct SentryFeedbackService: FeedbackService {
    /// Scope tag holding the screen the report came from. The tag reaches the
    /// feedback envelope through the scope: `SentrySDK.capture(feedback:)`
    /// captures through the current hub (`SentrySDK.swift:261-267`), the hub
    /// hands its scope to the client (`SentryHub.m:589-600`) and the client
    /// prepares the feedback event with it (`SentryClient.m:624-662`).
    static let screenTagKey = "feedback_screen"

    /// The capture call, injectable so a test can drive its outcome.
    let capture: FeedbackCapture

    init(capture: @escaping FeedbackCapture = SentryFeedbackService.captureWithSentry) {
        self.capture = capture
    }

    func submit(message: String, email: String?, screen: String) async throws {
        let report = FeedbackReport(
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            name: nil,
            email: Self.replyAddress(email)
        )
        let receipt: FeedbackReceipt
        do {
            receipt = try capture(report, screen)
        } catch {
            throw FeedbackSubmissionException(cause: error)
        }
        guard receipt.isDelivered else {
            throw FeedbackSubmissionException(cause: FeedbackNotDelivered())
        }
    }

    /// The reply address, or `nil` when the rider left the field empty: the SDK
    /// must not receive a blank `contact_email`.
    static func replyAddress(_ email: String?) -> String? {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The real capture: tag the scope with the screen, hand the feedback to the
    /// SDK, and answer with the id it will ship under.
    ///
    /// A build with no `SENTRY_DSN` never starts the SDK, so `isEnabled` is the
    /// one check that separates "the report left the device" from "nothing
    /// happened"; that is what turns the local build's form into its
    /// not-delivered wording instead of a fake success.
    static func captureWithSentry(_ report: FeedbackReport, screen: String) -> FeedbackReceipt {
        guard SentrySDK.isEnabled else { return .notDelivered }
        SentrySDK.configureScope { scope in
            scope.setTag(value: screen, key: screenTagKey)
        }
        let feedback = SentryFeedback(
            message: report.message,
            name: report.name,
            email: report.email,
            source: .custom
        )
        SentrySDK.capture(feedback: feedback)
        return FeedbackReceipt(id: feedback.eventId.sentryIdString)
    }
}
