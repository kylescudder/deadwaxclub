import SwiftUI

/// The Members, Pending invites and Invite by email sections for one space.
/// Place it inside a `Form` next to the app's own sections. Only owners see
/// the remove buttons and the invite form.
struct ShareMembersSections: View {
    @ObservedObject var sharing: SharingRepository
    let spaceID: String
    let currentUserID: String?

    @State private var inviteEmail = ""
    @State private var inviteRole: ShareRole = .editor
    @State private var inviteMessage: String?
    @State private var inviteError: String?
    @State private var isInviting = false
    @State private var successCount = 0
    @State private var errorCount = 0

    private var members: [ShareMember] { sharing.members(of: spaceID) }
    private var pending: [SharePendingInvite] { sharing.pendingInvites(for: spaceID) }

    private var isOwner: Bool {
        guard let currentUserID else { return false }
        return sharing.role(in: spaceID, userID: currentUserID) == .owner
    }

    var body: some View {
        Section("Members") {
            if members.isEmpty {
                Text("No one yet.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            ForEach(members) { member in
                HStack {
                    Text(name(of: member))
                        .font(.callout)
                    Spacer()
                    Text(member.role.label)
                        .captionSecondary()
                    if isOwner && member.userID != currentUserID {
                        Button(role: .destructive) {
                            Task { await sharing.removeMember(spaceID: spaceID, userID: member.userID) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(name(of: member))")
                    }
                }
            }
        }
        .task(id: members) {
            await sharing.refreshMemberProfiles(spaceID: spaceID)
        }

        if !pending.isEmpty {
            Section {
                ForEach(pending) { invite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.email)
                                .font(.callout)
                            Text("Pending · \(invite.role.label)")
                                .captionSecondary()
                        }
                        Spacer()
                        if isOwner {
                            Button(role: .destructive) {
                                Task { await sharing.revokePendingInvite(inviteID: invite.id) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel the invite to \(invite.email)")
                        }
                    }
                }
            } header: {
                Text("Pending invites")
            } footer: {
                Text(sharing.space.copy.pendingFooter)
            }
        }

        if isOwner {
            Section {
                HStack {
                    TextField("name@example.com", text: $inviteEmail)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await invite() } }
                    Picker("Role", selection: $inviteRole) {
                        ForEach(ShareRole.invitable, id: \.self) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Button("Send invite") { Task { await invite() } }
                    .disabled(inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty || isInviting)
                if let inviteMessage {
                    Text(inviteMessage)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if let inviteError {
                    Text(inviteError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Invite by email")
            } footer: {
                Text(sharing.space.copy.inviteFooter)
            }
            .sensoryFeedback(.success, trigger: successCount)
            .sensoryFeedback(.error, trigger: errorCount)
        }
    }

    private func name(of member: ShareMember) -> String {
        if let name = sharing.displayName(for: member.userID) { return name }
        if member.userID == currentUserID { return "You" }
        return String(member.userID.prefix(8)) + "…"
    }

    private func invite() async {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !isInviting else { return }
        isInviting = true
        defer { isInviting = false }
        inviteMessage = nil
        inviteError = nil
        do {
            switch try await sharing.invite(spaceID: spaceID, email: email, role: inviteRole) {
            case .added:
                inviteMessage = "Added \(email) to \(sharing.space.copy.destination)."
            case .pending:
                inviteMessage = "Invite sent to \(email). They'll join once they accept it."
            }
            inviteEmail = ""
            successCount += 1
        } catch {
            inviteError = error.localizedDescription
            errorCount += 1
        }
    }
}
