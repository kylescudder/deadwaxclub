import { test, expect, type Page } from '@playwright/test'

const api = 'https://api.example.test'

// Production serves every /l/<token> from /l/index.html (app.caddy) and writes
// js/config.js at build time; the preview server does neither, so the test does.
async function serveListViewer(
  page: Page,
  list: unknown[],
  records: unknown[]
) {
  await page.route(/\/l\/[^/]+$/, async (route) =>
    route.fulfill({
      response: await route.fetch({
        url: new URL('/l/', route.request().url()).href
      })
    })
  )
  await page.route('**/js/config.js', (route) =>
    route.fulfill({
      contentType: 'text/javascript',
      body: `window.DEADWAXCLUB_CONFIG = { apiUrl: '${api}' }`
    })
  )
  const requests: unknown[] = []
  for (const [name, body] of [
    ['get_shared_list', list],
    ['get_shared_list_records', records]
  ] as const) {
    await page.route(`${api}/api/public/${name}`, (route) => {
      requests.push(route.request().postDataJSON())
      return route.fulfill({
        json: body,
        headers: { 'access-control-allow-origin': '*' }
      })
    })
  }
  return requests
}

test('a shared list link shows its records and opens in the app', async ({
  page
}) => {
  const requests = await serveListViewer(
    page,
    [
      {
        name: 'Desert island discs',
        description: 'Ten records I would take anywhere.',
        owner_display_name: 'Sam'
      }
    ],
    [
      { title: 'Blue Train', artist: 'John Coltrane', year: 1957 },
      { title: 'Unknown Pleasures', artist: 'Joy Division', colourway: 'Clear' }
    ]
  )
  await page.goto('/l/abc123')
  await expect(
    page.getByRole('heading', { level: 1, name: 'Desert island discs' })
  ).toBeVisible()
  await expect(page).toHaveTitle('Desert island discs · Deadwax Club')
  await expect(page.getByText('Shared by Sam')).toBeVisible()
  await expect(page.getByText('2 records')).toBeVisible()
  await expect(page.locator('.record-tile')).toHaveCount(2)
  await expect(page.locator('.record-tile').first()).toContainText(
    'John Coltrane · 1957'
  )
  await expect(
    page.getByRole('link', { name: 'Open in Deadwax Club' })
  ).toHaveAttribute('href', 'deadwaxclub://list/abc123')
  expect(requests).toEqual([{ token: 'abc123' }, { token: 'abc123' }])
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true)
})

test('a private or deleted list explains that it is unavailable', async ({
  page
}) => {
  await serveListViewer(page, [], [])
  await page.goto('/l/gone123')
  await expect(
    page.getByRole('heading', { name: "Couldn't load list" })
  ).toBeVisible()
  await expect(page.locator('main')).toContainText("isn't available")
})
