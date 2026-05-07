import Foundation
import PowerSync

enum CollectionMemberRole: String, Codable {
    case owner, editor, viewer

    var label: String {
        switch self {
        case .owner:  return "Owner"
        case .editor: return "Editor"
        case .viewer: return "Viewer"
        }
    }
}

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

struct CollectionMember: Identifiable, Hashable {
    var id: String { "\(collectionID)/\(userID)" }
    var collectionID: String
    var userID: String
    var role: CollectionMemberRole
    var invitedBy: String?
    var joinedAt: Date
}

extension CollectionMember {
    static func from(cursor: SqlCursor) -> CollectionMember? {
        do {
            let roleRaw = try cursor.getString(name: "role")
            guard let role = CollectionMemberRole(rawValue: roleRaw) else { return nil }
            return CollectionMember(
                collectionID: try cursor.getString(name: "collection_id"),
                userID: try cursor.getString(name: "user_id"),
                role: role,
                invitedBy: try cursor.getStringOptional(name: "invited_by"),
                joinedAt: parseDate(try cursor.getStringOptional(name: "joined_at")) ?? Date()
            )
        } catch {
            return nil
        }
    }
}

struct CollectionPendingInvite: Identifiable, Hashable {
    let id: String
    var collectionID: String
    var email: String
    var role: CollectionMemberRole
    var invitedBy: String
    var createdAt: Date
    var acceptedAt: Date?
}

extension CollectionPendingInvite {
    static func from(cursor: SqlCursor) -> CollectionPendingInvite? {
        do {
            let roleRaw = try cursor.getString(name: "role")
            guard let role = CollectionMemberRole(rawValue: roleRaw) else { return nil }
            return CollectionPendingInvite(
                id: try cursor.getString(name: "id"),
                collectionID: try cursor.getString(name: "collection_id"),
                email: try cursor.getString(name: "email"),
                role: role,
                invitedBy: try cursor.getString(name: "invited_by"),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date(),
                acceptedAt: parseDate(try cursor.getStringOptional(name: "accepted_at"))
            )
        } catch {
            return nil
        }
    }
}
