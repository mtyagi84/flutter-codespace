const { Client } = require('pg');
require('./helpers/env');

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const COMPANY_ID = 'e73b9365-68d4-4f56-9398-0e683560e9cc';
const LOCATION_ID = 'e55f8e79-bf0f-464a-a6bf-b8db7f4f9556';
const ADMIN_USER_ID = '64580681-f840-43a3-8cea-dd97247d576d';
const CCY_ID = '59a096c5-4dcd-4d31-bb49-87bb7e1be805';

function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

(async () => {
  const client = new Client({
    connectionString: process.env.SAKAL_DEV_DB_URL,
    ssl: { rejectUnauthorized: false }
  });
  await client.connect();

  async function nextCode(parentId) {
    const r = await client.query(`SELECT fn_next_account_code($1,$2,$3) as code`, [CLIENT_ID, COMPANY_ID, parentId]);
    return r.rows[0].code;
  }
  async function findParent(code) {
    const r = await client.query(`SELECT id FROM rim_accounts WHERE client_id=$1 AND company_id=$2 AND account_code=$3`, [CLIENT_ID, COMPANY_ID, code]);
    if (!r.rows.length) throw new Error(`Parent account ${code} not found`);
    return r.rows[0].id;
  }
  async function createAccount(parentCode, name, nature, std) {
    const parentId = await findParent(parentCode);
    const code = await nextCode(parentId);
    const id = uuid();
    await client.query(`
      INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, account_currency_id, is_system_fixed, accounting_std, is_active, is_deleted, created_by, updated_by)
      VALUES ($1,$2,$3,$4,$5,$6,true,$7,$8,false,$9,true,false,$10,$10)
    `, [id, CLIENT_ID, COMPANY_ID, code, name, parentId, nature, CCY_ID, std, ADMIN_USER_ID]);
    console.log(`Created account [${code}] ${name} (${nature})`);
    return id;
  }

  const stdRes = await client.query(`SELECT accounting_std FROM rim_accounting_setup WHERE client_id=$1 AND company_id=$2`, [CLIENT_ID, COMPANY_ID]);
  const STD = stdRes.rows[0].accounting_std;
  console.log('Accounting std:', STD);

  console.log('\n--- Cash Customer + Cash Account + Quick Invoice Setup ---');
  const cashCustomerId = await createAccount('1120', 'POS Cash Customer', 'Customer', STD);
  const cashAccountId  = await createAccount('1110', 'POS Cash Drawer', 'Cash', STD);

  const existingQIS = await client.query(`SELECT id FROM ric_user_quick_invoice_setup WHERE client_id=$1 AND company_id=$2 AND user_id=$3`, [CLIENT_ID, COMPANY_ID, ADMIN_USER_ID]);
  if (existingQIS.rows.length === 0) {
    await client.query(`
      INSERT INTO ric_user_quick_invoice_setup (id, client_id, company_id, user_id, location_id, cash_customer_id, local_cash_account_id, base_cash_account_id, is_active, is_deleted)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,true,false)
    `, [uuid(), CLIENT_ID, COMPANY_ID, ADMIN_USER_ID, LOCATION_ID, cashCustomerId, cashAccountId, cashAccountId]);
    console.log('Quick Invoice Setup created.');
  } else {
    console.log('Quick Invoice Setup already exists.');
  }

  console.log('\n--- Non-cash tender clearing/liability accounts + links ---');
  const tenderLinks = [
    { key: 'CARD_CLEARING_ACCOUNT', name: 'Card Clearing Account', parent: '1110', nature: 'General' },
    { key: 'MOBILE_MONEY_CLEARING_ACCOUNT', name: 'Mobile Money Clearing Account', parent: '1110', nature: 'General' },
    { key: 'VOUCHER_CLEARING_ACCOUNT', name: 'Voucher Clearing Account', parent: '1110', nature: 'General' },
    { key: 'GIFT_CARD_LIABILITY_ACCOUNT', name: 'Gift Card Liability Account', parent: '2170', nature: 'General' },
    { key: 'STORE_CREDIT_LIABILITY_ACCOUNT', name: 'Store Credit Liability Account', parent: '2170', nature: 'General' },
  ];
  for (const t of tenderLinks) {
    const existingLink = await client.query(`
      SELECT d.account_id FROM rim_account_link_defaults d
      JOIN rim_account_link_types lt ON lt.id = d.link_type_id
      WHERE d.client_id=$1 AND d.company_id=$2 AND lt.link_key=$3 AND d.link_key_id IS NULL
    `, [CLIENT_ID, COMPANY_ID, t.key]);
    if (existingLink.rows.length) { console.log(`${t.key} already linked.`); continue; }

    const accId = await createAccount(t.parent, t.name, t.nature, STD);
    const linkTypeRes = await client.query(`SELECT id FROM rim_account_link_types WHERE link_key=$1`, [t.key]);
    const linkTypeId = linkTypeRes.rows[0].id;

    await client.query(`
      INSERT INTO rim_account_link_setup (id, client_id, company_id, link_type_id, link_type)
      VALUES ($1,$2,$3,$4,'COMPANY')
      ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING
    `, [uuid(), CLIENT_ID, COMPANY_ID, linkTypeId]);
    await client.query(`
      INSERT INTO rim_account_link_defaults (id, client_id, company_id, link_type_id, link_key_id, account_id, is_active, is_deleted)
      VALUES ($1,$2,$3,$4,NULL,$5,true,false)
    `, [uuid(), CLIENT_ID, COMPANY_ID, linkTypeId, accId]);
    console.log(`${t.key} -> linked to new account.`);
  }

  console.log('\nSETUP2_JSON_START');
  console.log(JSON.stringify({ cashCustomerId, cashAccountId, STD }));
  console.log('SETUP2_JSON_END');

  await client.end();
})().catch(e => { console.error('ERROR:', e.message, e.detail || ''); process.exit(1); });
