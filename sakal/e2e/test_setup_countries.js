// Phase 1 (System Setup) — Country Setup. Tests GEO-01: activate Zambia
// (currently inactive on this DRC-registered tenant). Same search+toggle
// pattern already proven on Currency Setup — checks current DB state
// first to stay idempotent across reruns (same lesson as Currency's own
// CUR-03 finding).
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

  const before = await dbClient.query(
    `SELECT is_active FROM rim_countries WHERE company_id=$1 AND country_name='Zambia'`,
    [companyId]
  );
  const alreadyActive = before.rows.length > 0 && before.rows[0].is_active === true;
  console.log('Zambia currently active:', alreadyActive);

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
  } catch (e) { fail('Login', e); await shot(page, 'geo-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/countries`);
    await textVisible(page, 'countries').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(800);
    // Search field at a known position (confirmed via screenshot: ~x=748,
    // y=108) — getByPlaceholder timed out despite the field clearly
    // rendering, same overlay-timing class of gap seen elsewhere.
    await page.mouse.click(748, 108);
    await page.waitForTimeout(150);
    await page.keyboard.type('Zambia', { delay: 30 });
    await page.waitForTimeout(600);
    await shot(page, 'geo-01-search');
    pass('Countries screen loaded, search filtered to "Zambia"');
  } catch (e) { fail('Open Countries / search', e); await shot(page, 'geo-01-fail'); }

  if (alreadyActive) {
    pass('GEO-01: Zambia already active from a prior run — skipping toggle to stay idempotent (same lesson as Currency Setup CUR-03)');
  } else {
    try {
      // Toggle at a known position (confirmed via screenshot: Zambia is
      // the only filtered row, toggle at ~x=981, y=282).
      await page.mouse.click(981, 282);
      await page.waitForTimeout(800);
      await shot(page, 'geo-02-toggled');
      pass('Zambia activation toggle clicked');
    } catch (e) { fail('Toggle Zambia active', e); await shot(page, 'geo-02-fail'); }
  }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT is_active FROM rim_countries WHERE company_id=$1 AND country_name='Zambia'`,
      [companyId]
    );
    console.log('Zambia row in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('Zambia country row not found in DB');
    if (row.rows[0].is_active !== true) throw new Error(`is_active=${row.rows[0].is_active}, expected true`);
    pass('DB: Zambia correctly active');
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: COUNTRY SETUP RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
