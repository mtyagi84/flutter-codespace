// Phase 1 (System Setup) — Location Setup. Creates a second location,
// needed for later multi-location/INTER_ENTITY tests (Phase 4 Stock
// Transfer). Currency doesn't apply directly to this screen.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const LOCATION_NAME = `QA Second Store ${STAMP}`;

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1366, height: 1100 } })).newPage();
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
  } catch (e) { fail('Login', e); await shot(page, 'loc-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/locations`);
    await page.getByRole('button', { name: 'Add Location', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'loc-01-loaded');
    pass('Locations screen loaded');
  } catch (e) { fail('Open Locations', e); await shot(page, 'loc-01-fail'); }

  try {
    await page.getByRole('button', { name: 'Add Location', exact: true }).first().click();
    await textVisible(page, 'Add Location').waitFor({ state: 'visible', timeout: 8000 });
    await page.waitForTimeout(1000);
    await shot(page, 'loc-02-form-opened');
    pass('Add Location form opened');
  } catch (e) { fail('Open Add Location form', e); await shot(page, 'loc-02-fail'); }

  try {
    const nameField = page.getByLabel('Location Name', { exact: false }).first();
    const labelWorks = await nameField.isVisible({ timeout: 2000 }).catch(() => false);
    if (labelWorks) {
      await nameField.click();
    } else {
      // _req() uses a RichText label, not plain labelText — may not be
      // getByLabel-locatable. Fall back to a coordinate click.
      await page.mouse.click(700, 192);
    }
    await page.waitForTimeout(150);
    await page.keyboard.type(LOCATION_NAME, { delay: 30 });
    await shot(page, 'loc-03-name-filled');
    pass(`Location name "${LOCATION_NAME}" filled`);
  } catch (e) { fail('Fill Location Name', e); await shot(page, 'loc-03-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Add Location', exact: true }).last();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'loc-04-saved');
    pass(`Location "${LOCATION_NAME}" saved`);
  } catch (e) { fail('Save new location', e); await shot(page, 'loc-04-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT location_name, location_type, is_active FROM ric_locations WHERE company_id=$1 AND location_name=$2`,
      [companyId, LOCATION_NAME]
    );
    console.log('New location in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('New location not found in DB');
    if (row.rows[0].is_active !== true) throw new Error('New location should be active by default');
    pass(`DB: Location "${LOCATION_NAME}" saved correctly, active`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: LOCATIONS RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
