const { test, expect } = require('@playwright/test');
const { enableSemantics, textVisible } = require('../helpers/flutter');
const { withDb } = require('../helpers/db');

// Phase 3 (Non-cash tender settlement) — see TEST_PLAN.md. Runs on the
// default `chromium` project (Till 1): charging via a non-cash tender
// never opens/closes a shift, same reasoning as Phase 2's returns.spec.js.
//
// PREREQUISITE, confirmed live and fixed this session: this tenant had
// NO non-cash tender settlement accounts configured in Account Link Setup
// at all (CARD/MOBILE_MONEY/VOUCHER clearing, GIFT_CARD/STORE_CREDIT
// liability) — every non-cash POS sale was completing with its GL
// settlement silently soft-failed (fn_settle_pos_non_cash_tenders's own
// documented convention: a settlement failure must never block the
// already-approved sale). Configured directly in the DB (user-approved)
// pointing each at an existing suitable leaf account ("1170 Other Current
// Assets" for the 3 clearing types, "2170 Other Current Liabilities" for
// the 2 liability types) so these tests have something real to verify.
// Separately, a NEW client-side guard now disables a non-cash tender
// option on the Payment screen entirely when its own link isn't
// configured (pos_payment_checkout_screen.dart's `configuredTenderTypes`)
// — prevents this exact silent-failure class for every future tenant,
// not just this one.
const PIN = process.env.POS_PIN;
test.skip(!PIN, 'Set POS_PIN to a real cashier PIN for this tenant to run this test.');
test.skip(!process.env.DATABASE_URL, 'Set DATABASE_URL to verify the real GL posting.');

async function pinLogin(page) {
  await page.goto('/#/pos/login');
  await enableSemantics(page);
  await expect(textVisible(page, 'Enter your PIN')).toBeVisible({ timeout: 15000 });
  for (const digit of PIN) await page.getByRole('button', { name: digit, exact: true }).click();
  await page.getByRole('button', { name: 'Enter' }).click();
}

