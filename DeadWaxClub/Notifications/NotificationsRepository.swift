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
            WidgetSnapshotStore.saveWishlistPriceAlerts([])
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.priceAlertWidgetKind)
            return
        }

        do {
            let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
            let wishlistRecords = try await database.getAll(
                sql: """
                select r.id, rp.cover_art_storage_path, rp.cover_art_source_url
                from records r
                join record_pressings rp on rp.id = r.record_pressing_id
                where r.id in (\(placeholders)) and r.status = 'wishlist' and r.deleted_at is null
                """,
                parameters: recordIDs,
                mapper: { cursor -> WidgetWishlistRecord? in
                    guard let id = try? cursor.getString(name: "id") else { return nil }
                    return WidgetWishlistRecord(
                        id: id,
                        coverArtStoragePath: try? cursor.getStringOptional(name: "cover_art_storage_path"),
                        coverArtSourceURL: try? cursor.getStringOptional(name: "cover_art_source_url")
                    )
                }
            )
            let recordsByID = Dictionary(uniqueKeysWithValues: wishlistRecords.compactMap { record in
                record.map { ($0.id, $0) }
            })
            let wishlistIDs = Set(recordsByID.keys)
            let wishlistAlerts = priceAlerts.filter { alert in
                guard let recordID = alert.payload["record_id"] else { return false }
                return wishlistIDs.contains(recordID)
            }

            var snapshots: [WishlistPriceAlertSnapshot] = []
            for alert in wishlistAlerts.prefix(3) {
                let recordID = alert.payload["record_id"] ?? ""
                let coverArtFileName: String?
                if let record = recordsByID[recordID] {
                    coverArtFileName = await saveWidgetCoverArt(for: record)
                } else {
                    coverArtFileName = nil
                }
                snapshots.append(
                    WishlistPriceAlertSnapshot(
                        id: alert.id,
                        recordID: recordID,
                        title: alert.title,
                        body: alert.body,
                        priceCents: alert.payload["price_cents"].flatMap(Int.init),
                        currency: alert.payload["currency"],
                        shopName: alert.payload["shop_name"],
                        coverArtFileName: coverArtFileName,
                        createdAt: alert.createdAt
                    )
                )
            }
            WidgetSnapshotStore.saveWishlistPriceAlerts(snapshots)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.priceAlertWidgetKind)
        } catch {
            Log.error(error, category: "notifications.widget")
        }
    }

    private func saveWidgetCoverArt(for record: WidgetWishlistRecord) async -> String? {
        if let data = try? Data(contentsOf: CoverArtCache.localFile(for: record.id)) {
            return WidgetSnapshotStore.saveCoverArt(data, recordID: record.id)
        }

        let remoteURL: URL? = {
            if let path = record.coverArtStoragePath {
                return CoverArtCache.publicStorageURL(path: path)
            }
            return record.coverArtSourceURL.flatMap(URL.init(string:))
        }()
        guard let remoteURL else { return nil }

        do {
            var request = URLRequest(url: remoteURL)
            request.setValue("DeadWaxClub/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return WidgetSnapshotStore.saveCoverArt(data, recordID: record.id)
        } catch {
            Log.error(error, category: "notifications.widgetCover")
            return nil
        }
    }
}

private struct WidgetWishlistRecord {
    var id: String
    var coverArtStoragePath: String?
    var coverArtSourceURL: String?
}
