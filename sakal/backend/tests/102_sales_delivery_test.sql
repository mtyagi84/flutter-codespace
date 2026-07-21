-- ============================================================
-- 102_sales_delivery_test.sql — pgTAP tests for migration 102
-- (fn_save_sales_delivery, fn_approve_sales_delivery)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Fixture: base=local=USD (same simplification precedent as
-- 089_sales_invoice_test.sql/099_sales_return_test.sql — currency
-- conversion correctness is exercised elsewhere).
--
-- Unlike 099_sales_return_test.sql, this fixture does NOT need to
-- fabricate the source invoice's own SLS/COS finance-voucher chain —
-- fn_approve_sales_delivery reads the CURRENT rim_product_location.
-- cost_price at approval time (a fresh outward movement, not a
-- reversal), never a historical cost read back from a prior voucher.
-- So the invoice fixture here is deliberately lighter than 099's.
--
-- Three invoices: INV-102-A (DEFERRED, untracked product, 10 units)
-- for the core delivery + cumulative-cap tests; INV-102-B (DEFERRED,
-- batch-tracked product, 5 units, only 3 in stock) for the negative-
-- stock/batch-insufficient test; INV-102-C (IMMEDIATE) for the
-- not-eligible-for-delivery test.
--
-- Structure mirrors 099's own proven pattern: alternating DO blocks
-- (setup/actions, bridging dynamic values via set_config) and top-level
-- ok()/is() calls (using current_setting()) — never ok() inside a DO
-- block, per CLAUDE.md's own pgTAP conventions.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(17);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id       uuid := '00000000-0000-0000-0102-000000000001';
  v_company_id      uuid := '00000000-0000-0000-0102-000000000002';
  v_loc_id          uuid := '00000000-0000-0000-0102-000000000003';
  v_user_id         uuid := '00000000-0000-0000-0102-000000000004';
  v_customer        uuid := '00000000-0000-0000-0102-000000000005';
  v_cust_grp        uuid := '00000000-0000-0000-0102-000000000006';
  v_stock_acc       uuid := '00000000-0000-0000-0102-000000000007';
  v_cos_acc         uuid := '00000000-0000-0000-0102-000000000008';
  v_product_id      uuid := '00000000-0000-0000-0102-000000000009';
  v_batch_product_id uuid := '00000000-0000-0000-0102-00000000000a';
  v_uom_id          uuid := '00000000-0000-0000-0102-00000000000b';
  v_fy_id           uuid := '00000000-0000-0000-0102-00000000000c';
  v_usd_ccy_id      uuid;
  v_unit_type_id    uuid;
  v_stock_link      uuid;
  v_cos_link        uuid;

  v_invoice_a text := 'INV-102-A';
  v_invoice_b text := 'INV-102-B';
  v_invoice_c text := 'INV-102-C';
  v_invoice_date date := '2026-07-10';
  v_delivery_date date := '2026-07-15';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST102', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST102 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test102 Loc', 'T102L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test102_user', 'Test102 User', crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST102', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_cust_grp, v_client_id, v_company_id, '3000', 'Sundry Debtors 102', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES (v_customer, v_client_id, v_company_id, v_cust_grp, '3000001', 'Test102 Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_stock_acc, v_client_id, v_company_id, '1300', 'Test102 Stock', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_cos_acc,   v_client_id, v_company_id, '5000', 'Test102 COGS',  'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_cos_link   FROM rim_account_link_types WHERE link_key = 'COST_OF_SALES_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_stock_link, 'COMPANY'),
    (v_client_id, v_company_id, v_cos_link,   'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_stock_link, NULL, v_stock_acc),
    (v_client_id, v_company_id, v_cos_link,   NULL, v_cos_acc)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece102', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'SD-001', 'Test102 Item', v_usd_ccy_id, 'NONE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_batch_product_id, v_client_id, v_company_id, 'SD-002', 'Test102 Batch Item', v_usd_ccy_id, 'BATCH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Opening stock: untracked product 100 units @ cost 10.
  PERFORM fn_post_stock_movement(
    v_client_id, v_company_id, v_loc_id, v_product_id,
    '2026-01-01'::date, 'OPENING_STOCK', 100,
    10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-102-001', '2026-01-01'::date, v_user_id
  );

  -- Opening stock: batch-tracked product, only 3 units in batch B1 —
  -- deliberately less than the 5 units INV-102-B will invoice, so a
  -- Delivery requesting the full 5 against batch B1 triggers
  -- BATCH_INSUFFICIENT_STOCK (batch/serial-tracked products can never
  -- go negative, unconditionally, per fn_post_stock_movement's rule).
  PERFORM fn_post_stock_movement(
    v_client_id, v_company_id, v_loc_id, v_batch_product_id,
    '2026-01-01'::date, 'OPENING_STOCK', 3,
    10, 10, 'B1', '2027-01-01'::date, NULL,
    'OPENING_BALANCE', 'OB-102-002', '2026-01-01'::date, v_user_id
  );

  -- ── Invoice A: DEFERRED, untracked product, 10 units ─────────────
  INSERT INTO rih_sales_invoices (
    client_id, company_id, location_id, invoice_no, invoice_date, invoice_mode,
    sale_type, customer_id, invoice_currency_id, rate_to_base, rate_to_local,
    gross_amount, tax_amount, grand_total, stock_dispatch_mode, cash_collection_mode,
    status, sales_voucher_no, sales_voucher_date,
    created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, v_invoice_a, v_invoice_date, 'DIRECT',
    'CREDIT', v_customer, v_usd_ccy_id, 1, 1,
    100, 0, 100, 'DEFERRED', 'DEFERRED',
    'APPROVED', 'SLS-102-A', v_invoice_date,
    v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rid_sales_invoice_lines (
    client_id, company_id, invoice_no, invoice_date, serial_no, product_id, uom_id, uom_conversion_factor,
    qty_pack, qty_loose, base_qty, rate, gross_amount, tax_amount, final_amount,
    base_amount, local_amount, delivered_qty, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_invoice_a, v_invoice_date, 1, v_product_id, v_uom_id, 1,
    10, 0, 10, 10, 100, 0, 100,
    100, 100, 0, v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  -- ── Invoice B: DEFERRED, batch-tracked product, 5 units ──────────
  INSERT INTO rih_sales_invoices (
    client_id, company_id, location_id, invoice_no, invoice_date, invoice_mode,
    sale_type, customer_id, invoice_currency_id, rate_to_base, rate_to_local,
    gross_amount, tax_amount, grand_total, stock_dispatch_mode, cash_collection_mode,
    status, sales_voucher_no, sales_voucher_date,
    created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, v_invoice_b, v_invoice_date, 'DIRECT',
    'CREDIT', v_customer, v_usd_ccy_id, 1, 1,
    50, 0, 50, 'DEFERRED', 'DEFERRED',
    'APPROVED', 'SLS-102-B', v_invoice_date,
    v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rid_sales_invoice_lines (
    client_id, company_id, invoice_no, invoice_date, serial_no, product_id, uom_id, uom_conversion_factor,
    qty_pack, qty_loose, base_qty, rate, gross_amount, tax_amount, final_amount,
    base_amount, local_amount, delivered_qty, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_invoice_b, v_invoice_date, 1, v_batch_product_id, v_uom_id, 1,
    5, 0, 5, 10, 50, 0, 50,
    50, 50, 0, v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  -- ── Invoice C: IMMEDIATE — not eligible for delivery ─────────────
  INSERT INTO rih_sales_invoices (
    client_id, company_id, location_id, invoice_no, invoice_date, invoice_mode,
    sale_type, customer_id, invoice_currency_id, rate_to_base, rate_to_local,
    gross_amount, tax_amount, grand_total, stock_dispatch_mode, cash_collection_mode,
    status, sales_voucher_no, sales_voucher_date,
    created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, v_invoice_c, v_invoice_date, 'DIRECT',
    'CREDIT', v_customer, v_usd_ccy_id, 1, 1,
    100, 0, 100, 'IMMEDIATE', 'DEFERRED',
    'APPROVED', 'SLS-102-C', v_invoice_date,
    v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rid_sales_invoice_lines (
    client_id, company_id, invoice_no, invoice_date, serial_no, product_id, uom_id, uom_conversion_factor,
    qty_pack, qty_loose, base_qty, rate, gross_amount, tax_amount, final_amount,
    base_amount, local_amount, delivered_qty, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_invoice_c, v_invoice_date, 1, v_product_id, v_uom_id, 1,
    10, 0, 10, 10, 100, 0, 100,
    100, 100, 0, v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user', v_user_id::text, false);
  PERFORM set_config('pgtap.v_product', v_product_id::text, false);
  PERFORM set_config('pgtap.v_batch_product', v_batch_product_id::text, false);
  PERFORM set_config('pgtap.v_uom', v_uom_id::text, false);
  PERFORM set_config('pgtap.v_invoice_a', v_invoice_a, false);
  PERFORM set_config('pgtap.v_invoice_b', v_invoice_b, false);
  PERFORM set_config('pgtap.v_invoice_c', v_invoice_c, false);
  PERFORM set_config('pgtap.v_invoice_date', v_invoice_date::text, false);
  PERFORM set_config('pgtap.v_delivery_date', v_delivery_date::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1: fn_save_sales_delivery — DRAFT save against Invoice A, 5 of 10.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_delivery_no text;
BEGIN
  v_delivery_no := fn_save_sales_delivery(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'delivery_no', null, 'delivery_date', current_setting('pgtap.v_delivery_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_a'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'received_by_name', 'John Doe', 'remarks', 'pgTAP test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5
    )),
    '[]'::jsonb, '[]'::jsonb, NULL,
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_delivery_1', v_delivery_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_delivery_1') LIKE 'SDEL%',
  'ok 1 — fn_save_sales_delivery returns an SDEL-numbered delivery_no'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND delivery_no = current_setting('pgtap.v_delivery_1')),
  'DRAFT', 'ok 2 — saved delivery is DRAFT'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rid_sales_delivery_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND delivery_no = current_setting('pgtap.v_delivery_1') AND base_qty = 5),
  'ok 3 — delivery line saved with base_qty=5'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 2: fn_approve_sales_delivery — posts COS, stock decreases,
-- delivered_qty increments.
-- ════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_approve_sales_delivery(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_delivery_1'), current_setting('pgtap.v_delivery_date')::date,
    current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND delivery_no = current_setting('pgtap.v_delivery_1')),
  'APPROVED', 'ok 4 — approved delivery status is APPROVED'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT cos_voucher_no IS NOT NULL FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND delivery_no = current_setting('pgtap.v_delivery_1')),
  'ok 5 — COS voucher number recorded on header'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature = 'DR' THEN trans_amount ELSE -trans_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT cos_voucher_no FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND delivery_no = current_setting('pgtap.v_delivery_1'))),
  'ok 6 — COS voucher is balanced (DR = CR)'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT sum(trans_amount) FROM rid_finance_lines
   WHERE trans_no = (SELECT cos_voucher_no FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND delivery_no = current_setting('pgtap.v_delivery_1'))
     AND trans_nature = 'DR'),
  50::numeric, 'ok 7 — COS voucher DR = 5 units x CURRENT cost 10 = 50 (current moving-average cost, not a historical reversal — Delivery is a fresh outward movement, unlike Sales Return)'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND location_id = current_setting('pgtap.v_loc')::uuid AND product_id = current_setting('pgtap.v_product')::uuid),
  95::numeric, 'ok 8 — stock dispatched (100 opening - 5 delivered = 95)'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT delivered_qty FROM rid_sales_invoice_lines
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND invoice_no = current_setting('pgtap.v_invoice_a') AND invoice_date = current_setting('pgtap.v_invoice_date')::date AND serial_no = 1),
  5::numeric, 'ok 9 — invoice line delivered_qty incremented to 5'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 3: cumulative cap — a second delivery for the remaining 5 succeeds,
