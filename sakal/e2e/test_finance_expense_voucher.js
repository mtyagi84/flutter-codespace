// Phase 2 (Finance Core) — Expense Voucher. Tests a simple service-bill
// accrual with a normal VAT tax: Supplier [4010001] QA Test Supplier,
// Expense Account [6500001] QA Office Supplies 69224, Amount 1000 USD,
// Tax Group "TVA Standard 16%" (ADD-nature, gl_input_account_id already
// configured on its member tax VAT_STD). Per the rubric: Currency applies
// (kept to base USD for this minimal pass, matching Journal Voucher's own
// precedent), GL effect applies directly (this IS the posting, EXP
// voucher: Dr Expense 1000, Dr Input VAT 160, Cr Supplier 1160), Stock/
// Chain don't apply. Withholding-tax variant (EXV-C02) deferred -- the
// only withholding tax on this tenant has no gl_expense_account_id
// configured yet.
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

async function pickFromModal(page, searchText, rowX = 660, rowY = 621, searchY = 365) {
  // Always click the modal's search box explicitly before typing -- do not
  // assume it holds focus just because the modal is open (confirmed real
  // bug class on Contra Voucher this session). NOTE: this modal's own
  // on-screen Y position is NOT constant across screens -- confirmed via
  // screenshot it renders at y~365 (search box) on Expense Voucher vs
  // y~506 on Contra Voucher, even though it's the same FinanceAccountPicker
  // widget. Never assume a coordinate carries over screen to screen. The
  // filtered single-result row position (y=621), however, IS consistent
  // between screens -- confirmed via diag_exv5.js: search box at y~365,
  // but the filtered single row still lands at y~621, same offset pattern
  // as Contra Voucher's own modal.
  await page.mouse.click(800, searchY);
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
  } catch (e) { fail('Login', e); await shot(page, 'exv-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/finance/expense-vouchers`);
    await page.waitForTimeout(2000);
    const newBtn = page.getByText(/New Expense Voucher/i).first();
    if (await newBtn.count() > 0) { await newBtn.click(); }
    await page.waitForTimeout(4000); // line 1's Expense Account auto-opens its modal
    await shot(page, 'exv-01-loaded');
    pass('Expense Voucher entry screen loaded');
  } catch (e) { fail('Open Expense Voucher', e); await shot(page, 'exv-01-fail'); }

  try {
    // Line 1's Expense Account modal is already open (auto-focused on load,
    // same UX as Journal Voucher's "Add line" auto-opening its picker).
    await pickFromModal(page, 'Office Supplies');
    await shot(page, 'exv-02-expense-account-picked');
    pass('Expense Account set to [6500001] QA Office Supplies');
  } catch (e) { fail('Pick Expense Account', e); await shot(page, 'exv-02-fail'); }

  try {
    await page.mouse.click(868, 281); // Amount field (line 1)
    await page.waitForTimeout(150);
    await page.keyboard.type('1000', { delay: 30 });
    await shot(page, 'exv-03-amount-filled');
    pass('Amount = 1000');
  } catch (e) { fail('Fill Amount', e); await shot(page, 'exv-03-fail'); }

  try {
    await page.mouse.click(1036, 281); // Tax Group dropdown (line 1)
    await page.waitForTimeout(600);
    await shot(page, 'exv-04-taxgroup-dropdown');
    // Native Flutter dropdown overlay menu -- items are None/VAT_ZERO_GRP/
    // QAG99529/VAT_STD_GRP, confirmed via diag_exv6.js screenshot.
    await page.mouse.click(1040, 430); // VAT_STD_GRP = "TVA Standard 16%"
    await page.waitForTimeout(400);
    await shot(page, 'exv-04b-taxgroup-picked');
    pass('Tax Group set to TVA Standard 16%');
  } catch (e) { fail('Pick Tax Group', e); await shot(page, 'exv-04-fail'); }

  try {
    // Supplier field (top-right, same modal picker pattern, but this
    // modal instance renders at yet ANOTHER screen position than the
    // auto-opened Expense Account one -- confirmed via diag_exv7.js
    // screenshot: search box at y~531 here, not y~365. Also pre-filtered
    // to Supplier-nature accounts only, so the one seeded test supplier
    // is already the sole row even before typing.
    await page.mouse.click(1360, 76);
    await page.waitForTimeout(500);
    await pickFromModal(page, 'QA Test Supplier', 660, 621, 531);
    await shot(page, 'exv-05-supplier-picked');
    pass('Supplier set to [4010001] QA Test Supplier');
  } catch (e) { fail('Pick Supplier', e); await shot(page, 'exv-05-fail'); }

  try {
    await page.mouse.click(477, 128); // Currency dropdown
    await page.waitForTimeout(500);
    await shot(page, 'exv-06-currency-dropdown');
    // Items: CDF/EUR/USD, confirmed via diag_exv6.js screenshot. Picking
    // base currency USD to keep this minimal pass simple (same precedent
    // as Journal Voucher's own base-currency-only first pass).
    await page.mouse.click(480, 231);
    await page.waitForTimeout(400);
    await shot(page, 'exv-06b-currency-picked');
    pass('Currency selected (USD, base)');
  } catch (e) { fail('Pick Currency', e); await shot(page, 'exv-06-fail'); }

  try {
    await page.mouse.click(918, 128); // Bill No field
    await page.waitForTimeout(150);
    await page.keyboard.type('QA-BILL-001', { delay: 30 });
    await shot(page, 'exv-07-billno-filled');
    pass('Bill No = QA-BILL-001');
  } catch (e) { fail('Fill Bill No', e); await shot(page, 'exv-07-fail'); }

  try {
    // Bill Date is also required despite no visible asterisk (confirmed
    // live: Save Draft failed with "Enter the supplier's Bill No and Bill
    // Date." when left blank). Opens a native Material date picker.
    await page.mouse.click(1360, 133);
    await page.waitForTimeout(600);
    await shot(page, 'exv-07b-billdate-picker');
    await page.mouse.click(1011, 696); // OK button, today's date pre-selected
    await page.waitForTimeout(400);
    pass('Bill Date = today');
  } catch (e) { fail('Fill Bill Date', e); await shot(page, 'exv-07b-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'exv-08-saved');
    pass('Expense Voucher saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'exv-08-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'exv-09-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'exv-10-approved');
    pass('Expense Voucher approved');
  } catch (e) { fail('Approve', e); await shot(page, 'exv-09-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT trans_no, trans_date, status, posted_voucher_no FROM rih_expense_voucher_headers
       WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest Expense Voucher header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No expense voucher header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}, expected APPROVED`);
    pass(`DB: Expense Voucher ${header.rows[0].trans_no} correctly approved, posted as ${header.rows[0].posted_voucher_no}`);

    const finHeader = await dbClient.query(
      `SELECT trans_no, is_posted, voucher_type_code FROM rih_finance_headers
       WHERE company_id=$1 AND trans_no=$2`,
      [companyId, header.rows[0].posted_voucher_no]
    );
    console.log('Posted EXP voucher header:', finHeader.rows);
    if (finHeader.rows.length === 0) throw new Error('Posted EXP voucher header not found');
    if (finHeader.rows[0].voucher_type_code !== 'EXP') throw new Error(`voucher_type_code=${finHeader.rows[0].voucher_type_code}, expected EXP`);
    if (finHeader.rows[0].is_posted !== true) throw new Error('EXP voucher not posted');
    pass('DB: posted under voucher_type_code=EXP (not EXV, the numbering code)');

    const lines = await dbClient.query(
      `SELECT a.account_code, a.account_name, a.account_nature, l.trans_nature, l.trans_amount, l.serial_no, l.inv_bill_no
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2
       ORDER BY l.serial_no`,
      [companyId, header.rows[0].posted_voucher_no]
    );
    console.log('EXP lines in DB:', lines.rows);
    if (lines.rows.length < 2) throw new Error(`Expected at least 2 lines, found ${lines.rows.length}`);
    const supplierLine = lines.rows.find(r => r.account_nature === 'Supplier');
    const expenseLine = lines.rows.find(r => r.account_code === '6500001');
    const vatLine = lines.rows.find(r => r.account_code !== '6500001' && r.account_nature !== 'Supplier');
    if (!supplierLine) throw new Error('No Supplier line found');
    if (supplierLine.serial_no !== 1) throw new Error(`Supplier line serial_no=${supplierLine.serial_no}, expected 1 (EXV-A02)`);
    if (supplierLine.trans_nature !== 'CR') throw new Error('Supplier line not CR as expected for a payable');
    if (!supplierLine.inv_bill_no) throw new Error('Supplier line missing inv_bill_no (bill linkage)');
    if (!expenseLine || expenseLine.trans_nature !== 'DR') throw new Error('Expense line not DR as expected');
    if (!vatLine || vatLine.trans_nature !== 'DR') throw new Error('Input VAT line not DR as expected (normal VAT ADDS to payable)');
    const totalDr = lines.rows.filter(r => r.trans_nature === 'DR').reduce((s, r) => s + Number(r.trans_amount), 0);
    const totalCr = lines.rows.filter(r => r.trans_nature === 'CR').reduce((s, r) => s + Number(r.trans_amount), 0);
    if (Math.abs(totalDr - totalCr) > 0.01) throw new Error(`Voucher does not balance: Dr=${totalDr}, Cr=${totalCr}`);
    if (Math.abs(Number(expenseLine.trans_amount) - 1000) > 0.01) throw new Error(`Expense line amount=${expenseLine.trans_amount}, expected 1000`);
    pass(`DB: EXV-C01 correct -- Dr [6500001] Office Supplies 1000, Dr Input VAT ${vatLine.trans_amount} (16%), Cr Supplier serial_no=1 (EXV-A02) with inv_bill_no=${supplierLine.inv_bill_no}, balanced (Dr=${totalDr.toFixed(2)}, Cr=${totalCr.toFixed(2)})`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 2: EXPENSE VOUCHER RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
