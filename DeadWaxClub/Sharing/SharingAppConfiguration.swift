import Foundation

/// Deadwax Club's values for the shared sharing core (`SharingRepository`,
/// `ShareMembersSections`). A Collection is the only shared space; its
/// endpoints are the existing library calls.
enum SharingAppConfiguration {
    static let spaces: [SharingSpace] = [.collection]
}

extension SharingSpace {
    static let collection = SharingSpace(
        name: "collections",
        membersTable: "collection_members",
        invitesTable: "collection_pending_invites",
        spaceColumn: "collection_id",
        invite: SharingEndpoint(path: "api/library/invite_to_collection", keys: ["p_collection_id", "p_email", "p_role"]),
        removeMember: SharingEndpoint(path: "api/library/remove_collection_member", keys: ["parent_id", "user_id"]),
        revokeInvite: SharingEndpoint(path: "api/library/revoke_collection_invite", keys: ["p_invite_id"]),
        memberProfiles: SharingEndpoint(path: "api/library/get_collection_member_profiles", keys: ["p_collection_id"]),
        copy: SharingCopy(
            destination: "the Collection",
            pendingFooter: "Auto-accepted when the invitee signs up with the matching email.",
            inviteFooter: "If they already have an account they're added straight away (and notified). Otherwise we'll save the invite and add them when they sign up."
        )
    )
}
