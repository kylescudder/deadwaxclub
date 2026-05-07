import Foundation
import PowerSync

enum NotificationKind: String, Codable {
    case priceAlert = "price_alert"
    case collectionInvite = "collection_invite"
}

struct InboxNotification: Identifiable, Hashable {
    let id: String
    var userID: String
    var kind: NotificationKind
    var title: String
    var body: String
    var payload: [String: String]
    var readAt: Date?
    var createdAt: Date

    var isRead: Bool { readAt != nil }
}

extension InboxNotification {
    static func from(cursor: SqlCursor) -> InboxNotification? {
        do {
            let kindRaw = try cursor.getString(name: "kind")
            guard let kind = NotificationKind(rawValue: kindRaw) else { return nil }
            let payloadJSON = try cursor.getStringOptional(name: "payload") ?? "{}"
            return InboxNotification(
                id: try cursor.getString(name: "id"),
                userID: try cursor.getString(name: "user_id"),
                kind: kind,
                title: try cursor.getString(name: "title"),
                body: try cursor.getString(name: "body"),
                payload: parsePayload(payloadJSON),
                readAt: parseDate(try cursor.getStringOptional(name: "read_at")),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date()
            )
        } catch {
            return nil
        }
    }

    private static func parsePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }
}
