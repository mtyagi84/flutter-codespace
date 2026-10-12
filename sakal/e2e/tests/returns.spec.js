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

// Rings up `qty` units of `productCode`/`productName`, cash — a
// generalization of new-sale-smoke.spec.js's own flow (searching/pressing
// Enter on the SAME product code repeatedly merges into one line, qty+1
// each time — confirmed via _addProduct's own merge-not-duplicate logic —
// so this is exactly what a cashier scanning the same item N times does).
// Returns the real grand total read off the Payment screen (never
// hardcoded) — this is the ACTUAL amount charged, already net of any
// scheme/promo discount, which is exactly what makes it the right
// reference value for every refund assertion below.
async function ringUpCashSale(page, productCode, productName, qty = 1) {
  const searchField = page.getByRole('textbox', { name: 'Scan barcode or search product…' });
  await expect(searchField).toBeVisible({ timeout: 20000 });
  for (let i = 0; i < qty; i++) {
    await searchField.fill(productCode);
    await searchField.press('Enter');
    await expect(textVisible(page, productName)).toBeVisible({ timeout: 10000 });
    // A real race found live: each add fires an async, fire-and-forget POS
    // scheme preview lookup (_refreshLineScheme) that recomputes the
    // line's own discount once it resolves — adding several units in
    // immediate succession and charging before the LAST one's preview
    // settles can leave the cart's own displayed total stale (missing a
    // scheme discount that genuinely applies, e.g. Fanta's "buy 2 get 1
    // free"). A short settle per add is cheap insurance against reading a
    // number that doesn't match what the server independently computes.
    await page.waitForTimeout(1200);
  }

  await page.getByRole('button', { name: /^Charge / }).click();
  await expect(page.getByRole('heading', { name: 'Payment' })).toBeVisible({ timeout: 10000 });
  // Give the Payment screen's own total a moment to reflect the final
  // cart state (same settle reasoning as above) before trusting it as the
  // reference value for every refund assertion downstream.
  await page.waitForTimeout(500);

  // REAL FINDING (2026-10-12): neither a plain "match any CDF-suffixed
  // text" locator NOR reconstructing the total from the rounded
  // Subtotal/Disc/Tax breakdown line is reliable here. Flutter's own
  // semantics merging of this screen is NOT stable run to run (confirmed
  // live, several different shapes seen across runs) — a generic
  // substring match can land on the header block, the bottom
  // Collected/Change-Due summary, or the Amount Collected field depending
  // on how things merged that render. Reconstructing from the displayed
  // 2-decimal Subtotal+Tax ALSO isn't exact: confirmed live, a real
  // invoice with grand_total 12220.9161 displays as Subtotal 10535.27 +
  // Tax 1685.64 = 12220.91 when added back from their own rounded
  // display values — one cent short of the real 12220.92, enough to make
  // "Save & Print" stay disabled ("Short by 0.01 CDF") when that
  // reconstructed figure is then used to fill Amount Collected.
  //
  // The reliable fix: every "<number> CDF" standalone text node on this
  // screen (there are normally 2-3 — the big bold Total up top, and the
  // Collected/Change Due summary at the bottom) is unambiguous by
  // POSITION even when it isn't by DOM/semantics order — the Total is
  // always the topmost one. Query the real page directly for exact
  // '<number> CDF' matches (not substring) and take whichever has the
  // smallest y-coordinate.
  const saleTotalCdf = await page.evaluate(() => {
    const re = /^[\d,]+\.\d{2}\s*CDF$/;
    const candidates = Array.from(document.querySelectorAll('span, flt-semantics'))
      .map((el) => ({ el, text: (el.textContent || '').trim() }))
      .filter((c) => re.test(c.text))
      .map((c) => ({ ...c, y: c.el.getBoundingClientRect().y }));
    if (candidates.length === 0) return null;
    candidates.sort((a, b) => a.y - b.y);
    const num = candidates[0].text.match(/[\d,]+\.\d{2}/)[0];
    return parseFloat(num.replace(/,/g, ''));
  });
  expect(saleTotalCdf, 'Could not find the Payment screen\'s own Total text on screen').not.toBeNull();

  // Separately: for a multi-unit cart, "Amount Collected" can also
  // prefill to a STALE, short amount (confirmed live: ringing up 3 Pizzas
  // once showed a correct 123622.86 total but an Amount Collected
  // prefilled to only 82415.24 — exactly 2/3 of it, as if the tender
  // default snapshot `_grandTotal` slightly before the 3rd item's cart
  // recompute settled). Looks like a real, separate app bug worth its own
  // investigation (flagged in TEST_PLAN.md) — not chased down further
  // here. Explicitly overwriting Amount Collected below (rather than
  // trusting its prefill) sidesteps it and keeps every invoice this suite
  // creates genuinely fully-collected.

  // Explicitly set Amount Collected to the confirmed-correct total rather
  // than trusting its own default prefill — see the real finding noted
  // above. Also just good test hygiene: avoids this E2E run saving a
  // genuinely under-collected CASH invoice into real tenant data.
  const collectedField = page.getByRole('textbox', { name: 'Amount Collected' });
  await collectedField.fill(saleTotalCdf.toFixed(2));

  const saveButton = page.getByRole('button', { name: 'Save & Print' });
  await expect(saveButton).toBeEnabled({ timeout: 10000 });
  await saveButton.click();
  await expect(searchField).toBeVisible({ timeout: 20000 });
  await expect(textVisible(page, productName)).not.toBeVisible({ timeout: 30000 });

  return saleTotalCdf;
}

