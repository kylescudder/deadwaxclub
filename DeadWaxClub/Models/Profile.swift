import Foundation

struct Profile: Identifiable, Hashable {
    let id: String
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
}

extension Profile {
    static func from(row: [String: Any]) -> Profile? {
        guard let id = row["id"] as? String else { return nil }
        return Profile(
            id: id,
            displayName: row["display_name"] as? String,
            createdAt: parseDate(row["created_at"]) ?? Date(),
            updatedAt: parseDate(row["updated_at"]) ?? Date()
        )
    }
}
