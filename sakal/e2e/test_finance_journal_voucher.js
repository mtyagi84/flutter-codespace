// Phase 2 (Finance Core) — Journal Voucher. Tests a balanced 2-line JV
// (Dr [5800] Internal Transfers 500, Cr [1200] Retained Earnings 500),
// Save Draft then Approve, DB-verifying the resulting GL posting. Per the
// rubric: Currency applies directly (a required field on this voucher —
// base currency here, minimal-coverage pass), GL effect applies directly
// (this IS the posting), Stock doesn't apply, no Chain (nothing converts
// into a JV). Downstream (Trial Balance/Account Ledger reflection)
// deferred to the Finance Reports pass.
//
// Row coordinates are FIXED, not computed from text locators — "Account"/
// "Amount"/"Dr / Cr" each appear exactly ONCE as a column HEADER, not once
// per row, so an earlier version of this script that looked up "the Nth
// match" of that text always resolved to the same header element
// regardless of N, silently confusing which row it was interacting with
// (confirmed live: line 2's amount/nature clicks landed on line 1
// instead). Grid row height is 57px (row 1 at y=330, row 2 at y=387,
// confirmed via screenshot at 1600x1100 viewport).
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

// Selecting a Currency reveals a new "1 USD = ? CDF" exchange-rate input
// row beneath it, shifting the whole Account Lines grid down by ~37px
// compared to its pre-currency-selection position — these coordinates are
// calibrated AFTER currency selection (confirmed via screenshot at
// 1600x1100 viewport: row 1 at y=382, row 2 at y=439).
const ROW_Y = [382, 439];
const COL_X = { account: 420, amount: 913, drcr: 1031 };

