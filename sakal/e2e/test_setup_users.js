// Phase 1 (User Management) — Users. Creates one additional user, needed
// as a real test subject for later permission-denial tests (CCC #6) and
// for Phase 7's cross-cutting regression pass. Currency/GL/Stock/Chain
// don't apply to this screen.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const FULL_NAME = `QA Test User ${STAMP}`;
const USERNAME = `qauser${STAMP}`;
const PASSWORD = 'QaTest12345';

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
  } catch (e) { fail('Login', e); await shot(page, 'usr-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/users`);
    await page.getByRole('button', { name: 'Add User', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'usr-01-loaded');
    pass('Users screen loaded');
  } catch (e) { fail('Open Users', e); await shot(page, 'usr-01-fail'); }

  try {
    await page.getByRole('button', { name: 'Add User', exact: true }).first().click();
    await page.waitForTimeout(600);
    const dialogVisible = await textVisible(page, 'Add User').isVisible({ timeout: 3000 }).catch(() => false);
    if (!dialogVisible) throw new Error('"Add User" dialog did not open');
    await typeInto(page, 'Full Name *', FULL_NAME);
    await typeInto(page, 'Username *', USERNAME);
    // typeInto's getByLabel is substring-matched (no exact:true) — "Password
    // *" also matches "Confirm Password *" as a substring, causing a strict-
    // mode violation. Disambiguate directly here instead of via typeInto.
    const pwField = page.getByLabel('Password *', { exact: true }).first();
    await pwField.click();
    await page.waitForTimeout(150);
    await page.keyboard.type(PASSWORD, { delay: 30 });
    const confirmField = page.getByLabel('Confirm Password *', { exact: true }).first();
    await confirmField.click();
    await page.waitForTimeout(150);
    await page.keyboard.type(PASSWORD, { delay: 30 });
    await shot(page, 'usr-02-filled');
    pass('New user form filled');
  } catch (e) { fail('Fill Add User form', e); await shot(page, 'usr-02-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Add User', exact: true }).last();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'usr-03-saved');
    pass(`User "${FULL_NAME}" (${USERNAME}) saved`);
  } catch (e) { fail('Save new user', e); await shot(page, 'usr-03-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT full_name, username, is_active FROM rim_users WHERE company_id=$1 AND username=$2`,
      [companyId, USERNAME]
    );
    console.log('New user in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('New user not found in DB');
    if (row.rows[0].full_name !== FULL_NAME) throw new Error(`full_name=${row.rows[0].full_name}, expected ${FULL_NAME}`);
    if (row.rows[0].is_active !== true) throw new Error('New user should be active by default');
    pass(`DB: User "${FULL_NAME}" (${USERNAME}) saved correctly, active`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log(`\nUSERNAME=${USERNAME}  PASSWORD=${PASSWORD}`);
  console.log('\n===== PHASE 1: USERS RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
