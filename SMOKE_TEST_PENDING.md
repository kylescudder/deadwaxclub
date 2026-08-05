# Smoke test — pending items

Captured at the end of the self-hosted infra smoke test on the
`claude/smoke-test-auth-sync-R7nPK` branch. Everything in this file is either
blocked on hardware/setup that wasn't available during the test, or is an open
architectural question. Confirmed bugs are tracked as separate GitHub issues
(#13–#21).

## Needs a real device

The iOS Simulator doesn't expose these subsystems.

- [ ] **Barcode scan (VisionKit)** — point at a sleeve in a shop, confirm
  Discogs lookup populates title/artist/year/colourway
- [ ] **Spotlight search** — search a record title in Spotlight on a real
  device, confirm the result tap deep-links into the app
- [ ] **"Hey Siri, log a price in Deadwax Club"** — full conversational flow
  (also blocked by #16)
- [ ] **Universal link from Messages** — tap `https://deadwaxclub.app/l/<token>`
  from a Messages thread, confirm it opens the app rather than Safari
  (also blocked by #17)

## Needs a second simulator / device

- [ ] **Two-device sync** — sign in on a second simulator with the same
  account, confirm records replicate down on initial sync

## Needs Network Link Conditioner or airplane mode

- [ ] **Offline + reconnect** — kill the network, add a record, restore the
  network, confirm PowerSync drains its CRUD queue and the row lands in
  Postgres

## Open architectural question

- [ ] **`record_images` and `list_items` have no `deleted_at` column** despite
  CLAUDE.md's "all deletions are soft" rule. Is this intentional (these are
  children of soft-deletable parents, so they go away with the parent) or an
  oversight that should be fixed by adding `deleted_at` + migrations + sync
  rule updates? If intentional, worth a paragraph in CLAUDE.md noting the
  exception so it doesn't trip up the next person.

## Verification still owed (known-bug repro)

- [ ] **Stats first-load spinner (#14)** — repro on a fresh sign-in after the
  recent changes, confirm the bug is still live before debugging it

## Deferred (separate stack)

- [ ] **ets2** — restore the missing `kong` + `functions` containers on the
  ets2 deployment
- [ ] **ets2** — Postgres 15 → 17 upgrade
