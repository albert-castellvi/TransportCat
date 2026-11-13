import SwiftUI

/// The tip jar (unit `support`): three voluntary consumables, their prices and
/// the thank-you state. It lives in Configuració's section and nowhere else
/// except Explora's occasional heart, which opens this same view in a sheet.
///
/// Nothing here is a feature: no purchase unlocks anything, and cancelling is
/// not an error — it just returns the jar to rest.
@MainActor
struct TipJarView: View {
    @State private var store: TipStore

    init(
        purchasing: TipPurchasing = StoreKitTipPurchasing(),
        onPurchased: @escaping () -> Void = { TipBadgeStore.shared.recordTip() }
    ) {
        _store = State(initialValue: TipStore(purchasing: purchasing, onPurchased: onPurchased))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            Text(TipCopy.caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The store answers from disk and, in a real device, from the network:
        // one load per visit is enough.
        .task { await store.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(TipCopy.loading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text(TipCopy.loadFailed)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(TipCopy.retry) {
                    Task { await store.load() }
                }
                .frame(minHeight: 44)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(TipTier.allCases) { tier in
                    TipRow(
                        tier: tier,
                        price: store.displayPrice(for: tier),
                        state: rowState(for: tier)
                    ) {
                        Task { await store.buy(tier) }
                    }
                }
                footer
            }
        }
    }

    private func rowState(for tier: TipTier) -> TipRow.RowState {
        switch store.purchase {
        case .purchasing(let buying) where buying == tier: return .purchasing
        case .idle, .purchased, .pending, .failed, .purchasing: return .idle
        }
    }

    /// What the last tap left behind: the thank-you line, the pending note, or
    /// the failure with its retry. A cancellation shows nothing at all.
    @ViewBuilder
    private var footer: some View {
        switch store.purchase {
        case .purchased(let tier):
            TipStatusLine(
                text: tier.thanks,
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tier.thanks)
            .onAppear {
                AccessibilityNotification.Announcement(tier.thanks).post()
            }
        case .pending:
            TipStatusLine(
                text: TipCopy.pending,
                systemImage: "clock",
                tint: .secondary
            )
        case .failed(let tier):
            VStack(alignment: .leading, spacing: 6) {
                TipStatusLine(
                    text: TipCopy.purchaseFailed,
                    systemImage: "exclamationmark.circle.fill",
                    tint: .red
                )
                Button(TipCopy.retry) {
                    Task { await store.buy(tier) }
                }
                .frame(minHeight: 44)
            }
        case .idle, .purchasing:
            EmptyView()
        }
    }
}

/// One tier: what it is, what it costs, and one line of why. The whole row is
/// the button, and it is at least 44 pt tall.
private struct TipRow: View {
    enum RowState {
        case idle
        case purchasing
    }

    let tier: TipTier
    let price: String?
    let state: RowState
    let action: () -> Void

    private var isPurchasing: Bool { state == .purchasing }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: tier.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tier.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        if isPurchasing {
                            ProgressView()
                                .controlSize(.small)
                        } else if let price {
                            Text(price)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(tier.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(price == nil || isPurchasing)
        // Read once: the tier, its price and its line, in that order.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        [tier.title, price, tier.note].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One status line under the jar. The icon is decorative; the sentence is read.
private struct TipStatusLine: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The jar as its own screen for Explora's sheet. Configuració embeds the
/// view directly in its section, so both read the same three rows.
struct TipJarScreen: View {
    var body: some View {
        ScrollView {
            TipJarView()
                .padding(20)
        }
        .navigationTitle(TipCopy.sectionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.basedOnSize)
    }
}
