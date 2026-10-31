const { chromium } = require('playwright');
require('./helpers/env');
const { enableSemantics, typeInto, dismissFirstLoginWelcomeIfPresent } = require('./helpers/flutter');
const tenant = require('./.test_tenant.json');
(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1600, height: 1100 } })).newPage();
  async function tryLogin() {
    await page.goto('http://localhost:8099/#/login');
    await enableSemantics(page);
    await typeInto(page, 'Email', tenant.adminEmail);
    await typeInto(page, 'Password', tenant.adminPassword);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.waitForTimeout(3500);
    await dismissFirstLoginWelcomeIfPresent(page);
    await page.waitForTimeout(2500);
  }
  try { await tryLogin(); } catch (e) { await tryLogin(); }
  await page.goto('http://localhost:8099/#/finance/bank-statement-formats');
  await page.waitForTimeout(5000);
  await page.mouse.click(1289, 28);
  await page.waitForTimeout(2500);

  await page.mouse.click(799, 234);
  await page.waitForTimeout(300);
  await page.keyboard.type('QA Main Bank USD CSV');
  await page.waitForTimeout(300);

  await page.mouse.click(799, 568);
  await page.waitForTimeout(300);
  await page.keyboard.type('Txn No');
  await page.waitForTimeout(300);

  await page.mouse.click(799, 624);
  await page.waitForTimeout(300);
  await page.keyboard.type('Date');
  await page.waitForTimeout(300);

  await page.mouse.click(799, 680);
  await page.waitForTimeout(300);
  await page.keyboard.type('Description');
  await page.waitForTimeout(300);

  await page.mouse.click(799, 736);
  await page.waitForTimeout(300);
  await page.keyboard.type('Debit');
  await page.waitForTimeout(300);

  await page.mouse.click(799, 792);
  await page.waitForTimeout(300);
  await page.keyboard.type('Credit');
  await page.waitForTimeout(300);

  await page.mouse.click(799, 848);
  await page.waitForTimeout(300);
  await page.keyboard.type('Balance');
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${__dirname}/screenshots/bsf-filled.png` });

  await page.mouse.click(990, 920);
  await page.waitForTimeout(3000);
  await page.screenshot({ path: `${__dirname}/screenshots/bsf-saved.png` });
  await browser.close();
})();
