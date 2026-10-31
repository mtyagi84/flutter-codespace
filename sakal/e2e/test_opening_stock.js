// Phase 4 (Inventory) — Opening Stock, GL OFF (simpler path first, same
// precedent as every other module this session). Location Main Store,
// 1 line: PRD-00002 QA Test Widget (a product never touched by the
// Purchase Cycle chain -- PRD-00001 already has cost_price=50 from GRN,
// which would trip OPENING_STOCK_ALREADY_ESTABLISHED), Qty Pack 20,
// Unit Cost 25. Per the rubric: Currency doesn't apply (base-currency-
// only unit cost), GL effect does NOT apply with the toggle off (this
// IS the test -- confirms no GL posts), Stock effect applies directly
// (this is the screen's whole purpose), Chain doesn't apply (no source
// document). Save is one click (Save+Approve chained, per CLAUDE.md).
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
  } catch (e) { fail('Login', e); await shot(page, 'os-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/inventory/opening-stock-entry`);
    await page.waitForTimeout(3000);
    await page.getByText('Add Line', { exact: false }).first().click();
    await page.waitForTimeout(800);
    await shot(page, 'os-01-line-added');
    pass('Opening Stock entry screen loaded, 1 line added');
  } catch (e) { fail('Open Opening Stock', e); await shot(page, 'os-01-fail'); }

  try {
    await page.mouse.click(570, 418); // Product field
    await page.waitForTimeout(400);
    await page.keyboard.type('QA Test Widget 69433', { delay: 50 }); // PRD-00002's full name
    await page.waitForTimeout(900);
    await shot(page, 'os-02-product-search');
    await page.getByText('[PRD-00002]', { exact: false }).first().click();
    // Real race found live: an async "checking existing stock..." indicator
    // runs after product pick and can overwrite/reset Qty Pack/Unit Cost if
    // they're filled too early -- 600ms wasn't enough (produced a wrong
    // Unit Cost of 50 in an earlier run), 1500ms reliably clears it.
    await page.waitForTimeout(1500);
    await shot(page, 'os-02b-product-picked');
    pass('Product set to PRD-00002 QA Test Widget');
  } catch (e) { fail('Pick Product', e); await shot(page, 'os-02-fail'); }

  try {
    await page.mouse.click(804, 418); // Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('20', { delay: 30 });
    // Real race found live: editing Qty Pack triggers a reactive row
    // rebuild; clicking Unit Cost and typing immediately after can have
    // the typed value silently overwritten a moment later by that rebuild
    // (observed: Unit Cost ended up "50", a value matching an UNRELATED
    // product's own cost_price, not anything typed this run). A settle
    // wait between the two fields avoids the race.
    await page.waitForTimeout(800);
    await page.mouse.click(994, 418); // Unit Cost
    await page.keyboard.press('Control+A');
    await page.keyboard.type('25', { delay: 30 });
    await page.waitForTimeout(800);
    await shot(page, 'os-03-line-filled');
    pass('Qty Pack=20, Unit Cost=25');
  } catch (e) { fail('Fill line', e); await shot(page, 'os-03-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'os-04-saved');
    pass('Opening Stock saved as Draft');
  } catch (e) { fail('Save', e); await shot(page, 'os-04-fail'); }

  try {
    // Correction: this screen does NOT auto-approve on Save (unlike Sales
    // Invoice) -- confirmed live, status stays DRAFT with a separate
    // Approve button available. A real stock effect requires this step.
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'os-04b-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'os-05-approved');
    pass('Opening Stock approved');
  } catch (e) { fail('Approve', e); await shot(page, 'os-04b-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00002'`, [companyId]);
    const stockLoc = await dbClient.query(
      `SELECT current_stock, cost_price FROM rim_product_location WHERE company_id=$1 AND product_id=$2`,
      [companyId, productRes.rows[0].id]
    );
    console.log('rim_product_location after Opening Stock:', stockLoc.rows);
    if (stockLoc.rows.length === 0) throw new Error('No rim_product_location row found for PRD-00002');
    if (Number(stockLoc.rows[0].current_stock) !== 20) throw new Error(`current_stock=${stockLoc.rows[0].current_stock}, expected 20`);
    if (Math.abs(Number(stockLoc.rows[0].cost_price) - 25) > 0.01) throw new Error(`cost_price=${stockLoc.rows[0].cost_price}, expected 25`);
    pass('DB: Stock effect correct -- current_stock=20, cost_price=25');

    const ledger = await dbClient.query(
      `SELECT trans_type, qty_change FROM ril_stock_ledger WHERE company_id=$1 AND product_id=$2 ORDER BY created_at DESC LIMIT 1`,
      [companyId, productRes.rows[0].id]
    );
    console.log('Latest ril_stock_ledger row:', ledger.rows);
    if (ledger.rows.length === 0) throw new Error('No stock ledger entry found');
    if (Number(ledger.rows[0].qty_change) !== 20) throw new Error(`qty_change=${ledger.rows[0].qty_change}, expected +20`);
    pass(`DB: Stock ledger entry correct -- trans_type=${ledger.rows[0].trans_type}, qty_change=+20`);

    // Confirm NO GL voucher posted (post_gl was left unchecked)
    const header = await dbClient.query(
      `SELECT id, opening_no, post_gl FROM rih_opening_stock_headers WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Opening Stock header:', header.rows);
    if (header.rows[0].post_gl !== false) throw new Error(`post_gl=${header.rows[0].post_gl}, expected false`);
    const finHeader = await dbClient.query(
      `SELECT trans_no FROM rih_finance_headers WHERE company_id=$1 AND source_doc_type='OPENING_STOCK' AND source_doc_no=$2`,
      [companyId, header.rows[0].opening_no]
    );
    console.log('GL vouchers for this Opening Stock doc:', finHeader.rows);
    if (finHeader.rows.length !== 0) throw new Error('A GL voucher was posted despite post_gl=false');
    pass('DB: correctly posted NO GL voucher (post_gl was left unchecked)');
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 4: OPENING STOCK RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
