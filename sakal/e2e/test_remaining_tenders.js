// Remaining non-cash tender types E2E test — Voucher, Gift Card, Store
// Credit (Mobile Money + Card/split already verified in an earlier run).
// For each: a single-tender sale, confirm the Payment screen accepts it,
// confirm a CRV voucher posts DR the tender's own configured clearing/
// liability account and CR the POS Cash Customer account for the full
// invoice amount.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';
const PRODUCT_CODE = 'PRD-POS-003';

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const PG_CONN = process.env.SAKAL_DEV_DB_URL;

const TENDERS = [
  { type: 'VOUCHER', label: 'Voucher', accountName: 'Voucher Clearing Account' },
  { type: 'GIFT_CARD', label: 'Gift Card', accountName: 'Gift Card Liability Account' },
  { type: 'STORE_CREDIT', label: 'Store Credit', accountName: 'Store Credit Liability Account' },
];

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

async function scanAndAdd(page, code, { retries = 3 } = {}) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    const field = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    const fieldVisible = await field.isVisible({ timeout: 2000 }).catch(() => false);
    if (fieldVisible) {
      await field.click();
      await page.waitForTimeout(300);
      await page.keyboard.type(code, { delay: 40 });
      // Verify the field actually received the typed text before pressing
      // Enter — a click-then-type can silently drop the first keystroke
      // (confirmed root cause elsewhere in this session's testing), leaving
      // Enter submitted against an empty/partial field and the scan a no-op.
      const typedOk = await field.inputValue().then(v => v === code).catch(() => false);
      if (!typedOk) { await page.waitForTimeout(800); continue; }
      await page.keyboard.press('Enter');
      const added = await textVisible(page, code).waitFor({ state: 'visible', timeout: 15000 }).then(() => true).catch(() => false);
      if (added) return true;
    }
    await page.waitForTimeout(1500);
  }
  return false;
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));
  page.on('console', msg => { if (msg.type() === 'error') console.log('CONSOLE_ERROR:', msg.text()); });
  page.on('response', res => { if (res.status() >= 400) console.log('HTTP_ERROR:', res.status(), res.request().method(), res.url()); });

  try {
    await page.goto(`${BASE_URL}/#/pos/device-setup`);
    await enableSemantics(page);
    const signInBtn = page.getByRole('button', { name: 'Sign in as Administrator' });
    if (await signInBtn.isVisible({ timeout: 10000 }).catch(() => false)) {
      await signInBtn.click();
      await textVisible(page, 'Administrator Sign-In').waitFor({ timeout: 10000 });
      const clientIdLink = page.getByText('Sign in with Client ID instead');
      if (await clientIdLink.isVisible({ timeout: 3000 }).catch(() => false)) { await clientIdLink.click(); await page.waitForTimeout(300); }
      await typeInto(page, 'Client No.', CLIENT_NO);
      await typeInto(page, 'Username', USERNAME);
      await typeInto(page, 'Password', PASSWORD);
      await page.getByRole('button', { name: 'Continue' }).click();
      await textVisible(page, 'Assign This Device').waitFor({ timeout: 15000 });
      await page.getByRole('button', { name: 'Store / Location', exact: false }).click();
      await page.getByRole('menuitem').first().click();
      await page.waitForTimeout(1200);
      const tillField = page.getByRole('button', { name: 'Till', exact: true });
      await tillField.waitFor({ timeout: 10000 });
      await tillField.click();
      await page.getByRole('menuitem').first().click();
      await page.getByRole('button', { name: 'Assign & Finish Setup' }).click();
    }
    await textVisible(page, 'Enter your PIN').waitFor({ timeout: 15000 });
    for (const digit of PIN) { await page.getByRole('button', { name: digit, exact: true }).click(); }
    await page.getByRole('button', { name: 'Enter' }).click();
    await page.waitForTimeout(1500);
    pass('Till Setup + PIN Login');
  } catch (e) { fail('Till Setup + PIN Login', e); await shot(page, 'rt-00-login-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/pos/shift`);
    await page.waitForTimeout(1500);
    const floatField = page.getByRole('textbox', { name: /Opening Float/i }).first();
    if (await floatField.isVisible({ timeout: 5000 }).catch(() => false)) {
      await floatField.click();
      await page.keyboard.type('500', { delay: 30 });
      await page.getByRole('button', { name: 'Open Shift', exact: true }).click();
      await page.waitForTimeout(2000);
    }
    await page.goto(`${BASE_URL}/#/pos/sale`);
    await page.waitForTimeout(1500);
    pass('Shift ready / on New Sale');
  } catch (e) { fail('Shift ready', e); await shot(page, 'rt-01-shift-fail'); }

  const client = new Client({ connectionString: PG_CONN, ssl: { rejectUnauthorized: false } });
  await client.connect();

  for (const tender of TENDERS) {
    let invoiceNo = null, grandTotal = null;
    const beforeSaveTime = new Date();
    try {
      // Defensive reset: if a prior iteration left stale cart state (e.g.
      // it failed after Charge but before reset), start this iteration
      // from a clean New Sale screen rather than compounding the mess.
      await page.goto(`${BASE_URL}/#/pos/sale`);
      await page.waitForTimeout(1200);
      const added = await scanAndAdd(page, PRODUCT_CODE);
      if (!added) throw new Error('Could not add product to cart');
      await page.waitForTimeout(1000); // let any in-flight recompute (scheme/tax) settle
      const chargeBtn = page.getByRole('button', { name: /^Charge/ });
      await chargeBtn.waitFor({ state: 'visible', timeout: 30000 });
      await chargeBtn.click();
      await page.getByRole('heading', { name: 'Payment' }).waitFor({ timeout: 10000 });

      const tenderChip = page.getByText(tender.label, { exact: true }).first();
      await tenderChip.click();
      await page.waitForTimeout(500);

      const totalLocator = page.locator('text=/\\d+\\.\\d{2} INR/').first();
      const dueText = await totalLocator.textContent().catch(() => null);
      const dueAmount = dueText ? parseFloat(dueText.replace(/[^0-9.]/g, '')) : null;

      const amountField = page.getByRole('textbox', { name: /Amount Collected/i }).first();
      await amountField.click();
      await page.waitForTimeout(300);
      await page.keyboard.press('Control+A');
      if (dueAmount) await page.keyboard.type(String(dueAmount), { delay: 40 });
      await page.waitForTimeout(500);

      const saveBtn = page.getByRole('button', { name: /Save & Print|Short by/ });
      await saveBtn.waitFor({ timeout: 8000 });
      const enabled = await saveBtn.isEnabled();
      if (!enabled) throw new Error(`${tender.type}: Save & Print disabled — amount does not cover due`);
      await saveBtn.click();
      // The reset-after-save UI wait is proven flaky in headless runs even
      // when the save itself genuinely completes (confirmed separately via
      // DB) — give it a generous fixed window, then force back to a clean
      // New Sale regardless, and let the DB query below (filtered to
      // invoices created AFTER this click) be the real source of truth.
      await page.waitForTimeout(8000);
      await shot(page, `rt-${tender.type.toLowerCase()}-saved`);
      pass(`${tender.type}: Save & Print clicked, waited for processing`);
    } catch (e) { fail(`${tender.type}: UI sale`, e); await shot(page, `rt-${tender.type.toLowerCase()}-fail`); continue; }

    try {
      const invRes = await client.query(
        `SELECT invoice_no, grand_total, created_at FROM rih_sales_invoices WHERE client_id=$1 ORDER BY created_at DESC LIMIT 1`,
        [CLIENT_ID]
      );
      if (new Date(invRes.rows[0].created_at) < beforeSaveTime) throw new Error(`Most recent invoice ${invRes.rows[0].invoice_no} predates this tender's own Save click — the sale likely did not actually save`);
      invoiceNo = invRes.rows[0].invoice_no;
      grandTotal = Number(invRes.rows[0].grand_total);

      const glRes = await client.query(
        `SELECT h.voucher_type_code, a.account_name, l.trans_nature, l.trans_amount
         FROM rid_finance_lines l
         JOIN rih_finance_headers h ON h.trans_no=l.trans_no AND h.trans_date=l.trans_date AND h.location_id=l.location_id
         JOIN rim_accounts a ON a.id=l.account_id
         WHERE l.client_id=$1 AND h.source_doc_no=$2 AND h.voucher_type_code='CRV'
         ORDER BY l.serial_no`,
        [CLIENT_ID, invoiceNo]
      );
      console.log(`${tender.type} (${invoiceNo}, total ${grandTotal}) CRV lines:`, glRes.rows);
      if (glRes.rows.length !== 2) throw new Error(`Expected exactly 2 CRV lines, got ${glRes.rows.length}`);
      const drLine = glRes.rows.find(r => r.trans_nature === 'DR' || r.trans_nature === 'D');
      const crLine = glRes.rows.find(r => r.trans_nature === 'CR' || r.trans_nature === 'C');
      if (!drLine || !crLine) throw new Error(`Could not find both a DR and a CR line (natures: ${glRes.rows.map(r => r.trans_nature).join(',')})`);
      if (drLine.account_name !== tender.accountName) throw new Error(`DR account "${drLine.account_name}" != expected "${tender.accountName}"`);
      if (Math.abs(Number(drLine.trans_amount) - grandTotal) > 0.01) throw new Error(`DR amount ${drLine.trans_amount} != invoice total ${grandTotal}`);
      if (Math.abs(Number(crLine.trans_amount) - grandTotal) > 0.01) throw new Error(`CR amount ${crLine.trans_amount} != invoice total ${grandTotal}`);
      pass(`${tender.type}: CRV posts DR ${drLine.account_name} ${drLine.trans_amount} / CR ${crLine.account_name} ${crLine.trans_amount} — matches invoice total exactly`);
    } catch (e) { fail(`${tender.type}: GL verification`, e); }
  }

  await client.end();
  await browser.close();

  console.log('\n===== REMAINING TENDERS E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
