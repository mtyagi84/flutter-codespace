// Phase 4 (Inventory) — Stock Transfer Request (Part 1 of 3: Request ->
// Transfer -> Receipt). FROM Main Store, TO QA Second Store, PRD-00002
// (stock=22), Qty Pack 5. Per the rubric: pure intent, no stock/GL effect
// at Request stage (mirrors PO/Material Requisition's own role).
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
  } catch (e) { fail('Login', e); await shot(page, 'str-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/inventory/stock-transfer-requests`);
    await page.waitForTimeout(2000);
    await page.getByText('New Request', { exact: false }).first().click();
    await page.waitForTimeout(4000);
    await page.mouse.click(1240, 111); // To Location dropdown
    await page.waitForTimeout(500);
    await page.mouse.click(1240, 183); // QA Second Store
    await page.waitForTimeout(500);
    await shot(page, 'str-01-locations-set');
    pass('FROM Main Store, TO QA Second Store set');
  } catch (e) { fail('Set locations', e); await shot(page, 'str-01-fail'); }

  try {
    await page.getByText('Add Line', { exact: false }).first().click();
    await page.waitForTimeout(800);
    await page.mouse.click(394, 317); // Product field
    await page.waitForTimeout(400);
    await page.keyboard.type('QA Test Widget 69433', { delay: 50 }); // PRD-00002
    await page.waitForTimeout(900);
    await page.getByText('[PRD-00002]', { exact: false }).first().click();
    await page.waitForTimeout(1200);
    await shot(page, 'str-02-product-picked');
    pass('Product set to PRD-00002 QA Test Widget');
  } catch (e) { fail('Pick Product', e); await shot(page, 'str-02-fail'); }

  try {
    await page.mouse.click(690, 317); // Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('5', { delay: 30 });
    await page.keyboard.press('Tab');
    await page.waitForTimeout(400);
    await shot(page, 'str-03-qty-filled');
    pass('Qty Pack = 5');
  } catch (e) { fail('Fill Qty', e); await shot(page, 'str-03-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'str-04-saved');
    pass('Stock Transfer Request saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'str-04-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'str-05-approved');
    pass('Stock Transfer Request approved');
  } catch (e) { fail('Approve', e); await shot(page, 'str-05-fail'); }

  await browser.close();

  // ---------- DB verification: Request is pure intent ----------
  try {
    const header = await dbClient.query(
      `SELECT request_no, status FROM rih_stock_transfer_requests
       WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Stock Transfer Request header:', header.rows);
    if (header.rows.length === 0) throw new Error('No Stock Transfer Request header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}`);
    pass(`DB: Stock Transfer Request ${header.rows[0].request_no} approved`);

    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00002'`, [companyId]);
    const stockLoc = await dbClient.query(`SELECT current_stock FROM rim_product_location WHERE company_id=$1 AND product_id=$2`, [companyId, productRes.rows[0].id]);
    console.log('Stock after Request approve:', stockLoc.rows);
    if (Number(stockLoc.rows[0].current_stock) !== 22) throw new Error(`current_stock=${stockLoc.rows[0].current_stock}, expected unchanged at 22 (Request is pure intent)`);
    pass('DB: Request correctly posted NO stock movement (pure intent)');
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 4: STOCK TRANSFER REQUEST RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
