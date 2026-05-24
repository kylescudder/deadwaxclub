import SwiftUI

/// Picker that shows every record across all the user's Collections (both
/// owned and wishlist) and lets them multi-select to add to a list. Sort and
/// filter mirror the Records tab — same `RecordsSort`, same `RecordsFilter`.
struct AddRecordsToListSheet: View {
    let listID: String

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var allRecords: [VinylRecord] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @AppStorage("records.sort") private var sortRaw: String = RecordsSort.recentlyUpdated.rawValue
    @State private var filter: RecordsFilter = .none
    @State private var showFilterSheet = false
    @State private var showAddRecord = false
    @State private var selectionCount = 0
    @State private var saveCount = 0

    private var sort: RecordsSort {
        RecordsSort(rawValue: sortRaw) ?? .recentlyUpdated
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if filter.isActive {
                    RecordsFilterChipsBar(filter: $filter)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                }
                content
            }
            .background(Theme.Colors.background)
            .searchable(text: $search)
            .navigationTitle("Add records")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortRaw) {
                            ForEach(RecordsSort.allCases) { sort in
                                Text(sort.label).tag(sort.rawValue)
                            }
                        }
                        Button {
                            showFilterSheet = true
                        } label: {
                            Label("Filter\(filter.isActive ? " (active)" : "")",
                                  systemImage: "line.3.horizontal.decrease.circle")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selected.count))") { Task { await save() } }
                        .disabled(selected.isEmpty)
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                RecordsFilterSheet(filter: $filter, showStatusFilter: true)
            }
            .sheet(isPresented: $showAddRecord, onDismiss: { Task { await loadAll() } }) {
                NavigationStack { AddRecordView(initialStatus: .owned) }
            }
            .sensoryFeedback(.selection, trigger: selectionCount)
            .sensoryFeedback(.success, trigger: saveCount)
            .task { await loadAll() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if allRecords.isEmpty {
            EmptyState(
                systemImage: "circle",
                imageName: "AppLogoIcon",
                title: "No records to add yet",
                message: "Add a record to your collection and it'll show up here.",
                actionTitle: "Add a record",
                action: { showAddRecord = true },
                secondaryActionTitle: "Scan a barcode",
                secondaryActionSystemImage: "barcode.viewfinder",
                secondaryAction: {
                    dismiss()
                    NotificationCenter.default.post(
                        name: .switchMainTab,
                        object: nil,
                        userInfo: ["tab": MainTab.scan]
                    )
                }
            )
        } else if filtered.isEmpty {
            EmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "Try a different search term or clear your filters."
            )
        } else {
            let sections = filtered.grouped(by: sort, grouping: .automatic)
            ScrollViewReader { proxy in
                List {
                    ForEach(sections) { section in
                        if let title = section.title {
                            Section(title) {
                                sectionRows(section)
                            }
                            .id(section.id)
                        } else {
                            recordRows(section.records)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .trailing) {
                    RecordsAlphabetIndex(sections: sections) { sectionID in
                        withAnimation(.snappy) {
                            proxy.scrollTo(sectionID, anchor: .top)
                        }
                    }
                    .padding(.trailing, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionRows(_ section: RecordsSection) -> some View {
        if section.subsections.isEmpty {
            recordRows(section.records)
        } else {
            ForEach(section.subsections) { subsection in
                if let title = subsection.title {
                    RecordsSubsectionHeader(title: title)
                }
                recordRows(subsection.records)
            }
        }
    }

    @ViewBuilder
    private func recordRows(_ records: [VinylRecord]) -> some View {
        ForEach(records) { record in
            Button {
                if selected.contains(record.id) { selected.remove(record.id) }
                else { selected.insert(record.id) }
                selectionCount += 1
            } label: {
                HStack {
                    RecordRowView(record: record)
                    Spacer()
                    Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .listRowBackground(Theme.Colors.surface)
        }
    }

    private var filtered: [VinylRecord] {
        var rows = allRecords.filtered(by: filter).sorted(by: sort)
        if !search.isEmpty {
            let q = search.lowercased()
            rows = rows.filter {
                $0.title.lowercased().contains(q)
                    || $0.artist.lowercased().contains(q)
                    || ($0.colourway?.lowercased().contains(q) ?? false)
            }
        }
        return rows
    }

    private func loadAll() async {
        guard let userID = services.auth.currentUserID?.lowerUUID else { return }
        do {
            let rows = try await services.sync.database.getAll(
                sql: """
                select
                  r.id,
                  r.record_pressing_id,
                  r.collection_id,
                  r.status,
                  a.title,
                  a.artist,
                  rp.year,
                  a.album_year,
                  rp.colourway,
                  rp.cover_art_source_url,
                  rp.cover_art_storage_path,
                  rp.discogs_release_id,
                  rp.barcode,
                  r.notes,
                  rp.estimated_price_cents,
                  rp.estimated_price_currency,
                  rp.estimated_price_updated_at,
                  r.created_at,
                  r.updated_at,
                  r.deleted_at
                from records r
                join record_pressings rp on rp.id = r.record_pressing_id
                join albums a on a.id = rp.album_id
                where r.collection_id in (select collection_id from collection_members where user_id = ?)
                  and r.deleted_at is null
                """,
                parameters: [userID],
                mapper: { VinylRecord.from(cursor: $0) }
            )
            allRecords = rows.compactMap { $0 }
        } catch {
            Log.error(error, category: "lists.addRecords.loadAll")
        }
    }

    private func save() async {
        for id in selected {
            await services.lists.addRecord(id, to: listID)
        }
        saveCount += 1
        dismiss()
    }
}
