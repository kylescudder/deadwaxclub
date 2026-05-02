import SwiftUI

struct ShareListSheet: View {
    let list: VinylList

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ListShareMode
    @State private var inviteEmail = ""
    @State private var inviteRole: ListMemberRole = .editor
    @State private var inviteError: String?
    @State private var isInviting = false
    @StateObject private var contents: ListContentsHolder = ListContentsHolder()

    init(list: VinylList) {
        self.list = list
        self._mode = State(initialValue: list.shareMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("How is this list shared?") {
                    ForEach(ListShareMode.allCases) { option in
                        Button {
                            Task {
                                mode = option
                                await services.lists.updateShareMode(listID: list.id, mode: option)
                                Haptics.selection()
                            }
                        } label: {
                            HStack {
                                Image(systemName: option.systemImage)
                                    .foregroundStyle(Theme.Colors.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Text(option.detail)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                                Spacer()
                                if mode == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.Colors.accent)
                                }
                            }
                        }
                    }
                }

                if mode == .linkPublic, let token = list.shareToken {
                    Section("Share link") {
                        let url = Self.shareURL(token: token)
                        ShareLink(item: url) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        Text(url.absoluteString)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .textSelection(.enabled)
                    }
                }

                if mode == .invite || mode == .collaborative {
                    Section {
                        HStack {
                            TextField("name@example.com", text: $inviteEmail)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if mode == .invite {
                                Picker("", selection: $inviteRole) {
                                    Text("View").tag(ListMemberRole.viewer)
                                    Text("Edit").tag(ListMemberRole.editor)
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                        }
                        Button("Send invite") { Task { await invite() } }
                            .disabled(inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty || isInviting)
                        if let inviteError {
                            Text(inviteError).font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("Invite by email")
                    } footer: {
                        Text("They'll need a Trackd account using that email. Collaborative lists are always invited as editors.")
                    }

                    if let repo = contents.repo {
                        Section("Members") {
                            if repo.members.isEmpty {
                                Text("No one yet.")
                                    .font(.callout)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            ForEach(repo.members) { member in
                                HStack {
                                    Text(member.userID.prefix(8) + "…")
                                        .font(.callout.monospaced())
                                    Spacer()
                                    Text(member.role.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                    Button(role: .destructive) {
                                        Task { await services.lists.removeMember(listID: list.id, userID: member.userID) }
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                contents.attach(database: services.sync.database, listID: list.id)
            }
        }
    }

    private func invite() async {
        let role: ListMemberRole = mode == .collaborative ? .editor : inviteRole
        isInviting = true
        defer { isInviting = false }
        do {
            try await services.lists.addMember(
                listID: list.id,
                userEmail: inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                role: role
            )
            inviteEmail = ""
            inviteError = nil
            Haptics.success()
        } catch {
            inviteError = error.localizedDescription
            Haptics.error()
        }
    }

    static func shareURL(token: String) -> URL {
        URL(string: "https://trackd.app/l/\(token)")!
    }
}
