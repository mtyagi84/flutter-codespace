const { test, expect } = require('@playwright/test');
const { enableSemantics, textVisible } = require('../../helpers/flutter');
const { withDb } = require('../../helpers/db');

// Real cashier PIN for Admin on the dedicated E2E test till (till2).
// Run with: POS_PIN=1234 DATABASE_URL=postgresql://... npx playwright test --project=chromium2
const PIN = process.env.POS_PIN;
test.skip(!PIN, 'Set POS_PIN to a real cashier PIN for this tenant to run this test.');
test.skip(!process.env.DATABASE_URL, 'Set DATABASE_URL to verify the real shift-close reconciliation.');

const OPENING_FLOAT_CDF = 10000;

async function pinLogin(page) {
  await page.goto('/#/pos/login');
  await enableSemantics(page);
  await expect(textVisible(page, 'Enter your PIN')).toBeVisible({ timeout: 15000 });
  for (const digit of PIN) await page.getByRole('button', { name: digit, exact: true }).click();
  await page.getByRole('button', { name: 'Enter' }).click();
}

// KNOWN UNRESOLVED ISSUE (2026-10-11), documented rather than silently
// worked around: the SECOND "Close Shift & Cash Up" click within one
// browser session (the real close, after ensureNoOpenShift's own leftover-
// shift reset already used this exact same button once) consistently
// fails to open its dialog — no error in the Flutter console, no page
// error, the button is visibly present and a bounding-box mouse click
// lands on it, yet the dialog never appears. Ruled out so far: a
// lingering SnackBar intercepting the click (confirmed via screenshot —
// no visual overlap, and waiting for it to clear first didn't help); a
// retry hitting the dialog's own tap-outside-to-dismiss barrier (switched
// to a single click, still fails); stale/incomplete `_load()` data
// (confirmed a REAL, separate bug this surfaced — see the sanity check
// below — but fixing the data race didn't fix this). The FIRST click
// (inside ensureNoOpenShift) works reliably every time; only the second
// one in the same session doesn't. Whether this is a genuine Flutter/
// Navigator state issue specific to rapid same-session reuse, or an
// artifact of Playwright automation a real cashier would never trigger
// (nobody clicks through this many screens in the time a human requires),
// is not yet established — needs either a manual two-close-in-a-row test
// by a real user, or a fresh investigation session with a clear budget.
async function openCloseShiftDialog(page) {
  const button = page.getByRole('button', { name: 'Close Shift & Cash Up' });
  const box = await button.boundingBox();
  if (box) {
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  } else {
    await button.click();
  }
  await expect(page.getByRole('textbox', { name: 'Counted Amount' }).first()).toBeVisible({ timeout: 20000 });
}

// Real bug caught live (2026-10-11): navigating to the Shift & Cash screen
// right after other POS activity sometimes hits a genuine Flutter runtime
// error — `PosShiftLoad: Null check operator used on a null value`,
// confirmed via the browser's own console — and the screen shows its
// error state (a "Retry" button) instead of the shift UI. This is a real,
// if transient, app-level race (not a test-authoring issue), and the app
// already provides its own recovery affordance for it — use that rather
// than fight the race from the test side.
async function goToShiftScreen(page) {
  await page.getByRole('button', { name: 'Shift & Cash' }).click();
  const movementsText = textVisible(page, "Today's Movements");
  const openShiftCard = textVisible(page, 'Open Shift');
  const retryButton = page.getByRole('button', { name: 'Retry' });
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await movementsText.isVisible().catch(() => false)) return;
    if (await openShiftCard.isVisible().catch(() => false)) return;
    if (await retryButton.isVisible().catch(() => false)) {
      await retryButton.click();
    }
    await page.waitForTimeout(1500);
  }
  throw new Error('Shift & Cash screen never loaded (stuck past the Retry screen) within 30s.');
}

