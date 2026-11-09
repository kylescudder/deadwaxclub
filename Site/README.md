# Deadwax Club Site

Astro marketing, support and legal site and the public list viewer for Deadwax
Club, served at **https://deadwaxclub.app**.

## Development

Use Bun 1.4.4 and install with `bun install --frozen-lockfile`, which also
installs the pre-commit hook. The list viewer reads `public/js/config.js`: copy
`public/js/config.example.js` to `public/js/config.js` and fill in the Supabase
values, then run `bun run dev`.

## Checks

See [CONTRIBUTING.md](CONTRIBUTING.md). In short:

```sh
bun run typecheck
bun run lint
bun run format:check
bun run build
bun run check:site
```

## Deployment

Merging to `main` builds an attested image (`Dockerfile`, `Caddyfile`) and
deploys it to Herman; see the repository README's Website deployment section.
Release builds write `public/js/config.js` with `scripts/write-config.mjs` from
`SUPABASE_URL` and `SUPABASE_ANON_KEY`.
