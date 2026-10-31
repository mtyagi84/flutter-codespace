// Phase 1 (System Setup) — Divisions. Tests GEO-02: confirm Zambia's
// system-seeded provinces/divisions load correctly after activating
// Zambia (done in test_setup_countries.js). This is a passive-
// verification test (global is_system=true rim_divisions data), not a
// create test.
const { chromium } = require('playwright');
require('./helpers/env');
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

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'div-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/divisions`);
    await textVisible(page, 'Country').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(800);
    await shot(page, 'div-01-loaded');
    pass('Divisions screen loaded');
  } catch (e) { fail('Open Divisions', e); await shot(page, 'div-01-fail'); }

  try {
    // Country filter dropdown — click at its known centered position
    // (confirmed via screenshot: ~x=803, y=98), search "Zambia", pick it.
    await page.mouse.click(803, 98);
    await page.waitForTimeout(150);
    await page.keyboard.type('Zambia', { delay: 30 });
    await page.waitForTimeout(600);
    await shot(page, 'div-02-country-search');
    const option = textVisible(page, 'Zambia').first();
    const found = await option.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error('"Zambia" option not found in Country filter');
    await option.click();
    await page.waitForTimeout(800);
    await shot(page, 'div-03-zambia-selected');
    pass('Country filter set to Zambia');
  } catch (e) { fail('Filter by Zambia', e); await shot(page, 'div-02-fail'); }

  try {
    // Zambia's provinces include e.g. "Lusaka", "Copperbelt" — confirm at
    // least one well-known province renders.
    const provinceVisible = await textVisible(page, 'Lusaka').isVisible({ timeout: 5000 }).catch(() => false)
      || await textVisible(page, 'Copperbelt').isVisible({ timeout: 2000 }).catch(() => false);
    if (!provinceVisible) throw new Error('No expected Zambia province (Lusaka/Copperbelt) found in the list');
    await shot(page, 'div-04-provinces-visible');
    pass('GEO-02: Zambia\'s system-seeded provinces load correctly (Lusaka/Copperbelt found)');
  } catch (e) { fail('Confirm Zambia provinces load', e); await shot(page, 'div-04-fail'); }

  await browser.close();

  console.log('\n===== PHASE 1: DIVISIONS RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