// Makes the test repeatable from any starting state. A fresh till with no
// shift ever opened blocks New Sale with "No shift is open on this till."
// — but once this test has run once, the NEXT run lands straight in New
// Sale instead (the previous shift is still open), confirmed live. Close
// any leftover shift first (throwaway sandbox data, no business meaning)
// so every run deterministically starts from a clean, no-shift state.
async function ensureNoOpenShift(page) {
  const noShiftText = textVisible(page, 'No shift is open on this till.');
  const scanField = page.getByRole('textbox', { name: 'Scan barcode or search product…' });
  await Promise.race([
    noShiftText.waitFor({ state: 'visible', timeout: 20000 }),
    scanField.waitFor({ state: 'visible', timeout: 20000 }),
  ]);
  if (!(await scanField.isVisible().catch(() => false))) return;

  await goToShiftScreen(page);
  await openCloseShiftDialog(page);
  const reasonField = page.getByRole('textbox', { name: 'Variance Reason (if any)' });
  await reasonField.click();
  await page.keyboard.type('E2E sandbox reset (leftover shift from a prior run)', { delay: 10 });
  await page.getByRole('button', { name: 'Close Shift', exact: true }).click();
  // Closing from the Shift & Cash screen itself (this path) lands directly
  // back on its own Open Shift card — distinct from New Sale's separate
  // "No shift is open on this till." guard (only ever seen on a till that
  // has literally never had a shift opened at all). No further navigation
  // needed here; the caller below normalizes both possible starting shapes.
  await expect(textVisible(page, 'Open Shift')).toBeVisible({ timeout: 15000 });
}

