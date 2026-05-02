import Foundation
import PowerSync

struct Profile: Identifiable, Hashable {
    let id: String
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
}

extension Profile {
    static func from(cursor: SqlCursor) -> Profile? {
        do {
            return Profile(
                id: try cursor.getString(name: "id"),
                displayName: try cursor.getStringOptional(name: "display_name"),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date(),
                updatedAt: parseDate(try cursor.getStringOptional(name: "updated_at")) ?? Date()
            )
        } catch {
            return nil
        }
    }
}
