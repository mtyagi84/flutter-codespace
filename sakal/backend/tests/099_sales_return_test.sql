-- ============================================================
-- 099_sales_return_test.sql — pgTAP tests for migration 099
-- (fn_save_sales_return, fn_approve_sales_return)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Fixture: base=local=USD (same simplification precedent as
-- 089_sales_invoice_test.sql — currency conversion correctness is
-- exercised elsewhere). Rather than re-exercise Sales Invoice's own
-- fn_save_sales_invoice/fn_approve_sales_invoice chain (a large,
-- independently-tested surface), this file fabricates the prerequisite
-- "already-APPROVED invoice" state directly via INSERT — a real Sales
-- Return should reverse whatever an invoice left behind regardless of how
-- that invoice was created, and this keeps the fixture tractable.
--
-- Two invoices: INV-099-A (CREDIT, stock dispatched, 10 units @ rate 10,
-- 10% tax) for the core reversal + cumulative-cap tests; INV-099-B (CASH,
-- collected in full, stock dispatched, same shape) for the refund tests.
--
-- Structure mirrors 089's own proven pattern: alternating DO blocks
-- (setup/actions, bridging dynamic values via set_config) and top-level
-- ok()/is() calls (using current_setting()) — never ok() inside a DO
-- block, per CLAUDE.md's own pgTAP conventions.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(16);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id     uuid := '00000000-0000-0000-0099-000000000001';
  v_company_id    uuid := '00000000-0000-0000-0099-000000000002';
  v_loc_id        uuid := '00000000-0000-0000-0099-000000000003';
  v_user_id       uuid := '00000000-0000-0000-0099-000000000004';
  v_credit_cust   uuid := '00000000-0000-0000-0099-000000000005';
  v_cash_cust     uuid := '00000000-0000-0000-0099-000000000006';
  v_cust_grp      uuid := '00000000-0000-0000-0099-000000000007';
  v_sales_acc     uuid := '00000000-0000-0000-0099-000000000008';
  v_sales_ret_acc uuid := '00000000-0000-0000-0099-000000000009';
  v_cos_acc       uuid := '00000000-0000-0000-0099-00000000000a';
  v_stock_acc     uuid := '00000000-0000-0000-0099-00000000000b';
  v_tax_out_acc   uuid := '00000000-0000-0000-0099-00000000000c';
  v_local_cash_acc uuid := '00000000-0000-0000-0099-00000000000d';
  v_base_cash_acc  uuid := '00000000-0000-0000-0099-00000000000e';
  v_product_id    uuid := '00000000-0000-0000-0099-00000000000f';
  v_uom_id        uuid := '00000000-0000-0000-0099-000000000010';
  v_tax_id        uuid := '00000000-0000-0000-0099-000000000011';
  v_tax_group_id  uuid := '00000000-0000-0000-0099-000000000012';
  v_fy_id         uuid := '00000000-0000-0000-0099-000000000013';
  v_tax_type_code text;
  v_usd_ccy_id    uuid;
  v_unit_type_id  uuid;
  v_sales_link    uuid;
  v_sales_ret_link uuid;
  v_cos_link      uuid;
  v_stock_link    uuid;

  v_invoice_a text := 'INV-099-A';
  v_invoice_b text := 'INV-099-B';
  v_invoice_date date := '2026-07-10';
  v_return_date  date := '2026-07-15';
  v_sls_a text := 'SLS-099-A';
  v_cos_a text := 'COS-099-A';
  v_sls_b text := 'SLS-099-B';
  v_cos_b text := 'COS-099-B';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST099', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST099 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test099 Loc', 'T99L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test099_user', 'Test099 User', crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST099', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_cust_grp, v_client_id, v_company_id, '3000', 'Sundry Debtors 099', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_credit_cust, v_client_id, v_company_id, v_cust_grp, '3000001', 'Test099 Credit Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_cash_cust,   v_client_id, v_company_id, v_cust_grp, '3000002', 'Test099 Cash Customer',   'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_sales_acc,     v_client_id, v_company_id, '4000', 'Test099 Sales',         'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_sales_ret_acc, v_client_id, v_company_id, '4001', 'Test099 Sales Returns', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_cos_acc,       v_client_id, v_company_id, '5000', 'Test099 COGS',          'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_stock_acc,     v_client_id, v_company_id, '1300', 'Test099 Stock',         'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_tax_out_acc,   v_client_id, v_company_id, '2200', 'Test099 Output Tax',    'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_local_cash_acc, v_client_id, v_company_id, '1000', 'Test099 Local Cash',   'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_base_cash_acc,  v_client_id, v_company_id, '1001', 'Test099 Base Cash',    'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_sales_link     FROM rim_account_link_types WHERE link_key = 'SALES_ACCOUNT';
  SELECT id INTO v_sales_ret_link FROM rim_account_link_types WHERE link_key = 'SALES_RETURNS_ACCOUNT';
  SELECT id INTO v_cos_link       FROM rim_account_link_types WHERE link_key = 'COST_OF_SALES_ACCOUNT';
  SELECT id INTO v_stock_link     FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_sales_link,     'COMPANY'),
    (v_client_id, v_company_id, v_sales_ret_link, 'COMPANY'),
    (v_client_id, v_company_id, v_cos_link,       'COMPANY'),
    (v_client_id, v_company_id, v_stock_link,     'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_sales_link,     NULL, v_sales_acc),
    (v_client_id, v_company_id, v_sales_ret_link, NULL, v_sales_ret_acc),
    (v_client_id, v_company_id, v_cos_link,       NULL, v_cos_acc),
    (v_client_id, v_company_id, v_stock_link,     NULL, v_stock_acc)
  ON CONFLICT DO NOTHING;

  INSERT INTO ric_user_quick_invoice_setup (client_id, company_id, user_id, location_id, cash_customer_id, local_cash_account_id, base_cash_account_id, is_active, is_deleted)
  VALUES (v_client_id, v_company_id, v_user_id, v_loc_id, v_cash_cust, v_local_cash_acc, v_base_cash_acc, true, false)
  ON CONFLICT (client_id, company_id, user_id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece099', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'SR-001', 'Test099 Item', v_usd_ccy_id, 'NONE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  SELECT tax_type_code INTO v_tax_type_code FROM rim_tax_types LIMIT 1;
  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, calculation_type, gl_output_account_id, is_active, is_deleted, created_by)
  VALUES (v_tax_id, v_client_id, v_company_id, 'T099', 'Test099 Tax 10%', v_tax_type_code, 'SALES', 'PERCENTAGE', v_tax_out_acc, true, false, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (client_id, company_id, tax_id, rate_label, rate, effective_from)
  VALUES (v_client_id, v_company_id, v_tax_id, 'STANDARD', 10, '2020-01-01')
  ON CONFLICT (client_id, company_id, tax_id, rate_label, effective_from) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, is_active, is_deleted)
  VALUES (v_tax_group_id, v_client_id, v_company_id, 'TG099', 'Test099 Group', 'SALES', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_client_id, v_company_id, v_tax_group_id, v_tax_id, 1)
  ON CONFLICT (client_id, company_id, tax_group_id, tax_id) DO NOTHING;

  -- Opening stock: 100 units @ cost 10 (base=specific since base=local=USD).
  PERFORM fn_post_stock_movement(
    v_client_id, v_company_id, v_loc_id, v_product_id,
    '2026-01-01'::date, 'OPENING_STOCK', 100,
    10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-099-001', '2026-01-01'::date, v_user_id
  );

  -- ── Fabricate INVOICE A (CREDIT, stock dispatched, no cash collection) ──
  INSERT INTO rih_sales_invoices (
    client_id, company_id, location_id, invoice_no, invoice_date, invoice_mode,
    sale_type, customer_id, invoice_currency_id, rate_to_base, rate_to_local,
    gross_amount, tax_amount, grand_total, stock_dispatch_mode, cash_collection_mode,
    status, sales_voucher_no, sales_voucher_date, cos_voucher_no, cos_voucher_date,
    created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, v_invoice_a, v_invoice_date, 'DIRECT',
    'CREDIT', v_credit_cust, v_usd_ccy_id, 1, 1,
    100, 10, 110, 'IMMEDIATE', 'DEFERRED',
    'APPROVED', v_sls_a, v_invoice_date, v_cos_a, v_invoice_date,
    v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rid_sales_invoice_lines (
    client_id, company_id, invoice_no, invoice_date, serial_no, product_id, uom_id, uom_conversion_factor,
    qty_pack, qty_loose, base_qty, rate, gross_amount, tax_group_id, tax_amount, final_amount,
    base_amount, local_amount, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_invoice_a, v_invoice_date, 1, v_product_id, v_uom_id, 1,
    10, 0, 10, 10, 100, v_tax_group_id, 10, 110,
    110, 110, v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rih_finance_headers (client_id, company_id, location_id, trans_no, trans_date, voucher_type_code, is_on_account, is_posted, posted_at, posted_by, created_by, updated_by)
  VALUES (v_client_id, v_company_id, v_loc_id, v_sls_a, v_invoice_date, 'SLS', false, true, now(), v_user_id, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, inv_bill_no, inv_bill_date, created_by, updated_by)
  VALUES
    (v_client_id, v_company_id, v_loc_id, v_sls_a, v_invoice_date, 1, v_credit_cust, 'DR', 110, 'USD', 110, 1, 110, 1, 110, 'USD', 1, v_sls_a, v_invoice_date, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_sls_a, v_invoice_date, 2, v_sales_acc,   'CR', 100, 'USD', 100, 1, 100, 1, 100, 'USD', 1, NULL, NULL, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_sls_a, v_invoice_date, 3, v_tax_out_acc, 'CR', 10,  'USD', 10,  1, 10,  1, 10,  'USD', 1, NULL, NULL, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO rih_finance_headers (client_id, company_id, location_id, trans_no, trans_date, voucher_type_code, is_on_account, is_posted, posted_at, posted_by, created_by, updated_by, source_doc_type, source_doc_no, source_doc_date)
  VALUES (v_client_id, v_company_id, v_loc_id, v_cos_a, v_invoice_date, 'COS', false, true, now(), v_user_id, v_user_id, v_user_id, 'SALES_INVOICE', v_invoice_a, v_invoice_date)
  ON CONFLICT DO NOTHING;

  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, source_line_type, source_line_no, created_by, updated_by)
  VALUES
    (v_client_id, v_company_id, v_loc_id, v_cos_a, v_invoice_date, 1, v_cos_acc,   'DR', 100, 'USD', 100, 1, 100, 1, 100, 'USD', 1, 'COGS',  1, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_cos_a, v_invoice_date, 2, v_stock_acc, 'CR', 100, 'USD', 100, 1, 100, 1, 100, 'USD', 1, 'STOCK', 1, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  PERFORM fn_post_stock_movement(
    v_client_id, v_company_id, v_loc_id, v_product_id,
    v_invoice_date, 'SALES_INVOICE', -10,
    NULL, NULL, NULL, NULL, NULL,
    'SALES_INVOICE', v_invoice_a, v_invoice_date, v_user_id
  );

  -- ── Fabricate INVOICE B (CASH, collected in full, stock dispatched) ─────
  INSERT INTO rih_sales_invoices (
    client_id, company_id, location_id, invoice_no, invoice_date, invoice_mode,
    sale_type, customer_id, invoice_currency_id, rate_to_base, rate_to_local,
    gross_amount, tax_amount, grand_total, stock_dispatch_mode, cash_collection_mode,
    collected_amount_local, collected_amount_base,
    status, sales_voucher_no, sales_voucher_date, cos_voucher_no, cos_voucher_date,
    created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, v_invoice_b, v_invoice_date, 'DIRECT',
    'CASH', v_cash_cust, v_usd_ccy_id, 1, 1,
    100, 10, 110, 'IMMEDIATE', 'IMMEDIATE',
    110, 0,
    'APPROVED', v_sls_b, v_invoice_date, v_cos_b, v_invoice_date,
    v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rid_sales_invoice_lines (
    client_id, company_id, invoice_no, invoice_date, serial_no, product_id, uom_id, uom_conversion_factor,
    qty_pack, qty_loose, base_qty, rate, gross_amount, tax_group_id, tax_amount, final_amount,
    base_amount, local_amount, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_invoice_b, v_invoice_date, 1, v_product_id, v_uom_id, 1,
    10, 0, 10, 10, 100, v_tax_group_id, 10, 110,
    110, 110, v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rih_finance_headers (client_id, company_id, location_id, trans_no, trans_date, voucher_type_code, is_on_account, is_posted, posted_at, posted_by, created_by, updated_by)
  VALUES (v_client_id, v_company_id, v_loc_id, v_sls_b, v_invoice_date, 'SLS', false, true, now(), v_user_id, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, inv_bill_no, inv_bill_date, created_by, updated_by)
  VALUES
    (v_client_id, v_company_id, v_loc_id, v_sls_b, v_invoice_date, 1, v_cash_cust,   'DR', 110, 'USD', 110, 1, 110, 1, 110, 'USD', 1, v_sls_b, v_invoice_date, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_sls_b, v_invoice_date, 2, v_sales_acc,   'CR', 100, 'USD', 100, 1, 100, 1, 100, 'USD', 1, NULL, NULL, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_sls_b, v_invoice_date, 3, v_tax_out_acc, 'CR', 10,  'USD', 10,  1, 10,  1, 10,  'USD', 1, NULL, NULL, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO rih_finance_headers (client_id, company_id, location_id, trans_no, trans_date, voucher_type_code, is_on_account, is_posted, posted_at, posted_by, created_by, updated_by, source_doc_type, source_doc_no, source_doc_date)
  VALUES (v_client_id, v_company_id, v_loc_id, v_cos_b, v_invoice_date, 'COS', false, true, now(), v_user_id, v_user_id, v_user_id, 'SALES_INVOICE', v_invoice_b, v_invoice_date)
  ON CONFLICT DO NOTHING;

  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, source_line_type, source_line_no, created_by, updated_by)
  VALUES
    (v_client_id, v_company_id, v_loc_id, v_cos_b, v_invoice_date, 1, v_cos_acc,   'DR', 100, 'USD', 100, 1, 100, 1, 100, 'USD', 1, 'COGS',  1, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_cos_b, v_invoice_date, 2, v_stock_acc, 'CR', 100, 'USD', 100, 1, 100, 1, 100, 'USD', 1, 'STOCK', 1, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  PERFORM fn_post_stock_movement(
    v_client_id, v_company_id, v_loc_id, v_product_id,
    v_invoice_date, 'SALES_INVOICE', -10,
    NULL, NULL, NULL, NULL, NULL,
    'SALES_INVOICE', v_invoice_b, v_invoice_date, v_user_id
  );

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user', v_user_id::text, false);
  PERFORM set_config('pgtap.v_product', v_product_id::text, false);
  PERFORM set_config('pgtap.v_uom', v_uom_id::text, false);
  PERFORM set_config('pgtap.v_tax_group', v_tax_group_id::text, false);
  PERFORM set_config('pgtap.v_invoice_a', v_invoice_a, false);
  PERFORM set_config('pgtap.v_invoice_b', v_invoice_b, false);
  PERFORM set_config('pgtap.v_invoice_date', v_invoice_date::text, false);
  PERFORM set_config('pgtap.v_return_date', v_return_date::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1: fn_save_sales_return — DRAFT save against Invoice A, 5 of 10.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_sales_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'return_no', null, 'return_date', current_setting('pgtap.v_return_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_a'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'taxable_amount', 50, 'tax_amount', 5, 'charges_amount', 0, 'return_total', 55,
      'refund_amount_local', 0, 'refund_amount_base', 0,
      'reason', 'Defective goods', 'remarks', 'pgTAP test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 10,
      'tax_group_id', current_setting('pgtap.v_tax_group')::uuid, 'gross_amount', 50, 'tax_amount', 5, 'final_amount', 55
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_return_1', v_return_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_return_1') LIKE 'SRET%',
  'ok 1 — fn_save_sales_return returns a SRET-numbered return_no'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1')),
  'DRAFT', 'ok 2 — saved return is DRAFT'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rid_sales_return_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1') AND base_qty = 5),
  'ok 3 — return line saved with base_qty=5'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 2: fn_approve_sales_return — posts CRN + COS, stock returns.
-- ════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_approve_sales_return(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_return_1'), current_setting('pgtap.v_return_date')::date,
    current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1')),
  'APPROVED', 'ok 4 — approved return status is APPROVED'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT credit_note_voucher_no IS NOT NULL FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1')),
  'ok 5 — CRN voucher number recorded on header'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT cos_voucher_no IS NOT NULL FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1')),
  'ok 6 — COS voucher number recorded on header (stock was dispatched)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature = 'DR' THEN trans_amount ELSE -trans_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT credit_note_voucher_no FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1'))),
  'ok 7 — CRN voucher is balanced (DR = CR)'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT sum(trans_amount) FROM rid_finance_lines
   WHERE trans_no = (SELECT cos_voucher_no FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1'))
     AND trans_nature = 'DR'),
  50::numeric, 'ok 8 — COS voucher reverses at the historical unit cost (5 units x cost 10 = 50, not a fresh average)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature = 'DR' THEN trans_amount ELSE -trans_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT cos_voucher_no FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_1'))),
  'ok 9 — COS voucher is balanced (DR = CR)'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND location_id = current_setting('pgtap.v_loc')::uuid AND product_id = current_setting('pgtap.v_product')::uuid),
  85::numeric, 'ok 10 — stock received back (100 opening - 10 Invoice A - 10 Invoice B + 5 returned = 85)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 3: cumulative cap — a second return for the remaining 5 succeeds,
-- a third attempt for even 1 more unit fails.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_sales_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'return_no', null, 'return_date', current_setting('pgtap.v_return_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_a'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'taxable_amount', 50, 'tax_amount', 5, 'charges_amount', 0, 'return_total', 55,
      'refund_amount_local', 0, 'refund_amount_base', 0,
      'reason', 'Defective goods (2nd batch)', 'remarks', 'pgTAP test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 10,
      'tax_group_id', current_setting('pgtap.v_tax_group')::uuid, 'gross_amount', 50, 'tax_amount', 5, 'final_amount', 55
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_sales_return(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_return_no, current_setting('pgtap.v_return_date')::date, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_return_2', v_return_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_2')),
  'APPROVED', 'ok 11 — second return for the remaining 5 units approves cleanly'
);

DO $$
DECLARE
  v_return_no text;
  v_error_raised boolean := false;
BEGIN
  v_return_no := fn_save_sales_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'return_no', null, 'return_date', current_setting('pgtap.v_return_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_a'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'taxable_amount', 10, 'tax_amount', 1, 'charges_amount', 0, 'return_total', 11,
      'refund_amount_local', 0, 'refund_amount_base', 0,
      'reason', 'Over-return attempt', 'remarks', 'pgTAP test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 10,
      'tax_group_id', current_setting('pgtap.v_tax_group')::uuid, 'gross_amount', 10, 'tax_amount', 1, 'final_amount', 11
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user')::uuid
  );
  BEGIN
    PERFORM fn_approve_sales_return(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      v_return_no, current_setting('pgtap.v_return_date')::date, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%RETURN_QTY_EXCEEDS_INVOICED%');
  END;
  PERFORM set_config('pgtap.v_test12', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test12')::boolean,
  'ok 12 — a third return exceeding the invoice''s total qty raises RETURN_QTY_EXCEEDS_INVOICED'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 4: cash refund — Invoice B, return 5 of 10, refund capped at 55.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_sales_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'return_no', null, 'return_date', current_setting('pgtap.v_return_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_b'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'taxable_amount', 50, 'tax_amount', 5, 'charges_amount', 0, 'return_total', 55,
      'refund_amount_local', 55, 'refund_amount_base', 0,
      'reason', 'Defective goods', 'remarks', 'pgTAP test cash refund'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 10,
      'tax_group_id', current_setting('pgtap.v_tax_group')::uuid, 'gross_amount', 50, 'tax_amount', 5, 'final_amount', 55
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_sales_return(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_return_no, current_setting('pgtap.v_return_date')::date, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_return_3', v_return_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_3')),
  'APPROVED', 'ok 13 — cash-sale return approves cleanly'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT refund_voucher_no_local IS NOT NULL FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_3')),
  'ok 14 — a CPV refund voucher was posted for the local leg'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature = 'DR' THEN trans_amount ELSE -trans_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT refund_voucher_no_local FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND return_no = current_setting('pgtap.v_return_3'))),
  'ok 15 — refund CPV voucher is balanced (DR = CR)'
);

