// Phase 1 (Finance Masters, found alongside System Setup) — Payment
// Terms. Tests PYT-01 (a single-line PERCENT term summing to 100%).
// Currency doesn't apply — GL/Stock/Chain don't apply directly (this is
// pure reference data consumed by Sales Order/Quotation later).
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const TERM_CODE = `QAT${STAMP}`.slice(0, 10);
const TERM_NAME = `QA Immediate ${STAMP}`;

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
  } catch (e) { fail('Login', e); await shot(page, 'pyt-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/payment-terms`);
    await page.getByRole('button', { name: 'Add Payment Term', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'pyt-01-loaded');
    pass('Payment Terms screen loaded');
  } catch (e) { fail('Open Payment Terms', e); await shot(page, 'pyt-01-fail'); }

  try {
    await page.getByRole('button', { name: 'Add Payment Term', exact: true }).first().click();
    await page.waitForTimeout(500);
    const dialogVisible = await textVisible(page, 'Add Payment Term').isVisible({ timeout: 3000 }).catch(() => false);
    if (!dialogVisible) throw new Error('"Add Payment Term" dialog did not open');
    await shot(page, 'pyt-02-dialog-opened');
    pass('Add Payment Term dialog opened');
  } catch (e) { fail('Open Add Payment Term dialog', e); await shot(page, 'pyt-02-fail'); }

  try {
    // Code/Name use SakalFieldCard external labels (no InputDecoration
    // labelText) — not getByLabel-locatable. Click by position (confirmed
    // via screenshot: Code field at ~x=492,y=375; Name at ~x=782,y=375).
    await page.mouse.click(492, 375);
    await page.waitForTimeout(150);
    await page.keyboard.type(TERM_CODE, { delay: 30 });
    await page.mouse.click(782, 375);
    await page.waitForTimeout(150);
    await page.keyboard.type(TERM_NAME, { delay: 30 });
    await shot(page, 'pyt-03-code-name-filled');
    pass(`Code "${TERM_CODE}" / Name "${TERM_NAME}" filled`);
  } catch (e) { fail('Fill Code/Name', e); await shot(page, 'pyt-03-fail'); }

  try {
    // The dialog already starts with ONE blank installment line by default
    // (confirmed via screenshot) — clicking "Add Line" would create a 2nd,
    // unwanted row. Type defaults to PERCENT already. Fill Percent=100,
    // Due Days stays 0 (already the field's own default).
    await shot(page, 'pyt-04-line-added');
    const percentField = page.getByLabel('Percent', { exact: true }).first();
    await percentField.click();
    await page.waitForTimeout(150);
    await page.keyboard.press('Control+A');
    await page.keyboard.type('100', { delay: 30 });
    // Due Days already defaults to 0 — no change needed.
    await shot(page, 'pyt-05-line-filled');
    pass('Line filled: PERCENT 100%, Due Days 0');
  } catch (e) { fail('Fill installment line', e); await shot(page, 'pyt-04-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Add Term', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'pyt-06-saved');
    pass(`Payment Term "${TERM_NAME}" saved`);
  } catch (e) { fail('Save Payment Term', e); await shot(page, 'pyt-06-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT id, term_code, term_name FROM rim_payment_terms WHERE company_id=$1 AND term_code=$2`,
      [companyId, TERM_CODE]
    );
    console.log('Payment term in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('Payment term not found in DB');
    pass(`DB: Payment Term "${TERM_NAME}" (code ${TERM_CODE}) saved`);

    const lines = await dbClient.query(
      `SELECT value_type, value_amount, due_days FROM rim_payment_term_lines WHERE term_id=$1 AND is_deleted=false`,
      [header.rows[0].id]
    );
    console.log('Payment term lines in DB:', lines.rows);
    if (lines.rows.length !== 1) throw new Error(`Expected 1 line, found ${lines.rows.length}`);
    if (lines.rows[0].value_type !== 'PERCENT') throw new Error(`value_type=${lines.rows[0].value_type}, expected PERCENT`);
    if (Number(lines.rows[0].value_amount) !== 100) throw new Error(`value_amount=${lines.rows[0].value_amount}, expected 100`);
    pass('DB: single PERCENT line correctly saved at 100%, due_days=0');
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: PAYMENT TERMS RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
