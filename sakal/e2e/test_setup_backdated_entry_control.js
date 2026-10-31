// Phase 1 (System Setup) — Backdated Entry Control. Tests BDC-02: set a
// Max Days window for one transaction type (Sales Invoice). BDC-01 (the
// actual block-on-a-backdated-save enforcement) is deferred to Phase 5
// (Sales Invoice), since it needs a real transaction attempt to exercise.
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
  } catch (e) { fail('Login', e); await shot(page, 'bdc-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/backdated-entry-control`);
    await textVisible(page, 'Sales Invoice').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'bdc-01-loaded');
    pass('Backdated Entry Control screen loaded');
  } catch (e) { fail('Open Backdated Entry Control', e); await shot(page, 'bdc-01-fail'); }

  try {
    // Fixed row positions confirmed via screenshot (9 rows, ~44px apart,
    // starting at y≈132): Sales Invoice is the 4th row, y≈300, Max Days
    // field at x≈860. A computed boundingBox-offset approach landed one
    // row too low (Sales Return) on first attempt — direct coordinates
    // from the screenshot are more reliable here.
    await page.mouse.click(860, 300);
    await page.waitForTimeout(150);
    await page.keyboard.type('30', { delay: 30 });
    await shot(page, 'bdc-02b-verify-row');
    const confirmBox = await textVisible(page, 'Sales Invoice').boundingBox();
    console.log('Sales Invoice label box (for diagnostics):', confirmBox);
    await shot(page, 'bdc-02-filled');
    pass('Sales Invoice Max Days set to 30');
  } catch (e) { fail('Fill Max Days for Sales Invoice', e); await shot(page, 'bdc-02-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Changes', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'bdc-03-saved');
    pass('Backdated Entry Control settings saved');
  } catch (e) { fail('Save settings', e); await shot(page, 'bdc-03-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT transaction_type, max_backdate_days, allow_future_date FROM ric_backdated_entry_control
       WHERE company_id=$1 AND transaction_type='SALES_INVOICE'`,
      [companyId]
    );
    console.log('Backdated entry control row in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('SALES_INVOICE row not found in DB');
    if (Number(row.rows[0].max_backdate_days) !== 30) throw new Error(`max_backdate_days=${row.rows[0].max_backdate_days}, expected 30`);
    pass('DB: Sales Invoice max_backdate_days correctly saved as 30');
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: BACKDATED ENTRY CONTROL RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
