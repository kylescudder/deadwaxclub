import Foundation
import PowerSync

/// A member's access to a shared space. Owners manage membership; editors
/// change the shared data; viewers only read it.
enum ShareRole: String, Codable, CaseIterable, Comparable, Sendable {
    case viewer, editor, owner

    /// Roles an owner can hand out. Ownership never transfers by invite.
    static let invitable: [ShareRole] = [.editor, .viewer]

    var label: String {
        switch self {
        case .owner: return "Owner"
        case .editor: return "Editor"
        case .viewer: return "Viewer"
        }
    }

    var canEdit: Bool { self != .viewer }

    private var rank: Int {
        switch self {
        case .viewer: return 0
        case .editor: return 1
        case .owner: return 2
        }
    }

    static func < (lhs: ShareRole, rhs: ShareRole) -> Bool { lhs.rank < rhs.rank }
}

/// One API call of the sharing contract: the path and the JSON keys its
/// values are sent under, in the order the shared repository passes them.
struct SharingEndpoint: Hashable, Sendable {
    let path: String
    let keys: [String]

    func body(_ values: [String]) -> [String: String] {
        precondition(values.count == keys.count, "\(path) expects \(keys.count) values")
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
    }
}

/// The wording `ShareMembersSections` uses for one space.
struct SharingCopy: Hashable, Sendable {
    /// Where an added member lands, as in "Added name@example.com to <destination>."
    let destination: String
    /// Footer under the pending invites.
    let pendingFooter: String
    /// Footer under the invite form.
    let inviteFooter: String
}

/// Something people can be invited into: one row per member in `membersTable`
/// and one row per unanswered email invite in `invitesTable`, both keyed by
/// `spaceColumn`. Both tables sync read-only; membership changes go through
/// the API endpoints below. The app declares its spaces in
/// `SharingAppConfiguration.swift`.
///
/// Members table columns: `<spaceColumn>, user_id, role, invited_by, joined_at`.
/// Invites table columns: `<spaceColumn>, email, role, invited_by, created_at, accepted_at`.
struct SharingSpace: Hashable, Sendable {
    /// Short name for logs and Sentry categories.
    let name: String
    let membersTable: String
    let invitesTable: String
    let spaceColumn: String
    /// Values: space ID, email, role. Responds `{"status": "added" | "pending"}`.
    let invite: SharingEndpoint
    /// Values: space ID, user ID. Owners remove others; anyone but the owner removes themselves.
    let removeMember: SharingEndpoint
    /// Values: invite ID.
    let revokeInvite: SharingEndpoint
    /// Values: space ID. Responds `[{"id": …, "display_name": …}]` for every member.
    let memberProfiles: SharingEndpoint
    let copy: SharingCopy
}

enum ShareInviteOutcome: Equatable, Sendable {
    /// The email belongs to an account, which is now a member.
    case added
    /// No account yet; the invite is kept and accepted when they sign up with that email.
    case pending
}

enum SharingError: LocalizedError, Equatable {
    case signedOut
    case invalidEmail
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in again to change who this is shared with."
        case .invalidEmail: return "Enter the email address they use to sign in."
        case let .unexpectedResponse(status): return "Unexpected invite response: \(status)"
        }
    }
}

struct ShareMember: Identifiable, Hashable, Sendable {
    var id: String { "\(spaceID)/\(userID)" }
    let spaceID: String
    let userID: String
    let role: ShareRole
    let invitedBy: String?
    let joinedAt: Date

    static func from(cursor: SqlCursor, spaceColumn: String) -> ShareMember? {
        do {
            guard let role = ShareRole(rawValue: try cursor.getString(name: "role")) else { return nil }
            return ShareMember(
                spaceID: try cursor.getString(name: spaceColumn),
                userID: try cursor.getString(name: "user_id"),
                role: role,
                invitedBy: try cursor.getStringOptional(name: "invited_by"),
                joinedAt: sharingDate(try cursor.getStringOptional(name: "joined_at")) ?? Date()
            )
        } catch {
            return nil
        }
    }
}

struct SharePendingInvite: Identifiable, Hashable, Sendable {
    let id: String
    let spaceID: String
    let email: String
    let role: ShareRole
    let invitedBy: String
    let createdAt: Date
    let acceptedAt: Date?

    static func from(cursor: SqlCursor, spaceColumn: String) -> SharePendingInvite? {
        do {
            guard let role = ShareRole(rawValue: try cursor.getString(name: "role")) else { return nil }
            return SharePendingInvite(
                id: try cursor.getString(name: "id"),
                spaceID: try cursor.getString(name: spaceColumn),
                email: try cursor.getString(name: "email"),
                role: role,
                invitedBy: try cursor.getString(name: "invited_by"),
                createdAt: sharingDate(try cursor.getStringOptional(name: "created_at")) ?? Date(),
                acceptedAt: sharingDate(try cursor.getStringOptional(name: "accepted_at"))
            )
        } catch {
            return nil
        }
    }
}

struct ShareMemberProfile: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// PowerSync stores timestamps as ISO 8601 text, with or without fractional
/// seconds, and with either a `T` or a space between date and time.
func sharingDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let normalized = value.replacingOccurrences(of: " ", with: "T")
    for options: ISO8601DateFormatter.Options in [
        [.withInternetDateTime, .withFractionalSeconds],
        [.withInternetDateTime],
    ] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        if let date = formatter.date(from: normalized) { return date }
    }
    return nil
}
