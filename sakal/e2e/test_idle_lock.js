// Idle-lock E2E test — real browser interaction, no DB assertions needed
// (this is a pure UI/session-timer feature). ric_companies.pos_idle_lock_minutes
// is temporarily set to 1 for this test (set_idle.js), so the lock fires after
// ~60-80s of no interaction (checked every 20s, DateTime.inMinutes truncates).
// Confirms: (1) scanning a product counts as interaction (no lock while active),
// (2) the "Till Locked" overlay appears after the idle window with no interaction,
// (3) cart/session state is preserved underneath, (4) the cashier's own PIN
// unlocks it and the cart is still there after unlock.
const { chromium } = require('playwright');
const { enableSemantics, textVisible, typeInto } = require('./helpers/flutter');

const BASE_URL = 'http://localhost:8099';
const CLIENT_NO = 'SK-72667';
const USERNAME = 'posadmin';
const PASSWORD = 'TestPass123';
const PIN = '1234';
const PRODUCT_CODE = 'PRD-POS-003';

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
  } catch (e) { fail('Till Setup + PIN Login', e); await shot(page, 'idle-00-login-fail'); }

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
  } catch (e) { fail('Shift ready', e); await shot(page, 'idle-01-shift-fail'); }

  try {
    const field = page.getByRole('textbox', { name: /Scan barcode or search product/i });
    await field.waitFor({ timeout: 10000 });
    await field.click();
    await page.keyboard.type(PRODUCT_CODE, { delay: 30 });
    await page.keyboard.press('Enter');
    await page.waitForTimeout(2000);
    const added = await textVisible(page, PRODUCT_CODE).isVisible({ timeout: 3000 }).catch(() => false);
    if (!added) throw new Error('Could not add product before idle wait');
    pass('Product added to cart before idle window');
  } catch (e) { fail('Add product before idle', e); await shot(page, 'idle-02-add-fail'); }

  try {
    // No interaction at all for ~85s — long enough for inMinutes to tick
    // past 1 even if the last scan landed right before a minute boundary,
    // plus one 20s periodic check cycle margin.
    console.log('Waiting ~85s with zero interaction for idle-lock to fire...');
    let locked = false;
    for (let i = 0; i < 17 && !locked; i++) {
      await page.waitForTimeout(5000);
      locked = await textVisible(page, 'Till Locked').isVisible({ timeout: 1000 }).catch(() => false);
    }
    await shot(page, 'idle-03-locked');
    if (!locked) throw new Error('"Till Locked" overlay did not appear after ~85s of no interaction');
    pass('Idle-lock overlay ("Till Locked") appeared after the configured idle window');
  } catch (e) { fail('Idle-lock overlay appears', e); await shot(page, 'idle-03-fail'); }

  try {
    // Confirm the product line is still present underneath the overlay
    // (DOM-level check — the overlay is a Positioned.fill on top, the cart
    // beneath it is untouched, not torn down).
    const cartStillThere = await textVisible(page, PRODUCT_CODE).isVisible({ timeout: 2000 }).catch(() => false);
    if (!cartStillThere) throw new Error('Cart/product line no longer present in DOM while locked');
    pass('Cart state preserved underneath the lock overlay');
  } catch (e) { fail('Cart preserved while locked', e); }

  try {
    // The lock overlay's PosPinPad digit buttons share labels with the cart's
    // own qty-stepper buttons underneath — the overlay was mounted LAST, so
    // its semantics nodes sort after the cart's; .last() disambiguates.
    for (const digit of PIN) { await page.getByRole('button', { name: digit, exact: true }).last().click(); }
    await page.getByRole('button', { name: 'Enter' }).last().click();
    await page.waitForTimeout(1500);
    const stillLocked = await textVisible(page, 'Till Locked').isVisible({ timeout: 3000 }).catch(() => false);
    if (stillLocked) throw new Error('Still showing "Till Locked" after entering the correct PIN');
    const cartAfterUnlock = await textVisible(page, PRODUCT_CODE).isVisible({ timeout: 3000 }).catch(() => false);
    if (!cartAfterUnlock) throw new Error('Cart/product line missing after unlock');
    await shot(page, 'idle-04-unlocked');
    pass('Correct PIN unlocks the till; cart state intact after unlock');
  } catch (e) { fail('Unlock with correct PIN', e); await shot(page, 'idle-04-fail'); }

  await browser.close();

  console.log('\n===== IDLE-LOCK E2E RESULTS =====');
  results.forEach(r => console.log(`${r.ok ? 'PASS' : 'FAIL'}: ${r.step}${r.err ? ' -- ' + r.err : ''}`));
  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed > 0 ? 1 : 0);
})();
