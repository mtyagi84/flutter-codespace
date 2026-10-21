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

  // 1. Sales controls for POS Admin: can discount up to 5% without override,
  // can override price. Low cap so a bigger discount triggers the PIN flow.
  const existingCtrl = await client.query(`SELECT id FROM ric_user_sales_controls WHERE client_id=$1 AND company_id=$2 AND user_id=$3`, [CLIENT_ID, COMPANY_ID, ADMIN_USER_ID]);
  if (existingCtrl.rows.length) {
    await client.query(`UPDATE ric_user_sales_controls SET can_override_price=true, can_give_discount=true, max_discount_percent=5 WHERE id=$1`, [existingCtrl.rows[0].id]);
  } else {
    await client.query(
      `INSERT INTO ric_user_sales_controls (id, client_id, company_id, user_id, can_override_price, can_give_discount, max_discount_percent, can_view_cost_price, is_deleted)
       VALUES ($1,$2,$3,$4,true,true,5,true,false)`,
      [uuid(), CLIENT_ID, COMPANY_ID, ADMIN_USER_ID]
    );
  }
  console.log('POS Admin sales controls: can discount up to 5%% without override.');

  // 2. A "Supervisor" user with higher discount rights, for the PIN-override flow.
  let supervisorId;
  const existingSup = await client.query(`SELECT id FROM rim_users WHERE client_id=$1 AND username='possupervisor'`, [CLIENT_ID]);
  if (existingSup.rows.length) {
    supervisorId = existingSup.rows[0].id;
    console.log('Reusing existing supervisor user:', supervisorId);
  } else {
    supervisorId = uuid();
    const roleRes = await client.query(`SELECT id FROM rim_user_roles WHERE client_id=$1 LIMIT 1`, [CLIENT_ID]).catch(() => ({ rows: [] }));
    await client.query(
      `INSERT INTO rim_users (id, client_id, company_id, username, email, full_name, password_hash, is_active, is_deleted, must_change_password)
       VALUES ($1,$2,$3,'possupervisor','possupervisor@example.com','POS Supervisor', crypt('Sup3rvisor!',gen_salt('bf')), true, false, false)`,
      [supervisorId, CLIENT_ID, COMPANY_ID]
    );
    console.log('Created supervisor user:', supervisorId);
  }
  // Supervisor PIN
  await client.query(`SELECT fn_set_user_pin($1,$2,$3,$4)`, [CLIENT_ID, COMPANY_ID, supervisorId, '9999']);
  console.log('Supervisor PIN set to 9999.');
  // Supervisor sales controls: can discount up to 50%
  const existingSupCtrl = await client.query(`SELECT id FROM ric_user_sales_controls WHERE client_id=$1 AND company_id=$2 AND user_id=$3`, [CLIENT_ID, COMPANY_ID, supervisorId]);
  if (existingSupCtrl.rows.length) {
    await client.query(`UPDATE ric_user_sales_controls SET can_override_price=true, can_give_discount=true, max_discount_percent=50 WHERE id=$1`, [existingSupCtrl.rows[0].id]);
  } else {
    await client.query(
      `INSERT INTO ric_user_sales_controls (id, client_id, company_id, user_id, can_override_price, can_give_discount, max_discount_percent, can_view_cost_price, is_deleted)
       VALUES ($1,$2,$3,$4,true,true,50,true,false)`,
      [uuid(), CLIENT_ID, COMPANY_ID, supervisorId]
    );
  }
  console.log('Supervisor can discount up to 50%%.');

  // 3. Age-restriction flag type + set true on PRD-POS-001 (Basmati Rice -- harmless choice, just for the guard test)
  let ageFlagExists = await client.query(`SELECT flag_key FROM rim_product_flag_types WHERE company_id=$1 AND flag_key='is_age_restricted'`, [COMPANY_ID]);
  if (!ageFlagExists.rows.length) {
    await client.query(
      `INSERT INTO rim_product_flag_types (id, client_id, company_id, flag_key, flag_label, default_value, sort_order, is_active)
       VALUES ($1,$2,$3,'is_age_restricted','Age Restricted',false,10,true)`,
      [uuid(), CLIENT_ID, COMPANY_ID]
    );
    console.log('Created is_age_restricted flag type.');
  }
  const ageProd = await client.query(`SELECT id, flags FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-006'`, [CLIENT_ID, COMPANY_ID]);
  const ageProdId = ageProd.rows[0].id;
  const newFlags = { ...(ageProd.rows[0].flags || {}), is_age_restricted: true };
  await client.query(`UPDATE rim_products SET flags=$1 WHERE id=$2`, [JSON.stringify(newFlags), ageProdId]);
  console.log('PRD-POS-006 marked age-restricted.');

  // 4. Min selling price floor on PRD-POS-007 (priced at 196; floor set to 190 so a >3% discount trips it)
  const minPriceProd = await client.query(`SELECT id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-007'`, [CLIENT_ID, COMPANY_ID]);
  await client.query(`UPDATE rim_products SET min_selling_price=190 WHERE id=$1`, [minPriceProd.rows[0].id]);
  console.log('PRD-POS-007 min_selling_price set to 190 (priced at 196).');

  // 5. A batch-tracked product with real stock, for FEFO auto-allocation test.
  let batchProdId;
  const existingBatchProd = await client.query(`SELECT id, base_uom_id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-BATCH'`, [CLIENT_ID, COMPANY_ID]);
  if (existingBatchProd.rows.length) {
    batchProdId = existingBatchProd.rows[0].id;
    console.log('Reusing existing batch-tracked product:', batchProdId);
  } else {
    const ref = await client.query(`SELECT category_id, base_uom_id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-001'`, [CLIENT_ID, COMPANY_ID]);
    batchProdId = uuid();
    await client.query(
      `INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, product_nature, category_id, base_uom_id, tracking_type, is_active, is_deleted, created_by, updated_by)
       VALUES ($1,$2,$3,'PRD-POS-BATCH','Tracked Test Item (Batch)','TRADING',$4,$5,'BATCH_WITH_EXPIRY',true,false,$6,$6)`,
      [batchProdId, CLIENT_ID, COMPANY_ID, ref.rows[0].category_id, ref.rows[0].base_uom_id, ADMIN_USER_ID]
    );
    await client.query(`INSERT INTO rim_product_uom (id, client_id, company_id, product_id, uom_id, conversion_factor, is_base_uom) VALUES ($1,$2,$3,$4,$5,1,true)`, [uuid(), CLIENT_ID, COMPANY_ID, batchProdId, ref.rows[0].base_uom_id]);
    console.log('Created batch-tracked product:', batchProdId);
  }
  // Price it at 100
  const bprod = await client.query(`SELECT base_uom_id FROM rim_products WHERE id=$1`, [batchProdId]);
  const compCcy = await client.query(`SELECT base_currency FROM ric_companies WHERE id=$1`, [COMPANY_ID]);
  const priceCcy = await client.query(`SELECT id FROM rim_currencies WHERE company_id=$1 AND currency_id=$2`, [COMPANY_ID, compCcy.rows[0].base_currency]);
  const pmHeader = await client.query(`SELECT fn_save_price_master_batch($1::jsonb, $2::jsonb, $3::uuid) as entry_no`, [
    JSON.stringify({ client_id: CLIENT_ID, company_id: COMPANY_ID, location_id: LOCATION_ID, entry_date: today, effective_date: today, price_type: 'GENERIC', price_currency_id: priceCcy.rows[0].id }),
    JSON.stringify([{ serial_no: 1, product_id: batchProdId, uom_id: bprod.rows[0].base_uom_id, selling_price: 100, is_tax_inclusive: false }]),
    ADMIN_USER_ID,
  ]);
  await client.query(`SELECT fn_approve_price_master_batch($1,$2,$3,$4,$5)`, [CLIENT_ID, COMPANY_ID, pmHeader.rows[0].entry_no, today, ADMIN_USER_ID]);
  console.log('Batch product priced at 100.');
  // Stock it with 2 real batches (different expiry so FEFO has something to choose between)
  await client.query(
    `SELECT fn_post_stock_movement($1,$2,$3,$4,$5,'OPENING_STOCK',20,60.00,NULL,'BATCH-A','2027-01-15',NULL,'TEST_SETUP','POS-BATCH-SETUP',$5,$6,1,NULL)`,
    [CLIENT_ID, COMPANY_ID, LOCATION_ID, batchProdId, today, ADMIN_USER_ID]
  );
  await client.query(
    `SELECT fn_post_stock_movement($1,$2,$3,$4,$5,'OPENING_STOCK',15,60.00,NULL,'BATCH-B','2026-12-01',NULL,'TEST_SETUP','POS-BATCH-SETUP',$5,$6,1,NULL)`,
    [CLIENT_ID, COMPANY_ID, LOCATION_ID, batchProdId, today, ADMIN_USER_ID]
  );
  console.log('Stocked 2 batches: BATCH-A (expiry 2027-01-15, qty 20), BATCH-B (expiry 2026-12-01 -- earlier, should be FEFO-picked first, qty 15).');

  // 6. PREASSEMBLED bundle: a bundle product that itself carries real stock
  // (assembled ahead of time via Stock Adjustment) -- no auto-consumption.
  let preassembledProductId;
  const existingPre = await client.query(`SELECT id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-PREASSEMBLED'`, [CLIENT_ID, COMPANY_ID]);
  if (existingPre.rows.length) {
    preassembledProductId = existingPre.rows[0].id;
  } else {
    const ref2 = await client.query(`SELECT category_id, base_uom_id FROM rim_products WHERE client_id=$1 AND company_id=$2 AND product_code='PRD-POS-001'`, [CLIENT_ID, COMPANY_ID]);
    preassembledProductId = uuid();
    await client.query(
      `INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, product_nature, category_id, base_uom_id, tracking_type, is_active, is_deleted, created_by, updated_by)
       VALUES ($1,$2,$3,'PRD-POS-PREASSEMBLED','Gift Hamper (Preassembled)','TRADING',$4,$5,'NONE',true,false,$6,$6)`,
      [preassembledProductId, CLIENT_ID, COMPANY_ID, ref2.rows[0].category_id, ref2.rows[0].base_uom_id, ADMIN_USER_ID]
    );
    await client.query(`INSERT INTO rim_product_uom (id, client_id, company_id, product_id, uom_id, conversion_factor, is_base_uom) VALUES ($1,$2,$3,$4,$5,1,true)`, [uuid(), CLIENT_ID, COMPANY_ID, preassembledProductId, ref2.rows[0].base_uom_id]);
  }
  const preUom = (await client.query(`SELECT base_uom_id FROM rim_products WHERE id=$1`, [preassembledProductId])).rows[0].base_uom_id;
  const pmHeader2 = await client.query(`SELECT fn_save_price_master_batch($1::jsonb, $2::jsonb, $3::uuid) as entry_no`, [
    JSON.stringify({ client_id: CLIENT_ID, company_id: COMPANY_ID, location_id: LOCATION_ID, entry_date: today, effective_date: today, price_type: 'GENERIC', price_currency_id: priceCcy.rows[0].id }),
    JSON.stringify([{ serial_no: 1, product_id: preassembledProductId, uom_id: preUom, selling_price: 500, is_tax_inclusive: false }]),
    ADMIN_USER_ID,
  ]);
  await client.query(`SELECT fn_approve_price_master_batch($1,$2,$3,$4,$5)`, [CLIENT_ID, COMPANY_ID, pmHeader2.rows[0].entry_no, today, ADMIN_USER_ID]);
  await client.query(
    `SELECT fn_post_stock_movement($1,$2,$3,$4,$5,'OPENING_STOCK',10,300.00,NULL,NULL,NULL,NULL,'TEST_SETUP','POS-PRE-SETUP',$5,$6,1,NULL)`,
    [CLIENT_ID, COMPANY_ID, LOCATION_ID, preassembledProductId, today, ADMIN_USER_ID]
  );
  const bundleRow = await client.query(`SELECT id FROM rim_product_bundles WHERE client_id=$1 AND company_id=$2 AND bundle_product_id=$3`, [CLIENT_ID, COMPANY_ID, preassembledProductId]);
  if (!bundleRow.rows.length) {
    await client.query(`INSERT INTO rim_product_bundles (id, client_id, company_id, bundle_product_id, bundle_mode, is_active, is_deleted) VALUES ($1,$2,$3,$4,'PREASSEMBLED',true,false)`, [uuid(), CLIENT_ID, COMPANY_ID, preassembledProductId]);
  }
  console.log('PREASSEMBLED bundle "Gift Hamper" created, priced 500, stocked 10 units directly.');

  // 7. Weighted-barcode config: prefix 20-29, embedded weight format (common
  // retail-scale convention: PPPPPWWWWWC -- 5-digit product code + 5-digit
  // weight in grams).
  await client.query(`UPDATE ric_companies SET weighted_barcode_prefix_from='20', weighted_barcode_prefix_to='29', weighted_barcode_format='PREFIX2_CODE5_WEIGHT5' WHERE id=$1`, [COMPANY_ID]).catch(e => console.log('weighted barcode config skipped (format value may differ from schema expectation):', e.message));

  console.log('\n=== SETUP COMPLETE ===');
  console.log('Age-restricted product: PRD-POS-006');
  console.log('Min-price-floor product: PRD-POS-007 (floor 190, priced 196)');
  console.log('Batch-tracked product: PRD-POS-BATCH (code), stock in BATCH-A/BATCH-B');
  console.log('Preassembled bundle: PRD-POS-PREASSEMBLED, 10 units in stock, price 500');
  console.log('Supervisor PIN: 9999 (max discount 50%)');
  console.log('POS Admin max discount without override: 5%');

  await client.end();
})().catch(e => { console.error('ERR', e.message, e.detail); process.exit(1); });
