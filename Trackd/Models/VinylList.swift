import Foundation

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
    static func from(row: [String: Any]) -> VinylList? {
        guard let id = row["id"] as? String,
              let ownerID = row["owner_id"] as? String,
              let name = row["name"] as? String,
              let modeRaw = row["share_mode"] as? String,
              let mode = ListShareMode(rawValue: modeRaw) else {
            return nil
        }
        return VinylList(
            id: id,
            ownerID: ownerID,
            name: name,
            description: row["description"] as? String,
            shareMode: mode,
            shareToken: row["share_token"] as? String,
            coverRecordID: row["cover_record_id"] as? String,
            createdAt: parseDate(row["created_at"]) ?? Date(),
            updatedAt: parseDate(row["updated_at"]) ?? Date(),
            deletedAt: parseDate(row["deleted_at"])
        )
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
