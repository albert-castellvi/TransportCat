import XCTest
@testable import TransportCat

/// The report submission seam (unit `support`): the three outcomes Sentry can
/// answer, the reply address rule, and the wording the form shows. No hub is
/// involved — the capture closure is injected.
final class FeedbackServiceTests: XCTestCase {
    private struct CaptureFailure: Error {}

    // MARK: - Outcomes

    func testAReceiptWithAnIdIsADeliveredReport() async throws {
        let recorder = CaptureRecorder(receipt: FeedbackReceipt(id: "0123456789abcdef0123456789abcdef"))
        let service = SentryFeedbackService { report, screen in
            recorder.record(report, screen)
            return recorder.receipt
        }

        try await service.submit(message: "El mapa no carrega", email: "a@b.cat", screen: "settings")

        XCTAssertEqual(recorder.reports.count, 1)
        XCTAssertEqual(recorder.reports.first?.message, "El mapa no carrega")
        XCTAssertEqual(recorder.reports.first?.email, "a@b.cat")
        XCTAssertEqual(recorder.screens, ["settings"])
    }

    /// Sentry's zero id is what an empty `SentryId` serialises to: the report
    /// never left the device, so the form must not claim success.
    func testTheEmptySentryIdIsNotDelivered() async {
        let service = SentryFeedbackService { _, _ in
            FeedbackReceipt(id: FeedbackReceipt.emptySentryId)
        }

        do {
            try await service.submit(message: "Hola", email: nil, screen: "settings")
            XCTFail("a zero id must not be reported as delivered")
        } catch let error as FeedbackSubmissionException {
            XCTAssertTrue(error.cause is FeedbackNotDelivered)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAnEmptyReceiptIsNotDelivered() async {
        let service = SentryFeedbackService { _, _ in .notDelivered }

        do {
            try await service.submit(message: "Hola", email: nil, screen: "settings")
            XCTFail("an empty receipt must not be reported as delivered")
        } catch let error as FeedbackSubmissionException {
            XCTAssertTrue(error.cause is FeedbackNotDelivered)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAFailingCaptureIsWrapped() async {
        let service = SentryFeedbackService { _, _ in throw CaptureFailure() }

        do {
            try await service.submit(message: "Hola", email: nil, screen: "settings")
            XCTFail("a throwing capture must be reported as a failure")
        } catch let error as FeedbackSubmissionException {
            XCTAssertTrue(error.cause is CaptureFailure)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - What is sent

    func testABlankEmailIsNoReplyAddress() async throws {
        for email in [nil, "", "   \n"] {
            let recorder = CaptureRecorder(receipt: FeedbackReceipt(id: "abc"))
            let service = SentryFeedbackService { report, screen in
                recorder.record(report, screen)
                return recorder.receipt
            }
            try await service.submit(message: "Hola", email: email, screen: "settings")
            XCTAssertNil(recorder.reports.first?.email, "\(String(describing: email)) must not become a reply address")
        }
    }

    func testTheReplyAddressIsTrimmed() async throws {
        let recorder = CaptureRecorder(receipt: FeedbackReceipt(id: "abc"))
        let service = SentryFeedbackService { report, screen in
            recorder.record(report, screen)
            return recorder.receipt
        }

        try await service.submit(message: "  Hola  ", email: "  a@b.cat ", screen: "settings")

        XCTAssertEqual(recorder.reports.first?.email, "a@b.cat")
        XCTAssertEqual(recorder.reports.first?.message, "Hola")
    }

    /// The report body and the reply address are user data: a failure must not
    /// turn them into an error message that could end up in a log.
    func testAFailureNeverCarriesTheReportBody() async {
        let body = "El meu correu és secret@example.com i la meva parada és Provença"
        let service = SentryFeedbackService { _, _ in throw CaptureFailure() }

        do {
            try await service.submit(message: body, email: "secret@example.com", screen: "settings")
            XCTFail("expected a failure")
        } catch {
            let described = String(describing: error)
            XCTAssertFalse(described.contains("secret@example.com"))
            XCTAssertFalse(described.contains("Provença"))
            XCTAssertTrue(described.contains("FeedbackSubmissionException"))
        }
    }

    // MARK: - Wording

    func testTheFormWordingIsPinned() {
        XCTAssertEqual(FeedbackCopy.sectionTitle, "Suport i millores")
        XCTAssertEqual(FeedbackCopy.rowTitle, "Escriu-nos")
        XCTAssertEqual(FeedbackCopy.messagePlaceholder, "Explica'ns què ha passat…")
        XCTAssertEqual(FeedbackCopy.emailPlaceholder, "El teu correu (opcional)")
        XCTAssertEqual(FeedbackCopy.send, "Envia")
        XCTAssertEqual(FeedbackCopy.retry, "Torna-ho a provar")
        XCTAssertEqual(FeedbackCopy.sent, "Gràcies! Ho hem rebut.")
        XCTAssertEqual(FeedbackCopy.failed, "No s'ha pogut enviar. Torna-ho a provar.")
    }
}

/// The form's four states, driven by a fake service: empty messages are not
/// reports, a success clears the way to the thank-you, and a failure keeps the
/// text so the retry sends the same thing.
@MainActor
final class FeedbackFormModelTests: XCTestCase {
    func testSendingAnEmptyMessageDoesNothing() async {
        let service = StubFeedbackService(result: .success(()))
        let model = FeedbackFormModel(service: service, screen: "settings")

        XCTAssertFalse(model.canSend)
        await model.send()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(service.submissions.count, 0)
        XCTAssertFalse(model.canSend)

        model.message = "   \n "
        XCTAssertFalse(model.canSend)
        await model.send()
        XCTAssertEqual(service.submissions.count, 0)
    }

    func testASentReportLandsOnTheThankYou() async {
        let service = StubFeedbackService(result: .success(()))
        let model = FeedbackFormModel(service: service, screen: "settings")
        model.message = "Falta la línia L9"
        model.email = "a@b.cat"

        await model.send()

        XCTAssertEqual(model.phase, .sent)
        XCTAssertTrue(model.isSent)
        XCTAssertEqual(service.submissions.first?.message, "Falta la línia L9")
        XCTAssertEqual(service.submissions.first?.email, "a@b.cat")
        XCTAssertEqual(service.submissions.first?.screen, "settings")
    }

    func testAFailedReportKeepsTheTextAndOffersTheRetry() async {
        let service = StubFeedbackService(result: .failure(StubError()))
        let model = FeedbackFormModel(service: service, screen: "settings")
        model.message = "No carrega"

        await model.send()

        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.isSent)
        XCTAssertEqual(model.message, "No carrega")
        XCTAssertTrue(model.canSend)

        // The retry sends the same report again.
        await model.send()
        XCTAssertEqual(service.submissions.count, 2)
    }

    func testTheScreenTagIsTheOneTheFormWasOpenedFrom() async {
        // Configuració is the only place that presents the form now: the tag
        // must be the one the settings screen passes, not the tour's.
        let service = StubFeedbackService(result: .success(()))
        let model = FeedbackFormModel(service: service, screen: "settings")
        model.message = "Hola"
        await model.send()
        XCTAssertEqual(service.submissions.first?.screen, "settings")
    }
}

// MARK: - Fakes

private struct StubError: Error {}

private final class CaptureRecorder {
    let receipt: FeedbackReceipt
    private(set) var reports: [FeedbackReport] = []
    private(set) var screens: [String] = []

    init(receipt: FeedbackReceipt) {
        self.receipt = receipt
    }

    func record(_ report: FeedbackReport, _ screen: String) {
        reports.append(report)
        screens.append(screen)
    }
}

private final class StubFeedbackService: FeedbackService {
    struct Submission {
        let message: String
        let email: String?
        let screen: String
    }

    private(set) var submissions: [Submission] = []
    private let result: Result<Void, Error>

    init(result: Result<Void, Error>) {
        self.result = result
    }

    func submit(message: String, email: String?, screen: String) async throws {
        submissions.append(Submission(message: message, email: email, screen: screen))
        try result.get()
    }
}
