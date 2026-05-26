import SwiftUI

struct RecordsListView: View {
    @Binding var status: RecordStatus
    var addRecordRequest: UUID?
    var logPriceRequest: UUID?

    @EnvironmentObject private var services: AppServices
    @State private var search: String = ""
    @State private var showAddSheet = false
    @AppStorage("records.sort") private var sortRaw: String = RecordsSort.recentlyUpdated.rawValue
    @State private var filter: RecordsFilter = .none
    @State private var showFilterSheet = false
    @State private var showNotificationInbox = false
    @State private var showLogPricePicker = false
    @State private var logPriceRecord: VinylRecord?
    @State private var recordsPendingDeletion: [VinylRecord] = []
    @State private var showDeleteConfirm = false
    @State private var refreshCount = 0

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
                RecordsFilterChipsBar(filter: $filter)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
            }

            content
        }
        .background(Theme.Colors.background)
        .navigationTitle("Records")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: VinylRecord.self) { record in
            RecordDetailView(record: record)
        }
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search my collection"
        )
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
        .sheet(isPresented: $showLogPricePicker) {
            NavigationStack {
                List(logPriceRecords) { record in
                    Button {
                        logPriceRecord = record
                        showLogPricePicker = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text(record.artist)
                                .font(.footnote)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                }
                .navigationTitle("Log price")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showLogPricePicker = false }
                    }
                }
                .overlay {
                    if logPriceRecords.isEmpty {
                        EmptyState(
                            systemImage: "tag",
                            title: "No collection records",
                            message: "Add a record to your collection before logging a price."
                        )
                    }
                }
            }
        }
        .sheet(item: $logPriceRecord) { record in
            LogPriceSheet(record: record)
        }
        .alert(deleteConfirmationTitle, isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deletePendingRecords() }
            }
            Button("Cancel", role: .cancel) {
                recordsPendingDeletion = []
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .onChange(of: addRecordRequest) { _, request in
            if request != nil {
                status = .owned
                showAddSheet = true
            }
        }
        .onChange(of: logPriceRequest) { _, request in
            if request != nil {
                status = .owned
                showLogPricePicker = true
            }
        }
        .task(id: status) { reconfigure() }
        .onAppear { reconfigure() }
    }

    private var logPriceRecords: [VinylRecord] {
        services.records.records
            .filter { $0.status == .owned }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    @ViewBuilder
    private var content: some View {
        let filtered = filteredAndSortedRecords
        if filtered.isEmpty && !filter.isActive && search.isEmpty {
            EmptyState(
                systemImage: status == .owned ? "circle" : "heart.fill",
                imageName: status == .owned ? "AppLogoIcon" : nil,
                title: status == .owned ? "Your collection is empty" : "Nothing on your wishlist",
                message: status == .owned
                    ? ""
                    : "Save vinyl you want to buy and track price changes over time.",
                actionTitle: status == .owned ? "Add a record" : "Add to wishlist",
                action: { showAddSheet = true }
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
                .refreshable {
                    refreshCount += 1
                    reconfigure()
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                .sensoryFeedback(.impact(weight: .light), trigger: refreshCount)
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
            NavigationLink(value: record) {
                RecordRowView(record: record)
            }
            .listRowBackground(Theme.Colors.surface)
        }
        .onDelete { offsets in delete(at: offsets, in: records) }
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
        guard let userID = services.auth.currentUserID?.lowerUUID else { return }
        services.records.startWatching(status: status, userID: userID)
    }

    private func delete(at offsets: IndexSet, in records: [VinylRecord]) {
        recordsPendingDeletion = offsets.map { records[$0] }
        showDeleteConfirm = !recordsPendingDeletion.isEmpty
    }

    private var deleteConfirmationTitle: String {
        recordsPendingDeletion.count == 1 ? "Delete this record?" : "Delete these records?"
    }

    private var deleteConfirmationMessage: String {
        if let record = recordsPendingDeletion.first, recordsPendingDeletion.count == 1 {
            return "\"\(record.title)\" will be removed from your collection and lists."
        }
        return "\(recordsPendingDeletion.count) records will be removed from your collection and lists."
    }

    private func deletePendingRecords() async {
        let toRemove = recordsPendingDeletion
        recordsPendingDeletion = []
        for record in toRemove {
            await services.records.softDelete(recordID: record.id)
        }
    }
}

struct RecordsSubsectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.Colors.accent)
            .textCase(.uppercase)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.lg, bottom: 0, trailing: Theme.Spacing.lg))
            .listRowBackground(Theme.Colors.surface)
    }
}

struct RecordsAlphabetIndex: View {
    let sections: [RecordsSection]
    let onSelect: (String) -> Void
    @State private var activeSectionID: String?

    private let rowHeight: CGFloat = 12
    private let rowSpacing: CGFloat = 1
    private let verticalPadding: CGFloat = 6

    private var entries: [(title: String, sectionID: String)] {
        sections.compactMap { section in
            guard let title = section.title,
                  let indexTitle = indexTitle(for: title) else { return nil }
            return (indexTitle, section.id)
        }
    }

    private var entryWidth: CGFloat {
        entries.contains { $0.title.count > 1 } ? 30 : 18
    }

    var body: some View {
        if entries.count > 1 {
            VStack(spacing: rowSpacing) {
                ForEach(entries, id: \.sectionID) { entry in
                    Text(entry.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            activeSectionID == entry.sectionID
                                ? Theme.Colors.textPrimary
                                : Theme.Colors.accent
                        )
                        .frame(width: entryWidth, height: rowHeight)
                }
            }
            .padding(.vertical, verticalPadding)
            .background(.ultraThinMaterial, in: Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        selectEntry(at: value.location.y)
                    }
                    .onEnded { _ in
                        activeSectionID = nil
                    }
            )
            .sensoryFeedback(.selection, trigger: activeSectionID)
            .accessibilityLabel("Section index")
        }
    }

    private func selectEntry(at yPosition: CGFloat) {
        let rowStride = rowHeight + rowSpacing
        let rawIndex = Int((yPosition - verticalPadding) / rowStride)
        let index = min(max(rawIndex, 0), entries.count - 1)
        let sectionID = entries[index].sectionID

        guard activeSectionID != sectionID else { return }
        activeSectionID = sectionID
        onSelect(sectionID)
    }

    private func indexTitle(for sectionTitle: String) -> String? {
        if sectionTitle == "#" { return sectionTitle }
        if sectionTitle.count == 1, sectionTitle.first?.isLetter == true { return sectionTitle }
        if sectionTitle == "Unknown year" { return "?" }
        if Int(sectionTitle) != nil { return String(sectionTitle.suffix(2)) }
        return nil
    }
}
