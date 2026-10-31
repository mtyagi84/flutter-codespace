// Phase 1 (Inventory Masters) — Consumption Area Setup. Tests DCA-01:
// link a Consumption Area to a Department + an expense account. Requires
// the Department/Consumption Area common masters created by
// test_setup_common_masters_dept_consumption.js — pass their exact names
// via env vars DEPT_NAME/AREA_NAME, or this script looks them up as the
// most-recently-created "QA " prefixed rows. Currency doesn't apply here;
// GL/Stock/Chain don't apply directly — downstream usage (Material
// Requisition/Issue's cascading picker resolving to this account) is
// deferred to the Inventory transactions phase.
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
  const dbClient = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await dbClient.connect();
  const cRes = await dbClient.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
  const compRes = await dbClient.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [cRes.rows[0].id]);
  const companyId = compRes.rows[0].id;

  const deptRow = await dbClient.query(
    `SELECT cm.id, cm.description FROM rim_common_masters cm
     JOIN rim_common_master_types t ON t.id = cm.type_id
     WHERE t.type_key='DEPARTMENT' AND cm.company_id=$1 AND cm.is_deleted=false
     ORDER BY cm.created_at DESC LIMIT 1`, [companyId]
  );
  const areaRow = await dbClient.query(
    `SELECT cm.id, cm.description FROM rim_common_masters cm
     JOIN rim_common_master_types t ON t.id = cm.type_id
     WHERE t.type_key='CONSUMPTION_AREA' AND cm.company_id=$1 AND cm.is_deleted=false
     ORDER BY cm.created_at DESC LIMIT 1`, [companyId]
  );
  if (deptRow.rows.length === 0 || areaRow.rows.length === 0) {
    console.error('Department or Consumption Area master missing — run test_setup_common_masters_dept_consumption.js first');
    process.exit(1);
  }
  const DEPT_NAME = deptRow.rows[0].description;
  const AREA_NAME = areaRow.rows[0].description;
  console.log(`Using Department="${DEPT_NAME}", Consumption Area="${AREA_NAME}"`);

  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1366, height: 900 } })).newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'dca-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/inventory/department-consumption-areas`);
    await textVisible(page, DEPT_NAME).waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(800);
    await shot(page, 'dca-01-loaded');
    pass('Consumption Area Setup screen loaded, test Department visible/selected');
  } catch (e) { fail('Open Consumption Area Setup', e); await shot(page, 'dca-01-fail'); }

  try {
    const addRowBtn = page.getByRole('button', { name: 'Add Consumption Area', exact: true }).first();
    await addRowBtn.click();
    await page.waitForTimeout(600);
    await shot(page, 'dca-02-row-added');
    pass('New link row added');
  } catch (e) { fail('Add link row', e); await shot(page, 'dca-02-fail'); }

  try {
    // Consumption Area dropdown — plain DropdownButtonFormField at a known
    // position (first/only row, confirmed via screenshot: ~x=380, y=161).
    await page.mouse.click(380, 161);
    await page.waitForTimeout(400);
    await shot(page, 'dca-03-area-dropdown-opened');
    const areaOption = textVisible(page, AREA_NAME).first();
    const found = await areaOption.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error(`Consumption Area "${AREA_NAME}" not found in dropdown`);
    await areaOption.click();
    await page.waitForTimeout(400);
    pass(`Picked Consumption Area "${AREA_NAME}"`);
  } catch (e) { fail('Pick Consumption Area', e); await shot(page, 'dca-03-fail'); }

  try {
    // Expense Account autocomplete — click to its right, search, pick
    // (confirmed via screenshot: ~x=647, y=161).
    await page.mouse.click(647, 161);
    await page.waitForTimeout(150);
    await page.keyboard.type('5800', { delay: 30 });
    await page.waitForTimeout(600);
    await shot(page, 'dca-04-account-search');
    const option = textVisible(page, 'Internal Transfers').first();
    const found = await option.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error('"5800 Internal Transfers" not found in account picker');
    await option.click();
    await page.waitForTimeout(500);
    await shot(page, 'dca-05-account-picked');
    pass('Picked expense account [5800] Internal Transfers');
  } catch (e) { fail('Pick expense account', e); await shot(page, 'dca-04-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'dca-06-saved');
    pass('Consumption Area link saved');
  } catch (e) { fail('Save link', e); await shot(page, 'dca-06-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT l.department_id, l.consumption_area_id, a.account_code, a.account_name
       FROM rim_department_consumption_areas l
       JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.company_id=$1 AND l.department_id=$2 AND l.consumption_area_id=$3`,
      [companyId, deptRow.rows[0].id, areaRow.rows[0].id]
    );
    console.log('DCA link in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('Link not found in DB');
    if (row.rows[0].account_code !== '5800') throw new Error(`account_code=${row.rows[0].account_code}, expected 5800`);
    pass(`DB: Consumption Area "${AREA_NAME}" correctly linked to Department "${DEPT_NAME}" and account [5800] Internal Transfers`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: CONSUMPTION AREA SETUP RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
