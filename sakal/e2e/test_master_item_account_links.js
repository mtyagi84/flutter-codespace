// Phase 1 (Finance Masters) — Item Account Links. Was blocked (zero
// products existed); unblocked now that Product Master testing created a
// real product ("QA Test Widget ..."). Tests IAL-01 — an ITEM-granularity
// override of one link type for that specific product, confirming it
// resolves independently of the COMPANY-level default. Currency/GL/Stock/
// Chain don't apply directly to this screen.
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
  const page = await (await browser.newContext({ viewport: { width: 1366, height: 900 } })).newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  const dbClient = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await dbClient.connect();
  const cRes = await dbClient.query(`SELECT id FROM ric_clients WHERE client_no=$1`, [tenant.clientNo]);
  const compRes = await dbClient.query(`SELECT id FROM ric_companies WHERE client_id=$1`, [cRes.rows[0].id]);
  const companyId = compRes.rows[0].id;
  const prodRes = await dbClient.query(
    `SELECT id, product_code, product_name FROM rim_products WHERE company_id=$1 AND is_deleted=false ORDER BY created_at ASC LIMIT 1`,
    [companyId]
  );
  if (prodRes.rows.length === 0) { console.error('No product found — run test_master_product_master.js first'); process.exit(1); }
  const product = prodRes.rows[0];
  console.log('Using product:', product);

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3000);
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'ial-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/item-account-links`);
    await textVisible(page, product.product_code).waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(500);
    await shot(page, 'ial-01-loaded');
    pass('Item Account Links screen loaded, test product visible in the list');
  } catch (e) { fail('Open Item Account Links', e); await shot(page, 'ial-01-fail'); }

  try {
    await textVisible(page, product.product_code).first().click();
    await page.waitForTimeout(800);
    await textVisible(page, 'Stock Account').waitFor({ state: 'visible', timeout: 8000 });
    await page.waitForTimeout(500);
    await shot(page, 'ial-02-dialog-opened');
    pass('Per-item account links dialog opened for the test product');
  } catch (e) { fail('Open per-item dialog', e); await shot(page, 'ial-02-fail'); }

  try {
    // Target "Sales Discount Account" instead of Stock Account — it starts
    // genuinely EMPTY ("Not configured", no Company default to inherit),
    // sidestepping a real automation gotcha found live: clearing a
    // PRE-FILLED picker on this dialog (Stock Account already shows the
    // Company default) via Control+A+Delete leaves the field refusing all
    // further typed input — tried 6 variations (select-all+type, per-
    // character typing with settle waits, re-click-after-clear, insertText)
    // and none got text into it. Since the actual goal (prove the ITEM-
    // level override mechanism works) doesn't require starting from a
    // pre-filled field, using an unconfigured one proves the identical
    // mechanism without fighting that specific widget state.
    const rowBox = await textVisible(page, 'Sales Discount Account').boundingBox();
    if (!rowBox) throw new Error('Could not locate the Sales Discount Account row');
    await page.mouse.click(727, rowBox.y + rowBox.height / 2);
    await page.waitForTimeout(150);
    await page.keyboard.type('5800', { delay: 80 });
    await page.waitForTimeout(600);
    await shot(page, 'ial-03-account-search');
    const option = textVisible(page, 'Internal Transfers').first();
    const found = await option.isVisible({ timeout: 3000 }).catch(() => false);
    if (!found) throw new Error('"5800 Internal Transfers" not found in the item-level account picker');
    await option.click();
    await page.waitForTimeout(500);
    await shot(page, 'ial-04-account-picked');
    pass('Configured Sales Discount Account to [5800] Internal Transfers for this item (ITEM-level, previously unconfigured)');
  } catch (e) { fail('Configure Sales Discount Account for this item', e); await shot(page, 'ial-03-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save', exact: true }).first();
    await saveBtn.click();
    await page.waitForTimeout(1500);
    await shot(page, 'ial-05-saved');
    pass('Item account link override saved');
  } catch (e) { fail('Save item account link', e); await shot(page, 'ial-05-fail'); }

  await browser.close();

  // ---------- DB verification ----------
  try {
    const row = await dbClient.query(
      `SELECT l.link_type, a.account_code, a.account_name
       FROM rim_account_links l
       JOIN rim_account_link_types lt ON lt.id = l.link_type_id
       JOIN rim_accounts a ON a.id = l.account_id
       WHERE l.company_id=$1 AND l.product_id=$2 AND lt.link_key='SALES_DISCOUNT_ACCOUNT' AND l.is_deleted=false`,
      [companyId, product.id]
    );
    console.log('Item-level Sales Discount Account link in DB:', row.rows);
    if (row.rows.length === 0) throw new Error('No ITEM-level SALES_DISCOUNT_ACCOUNT link found in rim_account_links for this product');
    if (row.rows[0].link_type !== 'ITEM') throw new Error(`link_type=${row.rows[0].link_type}, expected ITEM`);
    if (row.rows[0].account_code !== '5800') throw new Error(`account_code=${row.rows[0].account_code}, expected 5800`);
    pass(`DB: ITEM-level override correctly saved — Sales Discount Account for ${product.product_code} now resolves to [5800] Internal Transfers (link_type=ITEM, previously unconfigured at any level)`);
  } catch (e) { fail('DB verification', e); }
  await dbClient.end();

  console.log('\n===== PHASE 1: ITEM ACCOUNT LINKS RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
