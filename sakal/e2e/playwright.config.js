// @ts-check
const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  // Multi-step POS flows (shift open -> sale -> shift close) legitimately
  // take a while, especially with the Retry-aware navigation some screens
  // need (see shift-cash.spec.js's own goToShiftScreen) — 60s was found
  // live to cut a genuinely-still-progressing test off mid-flow.
  timeout: 120_000,
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
      testIgnore: /till2\//,
      use: { ...devices['Desktop Chrome'], storageState: '.auth/till.json' },
      dependencies: ['setup'],
    },
    // A SECOND, dedicated sandbox till (see till2-setup.setup.js's own
    // header comment) — used by any test that needs to freely open/close
    // shifts, since Till 1's real shift must never be touched by
    // automated testing.
    { name: 'setup2', testMatch: /till2-setup\.setup\.js/ },
    {
      name: 'chromium2',
      testMatch: /till2\//,
      use: { ...devices['Desktop Chrome'], storageState: '.auth/till2.json' },
      dependencies: ['setup2'],
    },
  ],
});
