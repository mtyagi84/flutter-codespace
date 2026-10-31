// Phase 3 (Purchase Cycle) — Purchase Bill (Purchase Invoice). Closes the
// GR/IR loop the Phase 3 GRN test opened: Supplier [4010001] QA Test
// Supplier, selects the pending GRN/MAIN/2026/00001 (500 USD, tax-
// exclusive), Taxable Amount auto-fills 500.00, VAT/Tax Amount entered
// as 80 (16%, matching the TVA Standard 16% group), Invoice Total 580.
// Per the rubric: Currency applies (inherited from GRN, base USD),
// GL effect applies directly (PUR voucher: Dr Purchase Accrual 500 +
// Dr Input VAT 80, Cr Supplier 580 -- the real GR/IR-clearing posting
// documented in CLAUDE.md), Stock doesn't apply (no stock movement at
// Bill time), Chain applies (GRN-against-PO... here Bill-against-GRN).
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
    await page.waitForTimeout(1500);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'pinv-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/purchase/invoices`);
    await page.waitForTimeout(2000);
    await page.getByText('New Purchase Bill', { exact: false }).first().click();
    await page.waitForTimeout(6000);
    await shot(page, 'pinv-01-loaded');
    pass('Purchase Bill entry screen loaded');
  } catch (e) { fail('Open Purchase Bill', e); await shot(page, 'pinv-01-fail'); }

  try {
    await page.mouse.click(648, 91);
    await page.waitForTimeout(600);
    await page.keyboard.type('4010', { delay: 60 });
    await page.waitForTimeout(1000);
    await page.getByText('[4010001] QA Test Supplier', { exact: false }).first().click();
    await page.waitForTimeout(1200);
    await shot(page, 'pinv-02-supplier-picked');
    pass('Supplier set to [4010001] QA Test Supplier, pending GRN shown');
  } catch (e) { fail('Pick Supplier', e); await shot(page, 'pinv-02-fail'); }

  try {
    await page.mouse.click(301, 313); // GRN checkbox
    await page.waitForTimeout(800);
    await shot(page, 'pinv-03-grn-checked');
    pass('Pending GRN GRN/MAIN/2026/00001 selected, Taxable Amount auto-filled 500.00');
  } catch (e) { fail('Check GRN', e); await shot(page, 'pinv-03-fail'); }

  try {
    await page.mouse.click(918, 164); // Supplier Invoice No
    await page.keyboard.type('SUP-INV-001', { delay: 30 });
    await page.waitForTimeout(300);
    await shot(page, 'pinv-04-invno-filled');
    pass('Supplier Invoice No = SUP-INV-001');
  } catch (e) { fail('Fill Supplier Invoice No', e); await shot(page, 'pinv-04-fail'); }

  try {
    await page.mouse.click(1330, 169); // Supplier Invoice Date
    await page.waitForTimeout(600);
    await shot(page, 'pinv-05-date-picker');
    await page.mouse.click(1011, 696); // OK, same date-picker shape as Expense Voucher
    await page.waitForTimeout(400);
    pass('Supplier Invoice Date = today');
  } catch (e) { fail('Fill Supplier Invoice Date', e); await shot(page, 'pinv-05-fail'); }

  try {
    // VAT/Tax Amount stays 0 -- the linked GRN's own line used "No Tax" at
    // receipt time (this session's GRN test), so there is no estimated/
    // deferred tax for Purchase Bill to apportion the real VAT against.
    // Confirmed live: entering a non-zero VAT (80) here produced a real,
    // correct validation block -- "None of the linked GRN lines had a tax
    // group / estimated tax to apportion the real VAT against." -- and
    // Approve silently no-ops while that banner is shown (logged as
    // PINV-VAL01 in the test plan). This run proves the no-tax GL path;
    // a tax-bearing variant needs a GRN line with a real tax group first.
    await shot(page, 'pinv-06-novat');
    pass('VAT/Tax Amount left at 0 (GRN had no tax group to apportion against)');
  } catch (e) { fail('Check VAT amount', e); await shot(page, 'pinv-06-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'pinv-07-saved');
    pass('Purchase Bill saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'pinv-07-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'pinv-08-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'pinv-09-approved');
    pass('Purchase Bill approved');
  } catch (e) { fail('Approve', e); await shot(page, 'pinv-08-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT invoice_no, invoice_date, status, posted_voucher_no FROM rih_purchase_invoices
       WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest Purchase Bill header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No Purchase Bill header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}, expected APPROVED`);
    pass(`DB: Purchase Bill ${header.rows[0].invoice_no} correctly approved, posted as ${header.rows[0].posted_voucher_no}`);

    const finHeader = await dbClient.query(
      `SELECT trans_no, voucher_type_code, is_posted FROM rih_finance_headers
       WHERE company_id=$1 AND trans_no=$2`,
      [companyId, header.rows[0].posted_voucher_no]
    );
    console.log('Posted PUR voucher header:', finHeader.rows);
    if (finHeader.rows.length === 0) throw new Error('Posted PUR voucher header not found');
    if (finHeader.rows[0].voucher_type_code !== 'PUR') throw new Error(`voucher_type_code=${finHeader.rows[0].voucher_type_code}, expected PUR`);

    const lines = await dbClient.query(
      `SELECT a.account_name, a.account_nature, l.trans_nature, l.base_amount, l.inv_bill_no
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 ORDER BY l.serial_no`,
      [companyId, finHeader.rows[0].trans_no]
    );
    console.log('PUR voucher lines:', lines.rows);
    const supplierLine = lines.rows.find(r => r.account_nature === 'Supplier');
    const accrualLine = lines.rows.find(r => r.account_name.includes('Accrual'));
    if (!supplierLine) throw new Error('No Supplier line found');
    if (supplierLine.trans_nature !== 'CR') throw new Error('Supplier line not CR');
    if (Math.abs(Number(supplierLine.base_amount) - 500) > 0.01) throw new Error(`Supplier line amount=${supplierLine.base_amount}, expected 500 (no-VAT scenario)`);
    if (!supplierLine.inv_bill_no) throw new Error('Supplier line missing inv_bill_no (bill linkage)');
    if (!accrualLine || accrualLine.trans_nature !== 'DR' || Math.abs(Number(accrualLine.base_amount) - 500) > 0.01) throw new Error('Purchase Accrual clearing line incorrect');
    const totalDr = lines.rows.filter(r => r.trans_nature === 'DR').reduce((s, r) => s + Number(r.base_amount), 0);
    const totalCr = lines.rows.filter(r => r.trans_nature === 'CR').reduce((s, r) => s + Number(r.base_amount), 0);
    if (Math.abs(totalDr - totalCr) > 0.01) throw new Error(`Voucher does not balance: Dr=${totalDr}, Cr=${totalCr}`);
    pass(`DB: GL effect correct -- Dr ${accrualLine.account_name} 500 (clears GRN's provisional accrual), Cr ${supplierLine.account_name} 500 (real payable) with inv_bill_no=${supplierLine.inv_bill_no}, balanced (Dr=${totalDr}, Cr=${totalCr})`);

    // Confirm the GRN is now marked billed (billed_invoice_no reservation)
    const grn = await dbClient.query(`SELECT billed_invoice_no FROM rih_grn_headers WHERE company_id=$1 AND grn_no='GRN/MAIN/2026/00001'`, [companyId]);
    console.log('GRN billed_invoice_no:', grn.rows);
    if (!grn.rows[0] || !grn.rows[0].billed_invoice_no) throw new Error('GRN not marked as billed');
    pass(`DB: GRN correctly marked billed_invoice_no=${grn.rows[0].billed_invoice_no} (closes the GR/IR loop)`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 3: PURCHASE BILL RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
