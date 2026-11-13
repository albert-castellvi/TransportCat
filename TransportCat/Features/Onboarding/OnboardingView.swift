import SwiftUI
import UIKit

/// The first-run introduction (unit `onboarding`): a full-screen, one-page-per
/// feature tour presented by `RootView` while `hasSeenOnboarding` is false, and
/// reopenable from Configuració.
///
/// Structure per page: the app's own art, the page title as a header, and three
/// to five bullet rows that say what each feature is and where to tap. The
/// pages scroll vertically, so nothing is cut at large Dynamic Type sizes, and
/// the copy lives in `OnboardingPage.all` — plain data, not view code.
@MainActor
struct OnboardingView: View {
    /// The same key `RootView` presents on and Configuració reopens.
    @AppStorage(OnboardingFlow.hasSeenKey) private var hasSeenOnboarding = false
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages = OnboardingPage.all

    private var isLast: Bool {
        OnboardingFlow.isLast(index, count: pages.count)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // First in source order so VoiceOver reads it before the page, and
            // lifted above the pages by `zIndex` so it also takes the tap and
            // is drawn over the art.
            skipButton
                .zIndex(1)
            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { offset, page in
                        OnboardingPageView(page: page)
                            .tag(offset)
                    }
                }
                // The system indicator is off: the dots below belong to the
                // bottom bar, so they stay right above the primary button.
                .tabViewStyle(.page(indexDisplayMode: .never))
                bottomBar
            }
        }
        .background(Color(uiColor: .systemBackground))
        // Skipping and finishing are the only ways out: the flag is what
        // decides, so a swipe must not leave the tour half seen.
        .interactiveDismissDisabled()
    }

    // MARK: - Chrome

    /// "Salta", top-trailing on every page: the whole tour is optional and one
    /// tap gets the rider to the map.
    private var skipButton: some View {
        Button {
            finish()
        } label: {
            Text("Salta")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 8)
        .padding(.trailing, 20)
    }

    /// Page indicator over the primary button, as the design calls for. It is
    /// decorative for VoiceOver-free dot reading but still announces the
    /// position, and it never animates under Reduce Motion.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: dot == index ? 18 : 6, height: 6)
            }
        }
        .animation(AppMotion.smooth(duration: 0.2, reduceMotion: reduceMotion), value: index)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Pàgina \(index + 1) de \(pages.count)"))
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            pageDots
            Button {
                advance()
            } label: {
                Text(isLast ? "Comença" : "Continua")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Actions

    private func advance() {
        guard !isLast else {
            finish()
            return
        }
        withAnimation(AppMotion.smooth(duration: 0.25, reduceMotion: reduceMotion)) {
            index = OnboardingFlow.next(after: index, count: pages.count)
        }
    }

    /// Skipping and finishing both set the flag, and the flag is what dismisses
    /// the cover `RootView` presents.
    private func finish() {
        hasSeenOnboarding = true
    }
}

// MARK: - One page

/// One page of the tour: art, title, and the bullets. Everything scrolls, so a
/// large Dynamic Type size pushes content down instead of clipping it.
@MainActor
struct OnboardingPageView: View {
    let page: OnboardingPage
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var artworkHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 110 : 160
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingIllustration(artwork: page.artwork)
                    .frame(height: artworkHeight)
                // The header trait is what makes VoiceOver announce the page
                // title as a heading while it reads the page top to bottom.
                Text(page.title)
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.bullets) { bullet in
                        OnboardingBulletRow(bullet: bullet)
                    }
                }
                if page.requestsPermissions {
                    OnboardingPermissionsView()
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            // Clears the floating "Salta" chip on the art's top-right corner.
            .padding(.top, 56)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One explained feature: the icon is decorative (its name would only repeat
/// the sentence in a language VoiceOver reads wrong), the sentence is the row.
struct OnboardingBulletRow: View {
    let bullet: OnboardingPage.Bullet

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: bullet.systemImage)
                .font(.title3)
                // The glyph keeps the row's gutter at every text size; the
                // sentence next to it is the part that grows.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(bullet.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Art

/// The page illustration, built only from what the app already ships: the
/// icon's `NetworkArt`, the metro badge images, the line colours of
/// `MetroLine.allLines` and SF Symbols. No image assets, and nothing animated,
/// so Reduce Motion needs no branch here.
///
/// Decorative: `accessibilityHidden`, because the bullets say the same thing in
/// words. Dynamic Type is capped inside the art so the symbols cannot overflow
/// the card the way they would at the accessibility sizes.
struct OnboardingIllustration: View {
    let artwork: OnboardingPage.Artwork

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
            motif
                .padding(18)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var motif: some View {
        switch artwork {
        case .network:
            NetworkArt(.illustration)
        case .map:
            ZStack(alignment: .bottom) {
                NetworkArt(.illustration)
                liveCapsule
            }
        case .follow:
            iconCluster(["tram.fill", "location.fill", "bus.fill"])
        case .timeline:
            timelineMotif
        case .station:
            iconCluster(["bell.fill", "dot.radiowaves.left.and.right", "figure.roll"])
        case .alerts:
            iconCluster(["exclamationmark.triangle.fill", "figure.roll", "bell.badge.fill"], tint: Color(hex: "FF9F0A"))
        case .explore:
            iconCluster(["magnifyingglass", "star.fill", "location.circle"])
        case .widget:
            widgetMotif
        case .permissions:
            iconCluster(["location.fill", "bell.fill", "hand.raised.fill"])
        }
    }

    /// A row of symbols in circles, the shape every non-map page reuses so the
    /// tour reads as one set instead of nine unrelated drawings.
    private func iconCluster(_ symbols: [String], tint: Color = .accentColor) -> some View {
        HStack(spacing: 14) {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.quaternary))
            }
        }
    }

    /// The map's status capsule (`FreshnessChip`) as the mock of a live feed.
    private var liveCapsule: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: "30D158"))
                .frame(width: 8, height: 8)
            Text("En directe")
                .font(.caption.weight(.semibold))
            Text("fa 3 s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.thinMaterial))
        .padding(.bottom, 6)
    }

    /// The Parades timeline in miniature: the L1 badge and three countdowns in
    /// the line's own colour.
    private var timelineMotif: some View {
        let lineColor = Color(hex: MetroLine.line(forCode: "1")?.colorHex ?? "CE1126")
        return HStack(spacing: 18) {
            Image("badge-l1")
                .resizable()
                .scaledToFit()
                .frame(height: 34)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["2 min", "4 min", "7 min"], id: \.self) { time in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(lineColor)
                            .frame(width: 10, height: 10)
                        Text(time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The widget as the rider sees it: a small card with two line badges and
    /// their countdowns, next to the watch.
    private var widgetMotif: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Properes arribades")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                widgetRow("badge-l3", time: "2 min")
                widgetRow("badge-l5", time: "6 min")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)
            )
            Image(systemName: "applewatch")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }

    private func widgetRow(_ badge: String, time: String) -> some View {
        HStack(spacing: 8) {
            Image(badge)
                .resizable()
                .scaledToFit()
                .frame(height: 18)
            Text(time)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }
}
