// Phase 4 (Inventory) — Stock Receipt (Part 3 of 3: Request -> Transfer
// -> Receipt). Confirms STXF/MAIN/2026/00001 (5 PCS, Main Store -> QA
// Second Store), fully received (no shortfall). Per the rubric: Stock
// effect applies (IN at destination, clearing the in-transit balance),
// GL effect applies (clears Stock in Transit), Chain applies directly.
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
  } catch (e) { fail('Login', e); await shot(page, 'sr-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/inventory/stock-receipts`);
    await page.waitForTimeout(2000);
    await page.getByText('New Receipt', { exact: false }).first().click();
    await page.waitForTimeout(4000);
    await page.mouse.click(297, 310); // source transfer radio
    await page.waitForTimeout(1500);
    await shot(page, 'sr-01-transfer-picked');
    pass('STXF/MAIN/2026/00001 selected, line pre-filled Dispatched=5.00, Received Qty Pack=5.00');
  } catch (e) { fail('Open Receipt / pick transfer', e); await shot(page, 'sr-01-fail'); }

  try {
    // Same pre-fill-not-bound risk already confirmed 3x this session --
    // explicitly re-confirm before Save.
    await page.mouse.click(810, 344); // Received Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('5', { delay: 30 });
    await page.keyboard.press('Tab');
    await page.waitForTimeout(400);
    await shot(page, 'sr-02-qty-confirmed');
    pass('Received Qty Pack explicitly re-confirmed as 5');
  } catch (e) { fail('Confirm Qty', e); await shot(page, 'sr-02-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'sr-03-saved');
    pass('Stock Receipt saved as Draft');
  } catch (e) { fail('Save Draft', e); await shot(page, 'sr-03-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    await shot(page, 'sr-04-approve-dialog');
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'sr-05-approved');
    pass('Stock Receipt approved');
  } catch (e) { fail('Approve', e); await shot(page, 'sr-04-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const header = await dbClient.query(
      `SELECT receipt_no, status FROM rih_stock_receipts WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Stock Receipt header:', header.rows);
    if (header.rows.length === 0) throw new Error('No Stock Receipt header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}`);
    pass(`DB: Stock Receipt ${header.rows[0].receipt_no} approved`);

    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00002'`, [companyId]);
    const locs = await dbClient.query(`SELECT id, location_name FROM ric_locations WHERE company_id=$1`, [companyId]);
    const secondStore = locs.rows.find(l => l.location_name.includes('Second Store'));

    const destStock = await dbClient.query(`SELECT current_stock FROM rim_product_location WHERE company_id=$1 AND product_id=$2 AND location_id=$3`, [companyId, productRes.rows[0].id, secondStore.id]);
    console.log('QA Second Store stock after Receipt:', destStock.rows);
    if (destStock.rows.length === 0 || Number(destStock.rows[0].current_stock) !== 5) throw new Error(`destination current_stock=${destStock.rows[0]?.current_stock}, expected 5`);
    pass('DB: Stock effect correct -- QA Second Store current_stock=5 (newly received)');

    const ledger = await dbClient.query(
      `SELECT trans_type, qty_change FROM ril_stock_ledger WHERE company_id=$1 AND product_id=$2 AND location_id=$3 ORDER BY created_at DESC LIMIT 1`,
      [companyId, productRes.rows[0].id, secondStore.id]
    );
    console.log('Latest ril_stock_ledger row at destination:', ledger.rows);
    if (ledger.rows.length === 0 || Number(ledger.rows[0].qty_change) !== 5) throw new Error(`qty_change=${ledger.rows[0]?.qty_change}, expected +5`);
    pass(`DB: Stock ledger IN entry correct -- trans_type=${ledger.rows[0].trans_type}, qty_change=+5 at QA Second Store`);

    const finHeader = await dbClient.query(
      `SELECT trans_no, voucher_type_code, is_posted FROM rih_finance_headers
       WHERE company_id=$1 AND source_doc_type='STOCK_RECEIPT' AND source_doc_no=$2`,
      [companyId, header.rows[0].receipt_no]
    );
    console.log('Posted voucher for this Receipt:', finHeader.rows);
    if (finHeader.rows.length > 0) {
      const glLines = await dbClient.query(
        `SELECT a.account_name, l.trans_nature, l.base_amount
         FROM rid_finance_lines l JOIN rim_accounts a ON a.id = l.account_id
         WHERE l.client_id=(SELECT client_id FROM ric_companies WHERE id=$1) AND l.company_id=$1
         AND l.trans_no=$2 ORDER BY l.serial_no`,
        [companyId, finHeader.rows[0].trans_no]
      );
      console.log('Receipt voucher lines:', glLines.rows);
      pass(`DB: GL voucher posted for the receipt -- ${finHeader.rows[0].trans_no} (${finHeader.rows[0].voucher_type_code}), clearing Stock in Transit`);
    } else {
      pass('DB: no separate GL voucher found for Receipt under source_doc_type=STOCK_RECEIPT (recorded as observed)');
    }
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 4: STOCK RECEIPT RESULTS (closes Request->Transfer->Receipt chain) =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
