import SwiftUI

/// Renders a list shared via `link_public` mode using the unauthenticated
/// `get_shared_list` and `get_shared_list_records` RPCs. Works without a
/// DeadWaxClub account; that's the whole point of "public link" mode.
struct PublicListView: View {
    let token: String

    @EnvironmentObject private var services: AppServices
    @State private var info: PublicListInfo?
    @State private var records: [PublicListRecord] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if let error {
                EmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load list",
                    message: error
                )
            } else if let info {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            if let owner = info.owner_display_name {
                                Text("Shared by \(owner)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            if let desc = info.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.callout)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                    }

                    Section("\(records.count) records") {
                        ForEach(records) { record in
                            PublicRecordRow(record: record)
                                .listRowBackground(Theme.Colors.surface)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .navigationTitle(info.name)
                .navigationBarTitleDisplayMode(.large)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let infoRows: [PublicListInfo] = try await services.auth.supabase
                .rpc("get_shared_list", params: ["token": token])
                .execute()
                .value
            guard let first = infoRows.first else {
                error = "This list isn't available — the owner may have made it private or deleted it."
                return
            }
            let recs: [PublicListRecord] = try await services.auth.supabase
                .rpc("get_shared_list_records", params: ["token": token])
                .execute()
                .value
            self.info = first
            self.records = recs
        } catch let e {
            error = e.localizedDescription
        }
    }
}

struct PublicListInfo: Decodable {
    let id: String
    let name: String
    let description: String?
    let owner_display_name: String?
    let cover_record_id: String?
    let updated_at: String?
}

struct PublicListRecord: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let year: Int?
    let colourway: String?
    let cover_art_storage_path: String?
    let cover_art_source_url: String?
    let position: Int
}

private struct PublicRecordRow: View {
    let record: PublicListRecord

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AsyncImage(url: coverURL) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Theme.Colors.surfaceElevated
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(record.artist).font(.footnote).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
                if let cw = record.colourway {
                    Text(cw).font(.caption2).foregroundStyle(Theme.Colors.textTertiary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var coverURL: URL? {
        if let path = record.cover_art_storage_path,
           let url = CoverArtCache.publicStorageURL(path: path) {
            return url
        }
        return record.cover_art_source_url.flatMap(URL.init(string:))
    }
}
