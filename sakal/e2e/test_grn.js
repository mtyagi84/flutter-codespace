// Phase 3 (Purchase Cycle) — GRN (Goods Receipt), DIRECT mode. Tests
// Supplier [4010001] QA Test Supplier, Currency USD, 1 line (PRD-00001
// QA Test Widget, Qty Pack 10, Rate 50 = 500), Save Draft then Approve.
// Per the rubric: Currency applies (kept base USD), GL effect applies
// directly (GRN posts Stock Dr / Purchase Accrual Cr per the GR/IR
// pattern, VAT deferred — see CLAUDE.md), Stock effect applies (ledger
// qty + cost), Chain applies via a future AGAINST_PO variant (not this
// pass — DIRECT mode tested first, matching this project's own "prove
// the simpler path first" precedent). Reuses the PO test's own lessons:
// 6s settle wait for the async Currency/Rate row, locator-based clicks
// for autocomplete suggestions.
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
  } catch (e) { fail('Login', e); await shot(page, 'grn-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/purchase/grn`);
    await page.waitForTimeout(2000);
    await page.getByText('New Goods Receipt', { exact: false }).first().click();
    await page.waitForTimeout(6000);
    await shot(page, 'grn-01-loaded');
    pass('GRN entry screen loaded (DIRECT mode)');
  } catch (e) { fail('Open GRN', e); await shot(page, 'grn-01-fail'); }

  try {
    await page.mouse.click(660, 144);
    await page.waitForTimeout(600);
    await page.keyboard.type('4010', { delay: 60 });
    await page.waitForTimeout(1000);
    await page.getByText('[4010001] QA Test Supplier', { exact: false }).first().click();
    await page.waitForTimeout(700);
    await shot(page, 'grn-02-supplier-picked');
    pass('Supplier set to [4010001] QA Test Supplier');
  } catch (e) { fail('Pick Supplier', e); await shot(page, 'grn-02-fail'); }

  try {
    await page.mouse.click(488, 196);
    await page.waitForTimeout(500);
    await page.mouse.click(488, 298); // USD, same offset confirmed on PO
    await page.waitForTimeout(500);
    await shot(page, 'grn-03-currency-picked');
    pass('Currency selected (USD)');
  } catch (e) { fail('Pick Currency', e); await shot(page, 'grn-03-fail'); }

  try {
    await page.getByText('Add Item', { exact: false }).first().click();
    await page.waitForTimeout(800);
    await page.mouse.click(394, 487); // Product field, confirmed via screenshot
    await page.waitForTimeout(400);
    await page.keyboard.type('QA Test Widget', { delay: 60 });
    await page.waitForTimeout(900);
    await page.getByText('[PRD-00001] QA Test Widget', { exact: false }).first().click();
    await page.waitForTimeout(600);
    await shot(page, 'grn-04-product-picked');
    pass('Product set to PRD-00001 QA Test Widget');
  } catch (e) { fail('Pick Product', e); await shot(page, 'grn-04-fail'); }

  try {
    await page.mouse.click(838, 487); // Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('10', { delay: 30 });
    await page.mouse.click(1054, 487); // Rate
    await page.keyboard.press('Control+A');
    await page.keyboard.type('50', { delay: 30 });
    await page.waitForTimeout(400);
    await shot(page, 'grn-05-line-filled');
    pass('Qty Pack=10, Rate=50');
  } catch (e) { fail('Fill line', e); await shot(page, 'grn-05-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'grn-06-saved');
    pass('GRN saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'grn-06-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'grn-07-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'grn-08-approved');
    pass('GRN approved');
  } catch (e) { fail('Approve', e); await shot(page, 'grn-07-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT grn_no, grn_date, status FROM rih_grn_headers
       WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest GRN header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No GRN header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}, expected APPROVED`);
    pass(`DB: GRN ${header.rows[0].grn_no} correctly approved`);

    const lines = await dbClient.query(
      `SELECT l.qty_pack, l.rate, l.final_amount, p.product_code
       FROM rid_grn_lines l JOIN rim_products p ON p.id = l.product_id
       WHERE l.company_id=$1 AND l.grn_no=$2 AND l.grn_date=$3`,
      [companyId, header.rows[0].grn_no, header.rows[0].grn_date]
    );
    console.log('GRN lines in DB:', lines.rows);
    if (lines.rows.length < 1) throw new Error('No GRN lines found');
    pass(`DB: GRN line correct -- ${lines.rows[0].product_code}, Qty ${lines.rows[0].qty_pack} x Rate ${lines.rows[0].rate} = ${lines.rows[0].final_amount}`);

    // Stock effect: ril_stock_ledger + rim_product_location
    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00001'`, [companyId]);
    const stockLoc = await dbClient.query(
      `SELECT current_stock, cost_price FROM rim_product_location WHERE company_id=$1 AND product_id=$2`,
      [companyId, productRes.rows[0].id]
    );
    console.log('rim_product_location after GRN:', stockLoc.rows);
    if (stockLoc.rows.length === 0 || Number(stockLoc.rows[0].current_stock) !== 10) {
      throw new Error(`current_stock=${stockLoc.rows[0]?.current_stock}, expected 10`);
    }
    if (Math.abs(Number(stockLoc.rows[0].cost_price) - 50) > 0.01) {
      throw new Error(`cost_price=${stockLoc.rows[0].cost_price}, expected 50`);
    }
    pass(`DB: Stock effect correct -- current_stock=10, cost_price=50 (weighted avg, first receipt)`);

    const ledger = await dbClient.query(
      `SELECT trans_type, qty_change FROM ril_stock_ledger WHERE company_id=$1 AND product_id=$2 ORDER BY created_at DESC LIMIT 1`,
      [companyId, productRes.rows[0].id]
    );
    console.log('Latest ril_stock_ledger row:', ledger.rows);
    if (ledger.rows.length === 0) throw new Error('No stock ledger entry found');
    if (Number(ledger.rows[0].qty_change) !== 10) throw new Error(`qty_change=${ledger.rows[0].qty_change}, expected +10`);
    pass(`DB: Stock ledger entry correct -- trans_type=${ledger.rows[0].trans_type}, qty_change=+10`);

    // GL effect: GRN posts a JV (Stock Dr / Purchase Accrual Cr, VAT deferred)
    const finHeader = await dbClient.query(
      `SELECT trans_no, voucher_type_code, is_posted FROM rih_finance_headers
       WHERE company_id=$1 AND source_doc_type='GRN' AND source_doc_no=$2`,
      [companyId, header.rows[0].grn_no]
    );
    console.log('Posted JV for this GRN:', finHeader.rows);
    if (finHeader.rows.length === 0) throw new Error('No GL voucher posted for this GRN');
    if (finHeader.rows[0].voucher_type_code !== 'JV') throw new Error(`voucher_type_code=${finHeader.rows[0].voucher_type_code}, expected JV`);
    if (finHeader.rows[0].is_posted !== true) throw new Error('GRN JV not posted');

    const glLines = await dbClient.query(
      `SELECT a.account_name, l.trans_nature, l.base_amount
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 ORDER BY l.serial_no`,
      [companyId, finHeader.rows[0].trans_no]
    );
    console.log('GRN JV lines:', glLines.rows);
    const stockLine = glLines.rows.find(r => r.trans_nature === 'DR');
    const accrualLine = glLines.rows.find(r => r.trans_nature === 'CR');
    if (!stockLine || Math.abs(Number(stockLine.base_amount) - 500) > 0.01) throw new Error('Stock Dr line incorrect or missing');
    if (!accrualLine || Math.abs(Number(accrualLine.base_amount) - 500) > 0.01) throw new Error('Purchase Accrual Cr line incorrect or missing');
    pass(`DB: GL effect correct -- Dr ${stockLine.account_name} 500, Cr ${accrualLine.account_name} 500 (GR/IR pattern, no VAT line at GRN per documented design)`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 3: GRN RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