// Looks up the invoice we just created via the DB — more reliable than
// trying to read the invoice number back off a snackbar/receipt.
async function findJustCreatedInvoice(saleTotalCdf) {
  return withDb(async (db) => {
    const res = await db.query(
      `SELECT invoice_no, grand_total FROM rih_sales_invoices
       WHERE sale_type = 'CASH' ORDER BY created_at DESC LIMIT 1`,
    );
    expect(res.rows.length, 'No invoice found right after ringing up the sale').toBe(1);
    expect(Number(res.rows[0].grand_total)).toBeCloseTo(saleTotalCdf, 2);
    return res.rows[0].invoice_no;
  });
}

// Navigates to Return and selects the given invoice.
//
// KNOWN, REPRODUCIBLE ISSUE (2026-10-11), bypassed here rather than fought
// further — see TEST_PLAN.md: clicking the sidebar "Return" button right
// after ringing up a sale on New Sale consistently (3/3 attempts, with
// waits up to several seconds in between) does NOT navigate. Playwright's
// own click action reports success every time — no error, no retry needed
// on Playwright's side — yet `context.go(RouteNames.posReturn)` never
// visibly takes effect and the screen stays on New Sale with zero
// console/page errors (confirmed via direct trace inspection: the click
// action completed cleanly, no exception anywhere). A plain, isolated
// repro script with the exact same steps (ring up a sale, wait for cart
// reset, click Return) succeeded once outside the Playwright test runner,
// so this looks specific to some interaction between go_router and
// whatever state Playwright's test-runner page is in at this point — not
// yet root-caused. Navigating directly via the hash route sidesteps it
// entirely and lets this phase test what it's actually meant to test (the
// return/refund engine's own correctness), without blocking on an
// unrelated, still-open navigation mystery.
//
// ROOT CAUSE FOUND for the invoice LIST row click (2026-10-11), the real
// explanation behind every "Playwright says the click succeeded but
// nothing happened" symptom hit while building this file (and very likely
// behind shift-cash.spec.js's own still-unresolved issue too):
// `textVisible()`'s `:text()` substring match doesn't just match a row's
// own compact semantics node (role "button", ~72px tall) — it ALSO
// matches a much larger ANCESTOR semantics node that Flutter merges the
// entire scrollable invoice list into (confirmed live: one node spanning
// the whole list's height, containing every row's text concatenated, with
// no interactive role at all), and that oversized node sits EARLIER in
// DOM order, so `.first()` silently picks the non-interactive wrapper
// instead of the real row — clicking it (even with `force: true`) does
// nothing because there's no tap handler on the wrapper itself. Each real
// row DOES expose a stable, specific `role="button"` — matching on that
// role instead of plain text sidesteps the wrapper entirely.
//
// SEPARATE FINDING (2026-10-12), NOT fully resolved: later in this same
// session, after this tenant's invoice list had grown to 70+ accumulated
// rows from extensive same-day test runs, even this role-based click (and
// several alternatives tried — a "find by invoice number" search fallback,
// explicit scroll-settle waits, retries) became consistently unreliable,
// up to the search field itself sometimes not even rendering within a
// 120s budget. Not root-caused — plausibly either a genuine Flutter
// semantics-tree scaling issue for a long ListView, or this extended
// debugging session's own heavy Supabase/dev-server load, neither of
// which a normal day's test run should hit. Reverted to the originally-
// proven simple form below (single role-based click, no retry) rather
// than keep layering workarounds for a problem that may be an artifact of
// this session's own unusually large accumulated dataset — if this
// becomes a recurring problem on a fresh run, revisit with a clean slate
// rather than more waits/retries.
async function openReturnFor(page, invoiceNo, firstLineProductName) {
  await page.goto('/#/pos/return');
  // Unlike the Payment screen's AppBar title (exposed as a real `heading`
  // role), this screen's title renders as plain text with no role —
  // confirmed via a direct diagnostic run (Flutter's semantics-merging
  // behavior is widget-structure-dependent, not predictable from outside;
  // see helpers/flutter.js's own comment on this exact class of gotcha).
  await expect(textVisible(page, 'Return / Refund')).toBeVisible({ timeout: 15000 });
  await page.getByRole('button', { name: new RegExp(invoiceNo.replace(/\//g, '\\/')) }).click();
  await expect(textVisible(page, firstLineProductName)).toBeVisible({ timeout: 10000 });
}

// Sets a line's return qty via its PosQtyStepper's own numpad (tap the qty
// number -> PosNumpad -> type digits -> Done). Scoped via a bare "0" text
// match, safe only because every test in this file uses a single-line
// invoice (qty starts at 0 for an unreturned line, see
// PosQtyStepper._trim — the Refund Value card always shows "0.00", never
// a bare "0", so there's no ambiguity with a single line).
async function setReturnQtyViaNumpad(page, qtyDigits) {
  await page.getByText('0', { exact: true }).first().click();
  await expect(textVisible(page, 'Quantity')).toBeVisible({ timeout: 10000 });
  for (const digit of String(qtyDigits)) {
    await page.getByRole('button', { name: digit, exact: true }).click();
  }
  await page.getByRole('button', { name: 'Done' }).click();
}

// Submits the return, declines the Exchange offer (every test here is a
// standalone return, not chained into a new sale), and lands back on New
// Sale.
async function submitReturnAndDecline(page) {
  await page.getByRole('button', { name: /^Refund / }).click();
  await expect(textVisible(page, 'Return complete')).toBeVisible({ timeout: 20000 });
  await page.getByRole('button', { name: 'Done' }).click();
  await expect(page.getByRole('textbox', { name: 'Scan barcode or search product…' })).toBeVisible({ timeout: 15000 });
}

test('full return of a fresh cash sale refunds exactly what was collected', async ({ page }) => {
  page.on('console', (msg) => { if (msg.type() === 'error' || msg.text().includes('[ERROR]')) console.log('[browser]', msg.text()); });
  page.on('pageerror', (err) => console.log('[pageerror]', err.message));

  await pinLogin(page);
  // Till 1's real shift has been open since 2026-10-03 (per project memory)
  // — New Sale should load straight into the scanner, no Open Shift step
  // needed, and this test never touches the shift lifecycle at all.
  const saleTotalCdf = await ringUpCashSale(page, 'PRD-00002', 'Fanta 330 MS', 1);
  const invoiceNo = await findJustCreatedInvoice(saleTotalCdf);

  await openReturnFor(page, invoiceNo, 'Fanta 330 MS');
  await setReturnQtyViaNumpad(page, 1);

  // "Remaining" on the line itself reflects already-approved returns, not
  // this uncommitted draft qty — it correctly stays "Remaining 1" until
  // Refund is actually submitted. Refund Value is the live figure that
  // should already reflect the full sale total.
  await expect(textVisible(page, saleTotalCdf.toFixed(2))).toBeVisible({ timeout: 10000 });

  await submitReturnAndDecline(page);

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

test('partial return refunds exactly the returned proportion', async ({ page }) => {
  page.on('console', (msg) => { if (msg.type() === 'error' || msg.text().includes('[ERROR]')) console.log('[browser]', msg.text()); });
  page.on('pageerror', (err) => console.log('[pageerror]', err.message));

  // Pizza (PRD-00004) — deliberately NOT Fanta (PRD-00002), which has an
  // active "buy 2 get 1 free" POS scheme (rim_pos_schemes 'Scheme 1',
  // confirmed live via a direct DB query) that would make a qty-3 line's
  // own total non-linear in qty, confusing this test's "2/3 of the total"
  // math — the scheme-discount interaction has its own dedicated test
  // below instead. Also deliberately NOT Coca Cola (PRD-00001): confirmed
  // live it has NO configured selling price on this tenant at all, which
  // silently blocks `_addProduct` with a "has no price configured" snackbar
  // — a real gotcha this test tripped over, since that snackbar's own text
  // happens to contain the product name too, so a naive `textVisible()`
  // wait for the product name is satisfied by the ERROR, not a real add.
  // Pizza has a confirmed price (rid_price_master_lines) and no scheme.
  await pinLogin(page);
  const saleTotalCdf = await ringUpCashSale(page, 'PRD-00004', 'Pizza', 3);
  const invoiceNo = await findJustCreatedInvoice(saleTotalCdf);

  await openReturnFor(page, invoiceNo, 'Pizza');
  await setReturnQtyViaNumpad(page, 2);

  // No scheme/discount on this line, so 2 of 3 units is exactly 2/3 of the
  // sale's own total — linear, no rounding surprises beyond normal 2dp.
  const expectedRefund = (saleTotalCdf * 2) / 3;
  await expect(textVisible(page, expectedRefund.toFixed(2))).toBeVisible({ timeout: 10000 });

  await submitReturnAndDecline(page);

  await withDb(async (db) => {
    const res = await db.query(
      `SELECT return_no, status, refund_amount_local, return_total FROM rih_sales_return_headers
       WHERE invoice_no = $1 ORDER BY created_at DESC LIMIT 1`,
      [invoiceNo],
    );
    expect(res.rows.length, `No return row found against invoice ${invoiceNo}`).toBe(1);
    const ret = res.rows[0];
    expect(ret.status).toBe('APPROVED');
    expect(Number(ret.refund_amount_local)).toBeCloseTo(expectedRefund, 2);
    expect(Number(ret.return_total)).toBeCloseTo(expectedRefund, 2);

    // The one line should show base_qty=2 returned, not the full 3 sold —
    // proves the qty actually submitted was 2, not silently the full line.
    // rid_sales_return_lines links to its header via return_no, not a
    // direct invoice_no column.
    const lineRes = await db.query(
      `SELECT base_qty FROM rid_sales_return_lines WHERE return_no = $1`,
      [ret.return_no],
    );
    expect(lineRes.rows.length).toBe(1);
    expect(Number(lineRes.rows[0].base_qty)).toBeCloseTo(2, 4);
  });
});

test('return of a scheme-discounted sale refunds the actual discounted total, not qty x rate', async ({ page }) => {
  page.on('console', (msg) => { if (msg.type() === 'error' || msg.text().includes('[ERROR]')) console.log('[browser]', msg.text()); });
  page.on('pageerror', (err) => console.log('[pageerror]', err.message));

  // Fanta 330 MS (PRD-00002) has an active "buy 2 get 1 free" POS scheme
  // (rim_pos_schemes 'Scheme 1' / rim_pos_scheme_rules benefit_type
  // FREE_QTY, min_qty 2, confirmed live via direct DB query) — ringing up
  // qty 3 triggers it, so the invoice's own grand_total is LESS than
  // 3 x unit rate. This is exactly the scenario the refund-overcharge bug
  // (fixed manually earlier this session, see _ReturnableLine's own doc
  // comment in pos_return_screen.dart) was found on: the fix derives a
  // return's amounts as a proportion of the invoice line's OWN stored
  // totals, never by recomputing qty x rate from scratch. A full return
  // here must refund exactly the discounted total actually charged.
  await pinLogin(page);
  const saleTotalCdf = await ringUpCashSale(page, 'PRD-00002', 'Fanta 330 MS', 3);
  const invoiceNo = await findJustCreatedInvoice(saleTotalCdf);

  await openReturnFor(page, invoiceNo, 'Fanta 330 MS');
  await setReturnQtyViaNumpad(page, 3);
  await expect(textVisible(page, saleTotalCdf.toFixed(2))).toBeVisible({ timeout: 10000 });

  await submitReturnAndDecline(page);

  await withDb(async (db) => {
    const res = await db.query(
      `SELECT status, refund_amount_local, return_total FROM rih_sales_return_headers
       WHERE invoice_no = $1 ORDER BY created_at DESC LIMIT 1`,
      [invoiceNo],
    );
    expect(res.rows.length, `No return row found against invoice ${invoiceNo}`).toBe(1);
    const ret = res.rows[0];
    expect(ret.status).toBe('APPROVED');
    // The real regression check: refund must equal what was ACTUALLY
    // collected (already net of the scheme discount), not a naive
    // qty x rate recompute (which would overcharge the refund since it'd
    // ignore the free unit entirely).
    expect(Number(ret.refund_amount_local)).toBeCloseTo(saleTotalCdf, 2);
    expect(Number(ret.return_total)).toBeCloseTo(saleTotalCdf, 2);
  });
});
