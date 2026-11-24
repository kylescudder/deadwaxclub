import Combine
import SwiftUI

/// Every open invite sent to the signed-in account, across all of the app's
/// shareable spaces. Recreate it with the account's sharing repositories.
@MainActor
final class SharingInbox: ObservableObject {
    struct Entry: Identifiable, Hashable {
        var id: String { "\(space.name)/\(invite.id)" }
        let space: SharingSpace
        let invite: ShareIncomingInvite
    }

    let repositories: [SharingRepository]
    private var cancellables = Set<AnyCancellable>()

    init(_ repositories: [SharingRepository]) {
        self.repositories = repositories
        for repository in repositories {
            repository.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// Newest first.
    var entries: [Entry] {
        repositories
            .flatMap { repository in repository.incomingInvites.map { Entry(space: repository.space, invite: $0) } }
            .sorted { ($0.invite.createdAt ?? .distantPast) > ($1.invite.createdAt ?? .distantPast) }
    }

    func refresh() async {
        for repository in repositories {
            await repository.refreshIncomingInvites()
        }
    }

    func accept(_ entry: Entry) async throws {
        try await repository(for: entry).accept(entry.invite)
    }

    func decline(_ entry: Entry) async throws {
        try await repository(for: entry).decline(entry.invite)
    }

    private func repository(for entry: Entry) throws -> SharingRepository {
        guard let repository = repositories.first(where: { $0.space == entry.space }) else { throw SharingError.signedOut }
        return repository
    }
}

/// An "Invites" section for a `List` or `Form`; it shows nothing when there
/// are no open invites.
struct ShareInvitesSection: View {
    @ObservedObject var inbox: SharingInbox

    var body: some View {
        if !inbox.entries.isEmpty {
            Section("Invites") {
                ForEach(inbox.entries) { entry in
                    ShareInviteRow(inbox: inbox, entry: entry)
                }
            }
        }
    }
}

/// The invites screen opened from an invite email or notification.
struct ShareInvitesView: View {
    @ObservedObject var inbox: SharingInbox
    /// The signed-in email, so someone signed in elsewhere knows why an invite is missing.
    let signedInEmail: String?
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Form {
                if inbox.entries.isEmpty {
                    Section {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("No invites right now.")
                                .font(.callout)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    } footer: {
                        if let signedInEmail {
                            Text("Invites show up for the email address they were sent to. You're signed in as \(signedInEmail).")
                        }
                    }
                } else {
                    ShareInvitesSection(inbox: inbox)
                }
            }
            .navigationTitle("Invites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await inbox.refresh() }
            .task {
                await inbox.refresh()
                isLoading = false
            }
        }
    }
}

private struct ShareInviteRow: View {
    @ObservedObject var inbox: SharingInbox
    let entry: SharingInbox.Entry
    @State private var isWorking = false
    @State private var error: String?
    @State private var successCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.invite.spaceName ?? "An invite")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("From \(entry.invite.inviterName ?? "someone") · \(entry.invite.role.label)")
                    .captionSecondary()
            }
            HStack {
                Button("Decline", role: .destructive) { Task { await answer(accept: false) } }
                    .buttonStyle(.bordered)
                Button("Accept") { Task { await answer(accept: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(isWorking)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .sensoryFeedback(.success, trigger: successCount)
    }

    private func answer(accept: Bool) async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            if accept {
                try await inbox.accept(entry)
            } else {
                try await inbox.decline(entry)
            }
            successCount += 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}
