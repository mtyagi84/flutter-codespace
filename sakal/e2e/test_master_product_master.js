// Phase 1 (Inventory Masters) — Product Master. Creates one real product
// (minimal required fields: Code, Name, Base UOM) via the real entry
// screen, since this fresh tenant has zero products — Item Account Links
// (Finance Masters) is blocked without at least one to test against.
// Currency applies to this screen (price/cost currency) — tests Base only
// here, as a minimal-coverage pass; a fuller 3-currency product pass is a
// follow-up. GL/Stock/Chain don't apply directly to Product Master itself
// — downstream usage (a real GRN/Sales Invoice line) is Phase 3/5's job.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const PRODUCT_NAME = `QA Test Widget ${STAMP}`;

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1366, height: 1000 } })).newPage();
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
  } catch (e) { fail('Login', e); await shot(page, 'prd-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/products`);
    await page.getByRole('button', { name: 'New Product', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'prd-01-list-loaded');
    pass('Product Master list screen loaded');
  } catch (e) { fail('Open Product Master list', e); await shot(page, 'prd-01-fail'); }

  try {
    await page.getByRole('button', { name: 'New Product', exact: true }).first().click();
    await page.waitForTimeout(1000);
    await textVisible(page, 'Basic Details').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'prd-02-entry-opened');
    pass('Product Entry screen opened');
  } catch (e) { fail('Open Product Entry', e); await shot(page, 'prd-02-fail'); }

  try {
    const generateBtn = page.getByRole('button', { name: 'Generate', exact: true }).first();
    await generateBtn.click();
    await page.waitForTimeout(800);
    await typeInto(page, 'Product Name', PRODUCT_NAME);
    await shot(page, 'prd-03-basic-filled');
    pass('Product Code generated, Product Name filled');
  } catch (e) { fail('Fill basic details', e); await shot(page, 'prd-03-fail'); }

  try {
    // Base UOM sits at the very bottom edge of the viewport, barely
    // visible (confirmed via screenshot) — scroll it fully into view, then
    // click by coordinate (same DropdownButtonFormField semantics gap
    // already confirmed on several other screens this session).
    await page.mouse.wheel(0, 300);
    await page.waitForTimeout(500);
    await shot(page, 'prd-04-scrolled-to-uom');
    const uomBox = await textVisible(page, 'UOM & Tracking').boundingBox();
    const clickY = uomBox ? uomBox.y + 90 : 400;
    await page.mouse.click(584, clickY);
    await page.waitForTimeout(400);
    await shot(page, 'prd-04b-uom-dropdown-opened');
    // "PCS" is the 2nd menu item, confirmed via screenshot at ~(584, 738)
    // — same overlay-semantics gap as every other dropdown this session.
    await page.mouse.click(584, 738);
    await page.waitForTimeout(500);
    await shot(page, 'prd-05-uom-picked');
    pass('Base UOM set to PCS');
  } catch (e) { fail('Pick Base UOM', e); await shot(page, 'prd-04-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Product', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2500);
    await shot(page, 'prd-06-saved');
    pass(`Product "${PRODUCT_NAME}" saved`);
  } catch (e) { fail('Save product', e); await shot(page, 'prd-06-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT p.product_code, p.product_name, p.base_uom_id, p.is_active, p.is_deleted,
              u.description AS uom_name
       FROM rim_products p LEFT JOIN rim_common_masters u ON u.id = p.base_uom_id
       WHERE p.company_id=$1 AND p.product_name=$2`,
      [companyId, PRODUCT_NAME]
    );
    console.log('Product in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('Product not found in DB');
    if (row.rows[0].uom_name !== 'PCS') throw new Error(`base_uom resolved to ${row.rows[0].uom_name}, expected PCS`);
    if (row.rows[0].is_active !== true || row.rows[0].is_deleted !== false) throw new Error('Product not active/not-deleted as expected');
    pass(`DB: Product "${PRODUCT_NAME}" (code ${row.rows[0].product_code}) saved correctly with Base UOM=PCS, active`);

    // NOT a bug: picking Base UOM alone does NOT create a rim_product_uom
    // row — that table is only populated via this screen's separate
    // "Multiple Barcode"/UOM-rows section, which this minimal-coverage
    // test never touched. Confirmed by reading product_entry_screen.dart's
    // own _save()/_saveUoms() directly: _saveUoms() iterates `_uomRows`
    // only, with no fallback row synthesized for the base UOM. This
    // matches the already-known, already-mitigated gap recorded in
    // project memory ("Product UOM Fallback Gap" — rim_product_uom≠
    // base_uom_id, fallback already fixed in Price Master + Sales) — not
    // a new finding. No DB assertion needed here; recorded as a comment
    // for anyone reading this script fresh.
    const uomRow = await dbClient.query(
      `SELECT pu.id FROM rim_product_uom pu
       JOIN rim_products p ON p.id = pu.product_id
       WHERE p.company_id=$1 AND p.product_name=$2`,
      [companyId, PRODUCT_NAME]
    );
    console.log(`rim_product_uom rows for this product: ${uomRow.rows.length} (expected 0 — base_uom_id alone is sufficient, known fallback elsewhere)`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: PRODUCT MASTER RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
