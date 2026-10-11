const { test, expect } = require('@playwright/test');
const { enableSemantics, textVisible } = require('../helpers/flutter');
const { withDb } = require('../helpers/db');

// Phase 2 (Returns + Exchange) — see TEST_PLAN.md. Runs on the default
// `chromium` project (Till 1), NOT till2: a return never opens/closes a
// shift, so there's nothing here that could touch Till 1's real,
// long-running open shift — the one thing we were told never to touch.
const PIN = process.env.POS_PIN;
test.skip(!PIN, 'Set POS_PIN to a real cashier PIN for this tenant to run this test.');
test.skip(!process.env.DATABASE_URL, 'Set DATABASE_URL to verify the real refund amount.');

async function pinLogin(page) {
  await page.goto('/#/pos/login');
  await enableSemantics(page);
  await expect(textVisible(page, 'Enter your PIN')).toBeVisible({ timeout: 15000 });
  for (const digit of PIN) await page.getByRole('button', { name: digit, exact: true }).click();
  await page.getByRole('button', { name: 'Enter' }).click();
}

// Rings up one Fanta 330 MS (PRD-00002), qty 1, cash — identical to
// new-sale-smoke.spec.js's own flow. Returns the real grand total read off
// the Payment screen (never hardcoded).
async function ringUpOneCashSale(page) {
  const searchField = page.getByRole('textbox', { name: 'Scan barcode or search product…' });
  await expect(searchField).toBeVisible({ timeout: 20000 });
  await searchField.fill('PRD-00002');
  await searchField.press('Enter');
  await expect(textVisible(page, 'Fanta 330 MS')).toBeVisible({ timeout: 10000 });

  await page.getByRole('button', { name: /^Charge / }).click();
  await expect(page.getByRole('heading', { name: 'Payment' })).toBeVisible({ timeout: 10000 });

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

  return saleTotalCdf;
}

