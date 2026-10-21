const { Client } = require('pg');
require('./helpers/env');
(async () => {
  const client = new Client({
    connectionString: process.env.SAKAL_DEV_DB_URL,
    ssl: { rejectUnauthorized: false }
  });
  await client.connect();

  console.log('--- Step 1: register test tenant ---');
  const ts = Date.now();
  const reg = await client.query(`
    SELECT fn_register_client(
      p_business_name  := 'POS Test Mart',
      p_country        := 'India',
      p_contact_name   := 'POS Tester',
      p_email          := 'postest${ts}@example.com',
      p_phone          := '+911234567890',
      p_company_name   := 'POS Test Mart Pvt Ltd',
      p_company_short  := 'PTM',
      p_base_currency  := 'INR',
      p_local_currency := 'INR',
      p_location_name  := 'Main Store',
      p_location_short := 'MAIN',
      p_location_type  := 'STORE',
      p_admin_name     := 'POS Admin',
      p_admin_email    := 'posadmin${ts}@example.com',
      p_username       := 'posadmin',
      p_password       := 'TestPass123'
    ) as result
  `);
  const result = reg.rows[0].result;
  console.log('Registered:', result);

  console.log('\n--- Step 2: accounting setup ---');
  const setup = await client.query(`
    SELECT fn_complete_accounting_setup(
      p_client_id := $1, p_company_id := $2, p_accounting_std := 'INDIAN',
      p_fy_start_month := 1, p_fy_start_day := 1
    ) as result
  `, [result.client_id, result.company_id]);
  console.log('Accounting setup:', setup.rows[0].result);

  console.log('\nTENANT_JSON_START');
  console.log(JSON.stringify(result));
  console.log('TENANT_JSON_END');

  await client.end();
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
