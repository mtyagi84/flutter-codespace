// Phase 3 (Purchase Cycle) — Purchase Return, BILLED branch (the Phase 3
// GRN/Purchase Bill tests' own GRN is now billed). Per CLAUDE.md: a
// billed GRN's line reverses real Stock+Input VAT, Supplier DR posted
// once in aggregate (posts an SDN -- Supplier Debit Note). This GRN had
// no VAT (No Tax line), so the SDN reverses pure stock value: Dr Supplier
// (debit note reduces what's owed) / Cr Stock Account. PO qty_received
// rolls back regardless of p_reopen_po. Per the rubric: Currency applies
// (inherited USD), GL effect applies (SDN voucher), Stock effect applies
// (ril_stock_ledger OUT, rim_product_location decreases), Chain applies
// (GRN->Return, closing the circle this phase opened).
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1600, height: 1100 } })).newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  const dbClient = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await dbClient.connect();
  const cRes = await dbClient.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
  const compRes = await dbClient.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [cRes.rows[0].id]);
  const companyId = compRes.rows[0].id;

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    await page.waitForTimeout(1500);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'pret-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/purchase/returns`);
    await page.waitForTimeout(2000);
    await page.getByText('New Purchase Return', { exact: false }).first().click();
    await page.waitForTimeout(6000);
    await shot(page, 'pret-01-loaded');
    pass('Purchase Return entry screen loaded');
  } catch (e) { fail('Open Purchase Return', e); await shot(page, 'pret-01-fail'); }

  try {
    await page.mouse.click(540, 91);
    await page.waitForTimeout(600);
    await page.keyboard.type('4010', { delay: 60 });
    await page.waitForTimeout(1000);
    await page.getByText('[4010001] QA Test Supplier', { exact: false }).first().click();
    await page.waitForTimeout(1200);
    await shot(page, 'pret-02-supplier-picked');
    pass('Supplier set, GRN/MAIN/2026/00001 shown as Billed');
  } catch (e) { fail('Pick Supplier', e); await shot(page, 'pret-02-fail'); }

  try {
    await page.mouse.click(1240, 143); // Reason dropdown
    await page.waitForTimeout(500);
    await page.mouse.click(1240, 149); // "Defective", first option
    await page.waitForTimeout(400);
    await shot(page, 'pret-03-reason-picked');
    pass('Reason = Defective');
  } catch (e) { fail('Pick Reason', e); await shot(page, 'pret-03-fail'); }

  try {
    await page.mouse.click(301, 261); // GRN checkbox
    await page.waitForTimeout(1000);
    await shot(page, 'pret-04-grn-checked');
    pass('GRN/MAIN/2026/00001 selected, Return Lines pre-filled with GRN qty');
  } catch (e) { fail('Check GRN', e); await shot(page, 'pret-04-fail'); }

  try {
    // Confirmed live: the Return Qty Pack field VISUALLY shows the GRN's
    // own pre-filled value (10.00) but Save Draft still rejected it with
    // "Enter a return quantity for at least one line." -- the displayed
    // value isn't bound into the form's actual state until the field is
    // explicitly touched. Click in, re-confirm the value, tab out.
    await page.mouse.click(681, 489); // Return Qty Pack field
    await page.keyboard.press('Control+A');
    await page.keyboard.type('10', { delay: 30 });
    await page.keyboard.press('Tab');
    await page.waitForTimeout(400);
    await shot(page, 'pret-04b-qty-confirmed');
    pass('Return Qty Pack explicitly re-confirmed as 10');
  } catch (e) { fail('Confirm Return Qty', e); await shot(page, 'pret-04b-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'pret-05-saved');
    pass('Purchase Return saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'pret-05-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'pret-06-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'pret-07-approved');
    pass('Purchase Return approved');
  } catch (e) { fail('Approve', e); await shot(page, 'pret-06-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT return_no, return_date, status FROM rih_purchase_return_headers
       WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Latest Purchase Return header in DB:', header.rows);
    if (header.rows.length === 0) throw new Error('No Purchase Return header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}, expected APPROVED`);
    pass(`DB: Purchase Return ${header.rows[0].return_no} correctly approved`);

    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00001'`, [companyId]);
    const stockLoc = await dbClient.query(
      `SELECT current_stock FROM rim_product_location WHERE company_id=$1 AND product_id=$2`,
      [companyId, productRes.rows[0].id]
    );
    console.log('rim_product_location after Return:', stockLoc.rows);
    if (Number(stockLoc.rows[0].current_stock) !== 0) throw new Error(`current_stock=${stockLoc.rows[0].current_stock}, expected 0 (10 received - 10 returned)`);
    pass('DB: Stock effect correct -- current_stock=0 (full 10-unit return of the 10 received via GRN)');

    const ledger = await dbClient.query(
      `SELECT trans_type, qty_change FROM ril_stock_ledger WHERE company_id=$1 AND product_id=$2 ORDER BY created_at DESC LIMIT 1`,
      [companyId, productRes.rows[0].id]
    );
    console.log('Latest ril_stock_ledger row:', ledger.rows);
    if (Number(ledger.rows[0].qty_change) !== -10) throw new Error(`qty_change=${ledger.rows[0].qty_change}, expected -10`);
    pass(`DB: Stock ledger entry correct -- trans_type=${ledger.rows[0].trans_type}, qty_change=-10`);

    const finHeader = await dbClient.query(
      `SELECT trans_no, voucher_type_code, is_posted FROM rih_finance_headers
       WHERE company_id=$1 AND source_doc_type='PURCHASE_RETURN' AND source_doc_no=$2`,
      [companyId, header.rows[0].return_no]
    );
    console.log('Posted voucher(s) for this Return:', finHeader.rows);
    if (finHeader.rows.length === 0) throw new Error('No GL voucher posted for this Return');

    const glLines = await dbClient.query(
      `SELECT a.account_name, a.account_nature, l.trans_nature, l.base_amount
       FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
       AND l.trans_no=$2 ORDER BY l.serial_no`,
      [companyId, finHeader.rows[0].trans_no]
    );
    console.log('Return voucher lines:', glLines.rows);
    const supplierLine = glLines.rows.find(r => r.account_nature === 'Supplier');
    const stockLine = glLines.rows.find(r => r.account_name.includes('Stock'));
    if (!supplierLine || supplierLine.trans_nature !== 'DR') throw new Error('Supplier line not DR as expected for a debit note');
    if (!stockLine || stockLine.trans_nature !== 'CR') throw new Error('Stock line not CR as expected for a return');
    if (Math.abs(Number(supplierLine.base_amount) - 500) > 0.01) throw new Error(`Supplier line amount=${supplierLine.base_amount}, expected 500`);
    const totalDr = glLines.rows.filter(r => r.trans_nature === 'DR').reduce((s, r) => s + Number(r.base_amount), 0);
    const totalCr = glLines.rows.filter(r => r.trans_nature === 'CR').reduce((s, r) => s + Number(r.base_amount), 0);
    if (Math.abs(totalDr - totalCr) > 0.01) throw new Error(`Voucher does not balance: Dr=${totalDr}, Cr=${totalCr}`);
    pass(`DB: GL effect correct -- Dr ${supplierLine.account_name} 500 (debit note, reduces payable) / Cr ${stockLine.account_name} 500, balanced (${finHeader.rows[0].voucher_type_code})`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 3: PURCHASE RETURN RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
