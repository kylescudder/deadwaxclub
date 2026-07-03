# Deadwax Club web

A small static site that renders public-link share lists (`https://deadwaxclub.app/l/<token>`) and serves as a landing page. Pure HTML / CSS / vanilla JS — no build step, no framework.

```
web/
├── index.html         landing page
├── l/index.html       public list viewer (any /l/<token> URL)
├── landing.css        promotional landing page theme
├── styles.css         shared legal/list theme — CSS variables match the iOS app
├── js/
│   ├── list.js        fetches via Supabase REST RPCs and renders the list
│   └── config.example.js   template for Supabase URL + anon key
├── .well-known/
│   └── apple-app-site-association   Universal Links manifest (template)
└── _redirects         Netlify rewrite for /l/<token> → l/index.html
```

Run the static site locally from the repo root:

```sh
npm run site
```

## Deploying to Netlify

```sh
cp web/js/config.example.js web/js/config.js
# edit web/js/config.js and paste your Supabase URL + anon key
```

Then either:

- **Drag-and-drop** the `web/` folder into [app.netlify.com/drop](https://app.netlify.com/drop), or
- Connect the repo to Netlify. The root-level `netlify.toml` already sets `publish = "web"` and configures the AASA `Content-Type` header.

```sh
# CLI alternative
npx netlify deploy --dir=web --prod
```

## Universal Links

Edit `web/.well-known/apple-app-site-association` and replace `TEAMID.com.deadwaxclub.app` with your real Apple Team ID + bundle identifier (e.g. `ABCDE12345.com.deadwaxclub.app`). Netlify serves the file with the correct `application/json` content type via `netlify.toml`. Verify with:

```sh
curl -i https://deadwaxclub.app/.well-known/apple-app-site-association
```

## How it works

The list viewer hits two unauthenticated Postgres RPCs that ship in `supabase/migrations/0004_lists.sql`:

- `get_shared_list(token)` — list metadata + owner display name
- `get_shared_list_records(token)` — record rows in display order

Both are `security definer` and only return data for lists in `link_public` mode, so making a list private immediately revokes web access without requiring a redeploy. Cover art is read from the same public Supabase Storage `covers` bucket the iOS app populates, so no Discogs round-trips happen on the web.

The Supabase anon key is safe to ship in the browser; RLS + the RPCs only expose explicitly shared data.
