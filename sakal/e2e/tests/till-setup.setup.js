const { test, expect } = require('@playwright/test');
const { enableSemantics, textVisible, typeInto } = require('../helpers/flutter');
const fs = require('fs');
const path = require('path');

// Real tenant credentials used throughout this project's own manual testing
// session (Client No SK-69077 / Admin) — override via env vars for a
// different tenant without editing this file.
const CLIENT_NO = process.env.POS_CLIENT_NO || 'SK-69077';
const USERNAME  = process.env.POS_USERNAME  || 'Admin';
const PASSWORD  = process.env.POS_PASSWORD  || '123@Admin';

const AUTH_FILE = path.join(__dirname, '..', '.auth', 'till.json');

test('bind this browser as a POS till (one-time)', async ({ page }) => {
  fs.mkdirSync(path.dirname(AUTH_FILE), { recursive: true });

  await page.goto('/#/pos/device-setup');
  await enableSemantics(page);

  await expect(textVisible(page, "This device isn't set up yet")).toBeVisible({ timeout: 15000 });
  await page.getByRole('button', { name: 'Sign in as Administrator' }).click();

  await expect(textVisible(page, 'Administrator Sign-In')).toBeVisible();
  // Flutter's web text-input bridge is most reliable against a real
  // click-then-type sequence (mirrors actual typing) rather than
  // `.fill()`, which was found to silently leave a field empty here —
  // Client No. and Password filled correctly, Username did not, on a
  // `.fill()`-based attempt.
  await typeInto(page, 'Client No.', CLIENT_NO);
  await typeInto(page, 'Username', USERNAME);
  await typeInto(page, 'Password', PASSWORD);
  await page.getByRole('button', { name: 'Continue' }).click();

  await expect(textVisible(page, 'Assign This Device')).toBeVisible({ timeout: 15000 });

  // Pick whichever location is first in the dropdown — this is a one-time
  // device binding, not a business decision; any active location works for
  // testing purposes. Override POS_LOCATION_NAME to pick a specific one.
  // Flutter's DropdownButtonFormField itself is exposed as role="button"
  // (its label + currently-selected value merged into one accessible
  // name — "Store / Location Head Office" once a value is picked, just
  // "Till" while still unselected), and its OPEN popup items as
  // role="menuitem" — none of this matches the web-standard
  // combobox/option roles `getByLabel`/`getByRole('option')` expect, all
  // confirmed live via Playwright's own accessibility snapshot.
  await page.getByRole('button', { name: 'Store / Location', exact: false }).click();
  if (process.env.POS_LOCATION_NAME) {
    await page.getByRole('menuitem', { name: process.env.POS_LOCATION_NAME }).click();
  } else {
    await page.getByRole('menuitem').first().click();
  }
  // Picking a location kicks off its own async terminal-list fetch
  // (_onLocationChanged) — give it a moment before opening the Till
  // dropdown, or it opens empty (confirmed live: the terminal genuinely
  // exists for this location in the database, this was a pure race).
  await page.waitForTimeout(1000);

  // "Existing Till" is the default selection — reuse an already-configured
  // terminal (e.g. "Till 1") rather than creating a new one on every run.
  // `exact: true` matters here — "Existing Till"/"New Till" (the segmented
  // buttons above this field) both also contain the substring "Till".
  const tillField = page.getByRole('button', { name: 'Till', exact: true });
  await expect(tillField).toBeVisible({ timeout: 10000 });
  await tillField.click();
  if (process.env.POS_TERMINAL_NAME) {
    await page.getByRole('menuitem', { name: new RegExp(process.env.POS_TERMINAL_NAME) }).click();
  } else {
    await page.getByRole('menuitem').first().click();
  }

  await page.getByRole('button', { name: 'Assign & Finish Setup' }).click();

  // Lands on the PIN screen once bound — this is the real proof the setup
  // succeeded (device-setup never routes here on its own).
  await expect(textVisible(page, 'Enter your PIN')).toBeVisible({ timeout: 15000 });

  await page.context().storageState({ path: AUTH_FILE });
});
