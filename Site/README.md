# Deadwax Club site

The static Astro home, privacy and terms pages and the public list viewer for
the Deadwax Club iOS app. Public hostname: **deadwaxclub.app**.

## Development

Use Bun 1.4.4. From `Site/`, install the committed dependencies with
`bun install --frozen-lockfile`. This also installs the pre-commit hook. The
list viewer reads `public/js/config.js` (git-ignored): copy
`public/js/config.example.js` to `public/js/config.js` and set the Deadwax API
origin.

```sh
bun run dev
```

Open **http://localhost:4321**.

## Checks

See [CONTRIBUTING.md](CONTRIBUTING.md). Before opening a pull request, run:

```sh
bun run typecheck
bun run lint
bun run format:check
bun run build
bun run check:site   # pages, og:url, contact links, assets, list viewer config and Apple association
bun run test:e2e
```

`check:site` needs `public/js/config.js`; CI writes one with
`API_URL=https://api.invalid bun scripts/write-config.mjs`. The app links to
`/privacy`, `/terms` and `/#support`, and share links are `/l/<token>`; keep
those paths working.

## Structure

Every iOS app shares this site's layout, tooling, image and workflows;
[Scripts/SHARED_SITE.md](../Scripts/SHARED_SITE.md) lists the shared files and
the app hooks. Deadwax Club's own files are `app.json`, `app.caddy`, the
header, footer and `Home*` components, the pages, `src/styles/global.css`,
`public/` and the list viewer below.

## Deployment

Merging a change under `Site/` to `main` runs `release-site.yml`: it repeats the
checks, builds an attested AMD64/ARM64 image
(`ghcr.io/kylescudder/deadwaxclub-site`) and asks Herman's deploy-core service
to deploy that digest through `https://$DEPLOY_HOST/hooks/deadwaxclub`. The
image serves `dist/` from an unprivileged, read-only Caddy container on port
8080 and reports the deployed commit in `X-Deadwax-Revision`. Herman checks the
attestation, the pages, assets and Apple association before switching, keeps
the previous image for rollback, and the workflow waits until the public site
reports the new commit. Run the workflow manually to redeploy.

| Setting                                          | Kind                 | Purpose                                                        |
| ------------------------------------------------ | -------------------- | -------------------------------------------------------------- |
| `API_BASE_URL`                                   | repository variable  | Deadwax API origin; the list viewer reads shared lists from it |
| `DEPLOY_HOST`                                    | repository variable  | Herman deploy hostname, protected by Cloudflare Access         |
| `SITE_BASE_URL`                                  | repository variable  | Public origin checked for the new revision                     |
| `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | `production` secrets | Access service token for the deploy hostname                   |
| `DEPLOY_WEBHOOK_SECRET`                          | `production` secret  | HMAC key for deploy requests                                   |

Host setup and recovery are in Herman's platform runbook.

## List viewer

`/l/<token>` is one page, `src/pages/l/index.astro`; `app.caddy` rewrites every
share link to it and `public/js/list.js` reads the token from the URL. The
script calls the API's unauthenticated, token-gated
`/api/public/get_shared_list` and `/api/public/get_shared_list_records`, using
the origin in `js/config.js`, which release builds write with
`scripts/write-config.mjs` from `API_BASE_URL`. Universal links use
`public/.well-known/apple-app-site-association`, which Caddy serves as
`application/json`; its app ID and paths must match `appLinks` in `app.json`.
