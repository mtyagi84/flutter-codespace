// Phase 2 (Finance Core) — Contra Voucher. Tests a Cash→Bank transfer:
// From = [5100001] QA Petty Cash EUR (100 EUR), To = [5200001] Main Bank
// USD (accepting the system-suggested amount, no manual edit — avoids
// needing to also test the Exchange Gain/Loss difference-row path this
// pass). Save Draft then Approve, DB-verifying the resulting GL posting.
// Per the rubric: Currency applies directly (a genuine cross-currency
// transfer, EUR->USD), GL effect applies directly, Stock doesn't apply,
// Chain doesn't apply. This screen uses FinanceAccountPicker (the modal
// picker, same as Journal Voucher) — confirmed via code read, not
// re-diagnosed from scratch.
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

async function pickFromModal(page, searchText, rowX = 660, rowY = 621) {
  // IMPORTANT: do not assume the modal's search box has keyboard focus just
  // because the modal is open -- when a PRIOR field (e.g. the FROM Amount
  // field, auto-focused after picking FROM) still holds focus, typing
  // immediately after opening the TO modal silently leaks into that prior
  // field instead of the modal's search box. Always click the search box
  // explicitly first. Diagnosed live via diag_ctr_to2/3/4.js screenshots.
  await page.mouse.click(800, 506); // modal search box, confirmed via screenshot
  await page.waitForTimeout(300);
  await page.keyboard.type(searchText, { delay: 60 });
  await page.waitForTimeout(700);
  await page.mouse.click(rowX, rowY);
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
  } catch (e) { fail('Login', e); await shot(page, 'ctr-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/finance/contra-entry`);
    await textVisible(page, 'REMARKS').waitFor({ state: 'visible', timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(2000);
    await shot(page, 'ctr-01-loaded');
    pass('Contra Voucher entry screen loaded');
  } catch (e) { fail('Open Contra Voucher', e); await shot(page, 'ctr-01-fail'); }

  try {
    // FROM Account field. NOTE: once both accounts are picked and have
    // different currencies, a new "Exchange Rate (System)" / "Actual Rate"
    // row appears between Reference No/Date and the From/To blocks, shifting
    // everything below it down ~55px (same layout-shift class of bug as
    // Journal Voucher's Currency field, documented earlier this session) --
    // coordinates below are calibrated for the POST-shift (both accounts
    // picked) state, confirmed via ctr-06-saved.png.
    await page.mouse.click(580, 236);
    await page.waitForTimeout(400);
    await pickFromModal(page, 'QA Petty Cash');
    await shot(page, 'ctr-02-from-picked');
    pass('FROM account set to [5100001] QA Petty Cash EUR');
  } catch (e) { fail('Pick FROM account', e); await shot(page, 'ctr-02-fail'); }

  try {
    await page.mouse.click(630, 284); // FROM Amount field (pre-shift, before TO is picked)
    await page.waitForTimeout(150);
    await page.keyboard.type('100', { delay: 30 });
    await shot(page, 'ctr-03-from-amount-filled');
    pass('FROM amount = 100');
  } catch (e) { fail('Fill FROM amount', e); await shot(page, 'ctr-03-fail'); }

  try {
    // TO Account field (still pre-shift here -- the rate strip only
    // appears once TO is also picked, i.e. right after this step).
    await page.mouse.click(1258, 236);
    await page.waitForTimeout(400);
    await pickFromModal(page, 'Main Bank');
    await page.waitForTimeout(400); // let the new Exchange Rate strip render and shift layout
    await shot(page, 'ctr-04-to-picked');
    pass('TO account set to [5200001] Main Bank USD');
  } catch (e) { fail('Pick TO account', e); await shot(page, 'ctr-04-fail'); }

  try {
    // The auto-suggested "Amount Received" value renders as selected/
    // highlighted text but is NOT a committed field value until something
    // confirms it -- clicking elsewhere (the Remarks field) commits it
    // without changing it, avoiding the Exchange Gain/Loss difference-row
    // path for this minimal-coverage pass. Confirmed live: Save Draft
    // failed with "Enter both amounts" when this commit step was skipped.
    // Remarks is now POST-shift (rate strip visible) -- y=403, not 396.
    await page.mouse.click(920, 403); // Remarks field -- commits TO amount
    await page.waitForTimeout(300);
    await shot(page, 'ctr-05-to-amount-auto');
    pass('TO amount left at system-suggested value (no manual edit)');
  } catch (e) { fail('Check TO amount', e); await shot(page, 'ctr-05-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'ctr-06-saved');
    pass('Contra Voucher saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'ctr-06-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'ctr-07-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'ctr-08-approved');
    pass('Contra Voucher approved');
  } catch (e) { fail('Approve', e); await shot(page, 'ctr-07-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT trans_no, trans_date, is_posted, voucher_type_code FROM rih_finance_headers
       WHERE company_id=$1 AND voucher_type_code='CTR' ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest CTR header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No CTR header found');
    if (header.rows[0].is_posted !== true) throw new Error(`is_posted=${header.rows[0].is_posted}, expected true`);
    pass(`DB: Contra Voucher ${header.rows[0].trans_no} correctly posted`);

    const lines = await dbClient.query(
      `SELECT a.account_code, a.account_name, a.account_nature, l.trans_nature, l.trans_amount, l.trans_currency, l.base_amount
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 AND l.trans_date=$3
       ORDER BY l.serial_no`,
      [companyId, header.rows[0].trans_no, header.rows[0].trans_date]
    );
    console.log('CTR lines in DB:', lines.rows);
    if (lines.rows.length < 2) throw new Error(`Expected at least 2 lines, found ${lines.rows.length}`);
    const fromLine = lines.rows.find(r => r.account_code === '5100001');
    const toLine = lines.rows.find(r => r.account_code === '5200001');
    if (!fromLine || fromLine.trans_nature !== 'CR') throw new Error('FROM line (Cash) not Cr as expected for a transfer out');
    if (!toLine || toLine.trans_nature !== 'DR') throw new Error('TO line (Bank) not Dr as expected for a transfer in');
    const totalDr = lines.rows.filter(r => r.trans_nature === 'DR').reduce((s, r) => s + Number(r.base_amount), 0);
    const totalCr = lines.rows.filter(r => r.trans_nature === 'CR').reduce((s, r) => s + Number(r.base_amount), 0);
    if (Math.abs(totalDr - totalCr) > 0.01) throw new Error(`Voucher does not balance: Dr=${totalDr}, Cr=${totalCr}`);
    pass(`DB: transfer correctly posted — Cr [5100001] Cash EUR / Dr [5200001] Bank USD, ${lines.rows.length} line(s), balanced (base Dr=${totalDr.toFixed(2)}, Cr=${totalCr.toFixed(2)})`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 2: CONTRA VOUCHER RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
