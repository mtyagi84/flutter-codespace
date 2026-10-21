// Quick-pick grid E2E test. Confirms the "Quick Pick" button opens a flat
// product grid (no scanning/typing/category drilling), a priced product's
// tile shows its price, tapping it adds that exact product to the cart at
// the correct price, and the sale completes end to end.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';
const PRODUCT_NAME = 'Toor Dal 1kg';
const PRODUCT_CODE = 'PRD-POS-003';

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const PG_CONN = process.env.SAKAL_DEV_DB_URL;

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

async function nativeClickByLabel(page, labelSubstring) {
  return page.evaluate((label) => {
    const all = Array.from(document.querySelectorAll(`[aria-label*="${label}"]`));
    if (all.length === 0) return false;
    let best = all[0]; let bestArea = Infinity;
    for (const el of all) { const r = el.getBoundingClientRect(); const area = r.width * r.height; if (area > 0 && area < bestArea) { bestArea = area; best = el; } }
    best.click(); if (best.focus) best.focus();
    return true;
  }, labelSubstring);
}

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
  } catch (e) { fail('Till Setup + PIN Login', e); await shot(page, 'qp-00-login-fail'); }

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
  } catch (e) { fail('Shift ready', e); await shot(page, 'qp-01-shift-fail'); }

  const client = new Client({ connectionString: PG_CONN, ssl: { rejectUnauthorized: false } });
  await client.connect();
  let expectedPrice = null;
  try {
    const r = await client.query(`SELECT fn_get_active_price($1,$2,$3,$4,$5,NULL,CURRENT_DATE,'INR') AS r`, [
      CLIENT_ID, 'e73b9365-68d4-4f56-9398-0e683560e9cc', 'e55f8e79-bf0f-464a-a6bf-b8db7f4f9556',
      (await client.query(`SELECT id FROM rim_products WHERE client_id=$1 AND product_code=$2`, [CLIENT_ID, PRODUCT_CODE])).rows[0].id,
      '11ce33eb-cf64-420a-959b-a83319a33804',
    ]);
    expectedPrice = parseFloat(String(r.rows[0].r).replace(/^\(/, '').split(',')[0]);
    console.log(`Ground-truth price for ${PRODUCT_CODE}: ${expectedPrice}`);
    pass('Fetched ground-truth price for comparison');
  } catch (e) { fail('Fetch ground-truth price', e); }

  try {
    const quickPickBtn = page.getByText('Quick Pick', { exact: true }).first();
    await quickPickBtn.waitFor({ timeout: 10000 });
    await quickPickBtn.click();
    await textVisible(page, 'Quick Pick').waitFor({ state: 'visible', timeout: 8000 });
    await shot(page, 'qp-02-grid-open');
    pass('Quick Pick button opens the flat product grid screen');
  } catch (e) { fail('Quick Pick: opens grid', e); await shot(page, 'qp-02-fail'); }

  try {
    const priceText = `${expectedPrice.toFixed(2)} INR`;
    const tileVisible = await textVisible(page, PRODUCT_NAME).waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    if (!tileVisible) throw new Error(`"${PRODUCT_NAME}" tile not found in the Quick Pick grid`);
    const priceVisible = await textVisible(page, priceText).waitFor({ state: 'visible', timeout: 8000 }).then(() => true).catch(() => false);
    if (!priceVisible) throw new Error(`Tile did not show the expected price "${priceText}"`);
    pass(`Quick Pick grid shows "${PRODUCT_NAME}" with correct price "${priceText}"`);
  } catch (e) { fail('Quick Pick: tile + price correctness', e); await shot(page, 'qp-03-fail'); }

  try {
    // The accessibility/semantics DOM overlay can go blank again after a
    // screen transition even though CanvasKit keeps painting pixels fine
    // (confirmed live: screenshot shows the grid perfectly rendered while
    // document.querySelectorAll('[aria-label]') returns nothing at all) —
    // re-trigger it the same way the page's own initial load does.
    await enableSemantics(page);
    let clickedOk = false;
    for (let attempt = 0; attempt < 8 && !clickedOk; attempt++) {
      const found = await page.evaluate((code) => {
        // Flutter Web alternates between exposing a widget's text via an
        // `aria-label` attribute on a merged semantics node, and a real
        // nested DOM text node — confirmed to differ depending on prior
        // navigation history, not predictable from the outside (same
        // caveat this project's own `textVisible()` helper already
        // documents). Try the attribute form first, then fall back to a
        // real textContent scan + closest clickable ancestor.
        const byAttr = document.querySelector(`[aria-label*="${code}"]`);
        if (byAttr) { byAttr.click(); return true; }
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          if (node.textContent && node.textContent.includes(code)) {
            let el = node.parentElement;
            while (el && el.tagName !== 'FLT-SEMANTICS') el = el.parentElement;
            if (!el) el = node.parentElement;
            el.click();
            return true;
          }
        }
        return false;
      }, PRODUCT_CODE);
      if (found) { clickedOk = true; break; }
      await page.waitForTimeout(1000);
    }
    if (!clickedOk) {
      const debugInfo = await page.evaluate(() => ({
        semanticsHostCount: document.querySelectorAll('flt-semantics-host').length,
        semanticsCount: document.querySelectorAll('flt-semantics').length,
        placeholderCount: document.querySelectorAll('flt-semantics-placeholder').length,
        ariaLabelCount: document.querySelectorAll('[aria-label]').length,
        bodyChildTags: Array.from(document.body.children).map(c => c.tagName),
      }));
      console.log('DEBUG — semantics DOM state at failure time:', JSON.stringify(debugInfo, null, 2));
      await shot(page, 'qp-debug-state');
      throw new Error(`Could not click a tile with aria-label containing "${PRODUCT_CODE}" after 8 retries`);
    }
    await page.waitForTimeout(1500);
    const backOnSale = await page.getByRole('textbox', { name: /Scan barcode or search product/i }).isVisible({ timeout: 5000 }).catch(() => false);
    const addedToCart = await textVisible(page, PRODUCT_CODE).isVisible({ timeout: 5000 }).catch(() => false);
    await shot(page, 'qp-04-added');
    if (!backOnSale) throw new Error('Did not return to New Sale screen after tapping a tile');
    if (!addedToCart) throw new Error(`${PRODUCT_CODE} not found in cart after Quick Pick selection`);
    pass('Tapping a Quick Pick tile returns to New Sale with the product added to the cart');
  } catch (e) { fail('Quick Pick: selection adds to cart', e); await shot(page, 'qp-04-fail'); }

  let beforeSaveTime = null;
  try {
    beforeSaveTime = new Date();
    const chargeBtn = page.getByRole('button', { name: /^Charge/ });
    await chargeBtn.waitFor({ state: 'visible', timeout: 15000 });
    await chargeBtn.click();
    await page.getByRole('heading', { name: 'Payment' }).waitFor({ timeout: 10000 });
    const saveBtn = page.getByRole('button', { name: /Save & Print|Short by/ });
    await saveBtn.waitFor({ timeout: 8000 });
    if (!(await saveBtn.isEnabled())) throw new Error('Save & Print disabled');
    await saveBtn.click();
    await page.waitForTimeout(8000);
    pass('Quick Pick-sourced cart line sells through Charge -> Payment -> Save normally');
  } catch (e) { fail('Quick Pick: sale completes', e); await shot(page, 'qp-05-fail'); }

  try {
    const invRes = await client.query(`SELECT invoice_no, created_at FROM rih_sales_invoices WHERE client_id=$1 ORDER BY created_at DESC LIMIT 1`, [CLIENT_ID]);
    if (new Date(invRes.rows[0].created_at) < beforeSaveTime) throw new Error('No new invoice found after Save');
    const invoiceNo = invRes.rows[0].invoice_no;
    const lineRes = await client.query(
      `SELECT p.product_code, l.rate FROM rid_sales_invoice_lines l JOIN rim_products p ON p.id=l.product_id WHERE l.client_id=$1 AND l.invoice_no=$2`,
      [CLIENT_ID, invoiceNo]
    );
    console.log(`Invoice ${invoiceNo} lines:`, lineRes.rows);
    const line = lineRes.rows.find(r => r.product_code === PRODUCT_CODE);
    if (!line) throw new Error(`${PRODUCT_CODE} not found on the saved invoice`);
    if (Math.abs(Number(line.rate) - expectedPrice) > 0.01) throw new Error(`Saved rate ${line.rate} != expected ${expectedPrice}`);
    pass(`Saved invoice line for ${PRODUCT_CODE} has the correct rate ${line.rate}, confirming Quick Pick fed the real priced product through end to end`);
  } catch (e) { fail('Quick Pick: saved invoice correctness', e); }

  await client.end();
  await browser.close();

  console.log('\n===== QUICK PICK E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
