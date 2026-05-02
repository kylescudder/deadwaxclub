import Foundation

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
    static func from(row: [String: Any]) -> PriceEntry? {
        guard let id = row["id"] as? String,
              let recordID = row["record_id"] as? String,
              let ownerID = row["owner_id"] as? String,
              let priceCents = row["price_cents"] as? Int,
              let currency = row["currency"] as? String else {
            return nil
        }
        return PriceEntry(
            id: id,
            recordID: recordID,
            ownerID: ownerID,
            priceCents: priceCents,
            currency: currency,
            shopName: row["shop_name"] as? String,
            scannedAt: parseDate(row["scanned_at"]) ?? Date(),
            createdAt: parseDate(row["created_at"]) ?? Date()
        )
    }
}