async function pickAccountViaModal(page, searchText) {
  await page.keyboard.type(searchText, { delay: 50 });
  await page.waitForTimeout(600);
  // The modal's single matching row renders at a fixed position below its
  // own search box, regardless of which grid row triggered it.
  await page.mouse.click(660, 621);
  await page.waitForTimeout(500);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1600, height: 1100 } })).newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  const dbClient = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await dbClient.connect();
  const cRes = await dbClient.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
  const compRes = await dbClient.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [cRes.rows[0].id]);
  const companyId = compRes.rows[0].id;

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'jv-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/finance/journal`);
    await page.getByRole('button', { name: 'New Journal Voucher', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await page.getByRole('button', { name: 'New Journal Voucher', exact: true }).first().click();
    await textVisible(page, 'Account Lines').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(1000);
    await shot(page, 'jv-01-loaded');
    pass('Journal Voucher entry screen loaded');
  } catch (e) { fail('Open Journal Voucher', e); await shot(page, 'jv-01-fail'); }

  try {
    // Currency is a required field (confirmed live: saving without it
    // showed "Select a currency." and silently failed despite the click
    // succeeding) — set it to the company's base currency, USD.
    await page.mouse.click(1364, 95);
    await page.waitForTimeout(400);
    await shot(page, 'jv-01b-currency-dropdown');
    const usdOption = textVisible(page, 'USD').first();
    const found = await usdOption.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error('"USD" not found in Currency dropdown');
    await usdOption.click();
    await page.waitForTimeout(500);
    pass('Currency set to USD');
  } catch (e) { fail('Set Currency', e); await shot(page, 'jv-01b-fail'); }

  // ---------- Line 1: Dr 5800 Internal Transfers, 500 ----------
  try {
    await page.mouse.click(COL_X.account, ROW_Y[0]);
    await page.waitForTimeout(400);
    await pickAccountViaModal(page, '5800');
    await shot(page, 'jv-04-line1-account-picked');
    pass('Line 1: picked account [5800] Internal Transfers');
  } catch (e) { fail('Line 1: pick account', e); await shot(page, 'jv-03-fail'); }

  try {
    // Nature DR/CR dropdown already defaults to DR for a fresh line —
    // correct for line 1.
    await page.mouse.click(COL_X.amount, ROW_Y[0]);
    await page.waitForTimeout(150);
    await page.keyboard.type('500', { delay: 30 });
    await shot(page, 'jv-05-line1-amount-filled');
    pass('Line 1: Amount = 500 (Dr, default nature)');
  } catch (e) { fail('Line 1: fill amount', e); await shot(page, 'jv-05-fail'); }

  // ---------- Add line 2 (auto-opens the account picker for the new row) ----------
  try {
    // "Add line" auto-focuses the new row's Account field, which itself
    // auto-opens the picker modal — confirmed live via screenshot: right
    // after clicking Add line, the "Option" modal is ALREADY open with the
    // full unfiltered account list. Clicking the Account cell again (as an
    // earlier version of this script did) interferes with/dismisses that
    // already-open modal instead of opening a fresh one. Don't click the
    // field at all for line 2 — just search inside the already-open modal.
    const addLineBtn = page.getByRole('button', { name: 'Add line', exact: true }).first();
    await addLineBtn.click();
    await page.waitForTimeout(600);
    await shot(page, 'jv-06-line2-added');
    pass('Line 2 added (account picker modal auto-opened)');
  } catch (e) { fail('Add line 2', e); await shot(page, 'jv-06-fail'); }

  // ---------- Line 2: Cr 1200 Retained Earnings, 500 ----------
  try {
    await pickAccountViaModal(page, '1200');
    await shot(page, 'jv-08-line2-account-picked');
    pass('Line 2: picked account [1200] Retained Earnings');
  } catch (e) { fail('Line 2: pick account', e); await shot(page, 'jv-07-fail'); }

  try {
    await page.mouse.click(COL_X.drcr, ROW_Y[1]);
    await page.waitForTimeout(400);
    await shot(page, 'jv-09-drcr-dropdown-opened');
    // CR is the 2nd menu item, directly below DR.
    await page.mouse.click(COL_X.drcr, ROW_Y[1] + 48);
    await page.waitForTimeout(400);
    pass('Line 2: Dr/Cr set to CR');
  } catch (e) { fail('Line 2: set CR', e); await shot(page, 'jv-09-fail'); }

  try {
    await page.mouse.click(COL_X.amount, ROW_Y[1]);
    await page.waitForTimeout(150);
    await page.keyboard.type('500', { delay: 30 });
    await shot(page, 'jv-10-line2-amount-filled');
    pass('Line 2: Amount = 500 (Cr)');
  } catch (e) { fail('Line 2: fill amount', e); await shot(page, 'jv-10-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'jv-11-saved');
    const stillOnEntry = await textVisible(page, 'Select a currency').isVisible({ timeout: 1000 }).catch(() => false);
    if (stillOnEntry) throw new Error('Save blocked — "Select a currency." validation error still showing');
    pass('Journal Voucher saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'jv-11-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'jv-12-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'jv-13-approved');
    pass('Journal Voucher approved');
  } catch (e) { fail('Approve', e); await shot(page, 'jv-12-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT trans_no, trans_date, is_posted, voucher_type_code FROM rih_finance_headers
       WHERE company_id=$1 AND voucher_type_code='JV' ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest JV header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No JV header found');
    if (header.rows[0].is_posted !== true) throw new Error(`is_posted=${header.rows[0].is_posted}, expected true`);
    pass(`DB: JV ${header.rows[0].trans_no} correctly posted (is_posted=true)`);

    const lines = await dbClient.query(
      `SELECT a.account_code, a.account_name, l.trans_nature, l.trans_amount, l.base_amount
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 AND l.trans_date=$3
       ORDER BY l.serial_no`,
      [companyId, header.rows[0].trans_no, header.rows[0].trans_date]
    );
    console.log('JV lines in DB:', lines.rows);
    if (lines.rows.length !== 2) throw new Error(`Expected 2 lines, found ${lines.rows.length}`);
    const drLine = lines.rows.find(r => r.account_code === '5800');
    const crLine = lines.rows.find(r => r.account_code === '1200');
    if (!drLine || drLine.trans_nature !== 'DR' || Number(drLine.trans_amount) !== 500) throw new Error('5800 line not Dr 500 as expected');
    if (!crLine || crLine.trans_nature !== 'CR' || Number(crLine.trans_amount) !== 500) throw new Error('1200 line not Cr 500 as expected');
    pass('DB: both lines correctly posted — Dr [5800] 500, Cr [1200] 500, balanced');
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 2: JOURNAL VOUCHER RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
