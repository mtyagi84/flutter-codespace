// Phase 1 (Finance Masters) — Account Link Setup. ALS-01 (new-tenant
// auto-wired links) is confirmed by direct DB check before this script
// even runs (STOCK_ACCOUNT/COST_OF_SALES_ACCOUNT/SALES_ACCOUNT/
// PURCHASE_ACCRUAL_ACCOUNT all present at COMPANY granularity — see
// PHASE_EXECUTION_LOG.md). This script covers ALS-04 — configuring a
// currently-UNCONFIGURED link type (STOCK_ADJUSTMENT_ACCOUNT) at COMPANY
// granularity for the first time, proving the generic account-link
// framework genuinely works end-to-end through the UI, not just the
// starter-kit's own seed data. Currency/GL/Stock/Chain don't apply
// directly to this screen — it's a pure configuration surface.
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
  const page = await (await browser.newContext({ viewport: { width: 1366, height: 900 } })).newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  const dbClient = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await dbClient.connect();
  const cRes = await dbClient.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
  const compRes = await dbClient.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [cRes.rows[0].id]);
  const companyId = compRes.rows[0].id;

  // ---------- Pre-check: ALS-01 (confirmed via direct DB, not UI) ----------
  try {
    const seeded = await dbClient.query(
      `SELECT lt.link_key, a.account_code FROM rim_account_link_defaults d
       JOIN rim_account_link_types lt ON lt.id = d.link_type_id
       JOIN rim_accounts a ON a.id = d.account_id
       WHERE d.company_id=$1 AND d.is_deleted=false
       AND lt.link_key IN ('STOCK_ACCOUNT','COST_OF_SALES_ACCOUNT','SALES_ACCOUNT','PURCHASE_ACCRUAL_ACCOUNT')`,
      [companyId]
    );
    console.log('ALS-01 seeded links:', JSON.stringify(seeded.rows));
    if (seeded.rows.length !== 4) throw new Error(`Expected 4 core auto-wired links, found ${seeded.rows.length}`);
    pass('ALS-01: all 4 core account links (Stock/COGS/Sales/Purchase Accrual) auto-wired for this fresh tenant');
  } catch (e) { fail('ALS-01 pre-check', e); }

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'als-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/account-link-setup`);
    await textVisible(page, 'Stock Adjustment Account').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'als-01-loaded');
    pass('Account Link Setup screen loaded, link types list visible');
  } catch (e) { fail('Open Account Link Setup', e); await shot(page, 'als-01-fail'); }

  try {
    const rowText = textVisible(page, 'Stock Adjustment Account').first();
    const box = await rowText.boundingBox();
    if (!box) throw new Error('Could not get bounding box for "Stock Adjustment Account" row');
    // The "Configure" button sits in the row's far-right column (flex:1 of
    // a 3+2+2+1 flex row spanning the full ~1140px content width starting
    // at x≈24) — click near the right edge, same y as the row's own text.
    await page.mouse.click(1300, box.y + box.height / 2);
    // The configure screen fetches its own accounts provider on open — wait
    // for the real content (the "Company-wide" granularity segment), not
    // just the header title which renders immediately while data loads.
    await textVisible(page, 'Company-wide').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'als-02-configure-opened');
    pass('Configure screen opened for "Stock Adjustment Account", granularity segments loaded');
  } catch (e) { fail('Open Configure for Stock Adjustment Account', e); await shot(page, 'als-02-fail'); }

  try {
    // No level is pre-selected for a never-configured link type (confirmed
    // via screenshot: "Pick a level above to start assigning accounts.") —
    // explicitly click "Company-wide" first. A semantics-based getByText
    // click didn't register (same overlay-vs-semantics gap seen elsewhere
    // in this app) — click the segment by its known screen position
    // instead (confirmed via screenshot: ~x=482, y=149).
    await page.mouse.click(482, 149);
    // The Account field appears right after selecting the level, confirmed
    // via screenshot (~y=248) — but isn't reliably getByLabel-locatable
    // (same semantics-tree-lag class of gap seen elsewhere), so click its
    // known position directly rather than polling for it.
    await page.waitForTimeout(1000);
    await shot(page, 'als-02b-company-level-selected');
    await page.mouse.click(620, 248);
    await page.waitForTimeout(150);
    // Search for "5800" (Internal Transfers) — a real POSTING leaf
    // (posting_allowed=true), unlike its own parent group "5000"/"6500"
    // which are correctly excluded from this picker (confirmed via
    // screenshot: searching "6500" only surfaced a leaf CHILD of that
    // group, never the group itself — the picker is correctly filtering
    // to postable accounts only, a real positive finding, not a bug).
    await page.keyboard.type('5800', { delay: 30 });
    await page.waitForTimeout(600);
    await shot(page, 'als-03-account-search');
    const optionVisible = await textVisible(page, 'Internal Transfers').isVisible({ timeout: 3000 }).catch(() => false);
    if (!optionVisible) throw new Error('"5800 Internal Transfers" option not found in account picker');
    await textVisible(page, 'Internal Transfers').first().click();
    await page.waitForTimeout(1000);
    await shot(page, 'als-04-account-picked');
    pass('Picked "5800 Internal Transfers" as the company-wide Stock Adjustment Account');
  } catch (e) { fail('Pick account for Stock Adjustment Account link', e); await shot(page, 'als-03-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT a.account_code, a.account_name
       FROM rim_account_link_defaults d
       JOIN rim_account_link_types lt ON lt.id = d.link_type_id
       JOIN rim_accounts a ON a.id = d.account_id
       WHERE d.company_id=$1 AND lt.link_key='STOCK_ADJUSTMENT_ACCOUNT' AND d.is_deleted=false`,
      [companyId]
    );
    console.log('Stock Adjustment Account link in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('STOCK_ADJUSTMENT_ACCOUNT link not found in DB after configuring via UI');
    if (row.rows[0].account_code !== '5800') throw new Error(`Expected account_code 5800, got ${row.rows[0].account_code}`);
    pass(`DB: STOCK_ADJUSTMENT_ACCOUNT correctly wired to [${row.rows[0].account_code}] ${row.rows[0].account_name} at COMPANY granularity`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: ACCOUNT LINK SETUP RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
