import Foundation
import PowerSync

enum ListShareMode: String, CaseIterable, Codable, Identifiable {
    case `private` = "private"
    case linkPublic = "link_public"
    case invite
    case collaborative

    var id: String { rawValue }

    var label: String {
        switch self {
        case .private:       return "Private"
        case .linkPublic:    return "Public link"
        case .invite:        return "Invite-only"
        case .collaborative: return "Collaborative"
        }
    }

    var detail: String {
        switch self {
        case .private:       return "Only you can see this list."
        case .linkPublic:    return "Anyone with the link can view."
        case .invite:        return "Only people you invite can view; editors can add."
        case .collaborative: return "Everyone you invite can view and add."
        }
    }

    var systemImage: String {
        switch self {
        case .private:       return "lock"
        case .linkPublic:    return "link"
        case .invite:        return "envelope"
        case .collaborative: return "person.2"
        }
    }
}

enum ListMemberRole: String, Codable {
    case viewer, editor
}

struct VinylList: Identifiable, Hashable {
    let id: String
    var ownerID: String
    var name: String
    var description: String?
    var shareMode: ListShareMode
    var shareToken: String?
    var coverRecordID: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

extension VinylList {
    static func from(cursor: SqlCursor) -> VinylList? {
        do {
            let modeRaw = try cursor.getString(name: "share_mode")
            guard let mode = ListShareMode(rawValue: modeRaw) else { return nil }
            return VinylList(
                id: try cursor.getString(name: "id"),
                ownerID: try cursor.getString(name: "owner_id"),
                name: try cursor.getString(name: "name"),
                description: try cursor.getStringOptional(name: "description"),
                shareMode: mode,
                shareToken: try cursor.getStringOptional(name: "share_token"),
                coverRecordID: try cursor.getStringOptional(name: "cover_record_id"),
                createdAt: parseDate(try cursor.getStringOptional(name: "created_at")) ?? Date(),
                updatedAt: parseDate(try cursor.getStringOptional(name: "updated_at")) ?? Date(),
                deletedAt: parseDate(try cursor.getStringOptional(name: "deleted_at"))
            )
        } catch {
            return nil
        }
    }
}

struct VinylListItem: Identifiable, Hashable {
    let id: String
    var listID: String
    var recordID: String
    var addedBy: String
    var position: Int
    var createdAt: Date
}

struct VinylListMember: Identifiable, Hashable {
    var id: String { "\(listID)/\(userID)" }
    var listID: String
    var userID: String
    var role: ListMemberRole
    var joinedAt: Date
}

struct PendingInvite: Identifiable, Hashable {
    let id: String
    var listID: String
    var email: String
    var role: ListMemberRole
    var invitedBy: String
    var createdAt: Date
    var acceptedAt: Date?
}

extension PendingInvite {
    static func from(cursor: SqlCursor) -> PendingInvite? {
        do {
            let roleRaw = try cursor.getString(name: "role")
            guard let role = ListMemberRole(rawValue: roleRaw) else { return nil }
            return PendingInvite(
                id: try cursor.getString(name: "id"),
                listID: try cursor.getString(name: "list_id"),
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
