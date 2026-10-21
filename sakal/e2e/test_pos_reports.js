// POS Reports E2E test — confirms the numbers actually rendered on screen
// are numerically correct, by independently computing the same aggregates
// directly from the DB (same tables/filters the screen itself queries) and
// comparing exact string matches against what's displayed.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const COMPANY_ID = 'e73b9365-68d4-4f56-9398-0e683560e9cc';
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
  } catch (e) { fail('Till Setup + PIN Login', e); await shot(page, 'rpt-00-login-fail'); }

  // Get the terminal id and currently open (most recent) shift directly
  // from the DB first, so the ground-truth query and the on-screen
  // selection are provably looking at the same shift.
  const client = new Client({ connectionString: PG_CONN, ssl: { rejectUnauthorized: false } });
  await client.connect();
  let shiftId = null, shiftNo = null;
  try {
    const shiftRes = await client.query(
      `SELECT id, shift_no FROM rih_pos_shifts WHERE client_id=$1 AND company_id=$2 AND is_deleted=false ORDER BY opened_at DESC LIMIT 1`,
      [CLIENT_ID, COMPANY_ID]
    );
    if (shiftRes.rows.length === 0) throw new Error('No shift found in DB at all');
    shiftId = shiftRes.rows[0].id;
    shiftNo = shiftRes.rows[0].shift_no;
    console.log(`Ground-truth shift: ${shiftNo} (${shiftId})`);
    pass('Resolved the most recent shift for ground-truth comparison');
  } catch (e) { fail('Resolve shift', e); }

  let expected = null;
  try {
    const compRes = await client.query(`SELECT local_currency FROM ric_companies WHERE id=$1`, [COMPANY_ID]);
    const localCcy = compRes.rows[0].local_currency;

    const invRes = await client.query(
      `SELECT sale_type, grand_total FROM rih_sales_invoices
       WHERE client_id=$1 AND company_id=$2 AND pos_shift_id=$3 AND status='APPROVED' AND is_deleted=false`,
      [CLIENT_ID, COMPANY_ID, shiftId]
    );
    const salesCount = invRes.rows.length;
    const salesTotal = invRes.rows.reduce((s, r) => s + Number(r.grand_total), 0);
    const cashSales = invRes.rows.filter(r => r.sale_type === 'CASH').reduce((s, r) => s + Number(r.grand_total), 0);
    const creditSales = salesTotal - cashSales;

    const floatRes = await client.query(`SELECT currency_id, opening_amount FROM rih_pos_shift_opening_float WHERE shift_id=$1`, [shiftId]);
    const openingByCcy = {};
    for (const r of floatRes.rows) openingByCcy[r.currency_id] = (openingByCcy[r.currency_id] || 0) + Number(r.opening_amount);

    const payoutRes = await client.query(`SELECT movement_type, amount, currency_id FROM rih_pos_payouts WHERE shift_id=$1 AND is_deleted=false`, [shiftId]);
    const cashInByCcy = {}, cashOutByCcy = {}, cashDropByCcy = {};
    for (const p of payoutRes.rows) {
      const amt = Number(p.amount);
      if (p.movement_type === 'CASH_IN') cashInByCcy[p.currency_id] = (cashInByCcy[p.currency_id] || 0) + amt;
      else if (p.movement_type === 'CASH_OUT' || p.movement_type === 'PAYOUT') cashOutByCcy[p.currency_id] = (cashOutByCcy[p.currency_id] || 0) + amt;
      else if (p.movement_type === 'CASH_DROP') cashDropByCcy[p.currency_id] = (cashDropByCcy[p.currency_id] || 0) + amt;
    }
    const touchedCcy = new Set([...Object.keys(openingByCcy), ...Object.keys(cashInByCcy), ...Object.keys(cashOutByCcy), ...Object.keys(cashDropByCcy), localCcy]);
    const expectedCashFor = (ccy) => {
      const opening = openingByCcy[ccy] || 0;
      const cashIn = cashInByCcy[ccy] || 0;
      const cashOut = cashOutByCcy[ccy] || 0;
      const cashDrop = cashDropByCcy[ccy] || 0;
      const cs = ccy === localCcy ? cashSales : 0;
      return opening + cs + cashIn - cashOut - cashDrop;
    };

    expected = { localCcy, salesCount, salesTotal, cashSales, creditSales, openingByCcy, cashInByCcy, cashOutByCcy, cashDropByCcy, touchedCcy, expectedCashFor };
    console.log('Expected (DB ground truth):', JSON.stringify({ salesCount, salesTotal, cashSales, creditSales, localCcy, touchedCcy: [...touchedCcy] }));
    pass('Computed ground-truth Sales + Cash Movement aggregates directly from DB');
  } catch (e) { fail('Compute ground truth', e); }

  try {
    await page.goto(`${BASE_URL}/#/pos/reports`);
    await page.waitForTimeout(2000);
    const shiftDropdown = await textVisible(page, shiftNo).waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    if (!shiftDropdown) throw new Error(`Reports screen did not default-select the expected most-recent shift ${shiftNo}`);
    pass(`POS Reports opened, correct shift (${shiftNo}) auto-selected`);
    await shot(page, 'rpt-01-loaded');
  } catch (e) { fail('POS Reports: open + shift selection', e); await shot(page, 'rpt-01-fail'); }

  const check2dp = async (label, value) => {
    const text = Number(value).toFixed(2);
    const visible = await textVisible(page, text).isVisible({ timeout: 3000 }).catch(() => false);
    return { label, text, visible };
  };

  try {
    const transChecks = await textVisible(page, String(expected.salesCount)).isVisible({ timeout: 3000 }).catch(() => false);
    const cashChk = await check2dp('Cash Sales', expected.cashSales);
    const creditChk = await check2dp('Credit Sales', expected.creditSales);
    const totalChk = await check2dp('Total Sales', expected.salesTotal);
    console.log('Sales card checks:', { transactions: `${expected.salesCount}=${transChecks}`, cashChk, creditChk, totalChk });
    if (!transChecks) throw new Error(`Transactions count ${expected.salesCount} not shown`);
    if (!cashChk.visible) throw new Error(`Cash Sales ${cashChk.text} not shown`);
    if (!creditChk.visible) throw new Error(`Credit Sales ${creditChk.text} not shown`);
    if (!totalChk.visible) throw new Error(`Total Sales ${totalChk.text} not shown`);
    pass(`Sales card matches DB exactly: ${expected.salesCount} txns, Cash ${cashChk.text}, Credit ${creditChk.text}, Total ${totalChk.text}`);
  } catch (e) { fail('Sales card correctness', e); await shot(page, 'rpt-02-fail'); }

  try {
    for (const ccy of expected.touchedCcy) {
      const headerVisible = await textVisible(page, `Cash Movements (${ccy})`).isVisible({ timeout: 3000 }).catch(() => false);
      if (!headerVisible) throw new Error(`No "Cash Movements (${ccy})" card found for a currency with real activity`);
      const openingChk = await check2dp(`Opening Float ${ccy}`, expected.openingByCcy[ccy] || 0);
      const cashInChk = await check2dp(`Cash In ${ccy}`, expected.cashInByCcy[ccy] || 0);
      const payOutChk = await check2dp(`Pay Outs ${ccy}`, -(expected.cashOutByCcy[ccy] || 0));
      const cashDropChk = await check2dp(`Cash Drops ${ccy}`, -(expected.cashDropByCcy[ccy] || 0));
      const expectedCashChk = await check2dp(`Expected Cash ${ccy}`, expected.expectedCashFor(ccy));
      console.log(`Cash Movements (${ccy}):`, { openingChk, cashInChk, payOutChk, cashDropChk, expectedCashChk });
      if (!openingChk.visible) throw new Error(`[${ccy}] Opening Float ${openingChk.text} not shown`);
      if (!cashInChk.visible) throw new Error(`[${ccy}] Cash In ${cashInChk.text} not shown`);
      if (!payOutChk.visible) throw new Error(`[${ccy}] Pay Outs ${payOutChk.text} not shown`);
      if (!cashDropChk.visible) throw new Error(`[${ccy}] Cash Drops ${cashDropChk.text} not shown`);
      if (!expectedCashChk.visible) throw new Error(`[${ccy}] Expected Cash ${expectedCashChk.text} not shown`);
    }
    pass(`Cash Movements card(s) match DB exactly for every touched currency: [${[...expected.touchedCcy].join(', ')}]`);
    await shot(page, 'rpt-03-cash-movements');
  } catch (e) { fail('Cash Movements correctness', e); await shot(page, 'rpt-03-fail'); }

  await client.end();
  await browser.close();

  console.log('\n===== POS REPORTS E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
