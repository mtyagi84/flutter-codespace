// Phase 1 prerequisite — creates a "Department" and a "Consumption Area"
// common-master value via Common Masters, needed before Consumption Area
// Setup (IN-DCA) can be tested at all (both lookups are empty on a fresh
// tenant). Not itself a rubric-scored test case; a setup step for DCA-01.
const { chromium } = require('playwright');
require('./helpers/env');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const DEPT_NAME = `QA Admin Dept ${STAMP}`;
const AREA_NAME = `QA Office Supplies Consumption ${STAMP}`;

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

async function addMasterValue(page, typeName, valueName) {
  await page.goto(`${BASE_URL}/#/master/common-masters`);
  await textVisible(page, 'Master Type').waitFor({ state: 'visible', timeout: 10000 });
  await page.waitForTimeout(800);
  // Type selector is a SakalAutocomplete — click it, select-all (it
  // defaults to "Brand", pre-filled, not empty), type the type name, pick
  // the option. Confirmed via screenshot: field at ~x=365, y=88.
  await page.mouse.click(365, 88);
  await page.waitForTimeout(200);
  await page.keyboard.press('Control+A');
  await page.keyboard.type(typeName, { delay: 30 });
  await page.waitForTimeout(600);
  await shot(page, `cm-type-search-${typeName.replace(/\s/g, '')}`);
  const opt = textVisible(page, typeName).first();
  const found = await opt.isVisible({ timeout: 3000 }).catch(() => false);
  if (!found) throw new Error(`Master Type "${typeName}" not found in dropdown`);
  await opt.click();
  await page.waitForTimeout(800);
  const addBtn = page.getByRole('button', { name: /^Add /i }).first();
  await addBtn.click();
  await page.waitForTimeout(600);
  await shot(page, `cm-add-row-${typeName.replace(/\s/g, '')}`);
  const descField = page.getByLabel('Description *', { exact: true }).first();
  await descField.click();
  await page.waitForTimeout(150);
  await page.keyboard.type(valueName, { delay: 30 });
  await page.waitForTimeout(300);
  const saveBtn = page.getByRole('button', { name: 'Save', exact: true }).first();
  await saveBtn.click();
  await page.waitForTimeout(1200);
  await shot(page, `cm-saved-${typeName.replace(/\s/g, '')}`);
}

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
  } catch (e) { fail('Login', e); }

  try {
    await addMasterValue(page, 'Department', DEPT_NAME);
    pass(`Department "${DEPT_NAME}" created`);
  } catch (e) { fail('Create Department', e); await shot(page, 'cm-dept-fail'); }

  try {
    await addMasterValue(page, 'Consumption Area', AREA_NAME);
    pass(`Consumption Area "${AREA_NAME}" created`);
  } catch (e) { fail('Create Consumption Area', e); await shot(page, 'cm-area-fail'); }

  await browser.close();
  console.log(`\nDEPT_NAME=${DEPT_NAME}`);
  console.log(`AREA_NAME=${AREA_NAME}`);
  console.log('\n===== PREREQUISITE SETUP RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
