// Shared by every app's site (Scripts/SHARED_SITE.md); the pages and support
// link come from app.json. App-only journeys go in their own spec files.
import { readFileSync } from 'node:fs'
import { test, expect } from '@playwright/test'

const app = JSON.parse(
  readFileSync(new URL('../app.json', import.meta.url), 'utf8')
) as { contact: string; support: string; pages: Record<string, string> }

test('every page is built with its content and fits the screen', async ({
  page
}) => {
  for (const [path, content] of Object.entries(app.pages)) {
    const response = await page.goto(path)
    expect(response?.status(), path).toBe(200)
    expect(await response?.text(), path).toContain(content)
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth
      ),
      `${path} scrolls sideways`
    ).toBe(true)
  }
})

test('visitors can read privacy and support information and return home', async ({
  page
}) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
  await page.locator('a[href="/privacy"]:visible').first().click()
  await expect(page).toHaveURL(/\/privacy\/?$/)
  await expect(page.getByRole('heading', { level: 1 })).toContainText(
    /privacy/i
  )
  await expect(page.locator('main')).toContainText(/information|data/i)
  await page.locator(`a[href="${app.support}"]:visible`).first().click()
  const [supportPage, anchor] = app.support.split('#')
  // Support is either its own page or a section of one.
  const support = anchor ? page.locator(`#${anchor}`) : page.locator('main')
  await expect(page).toHaveURL(
    anchor ? new RegExp(`#${anchor}$`) : new RegExp(`${supportPage}/?$`)
  )
  await expect(support).toBeInViewport()
  await expect(support).toContainText(/support/i)
  await expect(
    support.locator(`a[href^="mailto:${app.contact}"]`).first()
  ).toBeVisible()
  await page.locator('a[href="/"]:visible').first().click()
  await expect(page).toHaveURL(/\/$/)
  await page.evaluate(() => document.fonts.ready)
  await page.evaluate(() =>
    Promise.all(
      document
        .getAnimations()
        .filter((a) => a.effect?.getComputedTiming().iterations !== Infinity)
        .map((a) => a.finished)
    )
  )
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true)
})

test('an unknown page returns a real not-found response', async ({ page }) => {
  const response = await page.goto('/e2e-page-that-does-not-exist')
  expect(response?.status()).toBe(404)
  await expect(page.locator('body')).toContainText(/404|not found/i)
})
