import Foundation
import PowerSync
import WidgetKit

/// Watches the per-user `notifications` inbox and exposes the unread count.
/// Mark-as-read flows write back through PowerSync (RLS gates to user_id).
@MainActor
final class NotificationsRepository: ObservableObject {
    @Published private(set) var notifications: [InboxNotification] = []
    @Published private(set) var unreadCount: Int = 0

    private let database: PowerSyncDatabaseProtocol
    private var watchTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol) {
        self.database = database
    }

    deinit { watchTask?.cancel() }

    func startWatching(userID: String) {
        watchTask?.cancel()
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            let sql = """
            select * from notifications
            where user_id = ?
            order by created_at desc
            limit 200
            """
            do {
                let stream = try database.watch(
                    sql: sql,
                    parameters: [userID],
                    mapper: { InboxNotification.from(cursor: $0) }
                )
                for try await rows in stream {
                    let mapped = rows.compactMap { $0 }
                    let unread = mapped.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
                    await MainActor.run {
                        self.notifications = mapped
                        self.unreadCount = unread
                    }
                    await self.refreshWishlistPriceWidget(from: mapped)
                }
            } catch {
                Log.error(error, category: "notifications.watch")
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel(); watchTask = nil
        notifications = []
        unreadCount = 0
        WidgetSnapshotStore.saveWishlistPriceAlert(nil)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.priceAlertWidgetKind)
    }

    func markRead(_ notificationID: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update notifications set read_at = ? where id = ? and read_at is null",
                parameters: [now, notificationID]
            )
        } catch {
            Log.error(error, category: "notifications.markRead")
        }
    }

    func markAllRead(userID: String) async {
        do {
            let now = Date().iso8601
            try await database.execute(
                sql: "update notifications set read_at = ? where user_id = ? and read_at is null",
                parameters: [now, userID]
            )
        } catch {
            Log.error(error, category: "notifications.markAllRead")
        }
    }

    private func refreshWishlistPriceWidget(from notifications: [InboxNotification]) async {
        let priceAlerts = notifications.filter { $0.kind == .priceAlert }
        let recordIDs = Array(Set(priceAlerts.compactMap { $0.payload["record_id"] }))
        guard !recordIDs.isEmpty else {
            WidgetSnapshotStore.saveWishlistPriceAlert(nil)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.priceAlertWidgetKind)
            return
        }

        do {
            let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
            let wishlistRecordIDs = try await database.getAll(
                sql: "select id from records where id in (\(placeholders)) and status = 'wishlist' and deleted_at is null",
                parameters: recordIDs,
                mapper: { try? $0.getString(name: "id") }
            )
            let wishlistIDs = Set(wishlistRecordIDs.compactMap { $0 })
            let latest = priceAlerts.first { alert in
                guard let recordID = alert.payload["record_id"] else { return false }
                return wishlistIDs.contains(recordID)
            }

            WidgetSnapshotStore.saveWishlistPriceAlert(latest.map { alert in
                WishlistPriceAlertSnapshot(
                    id: alert.id,
                    recordID: alert.payload["record_id"] ?? "",
                    title: alert.title,
                    body: alert.body,
                    priceCents: alert.payload["price_cents"].flatMap(Int.init),
                    currency: alert.payload["currency"],
                    shopName: alert.payload["shop_name"],
                    createdAt: alert.createdAt
                )
            })
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.priceAlertWidgetKind)
        } catch {
            Log.error(error, category: "notifications.widget")
        }
    }
}
