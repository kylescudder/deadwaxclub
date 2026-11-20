// Checks the built site before it is packaged: pages, assets, the list viewer
// configuration and the Apple app-site association used by universal links.
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const root = 'dist'
const origin = 'https://deadwaxclub.app'

for (const [path, content] of [
  ['index.html', 'Support for Deadwax Club'],
  ['privacy/index.html', 'Privacy Policy'],
  ['terms/index.html', 'Terms of Use'],
  ['l/index.html', '/js/list.js']
]) {
  const html = readFileSync(join(root, path), 'utf8')
  assert(html.includes(content), `Missing content: ${path}`)
  if (path !== 'l/index.html') {
    assert(html.includes(`content="${origin}`), `Wrong origin: ${path}`)
  }
  const assets = [
    ...html.matchAll(/(?:src|href)="(\/(?:_astro|assets|js)\/[^"?#]+)"/g)
  ]
  assert(assets.length > 0, `Missing assets: ${path}`)
  for (const [, asset] of assets) {
    assert(existsSync(join(root, asset)), `Missing asset: ${asset}`)
  }
}

const config = readFileSync(join(root, 'js/config.js'), 'utf8')
assert.match(config, /"supabaseUrl": "https:\/\/[^"]+"/, 'Missing Supabase URL')
assert.match(config, /"supabaseAnonKey": "[^"]*"/, 'Missing anon key field')

const association = JSON.parse(
  readFileSync(join(root, '.well-known/apple-app-site-association'), 'utf8')
)
assert.deepEqual(association.applinks.details[0].appIDs, [
  '6AAGJ9Y234.com.deadwaxclub.app'
])
assert.deepEqual(association.applinks.details[0].components[0]['/'], '/l/*')

console.log('Pages, assets, list viewer config and Apple association verified.')