-- a third attempt for even 1 more unit fails.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_delivery_no text;
BEGIN
  v_delivery_no := fn_save_sales_delivery(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'delivery_no', null, 'delivery_date', current_setting('pgtap.v_delivery_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_a'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'received_by_name', 'Jane Doe (2nd batch)', 'remarks', 'pgTAP test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5
    )),
    '[]'::jsonb, '[]'::jsonb, NULL,
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_sales_delivery(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_delivery_no, current_setting('pgtap.v_delivery_date')::date, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_delivery_2', v_delivery_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND delivery_no = current_setting('pgtap.v_delivery_2')),
  'APPROVED', 'ok 10 — second delivery for the remaining 5 units approves cleanly'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT delivered_qty FROM rid_sales_invoice_lines
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND invoice_no = current_setting('pgtap.v_invoice_a') AND invoice_date = current_setting('pgtap.v_invoice_date')::date AND serial_no = 1),
  10::numeric, 'ok 11 — invoice line delivered_qty now fully 10'
);

DO $$
DECLARE
  v_delivery_no text;
  v_error_raised boolean := false;
BEGIN
  v_delivery_no := fn_save_sales_delivery(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'delivery_no', null, 'delivery_date', current_setting('pgtap.v_delivery_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_a'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'received_by_name', 'Over-delivery attempt', 'remarks', 'pgTAP test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1
    )),
    '[]'::jsonb, '[]'::jsonb, NULL,
    current_setting('pgtap.v_user')::uuid
  );
  BEGIN
    PERFORM fn_approve_sales_delivery(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      v_delivery_no, current_setting('pgtap.v_delivery_date')::date, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%DELIVERY_QTY_EXCEEDS_PENDING%');
  END;
  PERFORM set_config('pgtap.v_test12', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test12')::boolean,
  'ok 12 — a third delivery exceeding the invoice''s total qty raises DELIVERY_QTY_EXCEEDS_PENDING'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 4: validation guards on fn_save_sales_delivery.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    PERFORM fn_save_sales_delivery(
      jsonb_build_object(
        'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
        'delivery_no', null, 'delivery_date', current_setting('pgtap.v_delivery_date')::date,
        'invoice_no', current_setting('pgtap.v_invoice_b'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
        'remarks', 'zero qty test'
      ),
      jsonb_build_array(jsonb_build_object(
        'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_batch_product')::uuid, 'barcode', null,
        'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
        'qty_pack', 0, 'qty_loose', 0, 'base_qty', 0
      )),
      '[]'::jsonb, '[]'::jsonb, NULL,
      current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%DELIVERY_QTY_ZERO_NOT_ALLOWED%');
  END;
  PERFORM set_config('pgtap.v_test13', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test13')::boolean,
  'ok 13 — a zero-qty line is rejected at save with DELIVERY_QTY_ZERO_NOT_ALLOWED'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    PERFORM fn_save_sales_delivery(
      jsonb_build_object(
        'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
        'delivery_no', null, 'delivery_date', (current_setting('pgtap.v_invoice_date')::date - 1),
        'invoice_no', current_setting('pgtap.v_invoice_b'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
        'remarks', 'backdated before invoice test'
      ),
      jsonb_build_array(jsonb_build_object(
        'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_batch_product')::uuid, 'barcode', null,
        'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
        'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1
      )),
      '[]'::jsonb, '[]'::jsonb, NULL,
      current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%DELIVERY_DATE_BEFORE_INVOICE_DATE%');
  END;
  PERFORM set_config('pgtap.v_test14', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test14')::boolean,
  'ok 14 — a delivery dated before the invoice date is rejected with DELIVERY_DATE_BEFORE_INVOICE_DATE'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 5: future-dated delivery rejected at Approve (unconditional hard
-- guard, not a company-configurable opt-in).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_delivery_no text;
  v_error_raised boolean := false;
BEGIN
  v_delivery_no := fn_save_sales_delivery(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'delivery_no', null, 'delivery_date', (CURRENT_DATE + 1),
      'invoice_no', current_setting('pgtap.v_invoice_b'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'remarks', 'future date test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_batch_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1
    )),
    '[]'::jsonb, '[]'::jsonb, NULL,
    current_setting('pgtap.v_user')::uuid
  );
  BEGIN
    PERFORM fn_approve_sales_delivery(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      v_delivery_no, (CURRENT_DATE + 1), current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%FUTURE_DATE_NOT_ALLOWED%');
  END;
  PERFORM set_config('pgtap.v_test15', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test15')::boolean,
  'ok 15 — a future-dated delivery is rejected at Approve with FUTURE_DATE_NOT_ALLOWED'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 6: delivery against an IMMEDIATE-mode invoice is rejected at Save.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    PERFORM fn_save_sales_delivery(
      jsonb_build_object(
        'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
        'delivery_no', null, 'delivery_date', current_setting('pgtap.v_delivery_date')::date,
        'invoice_no', current_setting('pgtap.v_invoice_c'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
        'remarks', 'immediate mode test'
      ),
      jsonb_build_array(jsonb_build_object(
        'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
        'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
        'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1
      )),
      '[]'::jsonb, '[]'::jsonb, NULL,
      current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%INVOICE_NOT_ELIGIBLE_FOR_DELIVERY%');
  END;
  PERFORM set_config('pgtap.v_test16', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test16')::boolean,
  'ok 16 — a delivery against an IMMEDIATE-mode invoice is rejected with INVOICE_NOT_ELIGIBLE_FOR_DELIVERY'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 7: batch-tracked negative-stock block — requesting 5 units
-- against batch B1 (only 3 in stock) raises BATCH_INSUFFICIENT_STOCK,
-- inherited unchanged from fn_post_stock_movement (no new logic here).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_delivery_no text;
  v_error_raised boolean := false;
BEGIN
  v_delivery_no := fn_save_sales_delivery(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'delivery_no', null, 'delivery_date', current_setting('pgtap.v_delivery_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_b'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'remarks', 'batch insufficient stock test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_batch_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5
    )),
    jsonb_build_array(jsonb_build_object(
      'line_serial', 1, 'batch_no', 'B1', 'expiry_date', '2027-01-01', 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5
    )),
    '[]'::jsonb, NULL,
    current_setting('pgtap.v_user')::uuid
  );
  BEGIN
    PERFORM fn_approve_sales_delivery(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      v_delivery_no, current_setting('pgtap.v_delivery_date')::date, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%BATCH_INSUFFICIENT_STOCK%');
  END;
  PERFORM set_config('pgtap.v_test17', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test17')::boolean,
  'ok 17 — a batch-tracked delivery exceeding the batch''s own balance raises BATCH_INSUFFICIENT_STOCK (batch/serial can never go negative, regardless of allow_negative_stock flags)'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
