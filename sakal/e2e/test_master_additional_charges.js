// Phase 1 (Finance Masters) — Additional Charges. Tests CHG-01 (an
// ADD-nature Freight charge) and CHG-02 (a DEDUCT-nature Rebate charge),
// confirming the Nature toggle correctly flips Dr/Cr direction intent
// (stored as 'nature' column, the actual Dr/Cr flip happens at GRN/PO
// posting time — deferred to Phase 3). Currency does NOT apply to this
// screen (a charge's default amount is in whatever currency the document
// using it is raised in, not fixed here) — GL/Stock/Chain don't apply
// directly either; downstream usage (a charge actually posting on a GRN)
// is deferred to Phase 3 (Purchase Cycle).
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const FREIGHT_CODE = `QAF${STAMP}`.slice(0, 10);
const FREIGHT_NAME = `QA Freight ${STAMP}`;
const REBATE_CODE = `QAR${STAMP}`.slice(0, 10);
const REBATE_NAME = `QA Rebate ${STAMP}`;

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
  } catch (e) { fail('Login', e); await shot(page, 'chg-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/additional-charges`);
    const addVisible = await page.getByRole('button', { name: 'Add Charge', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    if (!addVisible) throw new Error('Additional Charges screen did not load (no "Add Charge" button)');
    await shot(page, 'chg-01-loaded');
    pass('Additional Charges screen loaded');
  } catch (e) { fail('Open Additional Charges', e); await shot(page, 'chg-01-fail'); }

  // ---------- Test 1: ADD-nature Freight charge ----------
  try {
    await page.getByRole('button', { name: 'Add Charge', exact: true }).first().click();
    await page.waitForTimeout(500);
    const dialogVisible = await textVisible(page, 'Add Charge Type').isVisible({ timeout: 3000 }).catch(() => false);
    if (!dialogVisible) throw new Error('"Add Charge Type" dialog did not open');
    await typeInto(page, 'Code', FREIGHT_CODE);
    await typeInto(page, 'Name', FREIGHT_NAME);
    // Nature defaults to ADD already — no change needed. Default Type
    // defaults to AMOUNT — enter a default amount.
    const valueField = page.getByLabel('Default Amount', { exact: true }).first();
    await valueField.click();
    await page.waitForTimeout(150);
    await page.keyboard.type('50', { delay: 30 });
    await shot(page, 'chg-02-freight-filled');
    const saveBtn = page.getByRole('button', { name: 'Add Charge', exact: true }).last();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'chg-03-freight-saved');
    pass(`ADD-nature charge "${FREIGHT_NAME}" saved`);
  } catch (e) { fail('Create ADD-nature Freight charge', e); await shot(page, 'chg-02-fail'); }

  // ---------- Test 2: DEDUCT-nature Rebate charge ----------
  try {
    await page.getByRole('button', { name: 'Add Charge', exact: true }).first().click();
    await page.waitForTimeout(500);
    await textVisible(page, 'Add Charge Type').waitFor({ state: 'visible', timeout: 5000 });
    await typeInto(page, 'Code', REBATE_CODE);
    await typeInto(page, 'Name', REBATE_NAME);
    // Switch Nature to DEDUCT.
    const deductChip = page.getByText('Deduct (rebate)', { exact: true }).first();
    await deductChip.click();
    await page.waitForTimeout(400);
    const valueField = page.getByLabel('Default Amount', { exact: true }).first();
    await valueField.click();
    await page.waitForTimeout(150);
    await page.keyboard.type('10', { delay: 30 });
    await shot(page, 'chg-04-rebate-filled');
    const saveBtn = page.getByRole('button', { name: 'Add Charge', exact: true }).last();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'chg-05-rebate-saved');
    pass(`DEDUCT-nature charge "${REBATE_NAME}" saved`);
  } catch (e) { fail('Create DEDUCT-nature Rebate charge', e); await shot(page, 'chg-04-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const freightRow = await dbClient.query(
      `SELECT charge_code, charge_name, nature, default_amount, applicable_on
       FROM rim_additional_charges WHERE company_id=$1 AND charge_code=$2`,
      [companyId, FREIGHT_CODE]
    );
    console.log('Freight charge in DB:', freightRow.rows);
    if (freightRow.rows.length === 0) throw new Error('Freight charge not found in DB');
    if (freightRow.rows[0].nature !== 'ADD') throw new Error(`nature=${freightRow.rows[0].nature}, expected ADD`);
    if (Number(freightRow.rows[0].default_amount) !== 50) throw new Error(`default_amount=${freightRow.rows[0].default_amount}, expected 50`);
    pass(`DB: Freight charge correctly saved with nature=ADD, default_amount=50`);

    const rebateRow = await dbClient.query(
      `SELECT charge_code, charge_name, nature, default_amount
       FROM rim_additional_charges WHERE company_id=$1 AND charge_code=$2`,
      [companyId, REBATE_CODE]
    );
    console.log('Rebate charge in DB:', rebateRow.rows);
    if (rebateRow.rows.length === 0) throw new Error('Rebate charge not found in DB');
    if (rebateRow.rows[0].nature !== 'DEDUCT') throw new Error(`nature=${rebateRow.rows[0].nature}, expected DEDUCT`);
    pass(`DB: Rebate charge correctly saved with nature=DEDUCT, default_amount=${rebateRow.rows[0].default_amount}`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: ADDITIONAL CHARGES RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
