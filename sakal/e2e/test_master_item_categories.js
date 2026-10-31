// Phase 1 (Inventory Masters) — Item Categories. Tests ITC-01 (create a
// Level 1 category) and confirms ITC-04 (the "General" starter category
// already exists on a fresh tenant, per the 2026-09-13 new-tenant starter
// kit fix) via direct DB check. Currency doesn't apply to this screen —
// GL/Stock/Chain don't apply directly either. Downstream usage (appearing
// in Product Master's category picker) deferred to a later Product Master
// pass since this session's single test product already used "General".
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const CATEGORY_NAME = `QA Category ${STAMP}`;

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1366, height: 900 } })).newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  const dbClient = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await dbClient.connect();
  const cRes = await dbClient.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
  const compRes = await dbClient.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [cRes.rows[0].id]);
  const companyId = compRes.rows[0].id;

  // ---------- ITC-04 pre-check (direct DB, already confirmed in Product Master testing) ----------
  try {
    const general = await dbClient.query(
      `SELECT category_name, parent_id FROM rim_item_categories WHERE company_id=$1 AND category_name='General' AND is_deleted=false`,
      [companyId]
    );
    if (general.rows.length === 0) throw new Error('"General" starter category not found');
    if (general.rows[0].parent_id !== null) throw new Error('"General" is not a Level-1 (root) category');
    pass('ITC-04: "General" starter Level-1 category confirmed present (2026-09-13 new-tenant fix)');
  } catch (e) { fail('ITC-04 pre-check', e); }

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'itc-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/item-categories`);
    await textVisible(page, 'General').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'itc-01-loaded');
    pass('Item Categories screen loaded, "General" category visible');
  } catch (e) { fail('Open Item Categories', e); await shot(page, 'itc-01-fail'); }

  try {
    const addBtn = page.getByRole('button', { name: /^Add /i }).first();
    await addBtn.click();
    await page.waitForTimeout(600);
    await shot(page, 'itc-02-add-form-opened');
    // getByLabel doesn't match (same label-association gap as every other
    // screen this session) — click by known position (confirmed via
    // screenshot: Name field at ~x=970, y=266).
    const formVisible = await textVisible(page, 'New Category').isVisible({ timeout: 5000 }).catch(() => false);
    if (!formVisible) throw new Error('"New Category" form did not open');
    await page.mouse.click(970, 266);
    await page.waitForTimeout(150);
    await page.keyboard.type(CATEGORY_NAME, { delay: 30 });
    await shot(page, 'itc-03-filled');
    pass(`Category name "${CATEGORY_NAME}" filled (Level defaults to 1)`);
  } catch (e) { fail('Open + fill Add Category form', e); await shot(page, 'itc-02-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'itc-04-saved');
    pass('Category saved');
  } catch (e) { fail('Save category', e); await shot(page, 'itc-04-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT category_name, parent_id, is_active FROM rim_item_categories WHERE company_id=$1 AND category_name=$2`,
      [companyId, CATEGORY_NAME]
    );
    console.log('New category in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('New category not found in DB');
    if (row.rows[0].parent_id !== null) throw new Error('New category should be Level 1 (parent_id null)');
    pass(`DB: Category "${CATEGORY_NAME}" correctly saved as a Level-1 (root) category`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: ITEM CATEGORIES RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
