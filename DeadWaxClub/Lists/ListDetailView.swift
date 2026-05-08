import SwiftUI
import PowerSync
import Combine

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
                        // Inline destination instead of value-based — the
                        // Records tab also registers
                        // `.navigationDestination(for: VinylRecord.self)` and
                        // SwiftUI's TabView leaks the conflict into this
                        // stack, causing taps to push the wrong destination.
                        NavigationLink {
                            RecordDetailView(record: record)
                        } label: {
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
        }
    }
}

@MainActor
final class ListContentsHolder: ObservableObject {
    @Published var repo: ListContentsRepository?
    private var innerCancellable: AnyCancellable?

    func attach(database: PowerSyncDatabaseProtocol, listID: String) {
        if repo == nil {
            let r = ListContentsRepository(database: database)
            r.startWatching(listID: listID)
            // SwiftUI only observes our own @Published `repo` slot; nested
            // ObservableObjects don't propagate. Re-publish the inner repo's
            // changes so the view re-renders when records / members /
            // pendingInvites update.
            innerCancellable = r.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            repo = r
        }
    }
}
