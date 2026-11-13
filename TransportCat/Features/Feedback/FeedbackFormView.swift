import SwiftUI

/// The words of the feedback form, kept in one place so the screen and its
/// tests read the same strings. `FeedbackServiceTests` pins them.
enum FeedbackCopy {
    /// The section and the pushed screen share one title.
    static let sectionTitle = String(localized: "Suport i millores")
    /// The row that opens the form from Configuració.
    static let rowTitle = String(localized: "Escriu-nos")
    static let messageLabel = String(localized: "El teu missatge")
    static let messagePlaceholder = String(localized: "Explica'ns què ha passat…")
    static let emailPlaceholder = String(localized: "El teu correu (opcional)")
    static let send = String(localized: "Envia")
    static let retry = String(localized: "Torna-ho a provar")
    static let sending = String(localized: "S'enviant…")
    static let sent = String(localized: "Gràcies! Ho hem rebut.")
    static let failed = String(localized: "No s'ha pogut enviar. Torna-ho a provar.")
}

/// State of one report, out of the view so `FeedbackFormTests` drives it with a
/// fake service: idle, sending, sent, or failed with the text still in the form.
@MainActor
@Observable
final class FeedbackFormModel {
    enum Phase: Equatable {
        case idle
        case sending
        case sent
        case failed
    }

    var message = ""
    var email = ""
    private(set) var phase: Phase = .idle

    private let service: FeedbackService
    private let screen: String

    init(service: FeedbackService = SentryFeedbackService(), screen: String) {
        self.service = service
        self.screen = screen
    }

    /// An empty message is not a report, and a second tap while one is on its
    /// way would send it twice.
    var canSend: Bool {
        phase != .sending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isSent: Bool { phase == .sent }

    /// Sends what the rider wrote. A failure leaves the text in the form and
    /// the phase at `.failed`, so the button retries the same report.
    func send() async {
        guard canSend else { return }
        phase = .sending
        do {
            try await service.submit(message: message, email: email, screen: screen)
            phase = .sent
        } catch {
            phase = .failed
        }
    }
}

/// The report form itself (unit `support`): one message, an optional reply
/// address, and the four states. Configuració is the only place that presents
/// it, pushed from "Escriu-nos"; the tour never embeds it.
///
/// It is a plain vertical stack, not a `Form`, so it can sit inside any scroll
/// view; the settings route wraps it in a `ScrollView` of its own.
@MainActor
struct FeedbackFormView: View {
    @State private var model: FeedbackFormModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(screen: String, service: FeedbackService = SentryFeedbackService()) {
        _model = State(initialValue: FeedbackFormModel(service: service, screen: screen))
    }

    /// The editor grows with the text size: four lines at the default size,
    /// more when the rider reads at the accessibility sizes.
    private var editorHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 220 : 140
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isSent {
                sentState
            } else {
                messageEditor
                emailField
                if model.phase == .failed {
                    statusText(FeedbackCopy.failed, systemImage: "exclamationmark.circle.fill", tint: .red)
                }
                sendButton
            }
        }
    }

    // MARK: - Fields

    /// A `TextEditor` has no prompt of its own, so the placeholder sits behind
    /// it and disappears as soon as there is a first character.
    private var messageEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.message)
                .frame(height: editorHeight)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .accessibilityLabel(FeedbackCopy.messageLabel)
                .disabled(model.phase == .sending)
            if model.message.isEmpty {
                Text(FeedbackCopy.messagePlaceholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    // The placeholder is the editor's own prompt: VoiceOver
                    // reads the field's label, never this twice.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var emailField: some View {
        TextField(FeedbackCopy.emailPlaceholder, text: $model.email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .frame(minHeight: 44)
            .disabled(model.phase == .sending)
    }

    // MARK: - States

    private var sendButton: some View {
        Button {
            Task { await model.send() }
        } label: {
            HStack(spacing: 8) {
                if model.phase == .sending {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(buttonTitle)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canSend)
        .accessibilityLabel(buttonTitle)
    }

    /// "Envia" the first time, "Torna-ho a provar" after a failure, and the
    /// in-flight wording while the report is on its way.
    private var buttonTitle: String {
        switch model.phase {
        case .failed: return FeedbackCopy.retry
        case .sending: return FeedbackCopy.sending
        case .idle, .sent: return FeedbackCopy.send
        }
    }

    /// The one success state: no confetti, no new dialog, just the sentence.
    private var sentState: some View {
        statusText(FeedbackCopy.sent, systemImage: "checkmark.circle.fill", tint: .green)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FeedbackCopy.sent)
            // Read once, when the state appears, instead of only when the
            // rider lands on it with the rotor.
            .onAppear {
                AccessibilityNotification.Announcement(FeedbackCopy.sent).post()
            }
    }

    private func statusText(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The form as its own screen: what Configuració pushes.
struct FeedbackScreen: View {
    let screen: String

    var body: some View {
        ScrollView {
            FeedbackFormView(screen: screen)
                .padding(20)
        }
        .navigationTitle(FeedbackCopy.sectionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.basedOnSize)
    }
}
