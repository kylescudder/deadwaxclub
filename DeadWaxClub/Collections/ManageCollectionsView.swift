import SwiftUI

struct ManageCollectionsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var newCollectionName: String = ""
    @State private var isCreating = false
    @State private var navTarget: VinylCollection?

    var body: some View {
        Form {
            Section {
                ForEach(services.collections.collections) { collection in
                    NavigationLink {
                        CollectionDetailView(collection: collection)
                    } label: {
                        row(for: collection)
                    }
                }
                if services.collections.collections.isEmpty {
                    Text("Your personal Collection will appear here once it syncs.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            } header: {
                Text("Your Collections")
            } footer: {
                Text("Records in your personal Collection are private to you. Records in a shared Collection are visible to everyone you've invited — perfect for couples, flatmates, or vinyl-trading friends.")
            }

            Section {
                HStack {
                    TextField("Name", text: $newCollectionName)
                        .textInputAutocapitalization(.words)
                    Button("Create") { Task { await create() } }
                        .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            } header: {
                Text("Start a new shared Collection")
            } footer: {
                Text("Create one for your household or a group of friends, then invite people by email.")
            }
        }
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.large)
        // Programmatic push (after create + deep-link). Tap navigation goes
        // through the inline NavigationLink above; declaring both an inline
        // destination *and* a `navigationDestination(for: VinylCollection.self)`
        // makes SwiftUI warn and silently pick one of them.
        .navigationDestination(item: $navTarget) { c in
            CollectionDetailView(collection: c)
        }
        .onChange(of: services.pendingDeepLinkCollectionID) { _, newValue in
            guard let id = newValue,
                  let target = services.collections.collections.first(where: { $0.id == id }) else { return }
            navTarget = target
            services.pendingDeepLinkCollectionID = nil
        }
    }

    private func row(for collection: VinylCollection) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: services.profile.profile?.primaryCollectionID == collection.id
                  ? "star.fill" : "rectangle.stack")
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).foregroundStyle(Theme.Colors.textPrimary)
                Text(memberSummary(for: collection))
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private func memberSummary(for collection: VinylCollection) -> String {
        let count = services.collections.members(of: collection.id).count
        let suffix = count == 1 ? "member" : "members"
        if services.profile.profile?.primaryCollectionID == collection.id {
            return "Primary · \(count) \(suffix)"
        }
        return "\(count) \(suffix)"
    }

    private func create() async {
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        if let created = await services.collections.create(name: name) {
            newCollectionName = ""
            navTarget = created
            Haptics.success()
        } else {
            Haptics.error()
        }
    }
}

private struct CollectionDetailView: View {
    let collection: VinylCollection

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var editingName: String = ""
    @State private var inviteEmail: String = ""
    @State private var inviteRole: CollectionMemberRole = .editor
    @State private var inviteError: String?
    @State private var inviteBanner: String?
    @State private var isInviting = false
    @State private var showLeaveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showMoveConfirm = false

    private var isPrimary: Bool {
        services.profile.profile?.primaryCollectionID == collection.id
    }

    private var currentUserID: String? {
        services.auth.currentUserID?.uuidString.lowercased()
    }

    private var currentRole: CollectionMemberRole? {
        guard let uid = currentUserID else { return nil }
        return services.collections.role(in: collection.id, userID: uid)
    }

    private var isOwner: Bool { currentRole == .owner }

