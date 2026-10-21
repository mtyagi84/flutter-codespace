const { Client } = require('pg');
require('./helpers/env');

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const COMPANY_ID = 'e73b9365-68d4-4f56-9398-0e683560e9cc';
const LOCATION_ID = 'e55f8e79-bf0f-464a-a6bf-b8db7f4f9556';
const ADMIN_USER_ID = '64580681-f840-43a3-8cea-dd97247d576d';

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

  console.log('--- PIN for admin (also acting as cashier) ---');
  await client.query(`SELECT fn_set_user_pin($1,$2,$3,$4)`, [CLIENT_ID, COMPANY_ID, ADMIN_USER_ID, '1234']);
  console.log('PIN set to 1234.');

  console.log('\n--- POS terminal + device + binding + terminal access ---');
  const TERMINAL_ID = uuid();
  await client.query(`
    INSERT INTO ric_pos_terminals (id, client_id, company_id, location_id, terminal_code, terminal_name, receipt_paper_profile, is_active, is_deleted, created_by)
    VALUES ($1,$2,$3,$4,'T1','Till 1','RECEIPT_80MM',true,false,$5)
  `, [TERMINAL_ID, CLIENT_ID, COMPANY_ID, LOCATION_ID, ADMIN_USER_ID]);
  console.log('Terminal T1 created:', TERMINAL_ID);

  const DEVICE_UID = uuid();
  const devRes = await client.query(`
    SELECT fn_pos_register_device($1,$2,$3,$4,'Test Browser','WEB') as device_id
  `, [CLIENT_ID, COMPANY_ID, LOCATION_ID, DEVICE_UID]);
  const DEVICE_ID = devRes.rows[0].device_id;
  console.log('Device registered:', DEVICE_ID, 'uid:', DEVICE_UID);

  await client.query(`SELECT fn_bind_pos_device($1,$2)`, [DEVICE_ID, TERMINAL_ID]);
  console.log('Device bound to terminal.');

  await client.query(`
    INSERT INTO ric_user_pos_terminal_access (id, client_id, company_id, user_id, terminal_id, access_type, is_active, is_deleted, created_by)
    VALUES ($1,$2,$3,$4,$5,'PERMANENT',true,false,$6)
    ON CONFLICT (client_id, company_id, user_id, terminal_id) DO NOTHING
  `, [uuid(), CLIENT_ID, COMPANY_ID, ADMIN_USER_ID, TERMINAL_ID, ADMIN_USER_ID]);
  console.log('Terminal access granted to admin.');

  console.log('\n--- POS Scheme: 10% off on product 1 (Basmati Rice) ---');
  const prodRes = await client.query(`SELECT id, product_name FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-001'`, [CLIENT_ID, COMPANY_ID]);
  const SCHEME_PRODUCT_ID = prodRes.rows[0].id;
  const SCHEME_ID = uuid();
  await client.query(`
    INSERT INTO rim_pos_schemes (id, client_id, company_id, scheme_code, scheme_name, scheme_type, scope, priority, is_stackable, is_active, is_deleted)
    VALUES ($1,$2,$3,'SCH-001','10% off Basmati Rice','PERCENT_OFF','PRODUCT',100,false,true,false)
  `, [SCHEME_ID, CLIENT_ID, COMPANY_ID]);
  await client.query(`
    INSERT INTO rim_pos_scheme_rules (id, client_id, company_id, scheme_id, applies_to_product_id, min_qty, benefit_type, benefit_value, is_deleted)
    VALUES ($1,$2,$3,$4,$5,1,'PERCENT',10,false)
  `, [uuid(), CLIENT_ID, COMPANY_ID, SCHEME_ID, SCHEME_PRODUCT_ID]);
  console.log('Scheme created: 10% off', prodRes.rows[0].product_name);

  console.log('\n--- Loyalty Program ---');
  const LOYALTY_ID = uuid();
  await client.query(`
    INSERT INTO rim_loyalty_programs (id, client_id, company_id, program_name, points_per_amount, point_value_in_base_currency, min_points_to_redeem, max_redemption_percent_of_bill, earn_basis, is_active, is_deleted)
    VALUES ($1,$2,$3,'POS Test Loyalty',1,0.5,10,50,'POST_DISCOUNT',true,false)
  `, [LOYALTY_ID, CLIENT_ID, COMPANY_ID]);
  console.log('Loyalty program created: 1 point per 1 INR spent, 1 point = 0.5 INR, min 10 pts to redeem, max 50% of bill.');

  console.log('\nSETUP3_JSON_START');
  console.log(JSON.stringify({ TERMINAL_ID, DEVICE_UID, DEVICE_ID, SCHEME_ID, SCHEME_PRODUCT_ID, LOYALTY_ID }));
  console.log('SETUP3_JSON_END');

  await client.end();
})().catch(e => { console.error('ERROR:', e.message, e.detail || ''); process.exit(1); });
