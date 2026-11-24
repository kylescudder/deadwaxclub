import Foundation
import PowerSync

struct VinylCollection: Identifiable, Hashable {
    let id: String
    var name: String
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

extension VinylCollection {
    static func from(cursor: SqlCursor) -> VinylCollection? {
        do {
            return VinylCollection(
                id: try cursor.getString(name: "id"),
                name: try cursor.getString(name: "name"),
                createdBy: try cursor.getString(name: "created_by"),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date(),
                updatedAt: parseDate(try cursor.getStringOptional(name: "updated_at")) ?? Date(),
                deletedAt: parseDate(try cursor.getStringOptional(name: "deleted_at"))
            )
        } catch {
            return nil
        }
    }
}
