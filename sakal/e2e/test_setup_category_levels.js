// Phase 1 (Inventory Masters) — Category Level Setup. Tests PCS-01: add a
// Level 1 label and confirm it saves. Currency/GL/Stock/Chain don't apply.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
// Level 1 ("Category") is already seeded by the new-tenant starter kit
// (confirmed live: dialog opened as "Add Level 2", not "Add Level 1") —
// test adds Level 2 instead.
const LEVEL2_LABEL = 'Sub-Category';

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

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'pcs-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/category-levels`);
    await textVisible(page, 'levels configured').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'pcs-01-loaded');
    pass('Category Level Setup screen loaded');
  } catch (e) { fail('Open Category Level Setup', e); await shot(page, 'pcs-01-fail'); }

  try {
    const addBtn = page.getByRole('button', { name: /^Add (Level|your first level)/i }).first();
    const addVisible = await addBtn.isVisible({ timeout: 5000 }).catch(() => false);
    if (!addVisible) throw new Error('No "Add Level" affordance visible');
    await addBtn.click();
    await page.waitForTimeout(500);
    await shot(page, 'pcs-02-dialog-opened');
    // getByLabel timed out despite real InputDecoration.labelText — likely
    // an AlertDialog-overlay semantics-timing gap, same family of issue
    // seen elsewhere. Click by known position (confirmed via screenshot:
    // field box at ~x=683, y=406).
    const dialogVisible = await textVisible(page, 'Add Level 2').isVisible({ timeout: 3000 }).catch(() => false);
    if (!dialogVisible) throw new Error('"Add Level 2" dialog did not open');
    await page.mouse.click(683, 406);
    await page.waitForTimeout(150);
    await page.keyboard.type(LEVEL2_LABEL, { delay: 30 });
    await shot(page, 'pcs-03-filled');
    const saveBtn = page.getByRole('button', { name: 'Save', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'pcs-04-saved');
    pass(`Level 2 label "${LEVEL2_LABEL}" saved`);
  } catch (e) { fail('Add Level 2', e); await shot(page, 'pcs-02-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT level_no, level_label, is_mandatory, is_active FROM rim_category_levels WHERE company_id=$1 AND level_no=2`,
      [companyId]
    );
    console.log('Level 2 in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('Level 2 not found in DB');
    if (row.rows[0].level_label !== LEVEL2_LABEL) throw new Error(`level_label=${row.rows[0].level_label}, expected ${LEVEL2_LABEL}`);
    pass(`DB: Level 2 correctly saved as "${LEVEL2_LABEL}"`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: CATEGORY LEVEL SETUP RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