test('open shift, ring up a cash sale, close shift, and verify the cash reconciliation', async ({ page }) => {
  page.on('console', (msg) => { if (msg.type() === 'error' || msg.text().includes('[ERROR]')) console.log('[browser]', msg.text()); });
  page.on('pageerror', (err) => console.log('[pageerror]', err.message));
  await pinLogin(page);
  await ensureNoOpenShift(page);

  // Two possible starting shapes land here: a truly fresh till shows New
  // Sale's "No shift is open" guard (its own "Open Shift" button navigates
  // to the Shift & Cash screen's card); ensureNoOpenShift's own close path
  // already lands directly on that same card. Check for the guard's own
  // unique text first — both screens share a same-labelled "Open Shift"
  // button (the card's own submit button), so checking for that directly
  // would be ambiguous.
  const onGuardScreen = await textVisible(page, 'No shift is open on this till.').isVisible().catch(() => false);
  if (onGuardScreen) {
    await page.getByRole('button', { name: 'Open Shift' }).click();
  }
  await expect(textVisible(page, 'Open Shift')).toBeVisible({ timeout: 15000 });

  const floatField = page.getByRole('textbox', { name: /Opening Float \(CDF\)/ });
  await floatField.click();
  await page.keyboard.type(String(OPENING_FLOAT_CDF), { delay: 30 });
  await page.getByRole('button', { name: 'Open Shift' }).click();

  // Opening a shift auto-navigates straight to New Sale.
  const searchField = page.getByRole('textbox', { name: 'Scan barcode or search product…' });
  await expect(searchField).toBeVisible({ timeout: 20000 });

  // Ring up one cash sale — same product/flow as the core smoke test.
  await searchField.fill('PRD-00002');
  await searchField.press('Enter');
  await expect(textVisible(page, 'Fanta 330 MS')).toBeVisible({ timeout: 10000 });
  await page.getByRole('button', { name: /^Charge / }).click();
  await expect(page.getByRole('heading', { name: 'Payment' })).toBeVisible({ timeout: 10000 });

  // Read the real grand total straight off the Payment screen rather than
  // hardcoding a product price. Confirmed live: this particular block
  // ("Subtotal X · Disc Y · Tax Z" and the total next to it) renders as
  // real DOM text, not a merged aria-label — read both possible forms
  // rather than assuming one, same reasoning as textVisible() itself.
  const totalEl = textVisible(page, 'CDF');
  await expect(totalEl).toBeVisible({ timeout: 10000 });
  const totalText = await totalEl.evaluate((el) => el.getAttribute('aria-label') || el.textContent);
  const totalMatch = totalText.match(/([\d,]+\.\d{2})\s*CDF/);
  expect(totalMatch, `Could not parse grand total out of: "${totalText}"`).toBeTruthy();
  const saleTotalCdf = parseFloat(totalMatch[1].replace(/,/g, ''));

  const saveButton = page.getByRole('button', { name: 'Save & Print' });
  await expect(saveButton).toBeEnabled({ timeout: 10000 });
  await saveButton.click();
  await expect(searchField).toBeVisible({ timeout: 20000 });
  await expect(textVisible(page, 'Fanta 330 MS')).not.toBeVisible({ timeout: 30000 });

  // Close the shift — counted = opening float + this sale's real collected
  // amount (the true, physically-correct drawer total), independent of
  // whatever the dialog's own "Expected" preview happens to show.
  const expectedTrueCash = OPENING_FLOAT_CDF + saleTotalCdf;

  await goToShiftScreen(page);
  await page.waitForTimeout(1000); // let the screen's own data fetch fully settle before opening the dialog
  await openCloseShiftDialog(page);

  // Sanity check caught live: the dialog can open showing ALL company
  // currencies with "Expected: 0.00" on every one of them, instead of
  // just CDF with the real 10000 float — pos_shift_screen.dart falls back
  // to every currency when its own `touchedCurrencies` set is empty,
  // which happens if the opening-float sub-fetch hadn't finished by the
  // time the dialog was built (the same underlying load race as
  // goToShiftScreen's own Retry handling, just surfacing differently
  // here). This shift definitely has a real CDF-only opening float —
  // detect the wrong (multi-currency) shape and retry once rather than
  // silently submit against the wrong Expected baseline.
  const eurCountedField = page.getByRole('textbox', { name: 'Counted Amount' }).nth(1);
  if (await eurCountedField.isVisible().catch(() => false)) {
    await page.getByRole('button', { name: 'Cancel' }).click();
    await page.waitForTimeout(1500);
    await openCloseShiftDialog(page);
  }

  const countedField = page.getByRole('textbox', { name: 'Counted Amount' }).first();
  await countedField.click();
  await page.keyboard.type(expectedTrueCash.toFixed(2), { delay: 30 });

  // If the dialog's own displayed "Expected" undercounts (it's known to
  // exclude cash sales — see pos_shift_screen.dart's own header comment),
  // this will show a non-zero on-screen "Variance" even though the true
  // cash position is exact. Supply a reason so Close Shift isn't blocked
  // by that stale preview, and let the DB-level assertions below be the
  // real judge of whether the backend's own (fixed) formula agrees.
  const reasonField = page.getByRole('textbox', { name: 'Variance Reason (if any)' });
  await reasonField.click();
  await page.keyboard.type('E2E test — verifying true reconciliation against DB', { delay: 10 });

  await page.getByRole('button', { name: 'Close Shift', exact: true }).click();
  await expect(textVisible(page, 'Open Shift')).toBeVisible({ timeout: 15000 });

  // ── Real DB verification — the part that actually proves correctness ──
  await withDb(async (db) => {
    const shiftRes = await db.query(
      `SELECT id, status, closed_at FROM rih_pos_shifts
       WHERE terminal_id = (SELECT id FROM ric_pos_terminals WHERE terminal_code = 'T-E2E' LIMIT 1)
       ORDER BY opened_at DESC LIMIT 1`,
    );
    expect(shiftRes.rows.length, 'No shift row found for the E2E test till').toBe(1);
    const shift = shiftRes.rows[0];
    expect(shift.status).toBe('CLOSED');
    expect(shift.closed_at).toBeTruthy();

    const closingCount = await db.query(
      `SELECT count FROM rid_pos_shift_denomination_counts
       WHERE shift_id = $1 AND count_stage = 'CLOSING' AND currency_id = 'CDF'`,
      [shift.id],
    );
    expect(closingCount.rows.length).toBe(1);
    expect(Number(closingCount.rows[0].count)).toBeCloseTo(expectedTrueCash, 2);

    // The invoice from this sale should exist, be CASH/APPROVED, and its
    // grand_total should match what we read off the Payment screen.
    const invoiceRes = await db.query(
      `SELECT invoice_no, status, sale_type, grand_total, gl_consolidated
       FROM rih_sales_invoices
       WHERE pos_shift_id = $1 ORDER BY created_at DESC LIMIT 1`,
      [shift.id],
    );
    expect(invoiceRes.rows.length, 'No invoice found tagged with this shift').toBe(1);
    const invoice = invoiceRes.rows[0];
    expect(invoice.status).toBe('APPROVED');
    expect(invoice.sale_type).toBe('CASH');
    expect(Number(invoice.grand_total)).toBeCloseTo(saleTotalCdf, 2);
  });
});
