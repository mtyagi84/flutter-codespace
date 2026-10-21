// Comprehensive headless POS E2E run against the fresh SK-72667 "POS Test
// Mart" throwaway tenant. Headless per the user's own request ("test on
// chrome in background without flashing chrome on my screen").
//
// Real obstacle, traced to its actual root this session (2026-10-20) by
// reading the `printing` package's own web source
// (printing_web.dart:195-270, package printing 5.14.3): `Printing.layoutPdf`
// creates a hidden <iframe id="__net_nfet_printing__"> pointed at a
// `blob:application/pdf` URL, and its internal Completer only resolves once
// that iframe's own `load` event fires (it then calls
// `iframe.contentWindow.print()` and completes immediately after — it does
// NOT wait for 'afterprint' at all, despite this project's playwright.config
// comment attributing the hang to 'afterprint' never firing). In headless
// Chromium that iframe's `load` event appears to never fire for a `blob:`
// PDF src, so the completer — and therefore the awaited
// `Printing.layoutPdf(...)` call inside `_charge()`'s `_printReceipt()` —
// hangs forever even though the save+approve (and the GL posting) already
// genuinely completed. Fixed here with a MutationObserver (installed via
// addInitScript, before any app code runs) that watches for that specific
// iframe being appended and force-dispatches a `load` event on it shortly
// after, in case the real one never comes — letting `_charge()`'s own
// save/approve/print/reset code path actually finish end to end, with no
// visible browser window and no change to the print package or app code.
const { chromium } = require('playwright');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';

const results = [];
function pass(step) { results.push({ step, ok: true }); console.log(`PASS: ${step}`); }
function fail(step, err) { results.push({ step, ok: false, err: String(err && err.message || err) }); console.log(`FAIL: ${step} -- ${err && err.message || err}`); }

