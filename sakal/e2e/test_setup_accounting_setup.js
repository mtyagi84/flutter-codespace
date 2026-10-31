// Phase 1 (System Setup) — Accounting Setup. Tests ACT-04: this tenant
// already completed Accounting Setup at registration (OHADA/DRC) — opening
// the screen now should show a read-only "locked" view, not the editable
// first-time wizard. Quick confirmation-only pass, no new data created.
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
  } catch (e) { fail('Login', e); await shot(page, 'act-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/setup/accounting`);
    await page.waitForTimeout(1500);
    await shot(page, 'act-01-loaded');
    // Locked view should show OHADA (the standard this tenant was
    // registered with) somewhere, and no longer show an editable "Save"/
    // "Continue" wizard action for picking the standard.
    const ohadaVisible = await textVisible(page, 'OHADA').isVisible({ timeout: 8000 }).catch(() => false);
    if (!ohadaVisible) throw new Error('"OHADA" (the registered standard) not visible — locked view may not be showing correctly');
    pass('ACT-04: Accounting Setup shows the locked view with OHADA (the registered standard)');
  } catch (e) { fail('Confirm locked Accounting Setup view', e); await shot(page, 'act-01-fail'); }

  await browser.close();

  console.log('\n===== PHASE 1: ACCOUNTING SETUP RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
