// Phase 1 (Inventory Masters) — Product Flag Types. PGS-01's "8 standard
// flags" were already confirmed present via direct DB check (the
// new-tenant starter kit seeds them) — this script verifies that via the
// real screen, then tests PGS-02 (add a custom flag). Currency/GL/Stock/
// Chain don't apply to this screen. This dialog uses REAL InputDecoration
// labelText (confirmed via code read), so getByLabel should work reliably
// here, unlike the SakalFieldCard-external-label pattern used elsewhere.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const FLAG_KEY = `is_qa_test_${STAMP}`;
const FLAG_LABEL = `QA Test Flag ${STAMP}`;

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
  } catch (e) { fail('Login', e); await shot(page, 'pgs-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/product-flag-types`);
    await textVisible(page, 'Can be Sold').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'pgs-01-loaded');
    pass('PGS-01: Product Flag Types screen loaded, 8 standard flags already present ("Can be Sold" visible)');
  } catch (e) { fail('Open Product Flag Types / confirm defaults', e); await shot(page, 'pgs-01-fail'); }

  try {
    const addBtn = page.getByRole('button', { name: 'Add Flag', exact: true }).first();
    await addBtn.click();
    await page.waitForTimeout(500);
    const dialogVisible = await textVisible(page, 'Add Flag Type').isVisible({ timeout: 3000 }).catch(() => false);
    if (!dialogVisible) throw new Error('"Add Flag Type" dialog did not open');
    await typeInto(page, 'Flag Key', FLAG_KEY);
    await typeInto(page, 'Label', FLAG_LABEL);
    await shot(page, 'pgs-02-filled');
    const saveBtn = page.getByRole('button', { name: 'Save', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'pgs-03-saved');
    pass(`PGS-02: Custom flag "${FLAG_KEY}" saved`);
  } catch (e) { fail('Add custom flag', e); await shot(page, 'pgs-02-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const standardFlags = await dbClient.query(
      `SELECT flag_key FROM rim_product_flag_types WHERE company_id=$1`,
      [companyId]
    );
    console.log('Total flags now:', standardFlags.rows.length, standardFlags.rows.map(r => r.flag_key));
    const stdKeys = ['is_saleable','is_purchasable','is_pos_item','is_discountable','is_transferable','is_intercompany','allow_negative_stock','is_consignment'];
    const missing = stdKeys.filter(k => !standardFlags.rows.some(r => r.flag_key === k));
    if (missing.length > 0) throw new Error(`Missing standard flags: ${missing.join(', ')}`);
    pass('DB: all 8 standard flags confirmed present');

    const customFlag = await dbClient.query(
      `SELECT flag_key, flag_label, default_value, is_active FROM rim_product_flag_types WHERE company_id=$1 AND flag_key=$2`,
      [companyId, FLAG_KEY]
    );
    console.log('Custom flag in DB:', customFlag.rows);
    if (customFlag.rows.length === 0) throw new Error('Custom flag not found in DB');
    if (customFlag.rows[0].flag_label !== FLAG_LABEL) throw new Error(`flag_label=${customFlag.rows[0].flag_label}, expected ${FLAG_LABEL}`);
    pass(`DB: custom flag "${FLAG_KEY}" saved correctly with label "${FLAG_LABEL}"`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: PRODUCT FLAG TYPES RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
