import SwiftUI

struct RecordsListView: View {
    @EnvironmentObject private var services: AppServices
    @State private var status: RecordStatus = .owned
    @State private var search: String = ""
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $status) {
                ForEach(RecordStatus.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)

            content
        }
        .background(Theme.Colors.background)
        .navigationTitle("Records")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { SyncStatusView() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack { AddRecordView(initialStatus: status) }
        }
        .task(id: status) { reconfigure() }
        .onAppear { reconfigure() }
    }

    @ViewBuilder
    private var content: some View {
        let filtered = filteredRecords
        if services.records.records.isEmpty && !services.records.isLoading {
            EmptyState(
                systemImage: status == .owned ? "opticaldisc" : "heart",
                title: status == .owned ? "No records yet" : "Nothing on your wishlist",
                message: status == .owned
                    ? "Scan a barcode in a shop or add records manually to start your collection."
                    : "Save vinyl you want to buy and track price changes over time.",
                actionTitle: "Add record"
            ) { showAddSheet = true }
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
            .navigationDestination(for: VinylRecord.self) { record in
                RecordDetailView(record: record)
            }
        }
    }

    private var filteredRecords: [VinylRecord] {
        guard !search.isEmpty else { return services.records.records }
        let q = search.lowercased()
        return services.records.records.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    private func reconfigure() {
        guard let ownerID = services.auth.currentUserID?.uuidString else { return }
        services.records.startWatching(status: status, ownerID: ownerID)
    }

    private func delete(at offsets: IndexSet) {
        let toRemove = offsets.map { filteredRecords[$0] }
        Task { for r in toRemove { await services.records.softDelete(recordID: r.id) } }
    }
}
