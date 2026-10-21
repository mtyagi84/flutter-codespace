const { Client } = require('pg');
require('./helpers/env');

const CLIENT_ID = '0559cd94-5692-4094-b62a-29282fa7f3e2';
const COMPANY_ID = 'e73b9365-68d4-4f56-9398-0e683560e9cc';
const LOCATION_ID = 'e55f8e79-bf0f-464a-a6bf-b8db7f4f9556';

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

  const u = await client.query(`SELECT id, full_name, username FROM rim_users WHERE client_id=$1 AND company_id=$2 LIMIT 1`, [CLIENT_ID, COMPANY_ID]);
  const ADMIN_USER_ID = u.rows[0].id;
  console.log('Admin user:', u.rows[0]);

  const comp = await client.query(`SELECT base_currency, local_currency FROM ric_companies WHERE id=$1`, [COMPANY_ID]);
  const BASE_CCY = comp.rows[0].base_currency;
  const ccy = await client.query(`SELECT id FROM rim_currencies WHERE client_id=$1 AND company_id=$2 AND currency_id=$3`, [CLIENT_ID, COMPANY_ID, BASE_CCY]);
  const CCY_ID = ccy.rows[0].id;
  console.log('Base currency:', BASE_CCY, CCY_ID);

  // --- UOM (Piece) — type_key is 'UNIT' not 'UOM' ---
  const uomType = await client.query(`SELECT id FROM rim_common_master_types WHERE type_key='UNIT'`);
  const UOM_TYPE_ID = uomType.rows[0].id;
  let uomRow = await client.query(`SELECT id FROM rim_common_masters WHERE client_id=$1 AND company_id=$2 AND type_id=$3 AND description='Piece'`, [CLIENT_ID, COMPANY_ID, UOM_TYPE_ID]);
  let UOM_ID;
  if (uomRow.rows.length) { UOM_ID = uomRow.rows[0].id; }
  else {
    UOM_ID = uuid();
    await client.query(`INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, is_active, is_deleted) VALUES ($1,$2,$3,$4,'Piece',true,false)`, [UOM_ID, CLIENT_ID, COMPANY_ID, UOM_TYPE_ID]);
  }
  console.log('UOM_ID:', UOM_ID);

  // --- Item Category ---
  let catRow = await client.query(`SELECT id FROM rim_item_categories WHERE client_id=$1 AND company_id=$2 AND category_name='General' AND parent_id IS NULL`, [CLIENT_ID, COMPANY_ID]);
  let CATEGORY_ID;
  if (catRow.rows.length) { CATEGORY_ID = catRow.rows[0].id; }
  else {
    CATEGORY_ID = uuid();
    await client.query(`INSERT INTO rim_item_categories (id, client_id, company_id, category_name, parent_id, level_no, is_active, is_deleted) VALUES ($1,$2,$3,'General',NULL,1,true,false)`, [CATEGORY_ID, CLIENT_ID, COMPANY_ID]);
  }
  console.log('CATEGORY_ID:', CATEGORY_ID);

  // --- 10 products ---
  console.log('\n--- Creating 10 products ---');
  const productDefs = [
    'Basmati Rice 5kg', 'Sunflower Oil 1L', 'Toor Dal 1kg', 'Wheat Flour 5kg', 'Sugar 1kg',
    'Tea Powder 500g', 'Salt 1kg', 'Milk Powder 400g', 'Biscuits Pack', 'Soap Bar'
  ];
  const products = [];
  for (let i = 0; i < productDefs.length; i++) {
    const existing = await client.query(`SELECT id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code=$3`, [CLIENT_ID, COMPANY_ID, `PRD-POS-${String(i + 1).padStart(3, '0')}`]);
    if (existing.rows.length) { products.push({ id: existing.rows[0].id, code: `PRD-POS-${String(i + 1).padStart(3, '0')}`, name: productDefs[i], cost: 50 + i * 15 }); continue; }
    const id = uuid();
    const code = `PRD-POS-${String(i + 1).padStart(3, '0')}`;
    const cost = 50 + i * 15;
    await client.query(`
      INSERT INTO rim_products (
        id, client_id, company_id, product_code, product_name, product_nature,
        category_id, base_uom_id, standard_cost, allowed_cost_variance,
        cost_currency_id, tracking_type, is_active, is_scalable, flags, lead_time_days
      ) VALUES ($1,$2,$3,$4,$5,'TRADING',$6,$7,$8,0,$9,'NONE',true,false,
        '{"is_saleable":true,"is_purchasable":true}'::jsonb, 0)
    `, [id, CLIENT_ID, COMPANY_ID, code, productDefs[i], CATEGORY_ID, UOM_ID, cost, CCY_ID]);
    products.push({ id, code, name: productDefs[i], cost });
  }
  console.log(`${products.length} products ready.`);

  // --- Price Master batch: selling price = cost * 1.4, rounded ---
  console.log('\n--- Price Master batch ---');
  const lines = products.map((p, i) => ({
    serial_no: i + 1,
    product_id: p.id,
    uom_id: UOM_ID,
    uom_conversion_factor: 1,
    cost_price: p.cost,
    margin_percent: 40,
    selling_price: Math.round(p.cost * 1.4),
    is_tax_inclusive: false,
  }));
  const header = {
    client_id: CLIENT_ID, company_id: COMPANY_ID, location_id: LOCATION_ID,
    entry_date: '2026-10-19',
    price_type: 'GENERIC', effective_date: '2026-01-01',
    price_currency_id: CCY_ID, rate_to_base: 1, rate_to_local: 1,
  };
  const pmRes = await client.query(`SELECT fn_save_price_master_batch($1::jsonb, $2::jsonb, $3::uuid) as entry_no`,
    [JSON.stringify(header), JSON.stringify(lines), ADMIN_USER_ID]);
  const PM_ENTRY_NO = pmRes.rows[0].entry_no;
  console.log('Price Master entry:', PM_ENTRY_NO);
  await client.query(`SELECT fn_approve_price_master_batch($1,$2,$3,$4,$5)`,
    [CLIENT_ID, COMPANY_ID, PM_ENTRY_NO, header.entry_date, ADMIN_USER_ID]);
  console.log('Price Master batch approved.');

  console.log('\nPRODUCTS_JSON_START');
  console.log(JSON.stringify({ products, UOM_ID, CATEGORY_ID, ADMIN_USER_ID, CCY_ID }));
  console.log('PRODUCTS_JSON_END');

  await client.end();
})().catch(e => { console.error('ERROR:', e.message, e.detail || '', e.stack); process.exit(1); });
