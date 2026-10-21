// Weighted-barcode scanning E2E test. Company configured with
// weighted_barcode_prefix_from/to='20'/'29', format=WEIGHT_EMBEDDED
// (setup_weighted_barcode.js). Product code '00099' priced 80/kg, 50kg in
// stock. Test barcode '2000099005000' = prefix 20 + itemCode 00099 +
// weight 00500 (grams) = 0.5kg + check digit. Expected: scanning it adds
// the product with qty 0.5 and amount 40.00 (80 * 0.5), using the active
// price lookup for rate (not an embedded price, since this company uses
// WEIGHT_EMBEDDED not PRICE_EMBEDDED).
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';
const WEIGHTED_BARCODE = '2000099005000';
const PRODUCT_CODE = '00099';

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
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
  } catch (e) { fail('Till Setup + PIN Login', e); await shot(page, 'wb-00-login-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/pos/shift`);
    await page.waitForTimeout(1500);
    const floatField = page.getByRole('textbox', { name: /Opening Float/i }).first();
    if (await floatField.isVisible({ timeout: 5000 }).catch(() => false)) {
      await floatField.click();
      await page.keyboard.type('500', { delay: 30 });
      await page.getByRole('button', { name: 'Open Shift', exact: true }).click();
      await page.waitForTimeout(2000);
    }
    await page.goto(`${BASE_URL}/#/pos/sale`);
    await page.waitForTimeout(1500);
    pass('Shift ready / on New Sale');
  } catch (e) { fail('Shift ready', e); await shot(page, 'wb-01-shift-fail'); }

  try {
    const field = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    await field.waitFor({ timeout: 10000 });
    let typedOk = false;
    for (let attempt = 0; attempt < 3 && !typedOk; attempt++) {
      await field.click();
      await page.waitForTimeout(300);
      await page.keyboard.type(WEIGHTED_BARCODE, { delay: 40 });
      typedOk = await field.inputValue().then(v => v === WEIGHTED_BARCODE).catch(() => false);
      if (!typedOk) await page.waitForTimeout(500);
    }
    if (!typedOk) throw new Error('Could not type the weighted barcode into the scan field');
    await page.keyboard.press('Enter');
    const added = await textVisible(page, PRODUCT_CODE).waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    await shot(page, 'wb-02-scanned');
    if (!added) throw new Error(`Weighted barcode "${WEIGHTED_BARCODE}" did not resolve to product ${PRODUCT_CODE} in the cart`);
    pass(`Weighted barcode resolved to product ${PRODUCT_CODE} in the cart`);
  } catch (e) { fail('Weighted barcode scan resolves product', e); await shot(page, 'wb-02-fail'); }

  try {
    const qtyVisible = await textVisible(page, '0.5').isVisible({ timeout: 4000 }).catch(() => false);
    const amountVisible = await textVisible(page, '40.00').isVisible({ timeout: 4000 }).catch(() => false);
    console.log(`Weighted-barcode result: qty 0.5 visible=${qtyVisible}, amount 40.00 visible=${amountVisible}`);
    if (!qtyVisible) throw new Error('Decoded weight (0.5 kg) not shown as the line quantity');
    if (!amountVisible) throw new Error('Expected amount (80/kg * 0.5kg = 40.00) not shown on the line');
    pass('Weighted barcode: qty decoded as 0.5kg, amount correctly computed as 40.00 (80/kg x 0.5kg)');
  } catch (e) { fail('Weighted barcode: qty/amount correctness', e); await shot(page, 'wb-03-fail'); }

  const client = new Client({ connectionString: PG_CONN, ssl: { rejectUnauthorized: false } });
  await client.connect();
  try {
    const beforeSaveTime = new Date();
    const chargeBtn = page.getByRole('button', { name: /^Charge/ });
    await chargeBtn.waitFor({ state: 'visible', timeout: 15000 });
    await chargeBtn.click();
    await page.getByRole('heading', { name: 'Payment' }).waitFor({ timeout: 10000 });
    const saveBtn = page.getByRole('button', { name: /Save & Print|Short by/ });
    await saveBtn.waitFor({ timeout: 8000 });
    if (!(await saveBtn.isEnabled())) throw new Error('Save & Print disabled');
    await saveBtn.click();
    await page.waitForTimeout(8000);

    const invRes = await client.query(
      `SELECT invoice_no, created_at FROM rih_sales_invoices WHERE client_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [CLIENT_ID]
    );
    if (new Date(invRes.rows[0].created_at) < beforeSaveTime) throw new Error('No new invoice found after Save — the weighted-barcode sale likely did not save');
    const invoiceNo = invRes.rows[0].invoice_no;

    const lineRes = await client.query(
      `SELECT l.base_qty, l.rate, l.final_amount, p.product_code
       FROM rid_sales_invoice_lines l JOIN rim_products p ON p.id=l.product_id
       WHERE l.client_id=$1 AND l.invoice_no=$2`,
      [CLIENT_ID, invoiceNo]
    );
    console.log(`Invoice ${invoiceNo} line:`, lineRes.rows);
    if (lineRes.rows.length !== 1) throw new Error(`Expected exactly 1 line, got ${lineRes.rows.length}`);
    const line = lineRes.rows[0];
    if (line.product_code !== PRODUCT_CODE) throw new Error(`Line product_code ${line.product_code} != ${PRODUCT_CODE}`);
    if (Math.abs(Number(line.base_qty) - 0.5) > 0.001) throw new Error(`Saved qty ${line.base_qty} != 0.5`);
    if (Math.abs(Number(line.rate) - 80) > 0.01) throw new Error(`Saved rate ${line.rate} != 80`);
    if (Math.abs(Number(line.final_amount) - 40) > 0.01) throw new Error(`Saved final_amount ${line.final_amount} != 40.00`);
    pass(`Weighted-barcode sale saved correctly: qty=${line.base_qty}, rate=${line.rate}, amount=${line.final_amount}`);
  } catch (e) { fail('Weighted barcode: sale saves with correct qty/rate/amount', e); await shot(page, 'wb-04-fail'); }

  await client.end();
  await browser.close();

  console.log('\n===== WEIGHTED BARCODE E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
