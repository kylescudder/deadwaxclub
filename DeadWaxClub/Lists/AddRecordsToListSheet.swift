import SwiftUI

/// Picker that shows every record across all the user's Collections (both
/// owned and wishlist) and lets them multi-select to add to a list. Sort and
/// filter mirror the Records tab — same `RecordsSort`, same `RecordsFilter`,
/// and they share the persisted `records.sort` AppStorage key so the user's
/// preferred order applies in both places.
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
                        Divider()
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
            List {
                ForEach(filtered) { record in
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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
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
                select * from records
                where collection_id in (select collection_id from collection_members where user_id = ?)
                  and deleted_at is null
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