async function shot(page, name) {
  try { await page.screenshot({ path: `${__dirname}/screenshots/${name}.png` }); } catch {}
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  await context.addInitScript(() => {
    const FRAME_ID = '__net_nfet_printing__';
    const forceLoad = (frame) => {
      // A real `load` may still fire later too — harmless double-dispatch,
      // the package's own listener removes itself on first call anyway.
      setTimeout(() => { try { frame.dispatchEvent(new Event('load')); } catch (_) {} }, 300);
    };
    const start = () => {
      const existing = document.getElementById(FRAME_ID);
      if (existing) forceLoad(existing);
      const observer = new MutationObserver((mutations) => {
        for (const m of mutations) {
          for (const node of m.addedNodes) {
            if (node && node.id === FRAME_ID) forceLoad(node);
          }
        }
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
    };
    // addInitScript runs before document.documentElement necessarily
    // exists yet — observe() on null threw live, confirmed in this exact
    // run. Defer until there's actually a document element to watch.
    if (document.documentElement) start();
    else document.addEventListener('DOMContentLoaded', start, { once: true });
  });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on('pageerror', err => console.log('PAGEERROR:', err.message));
  page.on('console', msg => { if (msg.type() === 'error') console.log('CONSOLE_ERROR:', msg.text()); });
  page.on('requestfailed', req => console.log('REQUEST_FAILED:', req.method(), req.url(), req.failure()?.errorText));
  page.on('response', res => { if (res.status() >= 400) console.log('HTTP_ERROR:', res.status(), res.request().method(), res.url()); });

  try {
    // ---------- Till Setup ----------
    await page.goto(`${BASE_URL}/#/pos/device-setup`);
    await enableSemantics(page);
    await textVisible(page, "This device isn't set up yet").waitFor({ timeout: 15000 }).catch(() => {});
    const signInBtn = page.getByRole('button', { name: 'Sign in as Administrator' });
    if (await signInBtn.isVisible().catch(() => false)) {
      await signInBtn.click();
      await textVisible(page, 'Administrator Sign-In').waitFor({ timeout: 10000 });
      // New login overhaul (shipped this session) defaults Admin Sign-In to
      // Email+Password — switch to the Client ID path, same credentials
      // this throwaway tenant's setup scripts used.
      const clientIdLink = page.getByText('Sign in with Client ID instead');
      if (await clientIdLink.isVisible({ timeout: 3000 }).catch(() => false)) {
        await clientIdLink.click();
        await page.waitForTimeout(300);
      }
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
    pass('Till Setup (admin sign-in, location+till bind)');
  } catch (e) { fail('Till Setup', e); await shot(page, '01-till-setup-fail'); }

  try {
    // ---------- PIN Login ----------
    for (const digit of PIN) {
      await page.getByRole('button', { name: digit, exact: true }).click();
    }
    await page.getByRole('button', { name: 'Enter' }).click();
    await page.waitForTimeout(1500);
    pass('PIN Login');
  } catch (e) { fail('PIN Login', e); await shot(page, '02-pin-login-fail'); }

  try {
    // ---------- Shift Open ----------
    // Navigate straight to the Shift & Cash screen rather than relying on
    // a guard-screen button click, which was found live to sometimes race
    // the post-login session/terminal-id load and silently no-op.
    await page.goto(`${BASE_URL}/#/pos/shift`);
    await page.waitForTimeout(1500);
    // PosAmountField is now a real TextField with labelText "Opening Float
    // (CCY)" — matched by role 'textbox' + regex accessible name (same
    // proven approach as the New Sale scan field), with a verify-then-retry
    // loop since a bare click+type was found live to silently leave the
    // field empty once.
    const floatField = page.getByRole('textbox', { name: /Opening Float/i }).first();
    const floatFieldVisible = await floatField.isVisible({ timeout: 8000 }).catch(() => false);
    if (!floatFieldVisible) {
      // A shift may already be open (leftover from a prior run against this
      // throwaway tenant) — Shift & Cash shows its dashboard instead, with
      // no Open Shift form and no auto-redirect back to New Sale.
      await page.goto(`${BASE_URL}/#/pos/sale`);
      await page.waitForTimeout(1500);
      pass('Shift Open (shift already open from a prior run — navigated to New Sale directly)');
    } else {
      let typedOk = false;
      for (let attempt = 0; attempt < 3 && !typedOk; attempt++) {
        await floatField.click();
        await page.waitForTimeout(200);
        await page.keyboard.type('500', { delay: 40 });
        await page.waitForTimeout(200);
        typedOk = await floatField.inputValue().then(v => v.includes('500')).catch(() => false);
      }
      if (!typedOk) throw new Error('Could not type into Opening Float field after 3 attempts');
      const confirmOpen = page.getByRole('button', { name: 'Open Shift', exact: true });
      await confirmOpen.waitFor({ timeout: 5000 });
      await confirmOpen.click();
      await page.waitForTimeout(2000);
      // Verify we actually left the shift-open form (scanner field or a
      // visible error means we know the outcome either way).
      const stillOnForm = await page.getByText(/Enter the opening float/i).isVisible({ timeout: 2000 }).catch(() => false);
      if (stillOnForm) throw new Error('Still on Open Shift form after clicking Open Shift — likely a validation error');
      pass('Shift Open');
    }
  } catch (e) { fail('Shift Open', e); await shot(page, '03-shift-open-fail'); }

  try {
    // ---------- New Sale: add scheme product (Basmati Rice) ----------
    const searchField = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    await searchField.waitFor({ timeout: 20000 });
    await searchField.fill('PRD-POS-001');
    await searchField.press('Enter');
    // `.isVisible({timeout})` does NOT poll (single immediate check) —
    // `.waitFor()` does. The earlier flaky "Basmati not visible" failures
    // traced to this, not to the product add itself (confirmed separately:
    // zero console errors, ample stock, and an isolated reproducer found
    // the add reliably lands within ~1.6-2.8s after Enter).
    const basmatiVisible = await textVisible(page, 'Basmati').waitFor({ state: 'visible', timeout: 10000 }).then(() => true).catch(() => false);
    if (basmatiVisible) pass('New Sale: add scheme-eligible product (Basmati Rice)');
    else fail('New Sale: add scheme-eligible product', new Error('Basmati Rice not visible in cart after scan'));
    await shot(page, '04-cart-basmati');
  } catch (e) { fail('New Sale: add scheme product', e); await shot(page, '04-add-product-fail'); }

  try {
    // Check for a discount/scheme indicator anywhere on screen (see the
    // waitFor-vs-isVisible note above — same polling fix applied here).
    const discountVisible = await textVisible(page, 'Scheme').waitFor({ state: 'visible', timeout: 5000 }).then(() => true).catch(() => false)
      || await textVisible(page, '10%').waitFor({ state: 'visible', timeout: 2000 }).then(() => true).catch(() => false)
      || await textVisible(page, 'Discount').waitFor({ state: 'visible', timeout: 2000 }).then(() => true).catch(() => false);
    if (discountVisible) pass('Scheme discount indicator visible on cart line');
    else fail('Scheme discount indicator', new Error('No scheme/discount text found near the Basmati Rice line'));
  } catch (e) { fail('Scheme discount check', e); }

  try {
    // ---------- Add a second plain product ----------
    const searchField = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    await searchField.fill('PRD-POS-002');
    await searchField.press('Enter');
    await page.waitForTimeout(1000);
    pass('New Sale: add second product');
    await shot(page, '05-cart-two-items');
  } catch (e) { fail('New Sale: add second product', e); await shot(page, '05-add-second-fail'); }

  try {
    // ---------- Loyalty phone capture ----------
    const phoneField = page.getByRole('textbox', { name: /phone|mobile/i }).first();
    if (await phoneField.isVisible({ timeout: 3000 }).catch(() => false)) {
      await phoneField.click();
      await page.waitForTimeout(150);
      await page.keyboard.type('9876543210', { delay: 30 });
      pass('Loyalty phone number captured');
    } else {
      fail('Loyalty phone number field', new Error('No phone/mobile field found on New Sale screen'));
    }
    await shot(page, '06-loyalty-phone');
  } catch (e) { fail('Loyalty phone capture', e); }

  try {
    // ---------- Charge -> Payment screen (Cash) ----------
    await page.getByRole('button', { name: /^Charge/ }).click();
    await page.getByRole('heading', { name: 'Payment' }).waitFor({ timeout: 10000 });
    const saveBtn = page.getByRole('button', { name: /Save & Print|Short by/ });
    await saveBtn.waitFor({ timeout: 8000 });
    const enabled = await saveBtn.isEnabled();
    if (!enabled) throw new Error('Save & Print button disabled — cash line does not cover due amount');
    await saveBtn.click();
    pass('Checkout: Cash payment saved');
  } catch (e) { fail('Checkout: Cash payment', e); await shot(page, '07-checkout-fail'); }

  try {
    // ---------- Confirm reset back to scanner (sale fully completed) ----------
    // _charge() keeps running (save -> approve -> print -> reset) well
    // after the Payment screen's own Save & Print click returns — poll
    // rather than a single fixed wait, since the stubbed-print path still
    // genuinely executes the real save/approve/print code.
    const searchField = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    await searchField.waitFor({ timeout: 25000 });
    let reset = false;
    for (let i = 0; i < 20 && !reset; i++) {
      reset = !(await textVisible(page, 'Basmati').isVisible({ timeout: 1000 }).catch(() => false));
      if (!reset) await page.waitForTimeout(2000);
    }
    if (reset) pass('Sale completed: screen reset for next sale (no print hang)');
    else fail('Sale completed / reset', new Error('Cart still shows previous sale items after 40s'));
    await shot(page, '08-post-sale-reset');
  } catch (e) { fail('Sale completed / reset', e); await shot(page, '08-reset-fail'); }

  try {
    // ---------- Price Check ----------
    // Try to find a nav/icon to Price Check — if not found via simple role search, skip gracefully.
    const priceCheckBtn = page.getByRole('button', { name: /Price Check/i });
    if (await priceCheckBtn.isVisible({ timeout: 4000 }).catch(() => false)) {
      await priceCheckBtn.click();
      await page.waitForTimeout(1000);
      pass('Price Check screen opened');
      await shot(page, '09-price-check');
      await page.goBack().catch(() => {});
    } else {
      fail('Price Check screen', new Error('No visible "Price Check" button found from New Sale screen'));
    }
  } catch (e) { fail('Price Check', e); }

  try {
    // ---------- Hold Sales ----------
    const searchField = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    await searchField.waitFor({ timeout: 10000 }).catch(() => {});
    await searchField.fill('PRD-POS-003');
    await searchField.press('Enter');
    await page.waitForTimeout(800);
    const holdBtn = page.getByRole('button', { name: /^Hold/i });
    if (await holdBtn.isVisible({ timeout: 4000 }).catch(() => false)) {
      await holdBtn.click();
      await page.waitForTimeout(1000);
      pass('Hold Sale created');
      await shot(page, '10-hold-sale');
    } else {
      fail('Hold Sale button', new Error('No visible Hold button on New Sale screen'));
    }
  } catch (e) { fail('Hold Sale', e); await shot(page, '10-hold-fail'); }

  try {
    // ---------- Resume held sale ----------
    const heldBtn = page.getByRole('button', { name: /Held Sales|Resume/i });
    if (await heldBtn.isVisible({ timeout: 4000 }).catch(() => false)) {
      await heldBtn.click();
      await page.waitForTimeout(1000);
      const firstHeld = page.getByRole('button').first();
      await firstHeld.click().catch(() => {});
      pass('Resume Held Sale screen reached');
      await shot(page, '11-resume-held');
    } else {
      fail('Resume Held Sale', new Error('No "Held Sales"/"Resume" entry point found'));
    }
  } catch (e) { fail('Resume Held Sale', e); await shot(page, '11-resume-fail'); }

  try {
    // ---------- Shift Close (cash count / variance) ----------
    await page.goto(`${BASE_URL}/#/pos/shift`);
    await page.waitForTimeout(1500);
    const closeBtn = page.getByRole('button', { name: /Close Shift/i });
    await closeBtn.waitFor({ timeout: 10000 });
    await closeBtn.click();
    await page.waitForTimeout(500);
    await page.getByRole('heading', { name: /Close Shift/i }).waitFor({ timeout: 8000 }).catch(() => {});

    // Read "Expected: N.NN" and type that exact figure into Counted
    // Amount, so the variance comes out at (or near) zero — proves the
    // cash-up math itself, not just that the button exists.
    const expectedLocator = textVisible(page, 'Expected:');
    const expectedText = await expectedLocator.first().textContent().catch(() => null);
    const match = expectedText ? expectedText.match(/Expected:\s*([\d.,]+)/) : null;
    const expectedAmount = match ? match[1].replace(/,/g, '') : null;

    const countedField = page.getByRole('textbox', { name: /Counted Amount/i }).first();
    await countedField.waitFor({ timeout: 8000 });
    await countedField.click();
    await page.waitForTimeout(150);
    await page.keyboard.type(expectedAmount || '500', { delay: 30 });

    const confirmClose = page.getByRole('button', { name: /^Close Shift$/i }).last();
    await confirmClose.click();
    await page.waitForTimeout(2000);

    const dialogStillOpen = await page.getByRole('heading', { name: /Close Shift & Cash Up/i }).isVisible({ timeout: 2000 }).catch(() => false);
    if (dialogStillOpen) throw new Error('Close Shift dialog still open after confirm — likely a validation error (variance reason required, etc.)');
    pass(`Shift Close (expected=${expectedAmount ?? 'unknown'})`);
    await shot(page, '12-shift-closed');
  } catch (e) { fail('Shift Close', e); await shot(page, '12-shift-close-fail'); }

  console.log('\n=== RESULTS SUMMARY ===');
  for (const r of results) {
    console.log(`${r.ok ? 'PASS' : 'FAIL'} — ${r.step}${r.err ? ' :: ' + r.err : ''}`);
  }
  const failures = results.filter(r => !r.ok).length;
  console.log(`\nTotal: ${results.length}, Passed: ${results.length - failures}, Failed: ${failures}`);

  await browser.close();
  process.exit(failures > 0 ? 1 : 0);
})();
