const { test, expect } = require('@playwright/test');
const { enableSemantics, textVisible } = require('../helpers/flutter');

// A real cashier PIN for this tenant — required, never guessed/hardcoded.
// Run with: POS_PIN=1234 npx playwright test
const PIN = process.env.POS_PIN;

test.skip(!PIN, 'Set POS_PIN to a real cashier PIN for this tenant to run this test.');

test('cashier signs in, rings up a sale, pays, and lands back on the scanner', async ({ page }) => {
  // This project's storageState (saved by till-setup.setup.js) already
  // binds this browser to a terminal — go straight to the PIN screen, same
  // as a real till that's already been set up.
  await page.goto('/#/pos/login');
  await enableSemantics(page);

  await expect(textVisible(page, 'Enter your PIN')).toBeVisible({ timeout: 15000 });
  for (const digit of PIN) {
    await page.getByRole('button', { name: digit, exact: true }).click();
  }
  await page.getByRole('button', { name: 'Enter' }).click();

  // New Sale screen — confirmed by the scan field itself. Matched by role,
  // not `getByPlaceholder`: Flutter Web only materializes a real native
  // `<input placeholder="...">` DOM element while a TextField is actually
  // focused — unfocused, it's canvas-painted with just an accessible name,
  // confirmed present throughout via the AX tree (`textbox "Scan barcode
  // or search product…"`), which `getByPlaceholder`'s attribute-based
  // query doesn't see.
  const searchField = page.getByRole('textbox', { name: 'Scan barcode or search product…' });
  await expect(searchField).toBeVisible({ timeout: 20000 });

  // PRD-00002 = Fanta 330 MS, used throughout this project's own manual
  // testing session — an exact product-code match auto-adds with no
  // disambiguation dialog.
  await searchField.fill('PRD-00002');
  await searchField.press('Enter');

  await expect(textVisible(page, 'Fanta 330 MS')).toBeVisible({ timeout: 10000 });

  // Charge — opens the dedicated full-page Payment screen (never a modal).
  // Its AppBar title renders as a real `heading` role here (not merged
  // into an aria-label group the way the device-setup screens' static
  // text was) — Flutter's semantics merging is widget-structure-dependent,
  // so match by role rather than assuming one text-matching strategy
  // covers every screen.
  await page.getByRole('button', { name: /^Charge / }).click();
  await expect(page.getByRole('heading', { name: 'Payment' })).toBeVisible({ timeout: 10000 });

  // Default single Cash line already covers the full due amount — Save &
  // Print should be enabled immediately with no further input needed.
  const saveButton = page.getByRole('button', { name: 'Save & Print' });
  await expect(saveButton).toBeEnabled({ timeout: 10000 });
  await saveButton.click();

  // A successful charge saves, approves, and prints (browser download/
  // print dialog — not asserted here, see README) before resetting —
  // give it real room before concluding the cart never cleared.
  await expect(searchField).toBeVisible({ timeout: 20000 });
  await expect(textVisible(page, 'Fanta 330 MS')).not.toBeVisible({ timeout: 30000 });
});