// Rings up one Fanta 330 MS (PRD-00002), qty 1, paid via the given
// non-cash tender mode (its chip label, e.g. 'Card'). Returns the real
// grand total read off the Payment screen.
async function ringUpSaleWithTender(page, tenderLabel) {
  const searchField = page.getByRole('textbox', { name: 'Scan barcode or search product…' });
  await expect(searchField).toBeVisible({ timeout: 20000 });
  await searchField.fill('PRD-00002');
  await searchField.press('Enter');
  await expect(textVisible(page, 'Fanta 330 MS')).toBeVisible({ timeout: 10000 });

  await page.getByRole('button', { name: /^Charge / }).click();
  await expect(page.getByRole('heading', { name: 'Payment' })).toBeVisible({ timeout: 10000 });

  // Switching the Payment Mode chip does NOT reset the Amount Collected
  // field — it already defaults to the full due amount from the CASH
  // default (pos_payment_checkout_screen.dart's `_PayLine` only mutates
  // `tenderType` on tap, confirmed via direct source read), so no
  // retyping is needed for a single-tender sale.
  await page.getByRole('button', { name: tenderLabel, exact: true }).click();

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

// label (Payment Mode chip text) -> [tender_type, expected clearing/
// liability account code]. Card/Mobile Money/Voucher clearing were all
// pointed at "1170 Other Current Assets"; Gift Card/Store Credit
// liability at "2170 Other Current Liabilities" (configured this
// session, see the header comment above).
const TENDER_CASES = [
  ['Card', 'CARD', '1170'],
  ['Mobile Money', 'MOBILE_MONEY', '1170'],
  ['Voucher', 'VOUCHER', '1170'],
  ['Gift Card', 'GIFT_CARD', '2170'],
  ['Store Credit', 'STORE_CREDIT', '2170'],
];

for (const [label, tenderType, expectedAccountCode] of TENDER_CASES) {
  test(`a ${label} sale settles via a real Receipt Voucher posted to its own clearing/liability account`, async ({ page }) => {
    page.on('console', (msg) => { if (msg.type() === 'error' || msg.text().includes('[ERROR]')) console.log('[browser]', msg.text()); });
    page.on('pageerror', (err) => console.log('[pageerror]', err.message));

    await pinLogin(page);
    const saleTotalCdf = await ringUpSaleWithTender(page, label);

    await withDb(async (db) => {
      const invoiceRes = await db.query(
        `SELECT invoice_no, invoice_date, grand_total, status FROM rih_sales_invoices
         WHERE sale_type = 'CASH' ORDER BY created_at DESC LIMIT 1`,
      );
      expect(invoiceRes.rows.length, 'No invoice found right after ringing up the sale').toBe(1);
      const invoice = invoiceRes.rows[0];
      expect(invoice.status).toBe('APPROVED');
      expect(Number(invoice.grand_total)).toBeCloseTo(saleTotalCdf, 2);

      // The tender line itself: correct tender_type, status='SUCCESS',
      // and its own amount matches the full sale total (single-tender).
      const tenderRes = await db.query(
        `SELECT tender_type, amount, status FROM rid_pos_tender_lines
         WHERE invoice_no = $1 AND invoice_date = $2`,
        [invoice.invoice_no, invoice.invoice_date],
      );
      expect(tenderRes.rows.length, 'No tender line found for this invoice').toBe(1);
      expect(tenderRes.rows[0].tender_type).toBe(tenderType);
      expect(tenderRes.rows[0].status).toBe('SUCCESS');
      expect(Number(tenderRes.rows[0].amount)).toBeCloseTo(saleTotalCdf, 2);

      // The real regression check this phase exists for: a Receipt
      // Voucher (CRV) was actually posted — DR the clearing/liability
      // account, CR the customer — tagged source_doc_type='POS_TENDER'
      // against this invoice, per fn_settle_pos_non_cash_tenders's own
      // header comment. This is also the exact code path a real,
      // previously-undiscovered bug was found and fixed on this session
      // (migration 224 — fn_settle_pos_non_cash_tenders was querying
      // source_doc_type/no/date on rid_finance_lines, which doesn't carry
      // those columns at all; they live on rih_finance_headers only).
      const headerRes = await db.query(
        `SELECT trans_no, trans_date, is_posted FROM rih_finance_headers
         WHERE voucher_type_code = 'CRV' AND source_doc_type = 'POS_TENDER' AND source_doc_no = $1
         ORDER BY created_at DESC LIMIT 1`,
        [invoice.invoice_no],
      );
      expect(headerRes.rows.length, `No CRV voucher posted for this ${label} sale's settlement`).toBe(1);
      const header = headerRes.rows[0];
      expect(header.is_posted).toBe(true);

      const linesRes = await db.query(
        `SELECT trans_nature, trans_amount, account_id FROM rid_finance_lines
         WHERE trans_no = $1 AND trans_date = $2 ORDER BY serial_no`,
        [header.trans_no, header.trans_date],
      );
      expect(linesRes.rows.length, 'The settlement voucher should have exactly 2 lines (DR clearing, CR customer)').toBe(2);
      const drLine = linesRes.rows.find((l) => l.trans_nature === 'DR');
      const crLine = linesRes.rows.find((l) => l.trans_nature === 'CR');
      expect(drLine, 'No DR line found').toBeTruthy();
      expect(crLine, 'No CR line found').toBeTruthy();
      expect(Number(drLine.trans_amount)).toBeCloseTo(saleTotalCdf, 2);
      expect(Number(crLine.trans_amount)).toBeCloseTo(saleTotalCdf, 2);

      const clearingRes = await db.query(
        `SELECT account_code FROM rim_accounts WHERE id = $1`,
        [drLine.account_id],
      );
      expect(clearingRes.rows[0]?.account_code).toBe(expectedAccountCode);
    });
  });
}
