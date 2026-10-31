// Phase 1 (Finance Masters) — Tax Groups. Tests TXG-01 (a group with one
// tax member, confirming it's selectable/usable — downstream GRN/Sales
// Invoice line usage is deferred to those phases) and confirms the
// seeded default group ("TVA Standard 16%") is reusable as a real member
// source. Currency does NOT apply to this screen (same reasoning as Tax
// Master) — GL/Stock/Chain don't apply directly either.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const GROUP_CODE = `QAG${STAMP}`.slice(0, 10);
const GROUP_NAME = `QA Standard Group ${STAMP}`;

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
  } catch (e) { fail('Login', e); await shot(page, 'txg-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/tax-groups`);
    await page.getByRole('button', { name: 'Add', exact: true }).first()
      .waitFor({ state: 'visible', timeout: 10000 });
    // Same lesson as Tax Master: wait for real data (a seeded group), not
    // just the Add button's own always-rendered visibility.
    await textVisible(page, 'TVA Standard').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'txg-01-loaded');
    pass('Tax Groups screen loaded, seeded groups visible');
  } catch (e) { fail('Open Tax Groups', e); await shot(page, 'txg-01-fail'); }

  try {
    await page.getByRole('button', { name: 'Add', exact: true }).first().click();
    await page.waitForTimeout(500);
    const newFormVisible = await textVisible(page, 'New Tax Group').isVisible({ timeout: 3000 }).catch(() => false);
    if (!newFormVisible) throw new Error('"New Tax Group" form did not open');
    await typeInto(page, 'Group Code', GROUP_CODE);
    await typeInto(page, 'Group Name', GROUP_NAME);
    await shot(page, 'txg-02-group-filled');
    pass('New Tax Group form filled');
  } catch (e) { fail('Open + fill New Tax Group', e); await shot(page, 'txg-02-fail'); }

  try {
    const addTaxBtn = page.getByRole('button', { name: 'Add Tax', exact: true }).first();
    await addTaxBtn.waitFor({ state: 'visible', timeout: 5000 });
    await addTaxBtn.click();
    await page.waitForTimeout(600);
    await shot(page, 'txg-03-add-member-sheet');
    // The bottom sheet's own search field has no accessible label text
    // (placeholder "Search taxes…" only) — type into it via the hint text.
    const searchField = page.getByPlaceholder('Search taxes…');
    await searchField.click();
    await page.waitForTimeout(150);
    await page.keyboard.type('TVA Standard', { delay: 30 });
    await page.waitForTimeout(500);
    await shot(page, 'txg-04-member-search-filtered');
    const taxOption = textVisible(page, 'TVA Standard').first();
    const taxFound = await taxOption.isVisible({ timeout: 3000 }).catch(() => false);
    if (!taxFound) throw new Error('"TVA Standard 16%" not found in Add Tax member sheet after search');
    await taxOption.click();
    await page.waitForTimeout(500);
    await shot(page, 'txg-05-member-added');
    pass('Added "TVA Standard 16%" as a group member via the Add Tax sheet');
  } catch (e) { fail('Add tax member', e); await shot(page, 'txg-03-fail'); }

  try {
    const memberVisible = await textVisible(page, 'TVA Standard').isVisible({ timeout: 3000 }).catch(() => false);
    if (!memberVisible) throw new Error('Member row not showing in the group form after adding');
    const saveBtn = page.getByRole('button', { name: 'Save Group', exact: true });
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'txg-06-group-saved');
    pass(`Tax Group "${GROUP_NAME}" (code ${GROUP_CODE}) saved with 1 member`);
  } catch (e) { fail('Save Tax Group', e); await shot(page, 'txg-06-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const groupRow = await dbClient.query(
      `SELECT id, group_code, group_name, applicable_on, is_active
       FROM rim_tax_groups WHERE company_id=$1 AND group_code=$2`,
      [companyId, GROUP_CODE]
    );
    console.log('Tax group in DB:', groupRow.rows);
    if (groupRow.rows.length === 0) throw new Error('Tax group not found in DB');
    pass(`DB: Tax group "${GROUP_NAME}" saved correctly (applicable_on=${groupRow.rows[0].applicable_on})`);

    const memberRows = await dbClient.query(
      `SELECT m.sequence_no, t.tax_code, t.tax_name
       FROM rim_tax_group_members m JOIN rim_taxes t ON t.id = m.tax_id
       WHERE m.tax_group_id=$1 ORDER BY m.sequence_no`,
      [groupRow.rows[0].id]
    );
    console.log('Group members in DB:', memberRows.rows);
    if (memberRows.rows.length !== 1) throw new Error(`Expected exactly 1 member, got ${memberRows.rows.length}`);
    if (!memberRows.rows[0].tax_name.includes('TVA Standard')) throw new Error(`Unexpected member: ${memberRows.rows[0].tax_name}`);
    pass(`DB: Group correctly has exactly 1 member — [${memberRows.rows[0].tax_code}] ${memberRows.rows[0].tax_name}, sequence_no=${memberRows.rows[0].sequence_no}`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: TAX GROUPS RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
