# Shared site

Every iOS app has an Astro marketing, support and legal site in `Site/`, served
by Caddy on Herman. The sites share one layout, tooling, image and workflows,
and the files in `shared-site.sha256` are byte-for-byte identical in every app.
`Site/Caddyfile` and `Site/compose.yaml` may differ only in the app's `token`
and `repository` from `Site/app.json`, which the check normalizes. Run
`sh Scripts/check-shared-site.sh`; site CI runs the same check.

To change a shared file, make the same edit in every app, run
`sh Scripts/check-shared-site.sh --write` in one of them, copy the changed files
and the manifest to the others, compare them, and run every app's site checks
and end-to-end tests. Never fork a shared file to fit one app: put the
app-specific part behind one of the app hooks below instead.

## Layout

```text
Site/
  app.json                  app hook: name, token, origin, pages (below)
  app.caddy                 app hook: extra Caddy headers and rewrites (may be only a comment)
  Caddyfile                 shared; imports app.caddy
  Dockerfile                shared; Bun build stage, read-only Caddy runtime on :8080
  compose.yaml              shared; the production container settings CI smoke-tests
  astro.config.mjs, tsconfig.json, playwright.config.ts           shared
  .prettierrc.mjs, .prettierignore, eslint.config.js, CONTRIBUTING.md, .husky/   shared house tooling
  package.json, bun.lock    same scripts and devDependencies in every app; only `name` differs
  README.md                 same sections in every app
  scripts/check-site.mjs    shared; checks the built site against app.json
  scripts/write-config.mjs  optional hook (below)
  e2e/site.spec.ts          shared journeys driven by app.json
  e2e/<feature>.spec.ts     app-only journeys
  src/layouts/BaseLayout.astro       shared: document head, Header, page, Footer, global.css
  src/components/DocumentHead.astro  shared: title, description, Open Graph, theme colour, icon
  src/components/LegalArticle.astro  shared: privacy, terms and support article wrapper
  src/components/Header.astro        app: site navigation
  src/components/Footer.astro        app: site footer
  src/components/Home*.astro         app: one component per home page section
  src/pages/                         app: index, privacy, terms, plus support or app-only pages
  src/styles/global.css              app: the whole site's styles and brand
  public/assets/                     app: icon, screenshots, badges
  public/.well-known/apple-app-site-association   optional: universal links
```

Every page uses `BaseLayout` and passes a `bodyClass` (`home-page`,
`legal-page`, or one for an app-only page) for page-level styles. Privacy,
terms and support copy goes in `LegalArticle`. A page served at many URLs, such
as a share link viewer, passes `canonical={false}` so it has no `og:url`.

## App hooks

- `Site/app.json`:
  - `name`: the display name, shown above legal page titles.
  - `token`: the app's deploy-core prefix. The site reports its commit in
    `X-<token>-Revision`, and deploy requests use `X-<token>-Signature` and
    expect `x-<token>-deploy-hook` back.
  - `repository`: the GitHub repository name. The image is
    `ghcr.io/kylescudder/<repository>-site`, the deploy hook is
    `https://$DEPLOY_HOST/hooks/<repository>`, and `compose.yaml` names the
    service after it.
  - `origin`: the public origin used for `og:url`.
  - `themeColor`, `icon`: browser chrome colour and favicon (PNG or SVG under
    `public/`).
  - `contact`: the support address. Privacy, terms and support must link to it.
  - `support`: where the app's support link goes, either a page (`/support`)
    or a home page section (`/#support`).
  - `pages`: every built page and text its HTML must contain. `/`, `/privacy`,
    `/terms` and the support page are required, because the app and its App
    Store listing link to them. CI requests each one with and without a
    trailing slash.
  - `routes`: paths served only by a Caddy rewrite in `app.caddy`, with text
    their response must contain.
  - `appLinks` (with an association file): the `appIDs` and `paths` that
    `public/.well-known/apple-app-site-association` must list. Caddy serves it
    as `application/json`.
- `Site/app.caddy`: headers and rewrites for app-only routes, imported inside
  the site block, such as `rewrite /l/* /l/index.html`.
- `Site/scripts/write-config.mjs` (optional): for pages that call the app's API
  from the browser. It writes `public/js/config.js` (git-ignored) from
  `API_URL` before the build. CI uses `https://api.invalid`; releases use the
  `API_BASE_URL` repository variable and fail without it.
- Header, Footer, Home sections, pages, `global.css` and `public/` are the
  app's own.

## Checks and release

- `bun run typecheck`, `lint`, `format:check`, `build`, `check:site` and
  `test:e2e` in `Site/`. `check:site` reads `app.json` and checks every page's
  content, `og:url`, assets and contact links, plus `js/config.js` and the
  Apple association when the app has them.
- `ci-site.yml` runs the shared check, the site checks in the pinned Bun image,
  then builds the production image and smoke-tests it under `compose.yaml`:
  revision header, cache headers, 404s, every page and route, and the
  association's content type. `e2e.yml` runs the Playwright tests.
- `release-site.yml` repeats CI, builds an attested multi-architecture image,
  and asks the app's deploy-core receiver at `DEPLOY_HOST` to deploy that
  digest. It then waits for `SITE_BASE_URL` to report the commit.
- Settings: repository variables `DEPLOY_HOST` and `SITE_BASE_URL` (and
  `API_BASE_URL` with the write-config hook); `production` environment secrets
  `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` and `DEPLOY_WEBHOOK_SECRET`.

## Adding an app's site

Copy every file in this manifest from an existing app, then write the app
hooks, Header, Footer, Home sections, pages, `global.css` and assets. Copy
`package.json` with its `name` changed to `<repository>-site` and run
`bun install`. Set the GitHub settings above, and make sure the check passes
before the first pull request.
