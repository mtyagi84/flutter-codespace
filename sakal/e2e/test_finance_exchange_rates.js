// Phase 1 (Finance Masters) — Exchange Rates. Establishes the "Other"
// (third, foreign) currency used throughout the mandatory multi-currency
// battery for every later phase: Base=USD, Local=CDF (from registration),
// Other=EUR (set up here with a real rate vs USD). Also exercises the
// screen itself (CRUD baseline + downstream usage, per the rubric — Tax
// Master/CRUD-type screens don't apply here since currency IS the whole
// point of this screen).
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const OTHER_CCY = 'EUR';
const BUYING_RATE = '0.92';
const SELLING_RATE = '0.94';
const EXCHANGE_RATE = '0.93';

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

async function clickByTextContent(page, text, { retries = 6 } = {}) {
  for (let attempt = 0; attempt < retries; attempt++) {
    const found = await page.evaluate((t) => {
      const byAttr = document.querySelector(`[aria-label*="${t}"]`);
      if (byAttr) { byAttr.click(); return true; }
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (node.textContent && node.textContent.trim() === t) {
          let el = node.parentElement;
          while (el && el.tagName !== 'FLT-SEMANTICS') el = el.parentElement;
          if (!el) el = node.parentElement;
          el.click();
          return true;
        }
      }
      return false;
    }, text);
    if (found) return true;
    await page.waitForTimeout(800);
  }
  return false;
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    const signInBtn = page.getByRole('button', { name: 'Sign In', exact: true });
    await signInBtn.waitFor({ timeout: 10000 });
    await signInBtn.click();
    await page.waitForTimeout(3000);
    await shot(page, 'exr-00-after-login');
    const stillOnLogin = await page.getByRole('button', { name: 'Sign In', exact: true }).isVisible({ timeout: 3000 }).catch(() => false);
    if (stillOnLogin) throw new Error('Still on login screen — login failed');
    pass('Logged in as fresh-tenant admin');
  } catch (e) { fail('Login', e); await shot(page, 'exr-00-fail'); }

  // ---------- Prerequisite: activate EUR via Currency Setup ----------
  // Exchange Rates only shows ACTIVE currencies (currenciesProvider filters
  // is_active=true) — a fresh tenant only has Base+Local auto-active from
  // registration, confirmed live (the grid showed only CDF, not the 150+
  // global currencies that exist in rim_currencies but inactive). EUR must
  // be switched on here first. The toggle is a blind flip (no explicit
  // on/off state read before clicking) — real bug in THIS test script
  // found live by re-running it: a second run re-toggled an already-active
  // EUR back OFF. Check the real DB state first and only click if it's
  // actually currently inactive, so this step is idempotent across reruns.
  const preCheckClient = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await preCheckClient.connect();
  let eurAlreadyActive = false;
  try {
    const c = await preCheckClient.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
    const comp = await preCheckClient.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [c.rows[0].id]);
    const r = await preCheckClient.query(`SELECT is_active FROM rim_currencies WHERE company_id=$1 AND currency_id=$2`, [comp.rows[0].id, OTHER_CCY]);
    eurAlreadyActive = r.rows[0] && r.rows[0].is_active === true;
    console.log(`EUR currently active in DB: ${eurAlreadyActive}`);
  } catch (e) { console.log('Pre-check EUR active state failed (non-fatal):', e.message); }
  await preCheckClient.end();

  if (eurAlreadyActive) {
    pass('EUR already active (prior run) — skipping toggle, idempotent');
  } else try {
    await page.goto(`${BASE_URL}/#/setup/currencies`);
    await page.waitForTimeout(2000);
    await dismissFirstLoginWelcomeIfPresent(page);
    const searchField = page.getByPlaceholder('Search by code or name…');
    await searchField.waitFor({ state: 'visible', timeout: 8000 });
    await searchField.click();
    await page.waitForTimeout(300);
    await page.keyboard.type(OTHER_CCY, { delay: 40 });
    await page.waitForTimeout(800);
    await shot(page, 'exr-00b-currency-search');

    const eurRow = textVisible(page, OTHER_CCY).first();
    await eurRow.waitFor({ state: 'visible', timeout: 5000 });
    const eurBox = await eurRow.boundingBox();
    const rowCenterY = eurBox.y + eurBox.height / 2;
    const toggled = await page.evaluate((bandY) => {
      const candidates = Array.from(document.querySelectorAll('flt-semantics[role="switch"], flt-semantics[role="checkbox"], flt-semantics[flt-tappable]'));
      let best = null, bestX = -Infinity;
      for (const el of candidates) {
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;
        const cy = r.top + r.height / 2;
        if (Math.abs(cy - bandY) > 20) continue;
        const cx = r.left + r.width / 2;
        if (cx > bestX) { bestX = cx; best = el; }
      }
      if (!best) return false;
      best.click();
      return true;
    }, rowCenterY);
    if (!toggled) throw new Error('Could not find the EUR row\'s active-toggle switch');
    await page.waitForTimeout(1000);
    await shot(page, 'exr-00c-eur-activated');
    pass(`Activated ${OTHER_CCY} via Currency Setup`);
  } catch (e) { fail('Activate EUR currency', e); await shot(page, 'exr-00b-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/finance/exchange-rates`);
    await page.waitForTimeout(2000);
    await dismissFirstLoginWelcomeIfPresent(page);
    await shot(page, 'exr-01-loaded');
    const headerVisible = await textVisible(page, 'Buying Rate').waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    if (!headerVisible) throw new Error('Exchange Rates grid did not load (no "Buying Rate" column header found)');
    pass('Exchange Rates screen loaded, grid visible');
  } catch (e) { fail('Open Exchange Rates screen', e); await shot(page, 'exr-01-fail'); }

  try {
    // Only ACTIVE currencies render here (just activated EUR above), so
    // the grid is short — no scrolling needed. Flutter Web sometimes
    // splits a tile's "EUR" / "Euro" lines into separate text nodes within
    // one semantics group (same quirk seen elsewhere in this app), so use
    // the generic aria-label-or-text helper rather than an exact regex.
    await dismissFirstLoginWelcomeIfPresent(page);
    let eurBox = await textVisible(page, OTHER_CCY).boundingBox().catch(() => null);
    if (!eurBox) {
      // Same semantics-mode inconsistency seen elsewhere in this app —
      // aria-label vs real DOM text varies by prior navigation, not
      // predictably. Fall back to a raw textContent scan + bounding rect.
      const rect = await page.evaluate((code) => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          if (node.textContent && node.textContent.trim() === code) {
            const el = node.parentElement;
            const r = el.getBoundingClientRect();
            return { x: r.x, y: r.y, width: r.width, height: r.height };
          }
        }
        return null;
      }, OTHER_CCY);
      if (rect) eurBox = rect;
    }
    if (!eurBox) {
      const allLabels = await page.evaluate(() => Array.from(document.querySelectorAll('[aria-label]')).map(el => el.getAttribute('aria-label')));
      console.log('DEBUG all aria-labels on Exchange Rates page:', JSON.stringify(allLabels));
    }
    if (!eurBox) throw new Error(`Could not get a bounding box for the ${OTHER_CCY} row`);
    const rowCenterY = eurBox.y + eurBox.height / 2;
    console.log(`Found ${OTHER_CCY} row at y=${rowCenterY}`);

    // Find the 3 REAL <input> elements in this row's Y-band directly,
    // sorted left-to-right — more robust than guessing column-center
    // coordinates from flex ratios (a decorative text-selection overlay
    // div sat exactly at the computed Buying-column x, found live: that
    // click landed on a DIV, not the input, leaving Buying empty while
    // Selling/Exchange — whose computed x happened to clear the overlay —
    // worked fine).
    const inputXs = await page.evaluate((bandY) => {
      const inputs = Array.from(document.querySelectorAll('input'));
      const matches = [];
      for (const el of inputs) {
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;
        const cy = r.top + r.height / 2;
        if (Math.abs(cy - bandY) > 20) continue;
        matches.push(r.left + r.width / 2);
      }
      return matches.sort((a, b) => a - b);
    }, rowCenterY);
    console.log(`Found ${inputXs.length} real <input> elements in the EUR row's Y-band:`, inputXs);
    if (inputXs.length !== 3) throw new Error(`Expected exactly 3 input fields (Buying/Selling/Exchange) in the EUR row, found ${inputXs.length}`);

    const [buyingX, sellingX, exchangeX] = inputXs;
    await page.mouse.click(buyingX, rowCenterY);
    await page.waitForTimeout(300);
    await page.keyboard.type(BUYING_RATE, { delay: 40 });
    await page.mouse.click(sellingX, rowCenterY);
    await page.waitForTimeout(300);
    await page.keyboard.type(SELLING_RATE, { delay: 40 });
    await page.mouse.click(exchangeX, rowCenterY);
    await page.waitForTimeout(300);
    await page.keyboard.type(EXCHANGE_RATE, { delay: 40 });
    await shot(page, 'exr-02-rates-typed');
    pass(`Typed Buying=${BUYING_RATE} Selling=${SELLING_RATE} Exchange=${EXCHANGE_RATE} for ${OTHER_CCY}`);
  } catch (e) { fail('Fill EUR exchange rate row', e); await shot(page, 'exr-02-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Rates', exact: true }).last();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'exr-03-after-save');
    const savedMsg = await textVisible(page, 'Exchange rates saved').isVisible({ timeout: 5000 }).catch(() => false);
    if (!savedMsg) throw new Error('"Exchange rates saved" confirmation not shown');
    pass('Exchange rates saved successfully');
  } catch (e) { fail('Save exchange rates', e); await shot(page, 'exr-03-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  const client = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await client.connect();
  try {
    const c = await client.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
    const clientId = c.rows[0].id;
    const comp = await client.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [clientId]);
    const companyId = comp.rows[0].id;
    const r = await client.query(
      `SELECT from_currency, to_currency, buying_rate, selling_rate, exchange_rate, rate_date
       FROM rim_exchange_rates WHERE client_id=$1 AND company_id=$2 AND to_currency=$3 ORDER BY rate_date DESC LIMIT 1`,
      [clientId, companyId, OTHER_CCY]
    );
    console.log('DB exchange rate row:', r.rows);
    if (r.rows.length === 0) throw new Error('No exchange rate row found in DB for EUR');
    const row = r.rows[0];
    if (row.from_currency !== 'USD') throw new Error(`from_currency ${row.from_currency} != USD (base)`);
    if (Math.abs(Number(row.buying_rate) - Number(BUYING_RATE)) > 0.001) throw new Error(`buying_rate ${row.buying_rate} != ${BUYING_RATE}`);
    if (Math.abs(Number(row.selling_rate) - Number(SELLING_RATE)) > 0.001) throw new Error(`selling_rate ${row.selling_rate} != ${SELLING_RATE}`);
    if (Math.abs(Number(row.exchange_rate) - Number(EXCHANGE_RATE)) > 0.001) throw new Error(`exchange_rate ${row.exchange_rate} != ${EXCHANGE_RATE}`);
    pass(`DB: USD->EUR rate correctly saved (buying=${row.buying_rate}, selling=${row.selling_rate}, exchange=${row.exchange_rate})`);
  } catch (e) { fail('DB verification', e); }
  await client.end();

  console.log('\n===== PHASE 1: EXCHANGE RATES RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
