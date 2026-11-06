import SwiftUI

/// Sheet that picks a metro line (redesign spec S4, mockup `V2LineSheet`),
/// opened from the bottom accessory's metro line chip.
///
/// The shape follows the mockup: a search field, the favorited lines, and the
/// full list. Termini come from the topology cache when the line has loaded at
/// least once, next to the TMB badge; the preferred list is the shared
/// `FavoritesStore`, so a star toggled anywhere shows up here.
struct MetroLinePickerSheet: View {
    /// The code of the line currently selected, for the checkmark row.
    private let selectedLineCode: String
    /// Called with the row the rider tapped. The sheet dismisses itself after
    /// it, so a presenter only has to remember the selection.
    private let onSelect: (MetroLine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Termini of every line, read once per presentation from the topology
    /// cache (never a network poll, spec S4).
    @State private var terminiByCode: [String: String] = [:]

    private var favorites: FavoritesStore { FavoritesStore.shared }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool {
        !trimmedQuery.isEmpty
    }

    init(selectedLineCode: String, onSelect: @escaping (MetroLine) -> Void) {
        self.selectedLineCode = selectedLineCode
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                searchField
                if !isSearching, !favoriteLines.isEmpty {
                    Section("Preferides") {
                        ForEach(favoriteLines) { line in
                            lineRow(line)
                        }
                    }
                }
                Section(isSearching ? "Resultats" : "Totes les línies") {
                    ForEach(shownLines) { line in
                        lineRow(line)
                    }
                }
            }
            .navigationTitle("Línia de metro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tancar") { dismiss() }
                }
            }
            .onAppear {
                terminiByCode = MetroLineTermini.cachedTerminiMap(lineCodes: MetroLine.allLines.map(\.code))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("Línia o estació", text: $query)
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
    }

    /// Lines matching the free-text query on the display name, or the catalog
    /// order while the search box is empty.
    private var shownLines: [MetroLine] {
        guard isSearching else { return MetroLine.allLines }
        return MetroLine.allLines.filter {
            $0.displayName.caseInsensitiveCompare(trimmedQuery) == .orderedSame
                || $0.displayName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    /// The shared favorite lines of the metro operator (spec S4: the bus keeps
    /// its own favorites inside `BusCatalogStore`).
    private var favoriteLines: [MetroLine] {
        favorites.favoriteLines.compactMap { line in
            line.operator == FavoriteLine.metro ? MetroLine.line(forCode: line.code) : nil
        }
    }

    /// Badge, name and the checkmark of the line on screen.
    private func lineRow(_ line: MetroLine) -> some View {
        Button {
            onSelect(line)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image("badge-\(line.assetKey)")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.displayName)
                        .font(.subheadline.weight(.semibold))
                    if let termini = terminiByCode[line.code] {
                        Text(termini)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if line.code == selectedLineCode {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Línia \(line.displayName)")
        .accessibilityAddTraits(line.code == selectedLineCode ? .isSelected : [])
    }
}
