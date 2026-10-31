// Phase 0 — Test Environment. Registers a brand-new, dedicated tenant
// through the REAL registration wizard (not SQL-seeded), doubling as a
// live re-confirmation of the Registration flow itself (last touched
// 2026-10-15/16). Country=DRC, Base=USD, Local(reporting)=CDF — matches
// CLAUDE.md's own realistic example and should auto-suggest the OHADA
// accounting standard via the wizard's own local-currency-driven
// auto-suggest logic. Captures the resulting Client No + admin
// credentials into e2e/.test_tenant.json for every later phase's scripts
// to reuse (gitignored — contains only test-tenant, not real, data).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
require('./helpers/env');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-6);
const BUSINESS_NAME = `Kivu Trading QA ${STAMP}`;
const COMPANY_NAME = `Kivu Trading QA ${STAMP}`;
const COMPANY_SHORT = `KIVU${STAMP}`.slice(0, 8);
const LOCATION_NAME = 'Main Store';
const LOCATION_SHORT = 'MAIN';
const CONTACT_NAME = 'QA Admin';
const CONTACT_EMAIL = `qa.contact.${STAMP}@example.com`;
const PHONE = '812345678'; // 9 digits for DRC
const ADMIN_NAME = 'QA Administrator';
const ADMIN_EMAIL = `qa.admin.${STAMP}@example.com`;
const ADMIN_USERNAME = `qaadmin${STAMP}`;
// Deliberately NO symbols — real gotcha found live 2026-10-24:
// page.keyboard.type() mis-typed '@' in a password field (Chromium
// keyboard-layout quirk with shifted characters), producing a password
// that visually looked correct (matching dot count in both Password/
// Confirm fields) but didn't match on login. The backend's own min-length
// (6 chars) has no symbol requirement, so plain alphanumeric avoids this
// class of bug entirely for any future registration script.
const ADMIN_PASSWORD = 'QaTest12345';

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));
  page.on('console', msg => { if (msg.type() === 'error') console.log('CONSOLE_ERROR:', msg.text()); });

  try {
    await page.goto(`${BASE_URL}/#/register`);
    await enableSemantics(page);
    await textVisible(page, 'Register Your Business').waitFor({ state: 'visible', timeout: 15000 });
    pass('Registration wizard opened');
  } catch (e) { fail('Open registration wizard', e); await shot(page, 'reg-00-fail'); }

  // ---------- Step 0: About Your Business ----------
  try {
    await typeInto(page, 'Business / Trading Company Name', BUSINESS_NAME);
    await page.getByRole('button', { name: 'Country', exact: false }).click();
    await page.waitForTimeout(500);
    const drcOption = page.getByRole('menuitem', { name: /Democratic Republic of Congo/i }).first()
      .or(page.getByText('Democratic Republic of Congo', { exact: true }).first());
    await drcOption.click();
    await page.waitForTimeout(300);
    await typeInto(page, 'Contact Person Name', CONTACT_NAME);
    await typeInto(page, 'Email Address', CONTACT_EMAIL);
    await typeInto(page, 'Phone Number', PHONE);
    await shot(page, 'reg-01-step0-filled');
    const continueBtn = page.getByRole('button', { name: 'Continue', exact: true });
    await continueBtn.click();
    await page.waitForTimeout(1000);
    pass('Step 0 (About Your Business) filled and submitted');
  } catch (e) { fail('Step 0: About Your Business', e); await shot(page, 'reg-01-fail'); }

  // ---------- Step 1: Company Details ----------
  try {
    await textVisible(page, 'Company Details').waitFor({ state: 'visible', timeout: 8000 });
    await typeInto(page, 'Company Name', COMPANY_NAME);
    await typeInto(page, 'Short Name (max 8 chars)', COMPANY_SHORT);
    // Base Currency -> USD, Other (local/reporting) Currency -> CDF.
    const baseCcyDropdown = page.getByRole('button', { name: /Base Currency/i });
    await baseCcyDropdown.click();
    await page.waitForTimeout(400);
    await page.getByRole('menuitem', { name: 'USD', exact: true }).first().click();
    await page.waitForTimeout(300);
    const localCcyDropdown = page.getByRole('button', { name: /Other Currency You Want to See Reports In/i });
    await localCcyDropdown.click();
    await page.waitForTimeout(400);
    await page.getByRole('menuitem', { name: 'CDF', exact: true }).first().click();
    await page.waitForTimeout(300);
    await shot(page, 'reg-02-step1-filled');
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await page.waitForTimeout(1000);
    pass('Step 1 (Company Details) filled: Base=USD, Local/Reporting=CDF');
  } catch (e) { fail('Step 1: Company Details', e); await shot(page, 'reg-02-fail'); }

  // ---------- Step 2: Your First Location ----------
  try {
    await textVisible(page, 'Your First Location').waitFor({ state: 'visible', timeout: 8000 });
    await typeInto(page, 'Location Name (e.g. Main Store)', LOCATION_NAME);
    await typeInto(page, 'Short Name (max 8 chars)', LOCATION_SHORT);
    await shot(page, 'reg-03-step2-filled');
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await page.waitForTimeout(1000);
    pass('Step 2 (First Location) filled');
  } catch (e) { fail('Step 2: First Location', e); await shot(page, 'reg-03-fail'); }

  // ---------- Step 3: Accounting Setup ----------
  let accountingStdShown = null;
  try {
    await textVisible(page, 'Accounting Setup').waitFor({ state: 'visible', timeout: 8000 });
    const ohadaVisible = await textVisible(page, 'OHADA').isVisible({ timeout: 3000 }).catch(() => false);
    accountingStdShown = ohadaVisible ? 'OHADA' : 'unknown (not auto-suggested to OHADA)';
    await shot(page, 'reg-04-step3-accounting');
    console.log(`Accounting standard step shows: ${accountingStdShown}`);
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await page.waitForTimeout(1000);
    pass(`Step 3 (Accounting Setup) — ${accountingStdShown}`);
  } catch (e) { fail('Step 3: Accounting Setup', e); await shot(page, 'reg-04-fail'); }

  // ---------- Step 4: Administrator Account ----------
  try {
    await textVisible(page, 'Administrator Account').waitFor({ state: 'visible', timeout: 8000 });
    await typeInto(page, 'Full Name', ADMIN_NAME);
    await typeInto(page, 'Email Address', ADMIN_EMAIL);
    await typeInto(page, 'Username', ADMIN_USERNAME);
    const pwFields = page.getByRole('textbox', { name: /Password/i });
    const pwCount = await pwFields.count();
    await pwFields.nth(0).click();
    await page.keyboard.type(ADMIN_PASSWORD, { delay: 20 });
    if (pwCount > 1) {
      await pwFields.nth(1).click();
      await page.keyboard.type(ADMIN_PASSWORD, { delay: 20 });
    }
    await shot(page, 'reg-05-step4-filled');
    await page.getByRole('button', { name: 'Complete Registration', exact: true }).click();
    await page.waitForTimeout(3000);
    pass('Step 4 (Administrator Account) filled and submitted');
  } catch (e) { fail('Step 4: Administrator Account', e); await shot(page, 'reg-05-fail'); }

  // ---------- Success screen: capture Client No ----------
  let clientNo = null;
  try {
    const successVisible = await textVisible(page, 'Your Client ID').waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    await shot(page, 'reg-06-success');
    if (!successVisible) throw new Error('Did not reach the success screen with "Your Client ID"');
    // The client no is rendered as its own prominent text right after the
    // "Your Client ID" label — scan all text nodes for the SK-##### shape.
    const texts = await page.evaluate(() => {
      const out = [];
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) { if (node.textContent) out.push(node.textContent.trim()); }
      const all = Array.from(document.querySelectorAll('[aria-label]')).map(el => el.getAttribute('aria-label'));
      return out.concat(all);
    });
    const match = texts.find(t => /^SK-\d{4,}$/.test(t)) || texts.map(t => (t.match(/SK-\d{4,}/) || [])[0]).find(Boolean);
    if (!match) throw new Error(`Could not find a Client ID (SK-#####) pattern on the success screen. Texts seen: ${JSON.stringify(texts.filter(t => t && t.length < 40))}`);
    clientNo = match;
    console.log(`Captured Client No: ${clientNo}`);
    pass(`Registration completed — Client No ${clientNo}`);
  } catch (e) { fail('Success screen: capture Client No', e); await shot(page, 'reg-06-fail'); }

  await browser.close();

  if (clientNo) {
    const tenantInfo = {
      clientNo, businessName: BUSINESS_NAME, companyName: COMPANY_NAME,
      locationName: LOCATION_NAME, baseCurrency: 'USD', localCurrency: 'CDF',
      accountingStandard: accountingStdShown,
      adminName: ADMIN_NAME, adminEmail: ADMIN_EMAIL, adminUsername: ADMIN_USERNAME,
      adminPassword: ADMIN_PASSWORD, registeredAt: new Date().toISOString(),
    };
    fs.writeFileSync(path.join(__dirname, '.test_tenant.json'), JSON.stringify(tenantInfo, null, 2));
    console.log('\nSaved tenant info to e2e/.test_tenant.json for reuse by later phase scripts.');
  }

  console.log('\n===== PHASE 0: REGISTER FRESH TENANT RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
