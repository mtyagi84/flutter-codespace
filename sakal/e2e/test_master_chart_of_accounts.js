// Phase 1 (Finance Masters) — Chart of Accounts. Per the rubric's own
// worked example: Currency applies ONLY conditionally within this one
// screen — tests both a Cash-nature leaf (under the seeded "5100 Cash"
// group, nature inherited+locked, currency relevant) and a General-nature
// leaf (under "6500 Other Operating Expenses", nature free, currency
// behavior checked empirically rather than assumed) to see exactly how
// the screen actually behaves, not guess from reading the code alone.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');

const BASE_URL = 'http://localhost:8099';
const STAMP = Date.now().toString().slice(-5);
const CASH_LEAF_NAME = `QA Petty Cash EUR ${STAMP}`;
const GENERAL_LEAF_NAME = `QA Office Supplies ${STAMP}`;
const ROW_HEIGHT = 36; // _NodeRow's rowHeight on desktop (alwaysShowActions=mobile=false)

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }
async function shot(page, name) { try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {} }

// Direct pixel-coordinate click, NOT a semantics-based locator. Root-caused
// live: Flutter Web's accessibility (flt-semantics) tree lags canvas paint
// specifically for GROUP rows (posting_allowed=false) scrolled into view via
// a raw mouse-wheel event — confirmed by dumping every flt-semantics text
// node at a known-good scrolled state: LEAF rows (e.g. "4300 Social
// Security", "5800 Internal Transfers") appear in the semantics tree fine,
// but every GROUP row at the same scroll position (4400/5000/5100/5200/
// 6000/6100/...) is completely absent from it even after a 3s settle wait —
// while the SAME rows paint correctly on canvas (confirmed via screenshot).
// This is a Flutter-Web CanvasKit semantics-on-scroll quirk, not a data or
// rendering bug (direct DB query already confirmed every "missing" account
// is seeded correctly with the right parent_id, and the row-building code
// has zero nature/type-based filtering anywhere). Clicking by pixel
// coordinate bypasses the gap entirely for this one-off test script.
//
// The target y is computed DYNAMICALLY (never hardcoded) from the live tree
// order fetched straight from the DB, anchored on a nearby LEAF row (which
// IS reliably locatable via semantics) — a hardcoded pixel position drifted
// wrong the moment a prior test run's own created accounts changed the
// list's length above the target row, silently clicking the wrong row with
// no error (confirmed live: it saved a leaf under the wrong parent).
async function computeTargetY(page, client, companyId, anchorCode, targetCode) {
  const res = await client.query(
    `SELECT account_code, parent_id, id FROM rim_accounts
     WHERE company_id=$1 AND is_deleted=false ORDER BY account_code ASC`,
    [companyId]
  );
  const byId = new Map(res.rows.map(r => [r.id, r]));
  const roots = res.rows.filter(r => !r.parent_id);
  const childMap = new Map();
  for (const r of res.rows) {
    if (r.parent_id) { if (!childMap.has(r.parent_id)) childMap.set(r.parent_id, []); childMap.get(r.parent_id).push(r); }
  }
  // Mirror _visibleNodes(): only roots are auto-expanded, traversal order
  // matches account_code ASC within each parent (same as the DB query's
  // own ORDER BY, since rows were collected into childMap in that order).
  const flat = [];
  const expandedRootIds = new Set(roots.map(r => r.id));
  function traverse(nodes, depth) {
    for (const n of nodes) {
      flat.push(n.account_code);
      if (expandedRootIds.has(n.id)) traverse(childMap.get(n.id) || [], depth + 1);
    }
  }
  traverse(roots, 0);
  const anchorIdx = flat.indexOf(anchorCode);
  const targetIdx = flat.indexOf(targetCode);
  if (anchorIdx === -1) throw new Error(`Anchor code ${anchorCode} not found in computed tree order`);
  if (targetIdx === -1) throw new Error(`Target code ${targetCode} not found in computed tree order`);
  const anchorLoc = textVisible(page, anchorCode).first();
  const box = await anchorLoc.boundingBox();
  if (!box) throw new Error(`Could not get bounding box for anchor row "${anchorCode}" — scroll it into view first`);
  const anchorY = box.y + box.height / 2;
  return anchorY + (targetIdx - anchorIdx) * ROW_HEIGHT;
}