-- A second return on Invoice B requesting more refund than remains
-- collected (110 collected, 55 already refunded, requesting 60 more)
-- must raise REFUND_EXCEEDS_COLLECTED, never silently clamp.
DO $$
DECLARE
  v_return_no text;
  v_error_raised boolean := false;
BEGIN
  v_return_no := fn_save_sales_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'return_no', null, 'return_date', current_setting('pgtap.v_return_date')::date,
      'invoice_no', current_setting('pgtap.v_invoice_b'), 'invoice_date', current_setting('pgtap.v_invoice_date')::date,
      'taxable_amount', 50, 'tax_amount', 5, 'charges_amount', 0, 'return_total', 55,
      'refund_amount_local', 60, 'refund_amount_base', 0,
      'reason', 'Over-refund attempt', 'remarks', 'pgTAP test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 10,
      'tax_group_id', current_setting('pgtap.v_tax_group')::uuid, 'gross_amount', 50, 'tax_amount', 5, 'final_amount', 55
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user')::uuid
  );
  BEGIN
    PERFORM fn_approve_sales_return(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      v_return_no, current_setting('pgtap.v_return_date')::date, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%REFUND_EXCEEDS_COLLECTED%');
  END;
  PERFORM set_config('pgtap.v_test16', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test16')::boolean,
  'ok 16 — requesting more refund than remains collected raises REFUND_EXCEEDS_COLLECTED'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
