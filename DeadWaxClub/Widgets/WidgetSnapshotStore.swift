import Foundation

struct WishlistPriceAlertSnapshot: Codable, Hashable {
    var id: String
    var recordID: String
    var title: String
    var body: String
    var priceCents: Int?
    var currency: String?
    var shopName: String?
    var coverArtFileName: String?
    var createdAt: Date
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.com.deadwaxclub.app"
    static let priceAlertWidgetKind = "DeadWaxClubWishlistPriceWidget"

    private static let wishlistPriceAlertKey = "dwc.widget.wishlistPriceAlert"
    private static let wishlistPriceAlertsKey = "dwc.widget.wishlistPriceAlerts"

    static func wishlistPriceAlert() -> WishlistPriceAlertSnapshot? {
        wishlistPriceAlerts().first
    }

    static func wishlistPriceAlerts() -> [WishlistPriceAlertSnapshot] {
        if let snapshots = AppGroupStore.load([WishlistPriceAlertSnapshot].self, forKey: wishlistPriceAlertsKey) {
            return snapshots
        }
        guard let snapshot = AppGroupStore.load(WishlistPriceAlertSnapshot.self, forKey: wishlistPriceAlertKey) else { return [] }
        return [snapshot]
    }

    static func saveWishlistPriceAlert(_ snapshot: WishlistPriceAlertSnapshot?) {
        saveWishlistPriceAlerts(snapshot.map { [$0] } ?? [])
    }

    static func saveWishlistPriceAlerts(_ snapshots: [WishlistPriceAlertSnapshot]) {
        AppGroupStore.remove(forKey: wishlistPriceAlertKey)
        if !snapshots.isEmpty, let data = try? JSONEncoder().encode(snapshots) {
            AppGroupStore.defaults.set(data, forKey: wishlistPriceAlertsKey)
        } else {
            AppGroupStore.remove(forKey: wishlistPriceAlertKey)
            AppGroupStore.remove(forKey: wishlistPriceAlertsKey)
        }
    }

    static func saveCoverArt(_ data: Data, recordID: String) -> String? {
        let fileName = "\(recordID).jpg"
        guard let url = coverArtFileURL(fileName: fileName) else { return nil }
        do {
            try FileManager.default.createDirectory(at: coverArtDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func coverArtFileURL(fileName: String) -> URL? {
        coverArtDirectory.appendingPathComponent(fileName)
    }

    private static var coverArtDirectory: URL {
        AppGroupStore.containerURL.appendingPathComponent("WidgetCovers", isDirectory: true)
    }
}