async function clickTreeRowAtCoord(page, x, y) {
  await page.mouse.click(x, y);
  await page.waitForTimeout(800);
  // The right-panel "Add Account" guidance IS a leaf-level widget with
  // normal semantics, unaffected by the list-scroll quirk above.
  const addBtn = page.getByText(/^\+?\s*Add (Account|Ledger|Child)/i).first();
  const addVisible = await addBtn.isVisible({ timeout: 3000 }).catch(() => false);
  if (addVisible) { await addBtn.click(); return true; }
  return 'row-clicked-no-add-button';
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));

  // DB connection opened up front (not just at the end) — computeTargetY
  // needs it live during the browser session to position clicks correctly.
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
    // Dismiss the first-login popup BEFORE navigating to Chart of Accounts
    // (not after) — a real bug found in this script's own development: the
    // app's own post-login redirect can still be settling when a `page.
    // goto()` fires right after Sign In, and an explicit nav issued before
    // that settles gets silently overridden, landing on /dashboard instead
    // of the intended screen with no error at all. Dismissing the popup
    // first (which itself waits out that settle period) avoids the race.
    await dismissFirstLoginWelcomeIfPresent(page);
    pass('Logged in');
  } catch (e) { fail('Login', e); await shot(page, 'coa-00-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/master/accounts`);
    const treeVisible = await textVisible(page, 'Class 1').waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    if (!treeVisible) throw new Error('Chart of Accounts tree did not load (no "Class 1" root group visible)');
    await page.waitForTimeout(1000);
    await shot(page, 'coa-01-loaded');
    pass('Chart of Accounts screen loaded, tree visible');
  } catch (e) { fail('Open Chart of Accounts', e); await shot(page, 'coa-01-fail'); }

  // Not every group is auto-expanded by default (confirmed via screenshot:
  // some rows show a collapsed ▶ chevron) — a collapsed group's children
  // never render in the DOM at all, which is the real reason "5100 Cash"
  // (child of the collapsed "5000 Class 5 - Treasury") was never found no
  // matter how much the list was scrolled. The header's own "Expand All"
  // icon (second icon after the sort-arrows icon, next to "Accounts")
  // solves this for every node at once, not just this one.
  try {
    // Every root-level group ("1000 Class 1" ... "9000 Class 9") is
    // auto-expanded by the screen itself on load (_autoExpandRoots()) —
    // confirmed by reading chart_of_accounts_screen.dart directly: ALL
    // `parent_id IS NULL` rows go into `_expanded` unconditionally, and
    // "5000 Class 5 - Treasury" is itself a root, so its direct children
    // (5100/5200/5800) are already expanded with no click needed.
    // Deliberately NOT clicking "Expand All" here: it also expands every
    // other previously-collapsed SUB-group (1100/1600/3100/...), which
    // shifts every row below them further down the list — this is exactly
    // what broke the fixed pixel-coordinate clicks below in an earlier
    // version of this script (the click landed on a different row than
    // intended once the list reflowed longer). Leaving only the roots
    // expanded keeps the scroll position used below reliable and matches
    // the known-good layout confirmed via screenshot.
    pass('Relying on root groups already being auto-expanded (Expand All deliberately not clicked — see comment)');
  } catch (e) { fail('Tree expansion check', e); await shot(page, 'coa-01b-fail'); }

  // ---------- Test 1: Cash-nature leaf under "5100 Cash" ----------
  try {
    // Scroll a fixed amount to bring both the anchor ("4300", a reliably-
    // locatable LEAF row) and the target ("5100", a GROUP row) into the
    // viewport together, then compute the target's y dynamically — see
    // computeTargetY's own comment for why this replaced a hardcoded pixel
    // guess.
    await page.mouse.move(400, 400);
    for (let i = 0; i < 3; i++) { await page.mouse.wheel(0, 300); await page.waitForTimeout(400); }
    await page.waitForTimeout(500);
    const targetY = await computeTargetY(page, dbClient, companyId, '4300', '5100');
    const clicked = await clickTreeRowAtCoord(page, 400, targetY);
    await shot(page, 'coa-02-cash-row-clicked');
    if (clicked === 'row-clicked-no-add-button') {
      const allLabels = await page.evaluate(() => Array.from(document.querySelectorAll('[aria-label]')).map(el => el.getAttribute('aria-label')).filter(l => l && l.length < 60));
      console.log('DEBUG — right-panel labels after selecting Cash row:', JSON.stringify(allLabels));
    }
    if (!clicked) throw new Error('Could not find/click the "Cash" group row');
    await page.waitForTimeout(500);
    const formVisible = await textVisible(page, 'Add Account').waitFor({ state: 'visible', timeout: 8000 }).then(() => true).catch(() => false);
    if (!formVisible) throw new Error('Add Account form did not open');
    await shot(page, 'coa-02-cash-add-form');
    pass('Add Account form opened for a child of "Cash"');
  } catch (e) { fail('Open Add form under Cash', e); await shot(page, 'coa-02-fail'); }

  let natureLockedToCash = null, currencyFieldPresent = null;
  try {
    // Node Type: select "Ledger" chip (default is Group).
    const ledgerChip = page.getByText('Ledger', { exact: true }).first();
    await ledgerChip.click();
    await page.waitForTimeout(500);
    await shot(page, 'coa-03-ledger-selected');

    natureLockedToCash = await textVisible(page, 'Cash').isVisible({ timeout: 2000 }).catch(() => false);
    currencyFieldPresent = await textVisible(page, 'Currency').isVisible({ timeout: 2000 }).catch(() => false);
    console.log(`Under Cash-nature parent: nature shows/locked to "Cash"=${natureLockedToCash}, Currency field present=${currencyFieldPresent}`);

    await typeInto(page, 'Enter account name', CASH_LEAF_NAME);
    if (currencyFieldPresent) {
      const ccyDropdown = page.getByRole('button', { name: /Select…|Currency/i }).last();
      await ccyDropdown.click().catch(() => {});
      await page.waitForTimeout(500);
      const eurOption = page.getByRole('menuitem', { name: /EUR/i }).first();
      const eurFound = await eurOption.isVisible({ timeout: 2000 }).catch(() => false);
      if (eurFound) { await eurOption.click(); await page.waitForTimeout(300); pass('Selected EUR currency for the Cash-nature leaf'); }
      else fail('Select EUR currency', new Error('EUR not found in Currency dropdown (was it activated earlier? should be, from test_finance_exchange_rates.js)'));
    }
    await shot(page, 'coa-04-cash-leaf-filled');
    const saveBtn = page.getByRole('button', { name: 'Save Account', exact: true });
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'coa-05-cash-leaf-saved');
    pass(`Cash-nature leaf "${CASH_LEAF_NAME}" saved (nature inherited/locked=${natureLockedToCash}, currency field present=${currencyFieldPresent})`);
  } catch (e) { fail('Fill + save Cash-nature leaf', e); await shot(page, 'coa-04-fail'); }

  // ---------- Test 2: General-nature leaf under "Other Operating Expenses" ----------
  try {
    await page.goto(`${BASE_URL}/#/master/accounts`);
    await textVisible(page, 'Class 1').waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(1000);
    // Same scroll amount as Test 1 also brings "6500 Other Operating
    // Expenses" into view; target y computed dynamically the same way.
    await page.mouse.move(400, 400);
    for (let i = 0; i < 3; i++) { await page.mouse.wheel(0, 300); await page.waitForTimeout(400); }
    await page.waitForTimeout(500);
    const targetY2 = await computeTargetY(page, dbClient, companyId, '4300', '6500');
    const clicked = await clickTreeRowAtCoord(page, 400, targetY2);
    if (!clicked) throw new Error('Could not click the Add icon on "Other Operating Expenses"');
    await page.waitForTimeout(1000);
    const ledgerChip = page.getByText('Ledger', { exact: true }).first();
    await ledgerChip.click();
    await page.waitForTimeout(500);
    const currencyFieldPresentGeneral = await textVisible(page, 'Currency').isVisible({ timeout: 2000 }).catch(() => false);
    console.log(`Under General-nature parent: Currency field present=${currencyFieldPresentGeneral}`);
    await typeInto(page, 'Enter account name', GENERAL_LEAF_NAME);
    await shot(page, 'coa-06-general-leaf-filled');
    const saveBtn = page.getByRole('button', { name: 'Save Account', exact: true });
    await saveBtn.click();
    await page.waitForTimeout(2000);
    await shot(page, 'coa-07-general-leaf-saved');
    pass(`General-nature leaf "${GENERAL_LEAF_NAME}" saved (Currency field present for General nature=${currencyFieldPresentGeneral})`);
  } catch (e) { fail('Fill + save General-nature leaf', e); await shot(page, 'coa-06-fail'); }

  await browser.close();

  // ---------- DB verification (reuses the same connection opened up front) ----------
  const client = dbClient;
  try {
    const cashRow = await client.query(
      `SELECT a.account_name, a.account_nature, a.posting_allowed, c.currency_id
       FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
       WHERE a.company_id=$1 AND a.account_name=$2`, [companyId, CASH_LEAF_NAME]
    );
    console.log('Cash-nature leaf in DB:', cashRow.rows);
    if (cashRow.rows.length === 0) throw new Error('Cash-nature leaf not found in DB');
    if (cashRow.rows[0].account_nature !== 'Cash') throw new Error(`account_nature ${cashRow.rows[0].account_nature} != Cash (expected inherited from parent)`);
    pass(`DB: Cash-nature leaf correctly inherited nature=Cash, currency=${cashRow.rows[0].currency_id}`);

    const genRow = await client.query(
      `SELECT a.account_name, a.account_nature, a.posting_allowed, c.currency_id
       FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
       WHERE a.company_id=$1 AND a.account_name=$2`, [companyId, GENERAL_LEAF_NAME]
    );
    console.log('General-nature leaf in DB:', genRow.rows);
    if (genRow.rows.length === 0) throw new Error('General-nature leaf not found in DB');
    if (genRow.rows[0].account_nature !== 'General') throw new Error(`account_nature ${genRow.rows[0].account_nature} != General`);
    pass(`DB: General-nature leaf correctly has nature=General, currency=${genRow.rows[0].currency_id ?? 'NULL (no currency, as expected for a non-Cash/Bank account)'}`);
  } catch (e) { fail('DB verification', e); }
  await client.end();

  console.log('\n===== PHASE 1: CHART OF ACCOUNTS RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
