# Shared sharing core

Apps that let people share their data with other accounts use one sharing
core: the same models, repository, member screen and tests. The files in
`shared-sharing-core.sha256` are byte-for-byte identical in every app that has
them. `@APP@` in that manifest is the `name:` from `project.yml`. Run
`sh Scripts/check-shared-sharing-core.sh`; iOS CI runs it whenever the script
is present. An app that doesn't share anything leaves out this manifest, its
script and these files.

To change a shared file, make the same edit in every app that has the core,
run `sh Scripts/check-shared-sharing-core.sh --write` in one of them, copy the
changed files and the manifest to the others, compare them, and run every
such app's iOS build and tests.

## Files

```text
<App>/Sharing/SharingModels.swift        ShareRole, SharingSpace, SharingEndpoint, SharingCopy, ShareMember, SharePendingInvite, ShareMemberProfile
<App>/Sharing/SharingRepository.swift    watches one space kind's members and invites; invite, remove, leave, revoke, member names
<App>/Sharing/ShareMembersSections.swift Members, Pending invites and Invite by email sections for a Form
<App>/Sharing/SharingInbox.swift         invites sent to the account across every space; ShareInvitesSection and ShareInvitesView
<App>Tests/SharedSharingTests.swift      the rules below, run against every space the app declares
```

## Model

A **space** is something people are invited into: a collection, a trip, or
everything one account owns. The app declares each kind as a `SharingSpace`
in its hook, `Sharing/SharingAppConfiguration.swift`, and lists them in
`SharingAppConfiguration.spaces`. Each space kind has:

- A members table, synced read-only, with columns
  `<spaceColumn>, user_id, role, invited_by, joined_at`. Its composite key is
  synthesised as `id = <space>:<user>` in the sync stream.
- An invites table, synced read-only, with columns
  `id, <spaceColumn>, email, role, invited_by, created_at, accepted_at`.
- Seven endpoints. The repository passes their values in a fixed order and
  sends them under the endpoint's `keys`, so each app keeps its own API:
  - `invite`: space ID, email, role. Responds `{"status": "pending"}`.
  - `removeMember`: space ID, user ID.
  - `revokeInvite`: invite ID.
  - `memberProfiles`: space ID. Responds `[{"id", "display_name"}]`.
  - `incoming`: no values. Responds the open invites sent to the caller's
    verified email: `[{"id", "space_id", "space_name", "inviter_name", "role", "created_at"}]`.
  - `accept`: invite ID. Makes the caller a member with the invite's role.
  - `decline`: invite ID.
- The wording `ShareMembersSections` shows (`SharingCopy`).

## Rules

- Roles are `owner`, `editor` and `viewer`. Every space has exactly one owner
  row; invites hand out only `editor` or `viewer`. Owners and editors change
  the shared data; viewers only read it.
- Membership never changes locally. Both tables stay out of the writable
  allowlist, and every change goes through the API with the signed-in owner's
  token. Without that session nothing is sent.
- A member sees every member of each space they belong to. Owners see the
  remove buttons and the invite form; members can leave.
- Inviting never adds anyone. Every invite is pending; the server emails the
  invitee a link to the app's invites page (the shared `invite` email kind,
  `invitesURL` in `auth-app.ts`), and they accept or decline it in the app.
  Only a signed-in account whose verified email matches the invite can see,
  accept or decline it, so a forwarded email or a leaked invite ID gives
  nothing away. Signing up never joins anything by itself.
- Incoming invites come from the API, not the sync stream, because the
  invitee can't see the space until they accept. `SharingInbox` merges every
  space's invites; apps show `ShareInvitesSection` where people look for
  shared things and present `ShareInvitesView` when the invite link
  (`<origin>/invites`, a universal link) or an invite notification opens the
  app.
- The server enforces every rule. The app's checks only decide what the UI
  offers.

The app keeps its spaces, schema tables, sync streams, endpoints, error
messages and its own screens around `ShareMembersSections` in its own files.
