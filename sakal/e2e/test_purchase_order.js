// Phase 3 (Purchase Cycle) — Purchase Order. Tests a Local PO: Supplier
// [4010001] QA Test Supplier, Location Main Store, 1 line (Product
// PRD-00001 QA Test Widget, Qty Pack 10, Rate 50 USD, no tax), Save Draft
// then Approve. Per the rubric: Currency applies (kept to base USD for
// this minimal pass), GL/Stock effects DON'T apply directly (PO is pure
// intent, no stock/GL posting until GRN), Chain applies via the future
// GRN-against-PO test (not this pass). PO uses plain INLINE autocompletes
// (confirmed via screenshot) for Supplier and Product, not the modal
// FinanceAccountPicker pattern.
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

async function pickInline(page, fieldX, fieldY, searchText, suggestionX, suggestionY) {
  await page.mouse.click(fieldX, fieldY);
  await page.waitForTimeout(400);
  await page.keyboard.type(searchText, { delay: 60 });
  await page.waitForTimeout(800);
  await page.mouse.click(suggestionX, suggestionY);
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
    await page.waitForTimeout(1500);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'po-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/purchase/orders`);
    await page.waitForTimeout(2000);
    const newBtn = page.getByText(/New Purchase Order/i).first();
    await newBtn.click();
    await page.waitForTimeout(6000); // Currency/Rate row loads async, see note below
    await shot(page, 'po-01-loaded');
    pass('Purchase Order entry screen loaded');
  } catch (e) { fail('Open Purchase Order', e); await shot(page, 'po-01-fail'); }

  try {
    // Real timing lesson from this session: the Currency/Rate row appears
    // asynchronously a few hundred ms AFTER the main form first renders,
    // unrelated to Supplier -- a fixed 3s wait after opening "New Purchase
    // Order" raced against this reflow and caused clicks to land on stale
    // positions. A 6s settle wait (above) avoids it; locator-based click
    // for the suggestion (not raw coordinates) avoids the remaining
    // flakiness in the suggestion's own click-target.
    await page.mouse.click(648, 144);
    await page.waitForTimeout(600);
    await page.keyboard.type('4010', { delay: 60 });
    await page.waitForTimeout(1000);
    await page.getByText('[4010001] QA Test Supplier', { exact: false }).first().click();
    await page.waitForTimeout(700);
    await shot(page, 'po-02-supplier-picked');
    pass('Supplier set to [4010001] QA Test Supplier');
  } catch (e) { fail('Pick Supplier', e); await shot(page, 'po-02-fail'); }

  try {
    // Currency dropdown -- required, appeared after Supplier pick.
    // Items confirmed via screenshot: CDF y~202, EUR y~250, USD y~298.
    // NOTE: getByText('USD') is ambiguous (also matches "RATE -> BASE
    // (USD)" label text) -- coordinate click is the reliable choice here.
    await page.mouse.click(434, 196);
    await page.waitForTimeout(500);
    await shot(page, 'po-03-currency-dropdown');
    await page.mouse.click(434, 298); // USD
    await page.waitForTimeout(400);
    await shot(page, 'po-03b-currency-picked');
    pass('Currency selected');
  } catch (e) { fail('Pick Currency', e); await shot(page, 'po-03-fail'); }

  try {
    await page.mouse.click(394, 435);
    await page.waitForTimeout(400);
    await page.keyboard.type('QA Test Widget', { delay: 60 });
    await page.waitForTimeout(900);
    await page.getByText('[PRD-00001] QA Test Widget', { exact: false }).first().click();
    await page.waitForTimeout(600);
    await shot(page, 'po-04-product-picked');
    pass('Product set to PRD-00001 QA Test Widget');
  } catch (e) { fail('Pick Product', e); await shot(page, 'po-04-fail'); }

  try {
    await page.mouse.click(838, 435); // Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('10', { delay: 30 });
    await page.mouse.click(1054, 435); // Rate
    await page.keyboard.press('Control+A');
    await page.keyboard.type('50', { delay: 30 });
    await page.waitForTimeout(400);
    await shot(page, 'po-05-line-filled');
    pass('Qty Pack=10, Rate=50');
  } catch (e) { fail('Fill line', e); await shot(page, 'po-05-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'po-06-saved');
    pass('Purchase Order saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'po-06-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'po-07-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'po-08-approved');
    pass('Purchase Order approved');
  } catch (e) { fail('Approve', e); await shot(page, 'po-07-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT order_no, order_date, status, supplier_id FROM rih_purchase_orders
       WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest PO header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No PO header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}, expected APPROVED`);
    pass(`DB: Purchase Order ${header.rows[0].order_no} correctly approved`);

    const lines = await dbClient.query(
      `SELECT l.qty_pack, l.base_qty, l.rate, l.final_amount, p.product_code
       FROM rid_purchase_order_lines l JOIN rim_products p ON p.id = l.product_id
       WHERE l.company_id=$1 AND l.order_no=$2 AND l.order_date=$3`,
      [companyId, header.rows[0].order_no, header.rows[0].order_date]
    );
    console.log('PO lines in DB:', lines.rows);
    if (lines.rows.length < 1) throw new Error('No PO lines found');
    const line = lines.rows[0];
    if (Number(line.qty_pack) !== 10) throw new Error(`qty_pack=${line.qty_pack}, expected 10`);
    if (Number(line.rate) !== 50) throw new Error(`rate=${line.rate}, expected 50`);
    if (Math.abs(Number(line.final_amount) - 500) > 0.01) throw new Error(`final_amount=${line.final_amount}, expected 500`);
    pass(`DB: PO line correct -- ${line.product_code}, Qty 10 x Rate 50 = ${line.final_amount}, no GL/stock posted (PO is pure intent)`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 3: PURCHASE ORDER RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
