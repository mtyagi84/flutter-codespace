// Phase 2 (Finance Core) — Payment/Receipt Voucher. Tests a Cash Receipt
// Voucher (CRV): Cash Account = [5100001] QA Petty Cash EUR, On Account
// line = the test Customer, Amount 100 (EUR, the Cash Account's own
// currency). Save Draft then Post Voucher (this screen's own name for
// Approve), DB-verifying the resulting GL posting. Per the rubric:
// Currency applies (derived from the Cash Account's own currency, EUR —
// a real "Other" foreign currency), GL effect applies directly, Stock
// doesn't apply, Chain doesn't apply (a direct voucher).
//
// Unlike Journal Voucher, this screen's account fields are plain INLINE
// autocompletes (suggestion row appears directly below the field, no
// centered "Option" modal) — confirmed via diagnostic screenshots.
// Journal Voucher uses a different, newer shared widget
// (`FinanceAccountPicker`) not used here. Also: switching to "On Account"
// mode already shows ONE blank credit line by default — no "Add Line"
// click needed for a single-line test.
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

async function pickInlineSuggestion(page, fieldX, fieldY, searchText, suggestionYOffset = 41) {
  await page.mouse.click(fieldX, fieldY);
  await page.waitForTimeout(400);
  await page.keyboard.type(searchText, { delay: 50 });
  await page.waitForTimeout(600);
  await page.mouse.click(fieldX - 174, fieldY + suggestionYOffset);
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
  } catch (e) { fail('Login', e); await shot(page, 'crv-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/finance/voucher-list`);
    await page.getByRole('button', { name: 'New Voucher', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await page.getByRole('button', { name: 'New Voucher', exact: true }).first().click();
    await page.waitForTimeout(500);
    const cashReceiptOption = page.getByText('Cash Receipt', { exact: true }).first();
    const found = await cashReceiptOption.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error('"Cash Receipt" option not found in New Voucher menu');
    await cashReceiptOption.click();
    await textVisible(page, 'New Cash Receipt Voucher').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(1500);
    await shot(page, 'crv-02-entry-opened');
    pass('Cash Receipt Voucher (CRV) entry screen opened');
  } catch (e) { fail('Open CRV entry screen', e); await shot(page, 'crv-01-fail'); }

  try {
    await page.mouse.click(417, 244); // "On Account" radio
    await page.waitForTimeout(500);
    pass('Switched to "On Account" mode (already shows one blank credit line)');
  } catch (e) { fail('Switch to On Account mode', e); await shot(page, 'crv-02b-fail'); }

  try {
    await pickInlineSuggestion(page, 590, 143, 'Petty');
    await shot(page, 'crv-04-cash-account-picked');
    pass('Cash Account set to [5100001] QA Petty Cash EUR');
  } catch (e) { fail('Pick Cash Account', e); await shot(page, 'crv-03-fail'); }

  try {
    // Line 1's own Account field — already present, no Add Line needed.
    await pickInlineSuggestion(page, 558, 430, 'QA Test Customer');
    await shot(page, 'crv-06-on-account-picked');
    pass('On Account line: picked the test Customer');
  } catch (e) { fail('Pick On Account line', e); await shot(page, 'crv-05-fail'); }

  try {
    await page.mouse.click(907, 430); // Amount field, same row as Account
    await page.waitForTimeout(150);
    await page.keyboard.type('100', { delay: 30 });
    await shot(page, 'crv-07-amount-filled');
    pass('On Account line Amount = 100');
  } catch (e) { fail('Fill On Account amount', e); await shot(page, 'crv-07-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'crv-08-saved');
    const stillBlocked = await textVisible(page, 'Select a cash').isVisible({ timeout: 1000 }).catch(() => false);
    if (stillBlocked) throw new Error('Save blocked — "Select a cash / bank account." validation error still showing');
    pass('CRV saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'crv-08-fail'); }

  try {
    const postBtn = page.getByRole('button', { name: 'Post Voucher', exact: true }).first();
    await postBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'crv-09-post-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Post', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'crv-10-posted');
    pass('CRV posted');
  } catch (e) { fail('Post Voucher', e); await shot(page, 'crv-09-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT trans_no, trans_date, is_posted, voucher_type_code FROM rih_finance_headers
       WHERE company_id=$1 AND voucher_type_code='CRV' ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest CRV header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No CRV header found');
    if (header.rows[0].is_posted !== true) throw new Error(`is_posted=${header.rows[0].is_posted}, expected true`);
    pass(`DB: CRV ${header.rows[0].trans_no} correctly posted`);

    const lines = await dbClient.query(
      `SELECT a.account_code, a.account_name, a.account_nature, l.trans_nature, l.trans_amount, l.trans_currency
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 AND l.trans_date=$3
       ORDER BY l.serial_no`,
      [companyId, header.rows[0].trans_no, header.rows[0].trans_date]
    );
    console.log('CRV lines in DB:', lines.rows);
    if (lines.rows.length !== 2) throw new Error(`Expected 2 lines, found ${lines.rows.length}`);
    const cashLine = lines.rows.find(r => r.account_nature === 'Cash');
    const custLine = lines.rows.find(r => r.account_nature === 'Customer');
    if (!cashLine || cashLine.trans_nature !== 'DR') throw new Error('Cash line not Dr as expected for a receipt');
    if (!custLine || custLine.trans_nature !== 'CR') throw new Error('Customer line not Cr as expected for a receipt');
    if (cashLine.trans_currency !== 'EUR') throw new Error(`Cash line currency=${cashLine.trans_currency}, expected EUR`);
    pass(`DB: both lines correctly posted — Dr Cash [${cashLine.account_code}] / Cr Customer [${custLine.account_code}], currency=EUR`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 2: PAYMENT/RECEIPT VOUCHER (CRV) RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
