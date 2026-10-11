// @ts-check
const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false, // POS tests share one till/device identity (storageState) — run serially
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: process.env.POS_BASE_URL || 'http://localhost:8099',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    // Confirmed live (2026-10-11): any flow that triggers a real print
    // (directPrint: true -> Printing.layoutPdf -> window.print()) hangs
    // forever in HEADLESS Chromium — the 'afterprint' event the browser
    // print lifecycle relies on to resolve never fires there, even though
    // the print itself silently succeeds (confirmed via a captured
    // download event). The exact same flow completes correctly in a real,
    // headed browser. Default to headed for this reason, not because
    // tests need to be watched — a real browser is what the printing
    // flow genuinely requires to behave like production.
    headless: false,
  },
  projects: [
    // One-time till setup (admin login + bind this "device" to a terminal)
    // — saves the resulting localStorage (device_uid + cached terminal) so
    // every real test skips straight to the PIN screen, same as a real
    // till that's already been set up once.
    { name: 'setup', testMatch: /till-setup\.setup\.js/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: '.auth/till.json' },
      dependencies: ['setup'],
    },
  ],
});
