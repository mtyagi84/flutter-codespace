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
  await page.goto('http://localhost:8099/#/sales/delivery-entry');
  await page.waitForTimeout(5000);
  await page.mouse.click(488, 91);
  await page.waitForTimeout(500);
  await page.mouse.click(488, 91);
  await page.waitForTimeout(600);
  await page.keyboard.type('SI/MAIN/2026/00003');
  await page.waitForTimeout(1500);
  await page.mouse.click(500, 123);
  await page.waitForTimeout(2500);
  await page.mouse.click(877, 377);
  await page.waitForTimeout(300);
  await page.keyboard.press('Control+A');
  await page.keyboard.type('1');
  await page.keyboard.press('Tab');
  await page.waitForTimeout(500);
  await page.getByText('Save Draft', { exact: false }).first().click();
  await page.waitForTimeout(3000);
  const approveBtn = page.getByText('Approve', { exact: true });
  if (await approveBtn.isVisible({ timeout: 3000 }).catch(()=>false)) {
    await approveBtn.click();
    await page.waitForTimeout(800);
    const confirm = page.getByText('Approve', { exact: true }).last();
    if (await confirm.isVisible().catch(() => false)) await confirm.click().catch(() => {});
    await page.waitForTimeout(3500);
  }
  await page.screenshot({ path: `${__dirname}/screenshots/dlv2-approved.png` });
  await browser.close();
})();
