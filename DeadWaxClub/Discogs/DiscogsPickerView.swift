import SwiftUI

/// Title/artist search against Discogs with a thumbnail-driven picker.
/// Used from AddRecordView ("Find on Discogs" before save) and from
/// RecordDetailView ("Look up on Discogs" to attach a release after the
/// fact). On selection, fetches the full release + marketplace stats and
/// hands back a `DiscogsLookup` via `onSelect`.
struct DiscogsPickerView: View {
    let initialTitle: String
    let initialArtist: String
    let onSelect: (DiscogsLookup) -> Void

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var results: [DiscogsSearchResult] = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var loadingReleaseID: Int64?
    @State private var hasSearchedOnce = false

    init(initialTitle: String, initialArtist: String, onSelect: @escaping (DiscogsLookup) -> Void) {
        self.initialTitle = initialTitle
        self.initialArtist = initialArtist
        self.onSelect = onSelect
        self._title = State(initialValue: initialTitle)
        self._artist = State(initialValue: initialArtist)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.md) {
                searchFields
                content
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Colors.background)
            .navigationTitle("Find on Discogs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await runSearch() }
        }
    }

    private var searchFields: some View {
        VStack(spacing: Theme.Spacing.sm) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            TextField("Artist", text: $artist)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            PrimaryButton(title: "Search", systemImage: "magnifyingglass", isLoading: isSearching) {
                Task { await runSearch() }
            }
            .disabled(isSearching || isQueryEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't search Discogs", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if isSearching && results.isEmpty {
            ProgressView().frame(maxHeight: .infinity)
        } else if results.isEmpty && hasSearchedOnce {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try a different title or artist."))
        } else if results.isEmpty {
            Spacer()
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        List(results) { result in
            Button { Task { await pick(result) } } label: {
                HStack(spacing: Theme.Spacing.md) {
                    cover(for: result)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(2)
                        if let colourway = result.colourway, !colourway.isEmpty {
                            Text(colourway)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.Colors.accent.opacity(0.15))
                                .foregroundStyle(Theme.Colors.accent)
                                .clipShape(Capsule())
                        }
                        Text(metadataLine(for: result))
                            .captionSecondary()
                            .lineLimit(1)
                        if let format = result.format {
                            Text(format)
                                .font(.caption2)
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if loadingReleaseID == result.id {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loadingReleaseID != nil)
        }
        .listStyle(.plain)
    }

    /// "2018 · Europe · Epitaph · 7600-1" — drops blanks so the dot
    /// separator never shows up doubled.
    private func metadataLine(for result: DiscogsSearchResult) -> String {
        var parts: [String] = []
        if let year = result.year { parts.append(String(year)) }
        if let country = result.country, !country.isEmpty { parts.append(country) }
        if let label = result.label, !label.isEmpty { parts.append(label) }
        if let catno = result.catno, !catno.isEmpty { parts.append(catno) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func cover(for result: DiscogsSearchResult) -> some View {
        if let urlString = result.coverThumb, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Theme.Colors.surface
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.Colors.surface)
                .frame(width: 56, height: 56)
                .overlay(
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                        .opacity(0.6)
                )
        }
    }

    private var isQueryEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            && artist.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runSearch() async {
        guard !isQueryEmpty else { return }
        isSearching = true
        error = nil
        defer { isSearching = false; hasSearchedOnce = true }
        do {
            let raw = try await services.discogs.search(title: title, artist: artist)
            results = sorted(raw)
        } catch {
            Log.error(error, category: "discogs.search")
            self.error = error.localizedDescription
            results = []
        }
    }

    /// Sort order: home-country first, then country alphabetically, then
    /// colourway alphabetically (rows without a colourway sink to the
    /// bottom of their country group), then year newest-first as a
    /// tiebreaker so reissues sit below the original.
    private func sorted(_ rows: [DiscogsSearchResult]) -> [DiscogsSearchResult] {
        rows.sorted { a, b in
            let aHome = isUserCountry(a.country)
            let bHome = isUserCountry(b.country)
            if aHome != bHome { return aHome }

            let aCountry = a.country?.lowercased() ?? "~"   // tilde sorts after letters
            let bCountry = b.country?.lowercased() ?? "~"
            if aCountry != bCountry { return aCountry < bCountry }

            let aColour = a.colourway ?? ""
            let bColour = b.colourway ?? ""
            let aHasColour = !aColour.isEmpty
            let bHasColour = !bColour.isEmpty
            if aHasColour != bHasColour { return aHasColour }
            if aColour != bColour {
                return aColour.localizedCaseInsensitiveCompare(bColour) == .orderedAscending
            }

            return (a.year ?? 0) > (b.year ?? 0)
        }
    }

    /// Discogs country values vs. ISO region codes don't always match —
    /// a couple of explicit aliases cover the common mismatches; everything
    /// else falls through to the localised region name lookup.
    private static let userCountryAliases: [String: Set<String>] = [
        "GB": ["uk", "united kingdom", "england", "scotland", "wales"],
        "US": ["us", "usa", "united states", "united states of america"],
    ]

    private func isUserCountry(_ country: String?) -> Bool {
        guard let raw = country?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return false }
        let regionCode = Locale.current.region?.identifier ?? ""
        if let aliases = Self.userCountryAliases[regionCode], aliases.contains(raw) {
            return true
        }
        if raw == regionCode.lowercased() { return true }
        if let regionName = Locale.current.localizedString(forRegionCode: regionCode)?.lowercased(),
           raw == regionName {
            return true
        }
        return false
    }

    private func pick(_ result: DiscogsSearchResult) async {
        loadingReleaseID = result.id
        defer { loadingReleaseID = nil }
        do {
            let lookup = try await services.discogs.release(id: result.id)
            onSelect(lookup)
            dismiss()
        } catch {
            Log.error(error, category: "discogs.pick")
            self.error = error.localizedDescription
        }
    }
}
