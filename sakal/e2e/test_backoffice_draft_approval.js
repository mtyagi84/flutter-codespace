// Back-office DRAFT-invoice-approval fallback E2E test. Confirms the
// documented recovery path for a stuck/offline-synced POS DRAFT invoice
// actually works: back-office Email+Password admin login -> Sales
// Invoice list -> open the DRAFT row -> Save Invoice (which both saves
// and approves, per this screen's own "no separate Approve button"
// design) -> confirm APPROVED status + real GL posting.
const { chromium } = require('playwright');
require('./helpers/env');
const { Client } = require('pg');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const ADMIN_EMAIL = 'posadmin1792408828234@example.com';
const ADMIN_PASSWORD = 'TestPass123';
const INVOICE_NO = 'SI/MAIN/2026/00065';

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';

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
  page.on('console', msg => { if (msg.type() === 'error') console.log('CONSOLE_ERROR:', msg.text()); });

  const client = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await client.connect();

  try {
    const before = await client.query(`SELECT status FROM rih_sales_invoices WHERE client_id=$1 AND invoice_no=$2`, [CLIENT_ID, INVOICE_NO]);
    console.log(`Ground truth before test: ${INVOICE_NO} status = ${before.rows[0].status}`);
    if (before.rows[0].status !== 'DRAFT') throw new Error(`Expected DRAFT, invoice is already ${before.rows[0].status} — pick a fresh DRAFT invoice for this test`);
    pass('Confirmed test invoice is in DRAFT status before starting');
  } catch (e) { fail('Pre-check DRAFT status', e); }

  try {
    await page.goto(`${BASE_URL}/#/login`);
    await enableSemantics(page);
    await typeInto(page, 'Email', ADMIN_EMAIL);
    await typeInto(page, 'Password', ADMIN_PASSWORD);
    const signInBtn = page.getByRole('button', { name: 'Sign In', exact: true });
    await signInBtn.waitFor({ timeout: 10000 });
    await signInBtn.click();
    await page.waitForTimeout(3000);
    await shot(page, 'bo-01-after-login');
    const stillOnLogin = await page.getByRole('button', { name: 'Sign In', exact: true }).isVisible({ timeout: 3000 }).catch(() => false);
    if (stillOnLogin) throw new Error('Still on login screen after Sign In click — login likely failed');
    pass('Back-office Email+Password login succeeded');
  } catch (e) { fail('Back-office login', e); await shot(page, 'bo-01-fail'); }

  try {
    await page.goto(`${BASE_URL}/#/sales/invoices`);
    await page.waitForTimeout(2000);
    const shortNo = INVOICE_NO.split('/').pop();
    const searchField = page.getByRole('textbox').first();
    if (await searchField.isVisible({ timeout: 3000 }).catch(() => false)) {
      await searchField.click();
      await page.keyboard.type(shortNo, { delay: 30 });
      await page.waitForTimeout(1500);
    }
    const rowVisible = await textVisible(page, INVOICE_NO).waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false)
      || await textVisible(page, shortNo).waitFor({ state: 'visible', timeout: 5000 }).then(() => true).catch(() => false);
    await shot(page, 'bo-02-list');
    if (!rowVisible) throw new Error(`Invoice ${INVOICE_NO} not found in the Sales Invoice list`);
    const draftBadge = await textVisible(page, 'Draft').isVisible({ timeout: 3000 }).catch(() => false);
    pass(`Sales Invoice list shows ${INVOICE_NO}${draftBadge ? ' with a visible Draft status badge' : ''}`);
  } catch (e) { fail('Sales Invoice list: find the DRAFT invoice', e); await shot(page, 'bo-02-fail'); }

  try {
    const clicked = await page.evaluate((code) => {
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
    }, INVOICE_NO.split('/').pop());
    if (!clicked) throw new Error('Could not click the invoice row to open it');
    await page.waitForTimeout(2000);
    await shot(page, 'bo-03-entry-opened');
    const saveBtnVisible = await page.getByRole('button', { name: 'Save Invoice', exact: true }).waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    if (!saveBtnVisible) throw new Error('Entry screen did not open with a visible "Save Invoice" button');
    pass('Opened the DRAFT invoice in the entry screen, "Save Invoice" button visible');
  } catch (e) { fail('Open DRAFT invoice in entry screen', e); await shot(page, 'bo-03-fail'); }

  try {
    const saveBtn = page.getByRole('button', { name: 'Save Invoice', exact: true });
    await saveBtn.click();
    await page.waitForTimeout(5000);
    await shot(page, 'bo-04-after-save');
    pass('Clicked "Save Invoice" (this screen\'s own save-is-approve action)');
  } catch (e) { fail('Click Save Invoice', e); await shot(page, 'bo-04-fail'); }

  try {
    const after = await client.query(`SELECT status FROM rih_sales_invoices WHERE client_id=$1 AND invoice_no=$2`, [CLIENT_ID, INVOICE_NO]);
    console.log(`Ground truth after Save Invoice: ${INVOICE_NO} status = ${after.rows[0].status}`);
    if (after.rows[0].status !== 'APPROVED') throw new Error(`Expected APPROVED, got ${after.rows[0].status}`);
    pass(`Invoice status correctly changed to APPROVED via the back-office fallback`);
  } catch (e) { fail('DB: status is APPROVED', e); }

  try {
    const gl = await client.query(
      `SELECT h.voucher_type_code FROM rih_finance_headers h WHERE h.client_id=$1 AND h.source_doc_no=$2`,
      [CLIENT_ID, INVOICE_NO]
    );
    const codes = gl.rows.map(r => r.voucher_type_code);
    console.log(`GL vouchers posted for ${INVOICE_NO}:`, codes);
    // This invoice was a 100%-cash sale, so GL is legitimately DEFERRED to
    // shift close (migration 221) — confirm that deferral state instead of
    // expecting immediate SLS/COS, same distinction this session already
    // nailed down once today.
    const header = await client.query(`SELECT gl_consolidated, deferred_si_lines IS NOT NULL AS has_deferred FROM rih_sales_invoices WHERE client_id=$1 AND invoice_no=$2`, [CLIENT_ID, INVOICE_NO]);
    console.log('GL-consolidation state:', header.rows[0]);
    if (codes.length === 0 && header.rows[0].gl_consolidated === false && header.rows[0].has_deferred) {
      pass('No immediate GL posted, but correctly deferred (gl_consolidated=false, deferred lines present) — consistent with this being a 100%-cash sale');
    } else if (codes.length > 0) {
      pass(`GL posted immediately: ${codes.join(', ')}`);
    } else {
      throw new Error('No GL posted and no deferral state either — real gap');
    }
  } catch (e) { fail('DB: GL posting or deferral correctness', e); }

  await client.end();
  await browser.close();

  console.log('\n===== BACK-OFFICE DRAFT APPROVAL E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
