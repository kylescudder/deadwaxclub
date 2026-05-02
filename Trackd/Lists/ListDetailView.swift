import SwiftUI
import PowerSync

struct ListDetailView: View {
    let list: VinylList

    @EnvironmentObject private var services: AppServices
    @StateObject private var contents: ListContentsHolder = ListContentsHolder()
    @State private var showShareSheet = false
    @State private var showAddRecordSheet = false

    var body: some View {
        Group {
            if let repo = contents.repo {
                content(repo: repo)
            } else {
                LoadingView()
            }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddRecordSheet = true
                    } label: { Label("Add records", systemImage: "plus") }
                    Button {
                        showShareSheet = true
                    } label: { Label("Sharing", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareListSheet(list: list)
        }
        .sheet(isPresented: $showAddRecordSheet) {
            AddRecordsToListSheet(listID: list.id)
        }
        .onAppear {
            contents.attach(database: services.sync.database, listID: list.id)
        }
    }

    @ViewBuilder
    private func content(repo: ListContentsRepository) -> some View {
        if repo.records.isEmpty {
            EmptyState(
                systemImage: "tray",
                title: "No records on this list",
                message: "Add records from your collection or wishlist.",
                actionTitle: "Add records"
            ) { showAddRecordSheet = true }
        } else {
            List {
                Section {
                    ForEach(repo.records) { record in
                        NavigationLink(value: record) {
                            RecordRowView(record: record)
                        }
                        .listRowBackground(Theme.Colors.surface)
                    }
                    .onDelete { offsets in
                        let toRemove = offsets.map { repo.records[$0] }
                        Task {
                            for r in toRemove {
                                await services.lists.removeRecord(r.id, from: list.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: list.shareMode.systemImage)
                        Text(list.shareMode.label)
                        Spacer()
                        Text("\(repo.records.count) records")
                    }
                    .font(.caption)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationDestination(for: VinylRecord.self) { RecordDetailView(record: $0) }
        }
    }
}

@MainActor
final class ListContentsHolder: ObservableObject {
    @Published var repo: ListContentsRepository?

    func attach(database: PowerSyncDatabaseProtocol, listID: String) {
        if repo == nil {
            let r = ListContentsRepository(database: database)
            r.startWatching(listID: listID)
            repo = r
        }
    }
}
