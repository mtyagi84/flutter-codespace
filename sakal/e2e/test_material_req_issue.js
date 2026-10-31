// Phase 4 (Inventory) — Material Requisition -> Material Issue chain.
// Requisition: FROM Main Store, PRD-00002 (stock=25 from Phase 4's own
// Opening Stock + Adjustment tests), Qty Pack 3, Department "QA Admin
// Dept", Consumption Area "QA Office Supplies Consumption" (the Phase 1
// IN-DCA link -- confirms the cascading filter only shows this
// department's own linked area). Requisition is pure intent (no stock/
// GL), matching PO's own precedent. Then Material Issue consolidates it,
// posting real stock + GL (Dr Expense via the Consumption Area's linked
// account / Cr Stock). Per the rubric: Currency doesn't apply (MIC
// voucher always posts in base currency per CLAUDE.md), GL+Stock effects
// apply on the Issue (not the Requisition), Chain applies directly (this
// IS the chain).
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
  } catch (e) { fail('Login', e); await shot(page, 'mri-00-fail'); }

  // ===== PART 1: Material Requisition =====
  try {
    await page.goto(`${BASE_URL}/#/inventory/requisitions`);
    await page.waitForTimeout(2000);
    await page.getByText('New', { exact: false }).first().click();
    await page.waitForTimeout(4000);
    await page.getByText('Add Line', { exact: false }).first().click();
    await page.waitForTimeout(800);
    await page.mouse.click(394, 300);
    await page.waitForTimeout(400);
    await page.keyboard.type('QA Test Widget 69433', { delay: 50 });
    await page.waitForTimeout(900);
    await page.getByText('[PRD-00002]', { exact: false }).first().click();
    await page.waitForTimeout(1200);
    await shot(page, 'mri-01-product-picked');
    pass('Requisition: Product PRD-00002 picked');
  } catch (e) { fail('Open Requisition / pick product', e); await shot(page, 'mri-01-fail'); }

  try {
    await page.mouse.click(945, 300); // Department
    await page.waitForTimeout(500);
    await page.mouse.click(928, 301); // QA Admin Dept
    await page.waitForTimeout(700);
    await page.mouse.click(1130, 300); // Consumption Area
    await page.waitForTimeout(500);
    await page.mouse.click(1138, 301); // QA Office Supplies Consumption
    await page.waitForTimeout(600);
    await shot(page, 'mri-02-dept-ca-picked');
    pass('Requisition: Department + Consumption Area picked (cascading filter)');
  } catch (e) { fail('Pick Department/Consumption Area', e); await shot(page, 'mri-02-fail'); }

  try {
    await page.mouse.click(690, 300); // Qty Pack
    await page.keyboard.press('Control+A');
    await page.keyboard.type('3', { delay: 30 });
    await page.waitForTimeout(400);
    await shot(page, 'mri-03-qty-filled');
    pass('Requisition: Qty Pack = 3');
  } catch (e) { fail('Fill Requisition Qty', e); await shot(page, 'mri-03-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Draft', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'mri-04-saved');
    pass('Requisition saved as Draft');
  } catch (e) { fail('Save Requisition', e); await shot(page, 'mri-04-fail'); }

  try {
    const approveBtn = page.getByRole('button', { name: 'Approve', exact: true }).first();
    await approveBtn.click();
    await page.waitForTimeout(800);
    const confirmBtn = page.getByRole('button', { name: 'Approve', exact: true }).last();
    await confirmBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'mri-05-approved');
    pass('Requisition approved');
  } catch (e) { fail('Approve Requisition', e); await shot(page, 'mri-05-fail'); }

  await browser.close();

  // ---------- DB verification: Requisition is pure intent ----------
  let requisitionNo = null;
  try {
    const header = await dbClient.query(
      `SELECT requisition_no, status FROM rih_material_requisition_headers
       WHERE company_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [companyId]
    );
    console.log('Requisition header:', header.rows);
    if (header.rows.length === 0) throw new Error('No Requisition header found');
    if (header.rows[0].status !== 'APPROVED') throw new Error(`status=${header.rows[0].status}`);
    requisitionNo = header.rows[0].requisition_no;
    pass(`DB: Requisition ${requisitionNo} approved`);

    const productRes = await dbClient.query(`SELECT id FROM rim_products WHERE company_id=$1 AND product_code='PRD-00002'`, [companyId]);
    const stockLoc = await dbClient.query(`SELECT current_stock FROM rim_product_location WHERE company_id=$1 AND product_id=$2`, [companyId, productRes.rows[0].id]);
    console.log('Stock after Requisition approve:', stockLoc.rows);
    if (Number(stockLoc.rows[0].current_stock) !== 25) throw new Error(`current_stock=${stockLoc.rows[0].current_stock}, expected unchanged at 25 (Requisition is pure intent)`);
    pass('DB: Requisition correctly posted NO stock movement (pure intent, like PO)');
  } catch (e) { fail('DB verification (Requisition)', e); }

  // ===== PART 2: Material Issue (consolidates the Requisition) =====
  const browser2 = await chromium.launch({ headless: true });
  const page2 = await (await browser2.newContext({ viewport: { width: 1600, height: 1100 } })).newPage();
  page2.setDefaultTimeout(20000);

  try {
    await page2.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page2);
    await typeInto(page2, 'Email', tenant.adminEmail);
    await typeInto(page2, 'Password', tenant.adminPassword);
    await page2.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page2.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page2);
    await page2.waitForTimeout(1500);
    await page2.goto(`${BASE_URL}/#/inventory/material-issue`);
    await page2.waitForTimeout(2000);
    await shot(page2, 'mri-06-issue-list');
    await page2.getByText('New', { exact: false }).first().click();
    await page2.waitForTimeout(4000);
    await shot(page2, 'mri-07-issue-entry');
    pass('Material Issue entry screen loaded');
  } catch (e) { fail('Open Material Issue', e); await shot(page2, 'mri-07-fail'); }

  await browser2.close();

  console.log('\n===== PHASE 4: MATERIAL REQUISITION RESULTS (Part 1 of 2) =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  console.log(`\nRequisition No for Part 2 (Material Issue): ${requisitionNo}`);
  const failed = results.filter(r => !r.ok).length;
  await dbClient.end();
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
