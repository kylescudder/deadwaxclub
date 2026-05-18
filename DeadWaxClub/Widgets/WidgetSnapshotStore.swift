import Foundation

struct WishlistPriceAlertSnapshot: Codable, Hashable {
    var id: String
    var recordID: String
    var title: String
    var body: String
    var priceCents: Int?
    var currency: String?
    var shopName: String?
    var createdAt: Date
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.com.deadwaxclub.app"
    static let priceAlertWidgetKind = "DeadWaxClubWishlistPriceWidget"

    private static let wishlistPriceAlertKey = "dwc.widget.wishlistPriceAlert"

    static func wishlistPriceAlert() -> WishlistPriceAlertSnapshot? {
        guard let data = defaults.data(forKey: wishlistPriceAlertKey) else { return nil }
        return try? JSONDecoder().decode(WishlistPriceAlertSnapshot.self, from: data)
    }

    static func saveWishlistPriceAlert(_ snapshot: WishlistPriceAlertSnapshot?) {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: wishlistPriceAlertKey)
        } else {
            defaults.removeObject(forKey: wishlistPriceAlertKey)
        }
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}
