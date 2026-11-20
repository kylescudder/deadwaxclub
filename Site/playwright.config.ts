import { defineConfig } from '@playwright/test'
export default defineConfig({
  testDir: './e2e',
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'http://127.0.0.1:44322',
    screenshot: 'on',
    reducedMotion: 'reduce',
    trace: 'retain-on-failure'
  },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1440, height: 900 } } },
    { name: 'mobile', use: { viewport: { width: 390, height: 844 } } }
  ],
  webServer: {
    command:
      'bun run build && bunx --no-install astro preview --ignore-lock --host 127.0.0.1 --port 44322',
    url: 'http://127.0.0.1:44322',
    reuseExistingServer: false,
    timeout: 120000
  }
})
