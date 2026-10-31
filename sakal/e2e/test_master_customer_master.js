// Phase 1 (Sales Masters) — Customer Master. Creates one real customer,
// needed to unblock Phase 5 (Sales Cycle) testing. Currency applies to
// this screen (Ledger Currency) — tests Base only here as a minimal-
// coverage pass; a fuller 3-currency customer battery is a follow-up.
// GL/Stock/Chain don't apply directly — downstream usage (a real Sales
// Invoice against this customer) is Phase 5's job.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const CUSTOMER_NAME = `QA Test Customer ${STAMP}`;

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
  } catch (e) { fail('Login', e); await shot(page, 'cust-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/customers`);
    await page.getByRole('button', { name: 'Add', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'cust-01-loaded');
    pass('Customer Master screen loaded');
  } catch (e) { fail('Open Customer Master', e); await shot(page, 'cust-01-fail'); }

  try {
    await page.getByRole('button', { name: 'Add', exact: true }).first().click();
    // The "New Customer" form's own content takes a moment longer to
    // settle than the panel header itself — textVisible('Customer Name')
    // timed out despite the field clearly rendering (confirmed via
    // screenshot), same overlay-timing gap as several other dialogs this
    // session. Wait for the panel title instead (always reliable) and a
    // fixed settle time before interacting by coordinate.
    await textVisible(page, 'New Customer').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(1000);
    await shot(page, 'cust-02-form-opened');
    pass('Add Customer form opened');
  } catch (e) { fail('Open Add Customer form', e); await shot(page, 'cust-02-fail'); }

  try {
    // Customer Name field at a known position (confirmed via screenshot:
    // ~x=963, y=169).
    await page.mouse.click(963, 169);
    await page.waitForTimeout(150);
    await page.keyboard.type(CUSTOMER_NAME, { delay: 30 });
    await shot(page, 'cust-03-name-filled');
    pass(`Customer name "${CUSTOMER_NAME}" filled`);
  } catch (e) { fail('Fill Customer Name', e); await shot(page, 'cust-03-fail'); }

  try {
    // Parent Group is NOT auto-defaulted (real finding, confirmed live: a
    // first save attempt without it showed "Customer group not found.
    // Please seed the Chart of Accounts first." even though the seeded
    // "4110 Customers" group genuinely exists — the form's own default-
    // group lookup just doesn't auto-populate it). Pick it explicitly.
    await page.mouse.click(963, 225);
    await page.waitForTimeout(150);
    await page.keyboard.type('4110', { delay: 30 });
    await page.waitForTimeout(600);
    await shot(page, 'cust-03b-parent-group-search');
    // Match by account CODE "4110", not the bare name "Customers" — the
    // bare name also matches the sidebar's own "Customers" menu item text,
    // which caused a real mis-click live: it navigated to the Dashboard
    // instead of selecting the picker option.
    const groupOption = textVisible(page, '4110').first();
    const found = await groupOption.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error('"4110 Customers" parent group not found in picker');
    await groupOption.click();
    await page.waitForTimeout(500);
    await shot(page, 'cust-03c-parent-group-picked');
    pass('Parent Group set to [4110] Customers');
  } catch (e) { fail('Pick Parent Group', e); await shot(page, 'cust-03b-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Create Customer', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'cust-04-saved');
    pass(`Customer "${CUSTOMER_NAME}" saved`);
  } catch (e) { fail('Save new customer', e); await shot(page, 'cust-04-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT account_code, account_name, account_nature, account_currency_id
       FROM rim_accounts WHERE company_id=$1 AND account_name=$2`,
      [companyId, CUSTOMER_NAME]
    );
    console.log('New customer in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('New customer not found in DB');
    if (row.rows[0].account_nature !== 'Customer') throw new Error(`account_nature=${row.rows[0].account_nature}, expected Customer`);
    pass(`DB: Customer "${CUSTOMER_NAME}" (account ${row.rows[0].account_code}) saved correctly with account_nature=Customer`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: CUSTOMER MASTER RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
