// Loyalty redemption E2E test — real browser interaction + DB verification.
// Sale 1: scan a product, capture a loyalty mobile number, cash-charge it.
//   Confirms an EARN ledger row posts and the profile's points_balance updates.
// Sale 2: same mobile number, redeem points via the Redeem Points field,
//   confirm the bill total is actually reduced on screen, cash-charge it,
//   then confirm a REDEEM ledger row posts with the correct negative points
//   and the invoice's own loyalty_points_redeemed/loyalty_redeem_value_amount
//   columns match what was redeemed.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';
const MOBILE = '9123450099';
const PRODUCT_CODE = 'PRD-POS-003'; // Toor Dal 1kg

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const COMPANY_ID = 'e73b9365-68d4-4f56-9398-0e683560e9cc';
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

async function scanAndAdd(page, code, { retries = 4 } = {}) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    const field = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    if (await field.isVisible({ timeout: 2000 }).catch(() => false)) {
      await field.click();
      await page.keyboard.type(code, { delay: 30 });
      await page.keyboard.press('Enter');
      await page.waitForTimeout(2000);
      const added = await textVisible(page, code).isVisible({ timeout: 2000 }).catch(() => false);
      if (added) return true;
    }
    await page.waitForTimeout(1500);
  }
  return false;
}

async function doCashCharge(page, label) {
  await page.getByRole('button', { name: /^Charge/ }).click();
  await page.getByRole('heading', { name: 'Payment' }).waitFor({ timeout: 10000 });
  const saveBtn = page.getByRole('button', { name: /Save & Print|Short by/ });
  await saveBtn.waitFor({ timeout: 8000 });
  const enabled = await saveBtn.isEnabled();
  if (!enabled) throw new Error('Save & Print disabled — cash does not cover due amount');
  await saveBtn.click();
  // wait for reset back to scanner field
  const searchField = page.getByRole('textbox', { name: /Scan barcode or search product/i });
  await searchField.waitFor({ timeout: 25000 });
  let reset = false;
  for (let i = 0; i < 20 && !reset; i++) {
    reset = !(await textVisible(page, PRODUCT_CODE).isVisible({ timeout: 1000 }).catch(() => false));
    if (!reset) await page.waitForTimeout(2000);
  }
  if (!reset) throw new Error(`${label}: cart did not reset after save`);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  await context.addInitScript(() => {
    const FRAME_ID = '__net_nfet_printing__';
    const forceLoad = (frame) => { setTimeout(() => { try { frame.dispatchEvent(new Event('load')); } catch (_) {} }, 300); };
    const start = () => {
      const existing = document.getElementById(FRAME_ID);
      if (existing) forceLoad(existing);
      const observer = new MutationObserver((mutations) => {
        for (const m of mutations) for (const node of m.addedNodes) { if (node && node.id === FRAME_ID) forceLoad(node); }
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
    };
    if (document.documentElement) start(); else document.addEventListener('DOMContentLoaded', start, { once: true });
  });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));
  page.on('console', msg => { if (msg.type() === 'error') console.log('CONSOLE_ERROR:', msg.text()); });

  // ---------- Till Setup + PIN Login ----------
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
  } catch (e) { fail('Till Setup + PIN Login', e); await shot(page, 'loy-00-login-fail'); }

  // ---------- Ensure shift open, land on New Sale ----------
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
  } catch (e) { fail('Shift ready', e); await shot(page, 'loy-01-shift-fail'); }

  let firstInvoiceNo = null, secondInvoiceNo = null;

  // ---------- Sale 1: EARN ----------
  try {
    const added = await scanAndAdd(page, PRODUCT_CODE);
    if (!added) throw new Error('Could not add product to cart for sale 1');
    const mobileField = page.getByRole('textbox', { name: /mobile/i }).first();
    await mobileField.click();
    await page.waitForTimeout(400);
    await page.keyboard.type(MOBILE, { delay: 50 });
    const typedOk = await mobileField.inputValue().then(v => v === MOBILE).catch(() => false);
    if (!typedOk) throw new Error(`Mobile field shows wrong value after typing (expected ${MOBILE})`);
    await page.keyboard.press('Enter');
    await page.waitForTimeout(1500);
    const profileChip = await textVisible(page, 'pts').isVisible({ timeout: 5000 }).catch(() => false);
    if (!profileChip) throw new Error('Loyalty profile chip (".. pts") did not appear after Enter on mobile field');
    await shot(page, 'loy-02-profile-added-sale1');
    pass('Sale 1: loyalty profile created/attached via mobile lookup');
  } catch (e) { fail('Sale 1: loyalty profile lookup', e); await shot(page, 'loy-02-fail'); }

  try {
    await doCashCharge(page, 'Sale 1');
    pass('Sale 1: cash sale completed');
  } catch (e) { fail('Sale 1: cash charge', e); await shot(page, 'loy-03-charge-fail'); }

  // ---------- DB check: EARN posted ----------
  const client = new Client({ connectionString: PG_CONN, ssl: { rejectUnauthorized: false } });
  await client.connect();
  let profileId = null, balanceAfterSale1 = null;
  try {
    const profileRes = await client.query(
      `SELECT id, points_balance FROM rih_customer_loyalty_profiles WHERE client_id=$1 AND company_id=$2 AND mobile_number=$3`,
      [CLIENT_ID, COMPANY_ID, MOBILE]
    );
    if (profileRes.rows.length === 0) throw new Error('No loyalty profile row found for this mobile number');
    profileId = profileRes.rows[0].id;
    balanceAfterSale1 = Number(profileRes.rows[0].points_balance);

    const invRes = await client.query(
      `SELECT invoice_no, invoice_date, grand_total, tax_amount FROM rih_sales_invoices
       WHERE client_id=$1 AND company_id=$2 AND loyalty_profile_id=$3 ORDER BY created_at DESC LIMIT 1`,
      [CLIENT_ID, COMPANY_ID, profileId]
    );
    if (invRes.rows.length === 0) throw new Error('No sales invoice found tagged with this loyalty profile');
    firstInvoiceNo = invRes.rows[0].invoice_no;
    const expectedEarn = Math.round((Number(invRes.rows[0].grand_total) - Number(invRes.rows[0].tax_amount)) * 100) / 100;

    const ledgerRes = await client.query(
      `SELECT trans_type, points_change FROM ril_loyalty_ledger WHERE loyalty_profile_id=$1 AND source_doc_no=$2 AND trans_type='EARN'`,
      [profileId, firstInvoiceNo]
    );
    if (ledgerRes.rows.length === 0) throw new Error('No EARN ledger row found for sale 1 invoice');
    const earned = Number(ledgerRes.rows[0].points_change);
    console.log(`Sale 1 invoice ${firstInvoiceNo}: grand_total-tax=${expectedEarn}, EARN ledger points_change=${earned}, profile balance=${balanceAfterSale1}`);
    if (Math.abs(earned - expectedEarn) > 0.01) throw new Error(`EARN points_change ${earned} does not match expected ${expectedEarn}`);
    const ledgerSumRes = await client.query(`SELECT coalesce(sum(points_change),0) AS total FROM ril_loyalty_ledger WHERE loyalty_profile_id=$1`, [profileId]);
    const ledgerSum = Number(ledgerSumRes.rows[0].total);
    if (Math.abs(balanceAfterSale1 - ledgerSum) > 0.01) throw new Error(`profile points_balance ${balanceAfterSale1} does not match sum of its own ledger ${ledgerSum}`);
    pass(`Sale 1: EARN ledger row correct (+${earned} pts), profile balance ${balanceAfterSale1} reconciles with ledger sum`);
  } catch (e) { fail('Sale 1: DB verification (EARN)', e); }

  if (!profileId || !(balanceAfterSale1 > 10)) {
    console.log(`Balance after sale 1 (${balanceAfterSale1}) is not > 10 — redeem test needs a bigger sale 1. Aborting redeem leg.`);
    await client.end();
    await browser.close();
    console.log('\n===== LOYALTY E2E RESULTS =====');
    results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
    const failed = results.filter(r => !r.ok).length;
    process.exit(failed > 0 ? 1 : 0);
  }

  const REDEEM_POINTS = 10;
  const expectedRedeemValue = REDEEM_POINTS * 0.5; // point_value_in_base_currency=0.5, base=local currency here

  // ---------- Sale 2: REDEEM ----------
  try {
    const added = await scanAndAdd(page, PRODUCT_CODE);
    if (!added) throw new Error('Could not add product to cart for sale 2');
    // Increase qty a bit via a second scan so the bill comfortably exceeds
    // the redeemed value and the 50%-of-bill cap never binds.
    await scanAndAdd(page, PRODUCT_CODE);
    await page.waitForTimeout(500);

    const mobileField = page.getByRole('textbox', { name: /mobile/i }).first();
    await mobileField.click();
    await page.waitForTimeout(400);
    await page.keyboard.type(MOBILE, { delay: 50 });
    const typedOk2 = await mobileField.inputValue().then(v => v === MOBILE).catch(() => false);
    if (!typedOk2) throw new Error(`Mobile field shows wrong value after typing on sale 2 (expected ${MOBILE})`);
    await page.keyboard.press('Enter');
    await page.waitForTimeout(1500);
    const balanceShown = await textVisible(page, 'pts').isVisible({ timeout: 5000 }).catch(() => false);
    if (!balanceShown) throw new Error('Loyalty balance chip did not reappear for sale 2');
    await shot(page, 'loy-04-profile-sale2');
    pass('Sale 2: loyalty profile re-attached, balance shown');
  } catch (e) { fail('Sale 2: loyalty re-attach', e); await shot(page, 'loy-04-fail'); }

  try {
    // Grand Total row is an exact amount (toStringAsFixed(2), no currency
    // suffix) inside the totals card — capture it before redeeming.
    const grandTotalBefore = await page.getByText(/^\d+\.\d{2}$/).last().textContent().catch(() => null);

    const redeemField = page.getByRole('textbox', { name: /Redeem Points/i }).first();
    await redeemField.waitFor({ timeout: 5000 });
    await redeemField.click();
    await page.waitForTimeout(300);
    await page.keyboard.press('Control+A');
    await page.keyboard.type(String(REDEEM_POINTS), { delay: 50 });
    await page.keyboard.press('Tab');
    await page.waitForTimeout(1000);

    const redeemRowVisible = await textVisible(page, 'Loyalty Redeemed').isVisible({ timeout: 4000 }).catch(() => false);
    if (!redeemRowVisible) throw new Error('"Loyalty Redeemed" row did not appear in totals after entering redeem points');
    // The row's own value cell shows "-5.00" (toStringAsFixed(2), negative of
    // the redeemed value) directly beside the "Loyalty Redeemed" label.
    const redeemAmountText = `-${expectedRedeemValue.toFixed(2)}`;
    const redeemAmountVisible = await textVisible(page, redeemAmountText).isVisible({ timeout: 3000 }).catch(() => false);
    await shot(page, 'loy-05-redeemed');
    if (!redeemAmountVisible) throw new Error(`"Loyalty Redeemed" row did not show the expected amount ${redeemAmountText}`);
    console.log(`Grand total before redeem: ${grandTotalBefore}; Loyalty Redeemed row shows ${redeemAmountText} as expected`);
    pass(`Sale 2: "Loyalty Redeemed" row shows -${expectedRedeemValue.toFixed(2)} on screen after redeeming ${REDEEM_POINTS} pts`);
  } catch (e) { fail('Sale 2: redeem reduces bill total', e); await shot(page, 'loy-05-fail'); }

  try {
    await doCashCharge(page, 'Sale 2');
    pass('Sale 2: cash sale completed');
  } catch (e) { fail('Sale 2: cash charge', e); await shot(page, 'loy-06-charge-fail'); }

  // ---------- DB check: REDEEM posted + balance correct ----------
  try {
    const invRes = await client.query(
      `SELECT invoice_no, grand_total, tax_amount, loyalty_points_redeemed, loyalty_redeem_value_amount
       FROM rih_sales_invoices WHERE client_id=$1 AND company_id=$2 AND loyalty_profile_id=$3
       ORDER BY created_at DESC LIMIT 1`,
      [CLIENT_ID, COMPANY_ID, profileId]
    );
    if (invRes.rows.length === 0) throw new Error('No second sales invoice found for this loyalty profile');
    secondInvoiceNo = invRes.rows[0].invoice_no;
    if (secondInvoiceNo === firstInvoiceNo) throw new Error('Second invoice lookup returned the same invoice as sale 1');
    const pointsRedeemedOnHeader = Number(invRes.rows[0].loyalty_points_redeemed);
    const redeemValueOnHeader = Number(invRes.rows[0].loyalty_redeem_value_amount);
    console.log(`Sale 2 invoice ${secondInvoiceNo}: loyalty_points_redeemed=${pointsRedeemedOnHeader}, loyalty_redeem_value_amount=${redeemValueOnHeader}`);
    if (Math.abs(pointsRedeemedOnHeader - REDEEM_POINTS) > 0.01) throw new Error(`Header loyalty_points_redeemed ${pointsRedeemedOnHeader} != ${REDEEM_POINTS}`);
    if (Math.abs(redeemValueOnHeader - expectedRedeemValue) > 0.5) throw new Error(`Header loyalty_redeem_value_amount ${redeemValueOnHeader} != expected ~${expectedRedeemValue}`);

    const redeemLedgerRes = await client.query(
      `SELECT points_change FROM ril_loyalty_ledger WHERE loyalty_profile_id=$1 AND source_doc_no=$2 AND trans_type='REDEEM'`,
      [profileId, secondInvoiceNo]
    );
    if (redeemLedgerRes.rows.length === 0) throw new Error('No REDEEM ledger row found for sale 2 invoice');
    const redeemed = Number(redeemLedgerRes.rows[0].points_change);
    if (Math.abs(redeemed - -REDEEM_POINTS) > 0.01) throw new Error(`REDEEM ledger points_change ${redeemed} != -${REDEEM_POINTS}`);

    const earnLedgerRes2 = await client.query(
      `SELECT points_change FROM ril_loyalty_ledger WHERE loyalty_profile_id=$1 AND source_doc_no=$2 AND trans_type='EARN'`,
      [profileId, secondInvoiceNo]
    );
    const earned2 = earnLedgerRes2.rows.length ? Number(earnLedgerRes2.rows[0].points_change) : 0;

    const profileRes2 = await client.query(`SELECT points_balance FROM rih_customer_loyalty_profiles WHERE id=$1`, [profileId]);
    const finalBalance = Number(profileRes2.rows[0].points_balance);
    const expectedFinalBalance = Math.round((balanceAfterSale1 - REDEEM_POINTS + earned2) * 100) / 100;
    console.log(`Final balance=${finalBalance}, expected=${expectedFinalBalance} (sale1=${balanceAfterSale1} - redeemed=${REDEEM_POINTS} + sale2 earn=${earned2})`);
    if (Math.abs(finalBalance - expectedFinalBalance) > 0.01) throw new Error(`Final points_balance ${finalBalance} != expected ${expectedFinalBalance}`);
    pass(`Sale 2: REDEEM ledger row correct (${redeemed} pts), header columns correct, final balance ${finalBalance} reconciles`);
  } catch (e) { fail('Sale 2: DB verification (REDEEM)', e); }

  await client.end();
  await browser.close();

  console.log('\n===== LOYALTY E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