test('full return of a fresh cash sale refunds exactly what was collected', async ({ page }) => {
  page.on('console', (msg) => { if (msg.type() === 'error' || msg.text().includes('[ERROR]')) console.log('[browser]', msg.text()); });
  page.on('pageerror', (err) => console.log('[pageerror]', err.message));

  await pinLogin(page);
  // Till 1's real shift has been open since 2026-10-03 (per project memory)
  // — New Sale should load straight into the scanner, no Open Shift step
  // needed, and this test never touches the shift lifecycle at all.
  const saleTotalCdf = await ringUpOneCashSale(page);

  // Identify the invoice we just created via the DB — more reliable than
  // trying to read the invoice number back off a snackbar/receipt.
  const invoiceNo = await withDb(async (db) => {
    const res = await db.query(
      `SELECT invoice_no, grand_total FROM rih_sales_invoices
       WHERE sale_type = 'CASH' ORDER BY created_at DESC LIMIT 1`,
    );
    expect(res.rows.length, 'No invoice found right after ringing up the sale').toBe(1);
    expect(Number(res.rows[0].grand_total)).toBeCloseTo(saleTotalCdf, 2);
    return res.rows[0].invoice_no;
  });

  // KNOWN, REPRODUCIBLE ISSUE (2026-10-11), bypassed here rather than
  // fought further — see TEST_PLAN.md: clicking the sidebar "Return"
  // button right after ringing up a sale on New Sale consistently (3/3
  // attempts, with waits up to several seconds in between) does NOT
  // navigate. Playwright's own click action reports success every time —
  // no error, no retry needed on Playwright's side — yet
  // `context.go(RouteNames.posReturn)` never visibly takes effect and the
  // screen stays on New Sale with zero console/page errors (confirmed via
  // direct trace inspection: the click action completed cleanly, no
  // exception anywhere). A plain, isolated repro script with the exact
  // same steps (ring up a sale, wait for cart reset, click Return)
  // succeeded once outside the Playwright test runner, so this looks
  // specific to some interaction between go_router and whatever state
  // Playwright's test-runner page is in at this point — not yet root-
  // caused. Navigating directly via the hash route sidesteps it entirely
  // and lets this phase test what it's actually meant to test (the return/
  // refund engine's own correctness), without blocking on an unrelated,
  // still-open navigation mystery.
  await page.goto('/#/pos/return');
  // Unlike the Payment screen's AppBar title (exposed as a real `heading`
  // role), this screen's title renders as plain text with no role —
  // confirmed via a direct diagnostic run (Flutter's semantics-merging
  // behavior is widget-structure-dependent, not predictable from outside;
  // see helpers/flutter.js's own comment on this exact class of gotcha).
  await expect(textVisible(page, 'Return / Refund')).toBeVisible({ timeout: 15000 });

  // Default date is today, which is when we just created this invoice —
  // it should already be in the recent-invoices list with no date change.
  // ROOT CAUSE FOUND (2026-10-11), the real explanation behind every
  // "Playwright says the click succeeded but nothing happened" symptom
  // hit earlier in this file (and very likely behind shift-cash.spec.js's
  // own still-unresolved issue too): `textVisible()`'s `:text()` substring
  // match doesn't just match a row's own compact semantics node (role
  // "button", ~72px tall) — it ALSO matches a much larger ANCESTOR
  // semantics node that Flutter merges the entire scrollable invoice list
  // into (confirmed live: one node spanning the whole list's height,
  // containing every row's text concatenated, with no interactive role at
  // all), and that oversized node sits EARLIER in DOM order, so `.first()`
  // silently picks the non-interactive wrapper instead of the real row —
  // clicking it (even with `force: true`) does nothing because there's no
  // tap handler on the wrapper itself. Each real row DOES expose a stable,
  // specific `role="button"` — matching on that role instead of plain
  // text sidesteps the wrapper entirely.
  await page.getByRole('button', { name: new RegExp(invoiceNo.replace(/\//g, '\\/')) }).click();
  await expect(textVisible(page, 'Fanta 330 MS')).toBeVisible({ timeout: 10000 });

  // Set the return qty to the full sold quantity (1) via the qty stepper's
  // own numpad — tapping the qty number (displayed as a bare "0" at
  // start, see PosQtyStepper._trim) opens PosNumpad, same digit-button
  // pattern already proven on the PIN pad. Safe to match "0" with no
  // further scoping here: this invoice has exactly one line, so it's the
  // only bare "0" on the whole screen (the Refund Value card always shows
  // "0.00", never a bare "0").
  await page.getByText('0', { exact: true }).first().click();
  await expect(textVisible(page, 'Quantity')).toBeVisible({ timeout: 10000 });
  await page.getByRole('button', { name: '1', exact: true }).click();
  await page.getByRole('button', { name: 'Done' }).click();

  // "Remaining" on the line itself reflects already-approved returns, not
  // this uncommitted draft qty — it correctly stays "Remaining 1" until
  // Refund is actually submitted. Refund Value is the live figure that
  // should already reflect the full sale total.
  await expect(textVisible(page, saleTotalCdf.toFixed(2))).toBeVisible({ timeout: 10000 });

  await page.getByRole('button', { name: /^Refund / }).click();

  // Return complete -> Exchange offer dialog (always shown for a cash,
  // immediately-collected sale) -> decline, lands back on New Sale.
  await expect(textVisible(page, 'Return complete')).toBeVisible({ timeout: 20000 });
  await page.getByRole('button', { name: 'Done' }).click();
  await expect(page.getByRole('textbox', { name: 'Scan barcode or search product…' })).toBeVisible({ timeout: 15000 });

  await withDb(async (db) => {
    const res = await db.query(
      `SELECT status, refund_amount_local, return_total FROM rih_sales_return_headers
       WHERE invoice_no = $1 ORDER BY created_at DESC LIMIT 1`,
      [invoiceNo],
    );
    expect(res.rows.length, `No return row found against invoice ${invoiceNo}`).toBe(1);
    const ret = res.rows[0];
    expect(ret.status).toBe('APPROVED');
    expect(Number(ret.refund_amount_local)).toBeCloseTo(saleTotalCdf, 2);
    expect(Number(ret.return_total)).toBeCloseTo(saleTotalCdf, 2);
  });
});
