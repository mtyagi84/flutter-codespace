// Price Check E2E test — real browser interaction + DB verification that
// the displayed price/stock figures are actually correct, not just that
// the screen opens and shows something.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';
const PRODUCT_CODE = 'PRD-POS-003';
const PRODUCT_NAME = 'Toor Dal 1kg';

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const COMPANY_ID = 'e73b9365-68d4-4f56-9398-0e683560e9cc';
const LOCATION_ID = 'e55f8e79-bf0f-464a-a6bf-b8db7f4f9556';
const PG_CONN = process.env.SAKAL_DEV_DB_URL;

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

  try {
    await page.goto(`${BASE_URL}/#/pos/device-setup`);
    await enableSemantics(page);
    const signInBtn = page.getByRole('button', { name: 'Sign in as Administrator' });
    if (await signInBtn.isVisible({ timeout: 10000 }).catch(() => false)) {
      await signInBtn.click();
      await textVisible(page, 'Administrator Sign-In').waitFor({ timeout: 10000 });
      const clientIdLink = page.getByText('Sign in with Client ID instead');
      if (await clientIdLink.isVisible({ timeout: 3000 }).catch(() => false)) { await clientIdLink.click(); await page.waitForTimeout(300); }
      await typeInto(page, 'Client No.', CLIENT_NO);
      await typeInto(page, 'Username', USERNAME);
      await typeInto(page, 'Password', PASSWORD);
      await page.getByRole('button', { name: 'Continue' }).click();
      await textVisible(page, 'Assign This Device').waitFor({ timeout: 15000 });
      await page.getByRole('button', { name: 'Store / Location', exact: false }).click();
      await page.getByRole('menuitem').first().click();
      await page.waitForTimeout(1200);
      const tillField = page.getByRole('button', { name: 'Till', exact: true });
      await tillField.waitFor({ timeout: 10000 });
      await tillField.click();
      await page.getByRole('menuitem').first().click();
      await page.getByRole('button', { name: 'Assign & Finish Setup' }).click();
    }
    await textVisible(page, 'Enter your PIN').waitFor({ timeout: 15000 });
    for (const digit of PIN) { await page.getByRole('button', { name: digit, exact: true }).click(); }
    await page.getByRole('button', { name: 'Enter' }).click();
    await page.waitForTimeout(1500);
    pass('Till Setup + PIN Login');
  } catch (e) { fail('Till Setup + PIN Login', e); await shot(page, 'pc-00-login-fail'); }

  // Query the real, current price/stock right before the on-screen lookup,
  // so there is no race against other tests concurrently changing stock.
  const client = new Client({ connectionString: PG_CONN, ssl: { rejectUnauthorized: false } });
  await client.connect();
  let expectedStock = null, expectedPrice = null;
  try {
    const prod = await client.query(`SELECT id, base_uom_id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code=$3`, [CLIENT_ID, COMPANY_ID, PRODUCT_CODE]);
    const pid = prod.rows[0].id;
    const loc = await client.query(`SELECT current_stock FROM rim_product_location WHERE client_id=$1 AND company_id=$2 AND location_id=$3 AND product_id=$4`, [CLIENT_ID, COMPANY_ID, LOCATION_ID, pid]);
    expectedStock = Math.round(Number(loc.rows[0].current_stock));
    const priceRes = await client.query(`SELECT fn_get_active_price($1,$2,$3,$4,$5,NULL,CURRENT_DATE,'INR') AS r`, [CLIENT_ID, COMPANY_ID, LOCATION_ID, pid, prod.rows[0].base_uom_id]);
    // fn_get_active_price returns a composite row as a string "(selling_price,native_selling_price,...)"
    const raw = priceRes.rows[0].r;
    expectedPrice = parseFloat(String(raw).replace(/^\(/, '').split(',')[0]);
    console.log(`DB ground truth for ${PRODUCT_CODE}: price=${expectedPrice}, stock=${expectedStock}`);
    pass('Fetched DB ground-truth price/stock for comparison');
  } catch (e) { fail('Fetch DB ground truth', e); }

  try {
    await page.goto(`${BASE_URL}/#/pos/price-check`);
    await page.waitForTimeout(1200);
    const searchField = page.getByRole('textbox').first();
    await searchField.click();
    await page.waitForTimeout(300);
    await page.keyboard.type(PRODUCT_CODE, { delay: 40 });
    await page.keyboard.press('Enter');
    const nameVisible = await textVisible(page, PRODUCT_NAME).waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    const skuVisible = await textVisible(page, `SKU ${PRODUCT_CODE}`).waitFor({ state: 'visible', timeout: 5000 }).then(() => true).catch(() => false);
    await shot(page, 'pc-01-result');
    if (!nameVisible || !skuVisible) throw new Error(`Result card did not show expected product (name visible=${nameVisible}, SKU visible=${skuVisible})`);
    pass('Price Check: correct product resolved from code lookup');
  } catch (e) { fail('Price Check: product lookup', e); await shot(page, 'pc-01-fail'); }

  try {
    const priceText = `${expectedPrice.toFixed(2)} INR`;
    const priceVisible = await textVisible(page, priceText).waitFor({ state: 'visible', timeout: 6000 }).then(() => true).catch(() => false);
    if (!priceVisible) throw new Error(`Displayed price did not match DB ground truth "${priceText}"`);
    pass(`Price Check: displayed price "${priceText}" matches DB ground truth exactly`);
  } catch (e) { fail('Price Check: price correctness', e); await shot(page, 'pc-02-fail'); }

  try {
    const stockText = `Stock on hand: ${expectedStock}`;
    const stockVisible = await textVisible(page, stockText).waitFor({ state: 'visible', timeout: 6000 }).then(() => true).catch(() => false);
    if (!stockVisible) throw new Error(`Displayed stock did not match DB ground truth "${stockText}"`);
    pass(`Price Check: displayed stock "${stockText}" matches DB ground truth exactly`);
  } catch (e) { fail('Price Check: stock correctness', e); await shot(page, 'pc-03-fail'); }

  try {
    // ---------- Name/fallback search path (not just exact code) ----------
    const searchField = page.getByRole('textbox').first();
    await searchField.click();
    await page.keyboard.press('Control+A');
    await page.keyboard.type('Toor', { delay: 40 });
    await page.keyboard.press('Enter');
    const found = await textVisible(page, PRODUCT_NAME).waitFor({ state: 'visible', timeout: 8000 }).then(() => true).catch(() => false);
    if (!found) throw new Error('Partial-name search "Toor" did not resolve to Toor Dal 1kg');
    pass('Price Check: partial-name fallback search also resolves correctly');
  } catch (e) { fail('Price Check: partial-name search', e); await shot(page, 'pc-04-fail'); }

  try {
    // ---------- Unknown code -> clear "not found" message ----------
    const searchField = page.getByRole('textbox').first();
    await searchField.click();
    await page.keyboard.press('Control+A');
    await page.keyboard.type('ZZZ-NONEXISTENT-999', { delay: 30 });
    await page.keyboard.press('Enter');
    const notFoundMsg = await textVisible(page, 'No product found').waitFor({ state: 'visible', timeout: 8000 }).then(() => true).catch(() => false);
    await shot(page, 'pc-05-not-found');
    if (!notFoundMsg) throw new Error('No "No product found" message shown for an unknown code');
    pass('Price Check: unknown code shows a clear "No product found" message');
  } catch (e) { fail('Price Check: unknown code handling', e); await shot(page, 'pc-05-fail'); }

  await client.end();
  await browser.close();

  console.log('\n===== PRICE CHECK E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
