// Phase 1 (Purchase Masters) — Supplier Master. Creates one real
// supplier, needed to unblock Phase 3 (Purchase Cycle) testing. Same
// layout/behavior as Customer Master (same screen family) — reuses the
// identical proven technique, including explicitly waiting for the form
// to settle before picking Parent Group (the same `_groups` async-load
// race suspected, not confirmed, on Customer Master).
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const SUPPLIER_NAME = `QA Test Supplier ${STAMP}`;

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
  } catch (e) { fail('Login', e); await shot(page, 'supp-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/suppliers`);
    await page.getByRole('button', { name: 'Add', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'supp-01-loaded');
    pass('Supplier Master screen loaded');
  } catch (e) { fail('Open Supplier Master', e); await shot(page, 'supp-01-fail'); }

  try {
    await page.getByRole('button', { name: 'Add', exact: true }).first().click();
    await textVisible(page, 'New Supplier').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(1200); // let _groups finish loading before interacting
    await shot(page, 'supp-02-form-opened');
    pass('Add Supplier form opened');
  } catch (e) { fail('Open Add Supplier form', e); await shot(page, 'supp-02-fail'); }

  try {
    await page.mouse.click(963, 169); // Supplier Name field, same layout as Customer Master
    await page.waitForTimeout(150);
    await page.keyboard.type(SUPPLIER_NAME, { delay: 30 });
    await shot(page, 'supp-03-name-filled');
    pass(`Supplier name "${SUPPLIER_NAME}" filled`);
  } catch (e) { fail('Fill Supplier Name', e); await shot(page, 'supp-03-fail'); }

  try {
    // Explicitly confirm/pick Parent Group to be safe (same precaution as
    // Customer Master) — "4010 Suppliers" is the seeded Supplier-nature
    // group.
    await page.mouse.click(963, 225);
    await page.waitForTimeout(150);
    await page.keyboard.press('Control+A');
    await page.keyboard.type('4010', { delay: 30 });
    await page.waitForTimeout(600);
    await shot(page, 'supp-03b-parent-group-search');
    const groupOption = textVisible(page, '4010').first();
    const found = await groupOption.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error('"4010 Suppliers" parent group not found in picker');
    await groupOption.click();
    await page.waitForTimeout(500);
    await shot(page, 'supp-03c-parent-group-picked');
    pass('Parent Group set to [4010] Suppliers');
  } catch (e) { fail('Pick Parent Group', e); await shot(page, 'supp-03b-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Create Supplier', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'supp-04-saved');
    pass(`Supplier "${SUPPLIER_NAME}" saved`);
  } catch (e) { fail('Save new supplier', e); await shot(page, 'supp-04-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT account_code, account_name, account_nature FROM rim_accounts WHERE company_id=$1 AND account_name=$2`,
      [companyId, SUPPLIER_NAME]
    );
    console.log('New supplier in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('New supplier not found in DB');
    if (row.rows[0].account_nature !== 'Supplier') throw new Error(`account_nature=${row.rows[0].account_nature}, expected Supplier`);
    pass(`DB: Supplier "${SUPPLIER_NAME}" (account ${row.rows[0].account_code}) saved correctly with account_nature=Supplier`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: SUPPLIER MASTER RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
