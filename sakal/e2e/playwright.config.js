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
  },
  projects: [
    // One-time till setup (admin login + bind this "device" to a terminal)
    // — saves the resulting localStorage (device_uid + cached terminal) so
    // every real test skips straight to the PIN screen, same as a real
    // till that's already been set up once.
    { name: 'setup', testMatch: /till-setup\.setup\.js/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: 'e2e/.auth/till.json' },
      dependencies: ['setup'],
    },
  ],
});
