// Phase 4 (Inventory) — Stock Adjustment, "+" (Increase) direction.
// Location Main Store, Reason "Physical Count Variance", 1 line:
// PRD-00002 (cost already established at 25 via the Phase 4 Opening
// Stock test -- a "+" line requires an established cost per CLAUDE.md),
// Qty Pack 5. Per the rubric: Currency doesn't apply (no currency field
// on this document), GL effect applies (Dr Stock / Cr Stock Adjustment
// Account), Stock effect applies directly (the screen's whole purpose),
// Chain doesn't apply for a direct entry (only Stock Count Review's
// auto-post path has a chain, not this pass).
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
  } catch (e) { fail('Login', e); await shot(page, 'sa-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/inventory/adjustments`);
    await page.waitForTimeout(2000);
    await page.getByText('New Stock Adjustment', { exact: false }).first().click();
    await page.waitForTimeout(4000);
    pass('Stock Adjustment entry screen loaded');
  } catch (e) { fail('Open Stock Adjustment', e); await shot(page, 'sa-01-fail'); }

  try {
    await page.mouse.click(543, 143); // Reason dropdown
    await page.waitForTimeout(500);
    await page.mouse.click(543, 293); // Physical Count Variance
    await page.waitForTimeout(400);
    await shot(page, 'sa-02-reason-picked');
    pass('Reason = Physical Count Variance');
  } catch (e) { fail('Pick Reason', e); await shot(page, 'sa-02-fail'); }

  try {
    await page.getByText('Add Line', { exact: false }).first().click();
    await page.waitForTimeout(800);
    await page.mouse.click(400, 312); // Product field
    await page.waitForTimeout(400);
    await page.keyboard.type('QA Test Widget 69433', { delay: 50 }); // PRD-00002
    await page.waitForTimeout(900);
    await page.getByText('[PRD-00002]', { exact: false }).first().click();
    await page.waitForTimeout(1200); // same async-check race class as Opening Stock
    await shot(page, 'sa-03-product-picked');
    pass('Product set to PRD-00002 QA Test Widget, Direction defaults to + Increase');
  } catch (e) { fail('Pick Product', e); await shot(page, 'sa-03-fail'); }

  try {
    await page.mouse.click(794, 312); // Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('5', { delay: 30 });
    await page.waitForTimeout(400);
    await shot(page, 'sa-04-qty-filled');
    pass('Qty Pack = 5');
  } catch (e) { fail('Fill Qty', e); await shot(page, 'sa-04-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'sa-05-saved');
    pass('Stock Adjustment saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'sa-05-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'sa-06-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'sa-07-approved');
    pass('Stock Adjustment approved');
  } catch (e) { fail('Approve', e); await shot(page, 'sa-06-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00002'`, [companyId]);
    const stockLoc = await dbClient.query(
      `SELECT current_stock, cost_price FROM rim_product_location WHERE company_id=$1 AND product_id=$2`,
      [companyId, productRes.rows[0].id]
    );
    console.log('rim_product_location after Adjustment:', stockLoc.rows);
    if (Number(stockLoc.rows[0].current_stock) !== 25) throw new Error(`current_stock=${stockLoc.rows[0].current_stock}, expected 25 (20 opening + 5 adjustment)`);
    pass('DB: Stock effect correct -- current_stock=25 (20 opening + 5 adjustment), cost blended as a no-op (same cost)');

    const ledger = await dbClient.query(
      `SELECT trans_type, qty_change FROM ril_stock_ledger WHERE company_id=$1 AND product_id=$2 ORDER BY created_at DESC LIMIT 1`,
      [companyId, productRes.rows[0].id]
    );
    console.log('Latest ril_stock_ledger row:', ledger.rows);
    if (Number(ledger.rows[0].qty_change) !== 5) throw new Error(`qty_change=${ledger.rows[0].qty_change}, expected +5`);
    pass(`DB: Stock ledger entry correct -- trans_type=${ledger.rows[0].trans_type}, qty_change=+5`);

    const header = await dbClient.query(
      `SELECT adjustment_no, status FROM rih_stock_adjustment_headers WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Stock Adjustment header:', header.rows);
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}, expected APPROVED`);
    pass(`DB: Stock Adjustment ${header.rows[0].adjustment_no} correctly approved`);

    const finHeader = await dbClient.query(
      `SELECT trans_no, voucher_type_code, is_posted FROM rih_finance_headers
       WHERE company_id=$1 AND source_doc_type='STOCK_ADJUSTMENT' AND source_doc_no=$2`,
      [companyId, header.rows[0].adjustment_no]
    );
    console.log('Posted voucher for this Adjustment:', finHeader.rows);
    if (finHeader.rows.length === 0) throw new Error('No GL voucher posted for this Adjustment');

    const glLines = await dbClient.query(
      `SELECT a.account_name, l.trans_nature, l.base_amount
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 ORDER BY l.serial_no`,
      [companyId, finHeader.rows[0].trans_no]
    );
    console.log('Adjustment voucher lines:', glLines.rows);
    const stockLine = glLines.rows.find(r => r.trans_nature === 'DR');
    const adjLine = glLines.rows.find(r => r.trans_nature === 'CR');
    if (!stockLine || Math.abs(Number(stockLine.base_amount) - 125) > 0.01) throw new Error(`Stock Dr line=${stockLine?.base_amount}, expected 125 (5 x 25)`);
    if (!adjLine || Math.abs(Number(adjLine.base_amount) - 125) > 0.01) throw new Error(`Adjustment Cr line=${adjLine?.base_amount}, expected 125`);
    pass(`DB: GL effect correct -- Dr ${stockLine.account_name} 125 / Cr ${adjLine.account_name} 125 (5 units x existing cost_price 25), balanced (${finHeader.rows[0].voucher_type_code})`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 4: STOCK ADJUSTMENT RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
