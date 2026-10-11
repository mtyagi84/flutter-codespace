const { test, expect } = require('@playwright/test');
const { enableSemantics, textVisible, typeInto } = require('../helpers/flutter');
const fs = require('fs');
const path = require('path');

// A SEPARATE physical "device" (fresh browser storage, fresh device_uid)
// bound to its OWN new till — deliberately never touches Till 1's real,
// long-running shift (SFT/HO/2026/00001, open since 2026-10-03 with real
// manual-testing transactions in it). Shift-lifecycle tests (open/close,
// cash reconciliation) need to freely open and close shifts, which would
// be destructive against that real shift — this gives them their own
// sandbox terminal instead.
const CLIENT_NO = process.env.POS_CLIENT_NO || 'SK-69077';
const USERNAME  = process.env.POS_USERNAME  || 'Admin';
const PASSWORD  = process.env.POS_PASSWORD  || '123@Admin';
const TILL_CODE = process.env.POS_TEST_TILL_CODE || 'T-E2E';
const TILL_NAME = process.env.POS_TEST_TILL_NAME || 'E2E Test Till';

const AUTH_FILE = path.join(__dirname, '..', '.auth', 'till2.json');

test('bind this (second) browser to a dedicated E2E test till', async ({ page }) => {
  fs.mkdirSync(path.dirname(AUTH_FILE), { recursive: true });

  await page.goto('/#/pos/device-setup');
  await enableSemantics(page);

  await expect(textVisible(page, "This device isn't set up yet")).toBeVisible({ timeout: 15000 });
  await page.getByRole('button', { name: 'Sign in as Administrator' }).click();

  await expect(textVisible(page, 'Administrator Sign-In')).toBeVisible();
  await typeInto(page, 'Client No.', CLIENT_NO);
  await typeInto(page, 'Username', USERNAME);
  await typeInto(page, 'Password', PASSWORD);
  await page.getByRole('button', { name: 'Continue' }).click();

  await expect(textVisible(page, 'Assign This Device')).toBeVisible({ timeout: 15000 });

  // Same location as Till 1 (Head Office) — only the terminal differs.
  await page.getByRole('button', { name: 'Store / Location', exact: false }).click();
  await page.getByRole('menuitem').first().click();
  await page.waitForTimeout(1000);

  // Idempotent: re-running this setup (e.g. on every `playwright test`
  // invocation, since setup projects aren't cached across runs) must
  // reuse the same E2E test till rather than creating a fresh duplicate
  // `ric_pos_terminals` row each time. "Existing Till" is already the
  // default selection — check whether this till was already created by a
  // prior run before falling back to "New Till".
  const tillField = page.getByRole('button', { name: 'Till', exact: true });
  await expect(tillField).toBeVisible({ timeout: 10000 });
  await tillField.click();
  // Real bug caught live here (2026-10-11): an immediate `isVisible()`
  // check raced the popup menu's own open animation and always reported
  // false even when the item genuinely existed — creating a SECOND
  // terminal with the same code on every re-run until it hit a real
  // unique-constraint failure ("Unable to set up this till"). Wait for
  // the popup to actually settle before deciding.
  await page.waitForTimeout(500);
  const existingOption = page.getByRole('menuitem', { name: new RegExp(TILL_NAME) });
  const alreadyExists = await existingOption.isVisible().catch(() => false);
  if (alreadyExists) {
    await existingOption.click();
  } else {
    // Close the (empty or non-matching) popup, switch to New Till.
    await page.keyboard.press('Escape');
    await page.getByRole('button', { name: 'New Till' }).click();
    await typeInto(page, 'Till Code (e.g. T1)', TILL_CODE);
    await typeInto(page, 'Till Name (e.g. Front Counter)', TILL_NAME);
  }

  await page.getByRole('button', { name: 'Assign & Finish Setup' }).click();

  await expect(textVisible(page, 'Enter your PIN')).toBeVisible({ timeout: 15000 });

  await page.context().storageState({ path: AUTH_FILE });
});