    private var canMoveAllFromPrimary: Bool {
        guard let primary = services.profile.profile?.primaryCollectionID else { return false }
        return primary != collection.id && primary != "" // moving from primary into this Collection
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Collection name", text: $editingName)
                    .onSubmit { Task { await renameIfChanged() } }
                Button("Save name") { Task { await renameIfChanged() } }
                    .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty
                              || editingName == collection.name
                              || !isOwner)
            }

            Section("Members") {
                let members = services.collections.members(of: collection.id)
                if members.isEmpty {
                    Text("No one yet.")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                ForEach(members) { member in
                    HStack {
                        Text(member.userID.prefix(8) + "…")
                            .font(.callout.monospaced())
                        Spacer()
                        Text(member.role.label)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        if isOwner && member.userID != currentUserID {
                            Button(role: .destructive) {
                                Task { await services.collections.removeMember(collectionID: collection.id, userID: member.userID) }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            let pending = services.collections.pendingInvites(for: collection.id)
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { invite in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(invite.email).font(.callout)
                                Text("Pending · \(invite.role.label)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            Spacer()
                            if isOwner {
                                Button(role: .destructive) {
                                    Task { await services.collections.revokePendingInvite(inviteID: invite.id) }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("Pending invites")
                } footer: {
                    Text("Auto-accepted when the invitee signs up with the matching email.")
                }
            }

            if isOwner {
                Section {
                    HStack {
                        TextField("name@example.com", text: $inviteEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("", selection: $inviteRole) {
                            Text("Editor").tag(CollectionMemberRole.editor)
                            Text("Viewer").tag(CollectionMemberRole.viewer)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Button("Send invite") { Task { await invite() } }
                        .disabled(inviteEmail.trimmingCharacters(in: .whitespaces).isEmpty || isInviting)
                    if let inviteBanner {
                        Text(inviteBanner).font(.footnote).foregroundStyle(.green)
                    }
                    if let inviteError {
                        Text(inviteError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Invite by email")
                } footer: {
                    Text("If they already have an account they're added straight away (and notified). Otherwise we'll save the invite and add them when they sign up.")
                }
            }

            Section {
                if !isPrimary {
                    Button {
                        Task {
                            await services.collections.setPrimary(collectionID: collection.id)
                            Haptics.success()
                        }
                    } label: {
                        Label("Set as primary", systemImage: "star")
                    }
                }
                if !isPrimary && canMoveAllFromPrimary {
                    Button {
                        showMoveConfirm = true
                    } label: {
                        Label("Move all my records here", systemImage: "arrow.right.square")
                    }
                }
                if !isPrimary {
                    Button(role: .destructive) {
                        showLeaveConfirm = true
                    } label: {
                        Label("Leave Collection", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                if isOwner && services.collections.collections.count > 1 {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Collection", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { editingName = collection.name }
        .alert("Leave this Collection?", isPresented: $showLeaveConfirm) {
            Button("Leave", role: .destructive) {
                Task {
                    await services.collections.leave(collectionID: collection.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stop seeing the records in this Collection. The other members keep their access.")
        }
        .alert("Delete this Collection?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    await services.collections.softDelete(collectionID: collection.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All members lose access. Records inside the Collection become inaccessible until restored.")
        }
        .alert("Move all your records here?", isPresented: $showMoveConfirm) {
            Button("Move records") {
                Task { await moveAllFromPrimary() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every record currently in your primary Collection moves into \(collection.name). Other members will see them straight away.")
        }
    }

    private func renameIfChanged() async {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != collection.name, isOwner else { return }
        await services.collections.rename(collectionID: collection.id, name: trimmed)
        Haptics.success()
    }

    private func invite() async {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        isInviting = true
        defer { isInviting = false }
        inviteError = nil
        inviteBanner = nil
        do {
            let outcome = try await services.collections.invite(
                collectionID: collection.id,
                email: email,
                role: inviteRole
            )
            switch outcome {
            case .added:   inviteBanner = "Added \(email) to the Collection."
            case .pending: inviteBanner = "Invitation saved. They'll join when they sign up with \(email)."
            }
            inviteEmail = ""
            Haptics.success()
        } catch {
            inviteError = error.localizedDescription
            Haptics.error()
        }
    }

    private func moveAllFromPrimary() async {
        guard let primary = services.profile.profile?.primaryCollectionID else { return }
        await services.collections.moveAllRecords(from: primary, to: collection.id)
        Haptics.success()
    }
}
