import SwiftUI

struct NotificationInboxView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Notifications")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if services.notifications.unreadCount > 0 {
                            Button("Mark all read") {
                                Task { await markAllRead() }
                            }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if services.notifications.notifications.isEmpty {
            EmptyState(
                systemImage: "bell.slash",
                title: "No notifications yet",
                message: "Price alerts on your wishlist and Collection invites will appear here."
            )
        } else {
            List {
                ForEach(services.notifications.notifications) { row in
                    Button {
                        Task { await tap(row) }
                    } label: {
                        rowView(row)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(row.isRead
                                       ? Theme.Colors.surface
                                       : Theme.Colors.surfaceElevated)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func rowView(_ row: InboxNotification) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon(for: row.kind))
                .font(.title3)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.callout.weight(row.isRead ? .regular : .semibold))
                Text(row.body).font(.footnote).foregroundStyle(Theme.Colors.textSecondary)
                Text(row.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer()
            if !row.isRead {
                Circle()
                    .fill(Theme.Colors.accent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for kind: NotificationKind) -> String {
        switch kind {
        case .priceAlert:       return "tag"
        case .collectionInvite: return "person.crop.circle.badge.plus"
        }
    }

    private func tap(_ row: InboxNotification) async {
        await services.notifications.markRead(row.id)
        switch row.kind {
        case .priceAlert:
            if let recordID = row.payload["record_id"] {
                NotificationCenter.default.post(
                    name: .openRecord, object: nil, userInfo: ["record_id": recordID]
                )
                dismiss()
            }
        case .collectionInvite:
            if let collectionID = row.payload["collection_id"] {
                NotificationCenter.default.post(
                    name: .openCollection, object: nil, userInfo: ["collection_id": collectionID]
                )
                dismiss()
            }
        }
    }

    private func markAllRead() async {
        guard let userID = services.auth.currentUserID?.lowerUUID else { return }
        await services.notifications.markAllRead(userID: userID)
    }
}

/// Toolbar bell + unread badge — drop into any NavigationStack.
struct NotificationBellToolbarItem: ToolbarContent {
    @Binding var isPresented: Bool
    let unreadCount: Int

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { isPresented = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                    if unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
            }
        }
    }
}
