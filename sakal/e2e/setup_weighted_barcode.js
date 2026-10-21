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
  const client = new Client({ connectionString: process.env.SAKAL_DEV_DB_URL, ssl: { rejectUnauthorized: false } });
  await client.connect();
  const today = new Date().toISOString().slice(0, 10);

  await client.query(`UPDATE ric_companies SET weighted_barcode_prefix_from='20', weighted_barcode_prefix_to='29', weighted_barcode_format='WEIGHT_EMBEDDED' WHERE id=$1`, [COMPANY_ID]);
  console.log('Company weighted-barcode config set: prefix 20-29, WEIGHT_EMBEDDED.');

  // _parseWeightedBarcode matches the embedded 5-digit code against
  // product_code EXACTLY -- needs a short numeric product_code.
  let wProdId;
  const existing = await client.query(`SELECT id, base_uom_id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='00099'`, [CLIENT_ID, COMPANY_ID]);
  if (existing.rows.length) {
    wProdId = existing.rows[0].id;
  } else {
    const ref = await client.query(`SELECT category_id, base_uom_id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-001'`, [CLIENT_ID, COMPANY_ID]);
    wProdId = uuid();
    await client.query(
      `INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, product_nature, category_id, base_uom_id, tracking_type, is_active, is_deleted, created_by, updated_by)
       VALUES ($1,$2,$3,'00099','Loose Tomatoes (Weighed)','TRADING',$4,$5,'NONE',true,false,$6,$6)`,
      [wProdId, CLIENT_ID, COMPANY_ID, ref.rows[0].category_id, ref.rows[0].base_uom_id, ADMIN_USER_ID]
    );
    await client.query(`INSERT INTO rim_product_uom (id, client_id, company_id, product_id, uom_id, conversion_factor, is_base_uom) VALUES ($1,$2,$3,$4,$5,1,true)`, [uuid(), CLIENT_ID, COMPANY_ID, wProdId, ref.rows[0].base_uom_id]);
  }
  const wUom = (await client.query(`SELECT base_uom_id FROM rim_products WHERE id=$1`, [wProdId])).rows[0].base_uom_id;
  const compCcy = await client.query(`SELECT base_currency FROM ric_companies WHERE id=$1`, [COMPANY_ID]);
  const priceCcy = await client.query(`SELECT id FROM rim_currencies WHERE company_id=$1 AND currency_id=$2`, [COMPANY_ID, compCcy.rows[0].base_currency]);
  const pmHeader = await client.query(`SELECT fn_save_price_master_batch($1::jsonb, $2::jsonb, $3::uuid) as entry_no`, [
    JSON.stringify({ client_id: CLIENT_ID, company_id: COMPANY_ID, location_id: LOCATION_ID, entry_date: today, effective_date: today, price_type: 'GENERIC', price_currency_id: priceCcy.rows[0].id }),
    JSON.stringify([{ serial_no: 1, product_id: wProdId, uom_id: wUom, selling_price: 80, is_tax_inclusive: false }]), // 80/kg
    ADMIN_USER_ID,
  ]);
  await client.query(`SELECT fn_approve_price_master_batch($1,$2,$3,$4,$5)`, [CLIENT_ID, COMPANY_ID, pmHeader.rows[0].entry_no, today, ADMIN_USER_ID]);
  await client.query(
    `SELECT fn_post_stock_movement($1,$2,$3,$4,$5,'OPENING_STOCK',50,40.00,NULL,NULL,NULL,NULL,'TEST_SETUP','POS-WEIGHTED-SETUP',$5,$6,1,NULL)`,
    [CLIENT_ID, COMPANY_ID, LOCATION_ID, wProdId, today, ADMIN_USER_ID]
  );
  console.log('Weighted product created: code=00099, priced 80/kg, 50kg in stock.');
  console.log('Test barcode (0.5kg = 500g): 2000099005000');

  await client.end();
})().catch(e => { console.error('ERR', e.message, e.detail); process.exit(1); });
