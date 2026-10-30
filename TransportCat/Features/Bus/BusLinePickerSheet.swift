import SwiftUI

/// Catalog sheet of bus lines (spec S2), opened from the line selector of the
/// bus map and of the bus Línies screen.
///
/// Three shapes, in this order: a search field, the family chips that filter
/// the list, and the rows. While the search box holds text the family filter
/// disappears and the flat results across all families are shown instead,
/// because a rider looking for a destination does not know its family.
struct BusLinePickerSheet: View {
    /// The shared catalog: lines, favorites and current selection.
    private let store: BusCatalogStore
    /// Called with the row the rider tapped. The sheet dismisses itself after
    /// it, so a presenter only has to remember the selection.
    private let onSelect: (BusLine) -> Void

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Family the rider tapped in the chip row. Nil means "the family of the
    /// line on screen", resolved from the store on every render so a selection
    /// made elsewhere is reflected here.
    @State private var pickedFamilyCode: Int?

    init(store: BusCatalogStore, onSelect: @escaping (BusLine) -> Void) {
        self.store = store
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if !isSearching && !families.isEmpty {
                    familyChips
                }
                content
            }
            .navigationTitle("Línies de bus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // The screens hosting the sheet load the catalog themselves; this only
        // covers a sheet opened before that task got a chance to run.
        .task {
            guard let client = app.client else { return }
            await store.load(client: client)
        }
    }

    // MARK: - Search

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("Cerca línia o destí", text: $query)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Esborra la cerca")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.11))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Families

    /// Families in `ORDRE_FAMILIA` order with their lines sorted by
    /// `ORDRE_LINIA` (spec S2).
    private var families: [BusFamily] {
        BusCatalog.families(of: store.lines)
    }

    /// Family the list shows: the tapped chip, else the one the current line
    /// belongs to, else the first family of the catalog.
    private var activeFamilyCode: Int? {
        if let pickedFamilyCode { return pickedFamilyCode }
        if let selected = store.selectedLine { return selected.familyCode }
        return families.first?.code
    }

    private var activeFamily: BusFamily? {
        families.first { $0.code == activeFamilyCode }
    }

    /// One capsule per family, labelled "Verticals 17" (name and line count).
    private var familyChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(families) { family in
                    let isSelected = family.code == activeFamilyCode
                    Button {
                        pickedFamilyCode = family.code
                    } label: {
                        Text("\(family.name) \(family.lines.count)")
                            .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(isSelected ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(isSelected ? Color.white : Color(white: 0.17)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - List

    /// Lines shown by the list: the results across every family while
    /// searching, the lines of the active family otherwise.
    private var shownLines: [BusLine] {
        if isSearching {
            return BusCatalog.search(store.lines, query: query)
        }
        return activeFamily?.lines ?? []
    }

    private var favoriteLines: [BusLine] {
        store.favorites.compactMap { code in
            store.lines.first { $0.code == code }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.lines.isEmpty {
            // Nothing to list yet: either the request is on its way or it
            // failed and the rider can try again from here.
            VStack(spacing: 12) {
                if store.isLoading || store.errorMessage == nil {
                    ProgressView("Carregant línies…")
                } else if let message = store.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Reintenta", action: retry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !isSearching && !favoriteLines.isEmpty {
                    Section("Preferides") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(favoriteLines) { line in
                                    Button {
                                        select(line)
                                    } label: {
                                        BusBadge(line: line, width: 46)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section {
                    ForEach(shownLines) { line in
                        lineRow(line)
                    }
                } header: {
                    if isSearching {
                        Text(shownLines.count == 1 ? "1 resultat" : "\(shownLines.count) resultats")
                    } else if let name = activeFamily?.name {
                        Text(name)
                    }
                }
            }
        }
    }

    /// Badge, headline, family and the star. Tapping anywhere but the star
    /// picks the line.
    private func lineRow(_ line: BusLine) -> some View {
        let starred = store.isFavorite(line)
        return HStack(spacing: 12) {
            Button {
                select(line)
            } label: {
                HStack(spacing: 12) {
                    BusBadge(line: line, width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.description)
                            .font(.subheadline.weight(.medium))
                            // Full headline, never clipped by the row height.
                            .fixedSize(horizontal: false, vertical: true)
                        Text(line.familyName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Línia \(line.name)")

            Button {
                store.toggleFavorite(line)
            } label: {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(starred ? Color(hex: "F59E0B") : Color(white: 0.55))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(starred ? "Treu de preferides" : "Afegeix a preferides")
        }
    }

    private func select(_ line: BusLine) {
        onSelect(line)
        dismiss()
    }

    private func retry() {
        guard let client = app.client else { return }
        Task {
            await store.load(client: client)
        }
    }
}
