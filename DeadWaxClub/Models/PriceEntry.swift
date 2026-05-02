import Foundation
import PowerSync

struct PriceEntry: Identifiable, Hashable {
    let id: String
    var recordID: String
    var ownerID: String
    var priceCents: Int
    var currency: String
    var shopName: String?
    var scannedAt: Date
    var createdAt: Date

    var priceMajor: Decimal { Decimal(priceCents) / 100 }
}

extension PriceEntry {
    static func from(cursor: SqlCursor) -> PriceEntry? {
        do {
            return PriceEntry(
                id: try cursor.getString(name: "id"),
                recordID: try cursor.getString(name: "record_id"),
                ownerID: try cursor.getString(name: "owner_id"),
                priceCents: try cursor.getInt(name: "price_cents"),
                currency: try cursor.getString(name: "currency"),
                shopName: try cursor.getStringOptional(name: "shop_name"),
                scannedAt: parseDate(try cursor.getStringOptional(name: "scanned_at")) ?? Date(),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date()
            )
        } catch {
            return nil
        }
    }
}
