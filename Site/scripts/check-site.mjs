// Checks the built site before it is packaged. Shared by every app's site
// (Scripts/SHARED_SITE.md); the pages, contact address and Apple app links come
// from app.json.
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const app = JSON.parse(readFileSync('app.json', 'utf8'))
const root = 'dist'
const read = (path) => readFileSync(join(root, path, 'index.html'), 'utf8')

// The app and its App Store listing link to these pages.
const [supportPage] = app.support.split('#')
const linked = ['/', '/privacy', '/terms', supportPage]
for (const path of linked) {
  assert(path in app.pages, `app.json pages must include ${path}`)
}

for (const [path, content] of Object.entries(app.pages)) {
  const html = read(path)
  assert(html.includes(content), `Missing content: ${path}`)
  const ogUrl = html.match(/<meta property="og:url" content="([^"]*)"/)?.[1]
  if (linked.includes(path)) {
    assert.equal(ogUrl, new URL(path, app.origin).href, `Wrong og:url: ${path}`)
  }
  const assets = [
    ...html.matchAll(/(?:src|href)="(\/(?:_astro|assets|js)\/[^"?#]+)"/g)
  ]
  assert(assets.length > 0, `Missing assets: ${path}`)
  for (const [, asset] of assets) {
    assert(existsSync(join(root, asset)), `Missing asset: ${asset}`)
  }
}

for (const path of ['/privacy', '/terms', supportPage]) {
  assert(
    read(path).includes(`mailto:${app.contact}`),
    `Missing contact: ${path}`
  )
}

// Optional hook: pages that call the app's API read js/config.js.
if (existsSync('scripts/write-config.mjs')) {
  const config = readFileSync(join(root, 'js/config.js'), 'utf8')
  assert.match(config, /"apiUrl": "https:\/\/[^"]+"/, 'Missing API URL')
}

// Universal links: the association names exactly the app IDs and paths in app.json.
const association = join(root, '.well-known/apple-app-site-association')
if (app.appLinks || existsSync(association)) {
  const { details } = JSON.parse(readFileSync(association, 'utf8')).applinks
  assert.deepEqual(
    details.flatMap((detail) => detail.appIDs),
    app.appLinks.appIDs
  )
  assert.deepEqual(
    details.flatMap((detail) => detail.components.map((c) => c['/'])),
    app.appLinks.paths
  )
}

console.log(`${app.name}: pages, contact links, assets and app links verified.`)
