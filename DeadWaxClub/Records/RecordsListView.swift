import SwiftUI

struct RecordsListView: View {
    @EnvironmentObject private var services: AppServices
    @State private var status: RecordStatus = .owned
    @State private var search: String = ""
    @State private var showAddSheet = false
    @AppStorage("records.sort") private var sortRaw: String = RecordsSort.recentlyUpdated.rawValue
    @State private var filter: RecordsFilter = .none
    @State private var showFilterSheet = false
    @State private var showNotificationInbox = false

    private var sort: RecordsSort {
        RecordsSort(rawValue: sortRaw) ?? .recentlyUpdated
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $status) {
                ForEach(RecordStatus.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)

            if filter.isActive {
                FilterChipsBar(filter: $filter)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
            }

            content
        }
        .background(Theme.Colors.background)
        .navigationTitle("Records")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            NotificationBellToolbarItem(
                isPresented: $showNotificationInbox,
                unreadCount: services.notifications.unreadCount
            )
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
                        Label("Filter\(filter.isActive ? " (active)" : "")", systemImage: "line.3.horizontal.decrease.circle")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack { AddRecordView(initialStatus: status) }
        }
        .sheet(isPresented: $showFilterSheet) {
            RecordsFilterSheet(filter: $filter)
        }
        .sheet(isPresented: $showNotificationInbox) {
            NotificationInboxView()
        }
        .task(id: status) { reconfigure() }
        .onAppear { reconfigure() }
    }

    @ViewBuilder
    private var content: some View {
        let filtered = filteredAndSortedRecords
        if filtered.isEmpty && !filter.isActive && search.isEmpty {
            EmptyState(
                systemImage: status == .owned ? "opticaldisc" : "heart",
                title: status == .owned ? "No records yet" : "Nothing on your wishlist",
                message: status == .owned
                    ? "Scan a barcode in a shop or add records manually to start your collection."
                    : "Save vinyl you want to buy and track price changes over time.",
                actionTitle: "Add record"
            ) { showAddSheet = true }
        } else if filtered.isEmpty {
            EmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "Try a different search term or clear your filters."
            )
        } else {
            List {
                ForEach(filtered) { record in
                    NavigationLink(value: record) {
                        RecordRowView(record: record)
                    }
                    .listRowBackground(Theme.Colors.surface)
                }
                .onDelete(perform: delete)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable {
                Haptics.tap()
                reconfigure()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            .navigationDestination(for: VinylRecord.self) { record in
                RecordDetailView(record: record)
            }
        }
    }

    private var filteredAndSortedRecords: [VinylRecord] {
        var rows = services.records.records.filtered(by: filter).sorted(by: sort)
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

    private func reconfigure() {
        guard let userID = services.auth.currentUserID?.uuidString.lowercased() else { return }
        services.records.startWatching(status: status, userID: userID)
    }

    private func delete(at offsets: IndexSet) {
        let toRemove = offsets.map { filteredAndSortedRecords[$0] }
        Task { for r in toRemove { await services.records.softDelete(recordID: r.id) } }
    }
}

private struct FilterChipsBar: View {
    @Binding var filter: RecordsFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                if let range = filter.yearRange {
                    chip("Year \(range.lowerBound)–\(range.upperBound == .max ? "now" : "\(range.upperBound)")") {
                        filter.yearRange = nil
                    }
                }
                if let cw = filter.colourwayContains, !cw.isEmpty {
                    chip("Colour: \(cw)") { filter.colourwayContains = nil }
                }
                if filter.hasPriceOnly {
                    chip("With est. value") { filter.hasPriceOnly = false }
                }
                if filter.hasNoPriceOnly {
                    chip("Missing price") { filter.hasNoPriceOnly = false }
                }
            }
        }
    }

    private func chip(_ text: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.caption)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.surface)
        .clipShape(Capsule())
    }
}
