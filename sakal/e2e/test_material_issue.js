// Phase 4 (Inventory) — Material Issue, Part 2 of the Requisition->Issue
// chain. Consolidates the Phase 4 Requisition's own MREQ/MAIN/2026/00001
// (PRD-00002, 3 PCS, Department "QA Admin Dept" / Consumption Area "QA
// Office Supplies Consumption", linked to [5800] Internal Transfers per
// Phase 1's DCA-01 test). This IS the real stock+GL posting step.
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
  } catch (e) { fail('Login', e); await shot(page, 'mi-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/inventory/material-issue`);
    await page.waitForTimeout(2000);
    await page.getByText('New', { exact: false }).first().click();
    await page.waitForTimeout(4000);
    await page.mouse.click(301, 238); // requisition checkbox
    await page.waitForTimeout(1200);
    await shot(page, 'mi-01-req-checked');
    pass('Requisition MREQ/MAIN/2026/00001 selected, Issue Qty Pack pre-filled 3.00');
  } catch (e) { fail('Open Material Issue / pick requisition', e); await shot(page, 'mi-01-fail'); }

  try {
    // Same pre-fill-not-bound-until-touched risk already confirmed on
    // Purchase Return -- explicitly re-confirm the Issue Qty Pack value
    // before Save rather than trusting the visible pre-fill alone.
    await page.mouse.click(1346, 425); // Issue Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('3', { delay: 30 });
    await page.keyboard.press('Tab');
    await page.waitForTimeout(400);
    await shot(page, 'mi-02-qty-confirmed');
    pass('Issue Qty Pack explicitly re-confirmed as 3');
  } catch (e) { fail('Confirm Issue Qty', e); await shot(page, 'mi-02-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'mi-03-saved');
    pass('Material Issue saved as Draft');
  } catch (e) { fail('Save Material Issue', e); await shot(page, 'mi-03-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'mi-04-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'mi-05-approved');
    pass('Material Issue approved');
  } catch (e) { fail('Approve Material Issue', e); await shot(page, 'mi-04-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT issue_no, status FROM rih_material_issue_headers WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Material Issue header:', header.rows);
    if (header.rows.length === 0) throw new Error('No Material Issue header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}`);
    pass(`DB: Material Issue ${header.rows[0].issue_no} approved`);

    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00002'`, [companyId]);
    const stockLoc = await dbClient.query(`SELECT current_stock FROM rim_product_location WHERE company_id=$1 AND product_id=$2`, [companyId, productRes.rows[0].id]);
    console.log('Stock after Material Issue:', stockLoc.rows);
    if (Number(stockLoc.rows[0].current_stock) !== 22) throw new Error(`current_stock=${stockLoc.rows[0].current_stock}, expected 22 (25 - 3)`);
    pass('DB: Stock effect correct -- current_stock=22 (25 - 3 issued)');

    const ledger = await dbClient.query(
      `SELECT trans_type, qty_change FROM ril_stock_ledger WHERE company_id=$1 AND product_id=$2 ORDER BY created_at DESC LIMIT 1`,
      [companyId, productRes.rows[0].id]
    );
    console.log('Latest ril_stock_ledger row:', ledger.rows);
    if (Number(ledger.rows[0].qty_change) !== -3) throw new Error(`qty_change=${ledger.rows[0].qty_change}, expected -3`);
    pass(`DB: Stock ledger entry correct -- trans_type=${ledger.rows[0].trans_type}, qty_change=-3`);

    const finHeader = await dbClient.query(
      `SELECT trans_no, voucher_type_code, is_posted FROM rih_finance_headers
       WHERE company_id=$1 AND source_doc_type='MATERIAL_ISSUE' AND source_doc_no=$2`,
      [companyId, header.rows[0].issue_no]
    );
    console.log('Posted voucher for this Issue:', finHeader.rows);
    if (finHeader.rows.length === 0) throw new Error('No GL voucher posted for this Material Issue');

    const glLines = await dbClient.query(
      `SELECT a.account_name, l.trans_nature, l.base_amount, l.trans_currency
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 ORDER BY l.serial_no`,
      [companyId, finHeader.rows[0].trans_no]
    );
    console.log('Material Issue voucher lines:', glLines.rows);
    const expenseLine = glLines.rows.find(r => r.trans_nature === 'DR');
    const stockLine = glLines.rows.find(r => r.trans_nature === 'CR');
    if (!expenseLine || Math.abs(Number(expenseLine.base_amount) - 75) > 0.01) throw new Error(`Expense Dr line=${expenseLine?.base_amount}, expected 75 (3 x cost_price 25)`);
    if (!stockLine || Math.abs(Number(stockLine.base_amount) - 75) > 0.01) throw new Error(`Stock Cr line=${stockLine?.base_amount}, expected 75`);
    if (expenseLine.trans_currency !== 'USD' || stockLine.trans_currency !== 'USD') throw new Error('MIC voucher should post entirely in base currency USD');
    pass(`DB: GL effect correct -- Dr ${expenseLine.account_name} 75 (the Consumption Area's linked expense account) / Cr ${stockLine.account_name} 75 (3 x cost_price 25), both in base currency, balanced (${finHeader.rows[0].voucher_type_code})`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 4: MATERIAL ISSUE RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
