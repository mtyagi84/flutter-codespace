-- ============================================================
-- 071_074_stock_transfer_test.sql — pgTAP tests for the Inter-Location
-- Stock Transfer module (migrations 071/072/073/074): Stock Transfer
-- Request, Stock Transfer, Stock Receipt.
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run) — Supabase's SQL
--      editor only displays the LAST statement's result grid, so every
--      assertion is captured into test_results and dumped in one grid
--      at the bottom. Look for any row NOT starting with "ok " — that's
--      the failure, with pgTAP's diagnostic text right below it.
--
-- Two companies, two scenarios:
--   COMPANY A (inter_location_model = 'SIMPLE') — two locations, no
--     groups at all -> every transfer is SAME_BOOK regardless.
--   COMPANY B (inter_location_model = 'INTER_ENTITY') — two locations in
--     TWO DIFFERENT location groups, each with its own customer/supplier/
--     inter-entity sales+COGS accounts -> transfers between them post
--     STXS+STXC (sales/COGS, immediate + final), and a same-group transfer
--     (a third location in Group 1) still posts SAME_BOOK STXJ.
--
-- Shortfall/write-off is exercised on BOTH scenarios' Receipt step (10
-- transferred, only 9 confirmed received) to prove the Stock Transfer
-- Loss account absorbs the gap identically in both accounting paths.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

-- ══════════════════════════════════════════════════════════════════════════
-- Fixture
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  -- Company A — SIMPLE
  v_client_a  uuid := '00000000-0000-0000-0074-0000000000a1';
  v_company_a uuid := '00000000-0000-0000-0074-0000000000a2';
  v_loc_a1    uuid := '00000000-0000-0000-0074-0000000000a3';  -- from
  v_loc_a2    uuid := '00000000-0000-0000-0074-0000000000a4';  -- to
  v_user_a    uuid := '00000000-0000-0000-0074-0000000000a5';
  v_usd_a     uuid;
  v_stock_acc_a  uuid := '00000000-0000-0000-0074-0000000000a6';
  v_transit_acc_a uuid := '00000000-0000-0000-0074-0000000000a7';
  v_loss_acc_a    uuid := '00000000-0000-0000-0074-0000000000a8';
  v_freight_acc_a uuid := '00000000-0000-0000-0074-0000000000a9';
  v_product_a     uuid := '00000000-0000-0000-0074-0000000000aa';
  v_fy_a          uuid := '00000000-0000-0000-0074-0000000000ab';
  v_charge_a      uuid := '00000000-0000-0000-0074-0000000000ac';

  -- Company B — INTER_ENTITY
  v_client_b  uuid := '00000000-0000-0000-0074-0000000000b1';
  v_company_b uuid := '00000000-0000-0000-0074-0000000000b2';
  v_loc_b1    uuid := '00000000-0000-0000-0074-0000000000b3';  -- Group 1 (from, cross-group transfer)
  v_loc_b2    uuid := '00000000-0000-0000-0074-0000000000b4';  -- Group 2 (to, cross-group transfer)
  v_loc_b3    uuid := '00000000-0000-0000-0074-0000000000b5';  -- Group 1 (same-group transfer partner for b1)
  v_user_b    uuid := '00000000-0000-0000-0074-0000000000b6';
  v_usd_b     uuid;
  v_group1_b uuid := '00000000-0000-0000-0074-0000000000b7';
  v_group2_b uuid := '00000000-0000-0000-0074-0000000000b8';
  v_stock_acc_b   uuid := '00000000-0000-0000-0074-0000000000b9';
  v_transit_acc_b uuid := '00000000-0000-0000-0074-0000000000ba';
  v_loss_acc_b    uuid := '00000000-0000-0000-0074-0000000000bb';
  v_g1_customer_acc uuid := '00000000-0000-0000-0074-0000000000bc';
  v_g1_supplier_acc uuid := '00000000-0000-0000-0074-0000000000bd';
  v_g1_ie_sales_acc uuid := '00000000-0000-0000-0074-0000000000be';
  v_g1_ie_cogs_acc  uuid := '00000000-0000-0000-0074-0000000000bf';
  v_g2_customer_acc uuid := '00000000-0000-0000-0074-0000000000c0';
  v_g2_supplier_acc uuid := '00000000-0000-0000-0074-0000000000c1';
  v_g2_ie_sales_acc uuid := '00000000-0000-0000-0074-0000000000c2';
  v_g2_ie_cogs_acc  uuid := '00000000-0000-0000-0074-0000000000c3';
  v_product_b       uuid := '00000000-0000-0000-0074-0000000000c4';
  v_fy_b            uuid := '00000000-0000-0000-0074-0000000000c5';

  v_stock_link_type   uuid;
  v_transit_link_type uuid;
  v_loss_link_type    uuid;
BEGIN
  -- ── Company A: SIMPLE ─────────────────────────────────────────────────
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_a, 'TEST074A', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company_a, v_client_a, 'TEST074A CO', 'USD', 'USD', 'SIMPLE', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES
    (v_loc_a1, v_client_a, v_company_a, 'TEST074A Loc1', 'A74A1', true, false, false, true, now()),
    (v_loc_a2, v_client_a, v_company_a, 'TEST074A Loc2', 'A74A2', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_a, v_client_a, v_company_a, 'test074a', 'Test User A', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_a FROM rim_currencies WHERE client_id = v_client_a AND company_id = v_company_a AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_stock_acc_a,   v_client_a, v_company_a, '13A1', 'Stock Account A',        'General', 'OHADA', true, true, false, now()),
    (v_transit_acc_a, v_client_a, v_company_a, '13A2', 'Stock In Transit A',     'General', 'OHADA', true, true, false, now()),
    (v_loss_acc_a,    v_client_a, v_company_a, '61A1', 'Stock Transfer Loss A',  'General', 'OHADA', true, true, false, now()),
    (v_freight_acc_a, v_client_a, v_company_a, '61A2', 'Freight Charges A',      'General', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_a, v_client_a, v_company_a, 'STX-A01', 'Transfer Test Item A', v_usd_a, 'NONE', v_user_a)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_a, v_client_a, v_company_a, 'FY TEST074A', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link_type   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_transit_link_type FROM rim_account_link_types WHERE link_key = 'STOCK_IN_TRANSIT_ACCOUNT';
  SELECT id INTO v_loss_link_type    FROM rim_account_link_types WHERE link_key = 'STOCK_TRANSFER_LOSS_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_a, v_company_a, v_stock_link_type, 'COMPANY'),
    (v_client_a, v_company_a, v_transit_link_type, 'COMPANY'),
    (v_client_a, v_company_a, v_loss_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_a, v_company_a, v_stock_link_type, NULL, v_stock_acc_a),
    (v_client_a, v_company_a, v_transit_link_type, NULL, v_transit_acc_a),
    (v_client_a, v_company_a, v_loss_link_type, NULL, v_loss_acc_a)
  ON CONFLICT DO NOTHING;

  INSERT INTO rim_additional_charges (id, client_id, company_id, charge_code, charge_name, applicable_on, default_gl_account_id, is_active, created_by)
  VALUES (v_charge_a, v_client_a, v_company_a, 'FRT-A', 'Freight A', 'TRANSFER', v_freight_acc_a, true, v_user_a)
  ON CONFLICT (id) DO NOTHING;

  -- Seed 20 units of product A @ cost 10 (=200) directly into rim_product_location
  -- via a plain stock-in movement, so we have a known moving-average cost to
  -- transfer from without depending on the Purchase/GRN module in this test.
  PERFORM fn_post_stock_movement(
    v_client_a, v_company_a, v_loc_a1, v_product_a,
    '2026-06-01'::date, 'OPENING_STOCK', 20,
    10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-A-001', '2026-06-01'::date, v_user_a
  );

  PERFORM set_config('pgtap.v_usd_074a', v_usd_a::text, false);

  -- ── Company B: INTER_ENTITY ───────────────────────────────────────────
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_b, 'TEST074B', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company_b, v_client_b, 'TEST074B CO', 'USD', 'USD', 'INTER_ENTITY', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_b, v_client_b, v_company_b, 'test074b', 'Test User B', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_b FROM rim_currencies WHERE client_id = v_client_b AND company_id = v_company_b AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_stock_acc_b,     v_client_b, v_company_b, '13B1', 'Stock Account B',            'General',  'OHADA', true, true, false, now()),
    (v_transit_acc_b,   v_client_b, v_company_b, '13B2', 'Stock In Transit B',         'General',  'OHADA', true, true, false, now()),
    (v_loss_acc_b,      v_client_b, v_company_b, '61B1', 'Stock Transfer Loss B',      'General',  'OHADA', true, true, false, now()),
    (v_g1_customer_acc, v_client_b, v_company_b, '41B1', 'Group1 As Customer',         'Customer', 'OHADA', true, true, false, now()),
    (v_g1_supplier_acc, v_client_b, v_company_b, '40B1', 'Group1 As Supplier',         'Supplier', 'OHADA', true, true, false, now()),
    (v_g1_ie_sales_acc, v_client_b, v_company_b, '70B1', 'Group1 Inter-Entity Sales',  'General',  'OHADA', true, true, false, now()),
    (v_g1_ie_cogs_acc,  v_client_b, v_company_b, '60B1', 'Group1 Inter-Entity COGS',   'General',  'OHADA', true, true, false, now()),
    (v_g2_customer_acc, v_client_b, v_company_b, '41B2', 'Group2 As Customer',         'Customer', 'OHADA', true, true, false, now()),
    (v_g2_supplier_acc, v_client_b, v_company_b, '40B2', 'Group2 As Supplier',         'Supplier', 'OHADA', true, true, false, now()),
    (v_g2_ie_sales_acc, v_client_b, v_company_b, '70B2', 'Group2 Inter-Entity Sales',  'General',  'OHADA', true, true, false, now()),
    (v_g2_ie_cogs_acc,  v_client_b, v_company_b, '60B2', 'Group2 Inter-Entity COGS',   'General',  'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_location_groups (id, client_id, company_id, group_code, group_name,
    customer_account_id, supplier_account_id, inter_entity_sales_account_id, inter_entity_cogs_account_id, is_active, created_by)
  VALUES
    (v_group1_b, v_client_b, v_company_b, 'GRP1', 'Group 1', v_g1_customer_acc, v_g1_supplier_acc, v_g1_ie_sales_acc, v_g1_ie_cogs_acc, true, v_user_b),
    (v_group2_b, v_client_b, v_company_b, 'GRP2', 'Group 2', v_g2_customer_acc, v_g2_supplier_acc, v_g2_ie_sales_acc, v_g2_ie_cogs_acc, true, v_user_b)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, group_id, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES
    (v_loc_b1, v_client_b, v_company_b, 'TEST074B Loc1 (Grp1)', 'B74B1', v_group1_b, true, false, false, true, now()),
    (v_loc_b2, v_client_b, v_company_b, 'TEST074B Loc2 (Grp2)', 'B74B2', v_group2_b, true, false, false, true, now()),
    (v_loc_b3, v_client_b, v_company_b, 'TEST074B Loc3 (Grp1)', 'B74B3', v_group1_b, true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_b, v_client_b, v_company_b, 'STX-B01', 'Transfer Test Item B', v_usd_b, 'NONE', v_user_b)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_b, v_client_b, v_company_b, 'FY TEST074B', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_b, v_company_b, v_stock_link_type, 'COMPANY'),
    (v_client_b, v_company_b, v_transit_link_type, 'COMPANY'),
    (v_client_b, v_company_b, v_loss_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_b, v_company_b, v_stock_link_type, NULL, v_stock_acc_b),
    (v_client_b, v_company_b, v_transit_link_type, NULL, v_transit_acc_b),
    (v_client_b, v_company_b, v_loss_link_type, NULL, v_loss_acc_b)
  ON CONFLICT DO NOTHING;

  -- Seed 20 units of product B @ cost 10 (=200) at Loc1 (Group 1) and
  -- Loc3 (also Group 1) via opening stock, same pattern as Company A.
  PERFORM fn_post_stock_movement(
    v_client_b, v_company_b, v_loc_b1, v_product_b,
    '2026-06-01'::date, 'OPENING_STOCK', 20,
    10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-B-001', '2026-06-01'::date, v_user_b
  );
  PERFORM fn_post_stock_movement(
    v_client_b, v_company_b, v_loc_b3, v_product_b,
    '2026-06-01'::date, 'OPENING_STOCK', 20,
    10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-B-002', '2026-06-01'::date, v_user_b
  );

  PERFORM set_config('pgtap.v_client_a', v_client_a::text, false);
  PERFORM set_config('pgtap.v_company_a', v_company_a::text, false);
  PERFORM set_config('pgtap.v_loc_a1', v_loc_a1::text, false);
  PERFORM set_config('pgtap.v_loc_a2', v_loc_a2::text, false);
  PERFORM set_config('pgtap.v_user_a', v_user_a::text, false);
  PERFORM set_config('pgtap.v_product_a', v_product_a::text, false);
  PERFORM set_config('pgtap.v_charge_a', v_charge_a::text, false);
  PERFORM set_config('pgtap.v_freight_acc_a', v_freight_acc_a::text, false);
  PERFORM set_config('pgtap.v_transit_acc_a', v_transit_acc_a::text, false);
  PERFORM set_config('pgtap.v_loss_acc_a', v_loss_acc_a::text, false);

  PERFORM set_config('pgtap.v_client_b', v_client_b::text, false);
  PERFORM set_config('pgtap.v_company_b', v_company_b::text, false);
  PERFORM set_config('pgtap.v_loc_b1', v_loc_b1::text, false);
  PERFORM set_config('pgtap.v_loc_b2', v_loc_b2::text, false);
  PERFORM set_config('pgtap.v_loc_b3', v_loc_b3::text, false);
  PERFORM set_config('pgtap.v_user_b', v_user_b::text, false);
  PERFORM set_config('pgtap.v_product_b', v_product_b::text, false);
  PERFORM set_config('pgtap.v_g1_customer_acc', v_g1_customer_acc::text, false);
  PERFORM set_config('pgtap.v_g1_supplier_acc', v_g1_supplier_acc::text, false);
  PERFORM set_config('pgtap.v_g1_ie_sales_acc', v_g1_ie_sales_acc::text, false);
  PERFORM set_config('pgtap.v_g1_ie_cogs_acc', v_g1_ie_cogs_acc::text, false);
  PERFORM set_config('pgtap.v_g2_customer_acc', v_g2_customer_acc::text, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(24);

-- ══════════════════════════════════════════════════════════════════════════
-- SCENARIO A (SIMPLE company): Request -> Transfer (10 units, with a $15
-- freight charge) -> Receipt confirming only 9 (1 short).
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_req_no text;
BEGIN
  v_req_no := fn_save_stock_transfer_request(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_a'), 'company_id', current_setting('pgtap.v_company_a'),
      'from_location_id', current_setting('pgtap.v_loc_a1'), 'to_location_id', current_setting('pgtap.v_loc_a2'),
      'request_no', NULL, 'request_date', '2026-06-05', 'remarks', 'Test A'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_a'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10)),
    current_setting('pgtap.v_user_a')::uuid
  );
  PERFORM set_config('pgtap.v_req_a', v_req_no, false);
  PERFORM fn_approve_stock_transfer_request(
    current_setting('pgtap.v_client_a')::uuid, current_setting('pgtap.v_company_a')::uuid,
    v_req_no, '2026-06-05'::date, current_setting('pgtap.v_user_a')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_transfer_requests WHERE request_no = current_setting('pgtap.v_req_a')) = 'APPROVED',
  'ok 1 — Stock Transfer Request A approved'
);

DO $$
DECLARE v_transfer_no text;
BEGIN
  v_transfer_no := fn_save_stock_transfer(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_a'), 'company_id', current_setting('pgtap.v_company_a'),
      'from_location_id', current_setting('pgtap.v_loc_a1'), 'to_location_id', current_setting('pgtap.v_loc_a2'),
      'transfer_no', NULL, 'transfer_date', '2026-06-06', 'against_request', true,
      'source_request_no', current_setting('pgtap.v_req_a'), 'source_request_date', '2026-06-05', 'remarks', 'Test A transfer'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1,
      'source_request_no', current_setting('pgtap.v_req_a'), 'source_request_date', '2026-06-05', 'source_request_line_serial', 1,
      'product_id', current_setting('pgtap.v_product_a'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'charge_amount', 15)),
    '[]'::jsonb, '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'charge_id', current_setting('pgtap.v_charge_a'),
      'charge_name', 'Freight A', 'nature', 'ADD', 'gl_account_id', current_setting('pgtap.v_freight_acc_a'),
      'amount_or_percent', 'AMOUNT', 'amount', 15)),
    current_setting('pgtap.v_user_a')::uuid
  );
  PERFORM set_config('pgtap.v_transfer_a', v_transfer_no, false);
  PERFORM fn_approve_stock_transfer(
    current_setting('pgtap.v_client_a')::uuid, current_setting('pgtap.v_company_a')::uuid,
    v_transfer_no, '2026-06-06'::date, current_setting('pgtap.v_user_a')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_a')) = 'APPROVED'
  AND (SELECT posting_mode FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_a')) = 'SAME_BOOK',
  'ok 2 — Transfer A approved, posting_mode = SAME_BOOK (SIMPLE company)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client_a')::uuid AND location_id = current_setting('pgtap.v_loc_a1')::uuid
     AND product_id = current_setting('pgtap.v_product_a')::uuid) = 10,
  'ok 3 — FROM location stock drops 20 -> 10 immediately at Transfer-approve'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_transfer_requests WHERE request_no = current_setting('pgtap.v_req_a')) = 'CLOSED',
  'ok 4 — Request A rolls up to CLOSED (10 of 10 transferred)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_a'))) = 'STXJ',
  'ok 5 — Transfer A posts a dedicated STXJ voucher'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_a'))) = 0,
  'ok 6 — STXJ voucher balances exactly on its own (stock 100 + freight 15 = transit 115)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_a'))
     AND account_id = current_setting('pgtap.v_transit_acc_a')::uuid AND trans_nature = 'DR') = 115,
  'ok 7 — Stock-in-Transit Dr = cost 100 (10x10) + freight 15 = 115'
);

-- Receipt: confirm only 9 units (1 short).
DO $$
DECLARE v_receipt_no text;
BEGIN
  v_receipt_no := fn_save_stock_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_a'), 'company_id', current_setting('pgtap.v_company_a'),
      'receipt_no', NULL, 'receipt_date', '2026-06-07',
      'source_transfer_no', current_setting('pgtap.v_transfer_a'), 'source_transfer_date', '2026-06-06', 'remarks', 'Test A receipt'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_transfer_line_serial', 1,
      'product_id', current_setting('pgtap.v_product_a'),
      'uom_conversion_factor', 1, 'received_qty_pack', 9, 'received_qty_loose', 0, 'received_base_qty', 9)),
    '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_a')::uuid
  );
  PERFORM set_config('pgtap.v_receipt_a', v_receipt_no, false);
  PERFORM fn_approve_stock_receipt(
    current_setting('pgtap.v_client_a')::uuid, current_setting('pgtap.v_company_a')::uuid,
    v_receipt_no, '2026-06-07'::date, current_setting('pgtap.v_user_a')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_receipts WHERE receipt_no = current_setting('pgtap.v_receipt_a')) = 'APPROVED'
  AND (SELECT status FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_a')) = 'CLOSED',
  'ok 8 — Receipt A approved, Transfer A closes'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client_a')::uuid AND location_id = current_setting('pgtap.v_loc_a2')::uuid
     AND product_id = current_setting('pgtap.v_product_a')::uuid) = 9,
  'ok 9 — TO location receives exactly 9 (the confirmed qty, not the full 10 transferred)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_receipts WHERE receipt_no = current_setting('pgtap.v_receipt_a'))) = 0,
  'ok 10 — Receipt A''s STXJ voucher balances on its own (stock 90 + loss 10 = transit cleared 100)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_receipts WHERE receipt_no = current_setting('pgtap.v_receipt_a'))
     AND account_id = current_setting('pgtap.v_loss_acc_a')::uuid) = 11.5,
  'ok 11 — Stock Transfer Loss Dr = 1 unit shortfall x LANDED unit value 11.5 ((100 cost + 15 freight)/10) = 11.5'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_receipts WHERE receipt_no = current_setting('pgtap.v_receipt_a'))
     AND account_id = current_setting('pgtap.v_transit_acc_a')::uuid AND trans_nature = 'CR') = 115,
  'ok 12 — Stock-in-Transit is cleared for the FULL originally-transferred value (115), not just what arrived'
);

-- Second receipt attempt on the same (now CLOSED) transfer must fail — one
-- receipt per transfer, by the UNIQUE(source_transfer_no, source_transfer_date).
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_stock_receipt(
       jsonb_build_object('client_id', %L, 'company_id', %L, 'receipt_no', NULL, 'receipt_date', '2026-06-08',
         'source_transfer_no', %L, 'source_transfer_date', '2026-06-06'),
       jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_transfer_line_serial', 1,
         'product_id', %L, 'uom_conversion_factor', 1, 'received_qty_pack', 1, 'received_qty_loose', 0, 'received_base_qty', 1)),
       '[]'::jsonb, '[]'::jsonb, %L::uuid
     ) $$,
     current_setting('pgtap.v_client_a'), current_setting('pgtap.v_company_a'), current_setting('pgtap.v_transfer_a'),
     current_setting('pgtap.v_product_a'), current_setting('pgtap.v_user_a')
  ),
  format('Stock Transfer %s is %s — only an APPROVED transfer can be received.', current_setting('pgtap.v_transfer_a'), 'CLOSED'),
  'ok 13 — a second receipt against an already-CLOSED transfer is rejected'
);

-- ══════════════════════════════════════════════════════════════════════════
-- SCENARIO B1 (INTER_ENTITY company, SAME GROUP): Loc1 -> Loc3, both
-- Group 1 -> must still resolve SAME_BOOK despite the company being
-- INTER_ENTITY, since same group_id always means pure stock transfer.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_transfer_no text;
BEGIN
  v_transfer_no := fn_save_stock_transfer(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_b'), 'company_id', current_setting('pgtap.v_company_b'),
      'from_location_id', current_setting('pgtap.v_loc_b1'), 'to_location_id', current_setting('pgtap.v_loc_b3'),
      'transfer_no', NULL, 'transfer_date', '2026-06-06', 'against_request', false, 'remarks', 'Test B1 same-group'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_b'),
      'uom_conversion_factor', 1, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'charge_amount', 0)),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM set_config('pgtap.v_transfer_b1', v_transfer_no, false);
  PERFORM fn_approve_stock_transfer(
    current_setting('pgtap.v_client_b')::uuid, current_setting('pgtap.v_company_b')::uuid,
    v_transfer_no, '2026-06-06'::date, current_setting('pgtap.v_user_b')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT posting_mode FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_b1')) = 'SAME_BOOK',
  'ok 14 — same-group transfer (Loc1 -> Loc3, both Group 1) resolves SAME_BOOK even though the company is INTER_ENTITY'
);

-- ══════════════════════════════════════════════════════════════════════════
-- SCENARIO B2 (INTER_ENTITY company, CROSS GROUP): Loc1 (Group1) ->
-- Loc2 (Group2), 10 units, cost 10, sales_price 15 (profit margin) ->
-- Receipt confirms only 9 (1 short, at sales_price).
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_transfer_no text;
BEGIN
  v_transfer_no := fn_save_stock_transfer(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_b'), 'company_id', current_setting('pgtap.v_company_b'),
      'from_location_id', current_setting('pgtap.v_loc_b1'), 'to_location_id', current_setting('pgtap.v_loc_b2'),
      'transfer_no', NULL, 'transfer_date', '2026-06-10', 'against_request', false, 'remarks', 'Test B2 cross-group'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_b'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'sales_price', 15, 'charge_amount', 0)),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM set_config('pgtap.v_transfer_b2', v_transfer_no, false);
  PERFORM fn_approve_stock_transfer(
    current_setting('pgtap.v_client_b')::uuid, current_setting('pgtap.v_company_b')::uuid,
    v_transfer_no, '2026-06-10'::date, current_setting('pgtap.v_user_b')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT posting_mode FROM rih_stock_transfers WHERE transfer_no = current_setting('pgtap.v_transfer_b2')) = 'INTER_ENTITY',
  'ok 15 — cross-group transfer (Loc1/Group1 -> Loc2/Group2) resolves INTER_ENTITY'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (
    SELECT 1 FROM rih_finance_headers h
    WHERE h.source_doc_type = 'STOCK_TRANSFER' AND h.source_doc_no = current_setting('pgtap.v_transfer_b2')
      AND h.voucher_type_code = 'STXS'
  ),
  'ok 16 — a dedicated STXS (sale) voucher is posted for the cross-group transfer'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers h
   WHERE h.source_doc_type = 'STOCK_TRANSFER' AND h.source_doc_no = current_setting('pgtap.v_transfer_b2')
     AND h.voucher_type_code = 'STXC') IS NOT NULL,
  'ok 17 — a dedicated STXC (cost of sale) voucher is ALSO posted (two separate, both final)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines l
   JOIN rih_finance_headers h ON h.trans_no = l.trans_no
   WHERE h.source_doc_type = 'STOCK_TRANSFER' AND h.source_doc_no = current_setting('pgtap.v_transfer_b2')
     AND h.voucher_type_code = 'STXS' AND l.account_id = current_setting('pgtap.v_g1_ie_sales_acc')::uuid) = 150,
  'ok 18 — Group1''s Inter-Entity Sales Cr = 10 units x sales_price 15 = 150'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines l
   JOIN rih_finance_headers h ON h.trans_no = l.trans_no
   WHERE h.source_doc_type = 'STOCK_TRANSFER' AND h.source_doc_no = current_setting('pgtap.v_transfer_b2')
     AND h.voucher_type_code = 'STXC' AND l.account_id = current_setting('pgtap.v_g1_ie_cogs_acc')::uuid) = 100,
  'ok 19 — Group1''s Inter-Entity COGS Dr = 10 units x cost_price 10 = 100 -> 50 profit recognized'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT inv_bill_no FROM rid_finance_lines l
   JOIN rih_finance_headers h ON h.trans_no = l.trans_no
   WHERE h.source_doc_type = 'STOCK_TRANSFER' AND h.source_doc_no = current_setting('pgtap.v_transfer_b2')
     AND h.voucher_type_code = 'STXS' AND l.account_id = current_setting('pgtap.v_g2_customer_acc')::uuid) = current_setting('pgtap.v_transfer_b2'),
  'ok 20 — Group2''s receivable (Group2''s own customer_account Dr, the TO group) is tagged with the transfer''s own number, riding the pending-bills mechanism'
);

-- Receipt B2: confirm only 9 units (1 short, at sales_price 15).
DO $$
DECLARE v_receipt_no text;
BEGIN
  v_receipt_no := fn_save_stock_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_b'), 'company_id', current_setting('pgtap.v_company_b'),
      'receipt_no', NULL, 'receipt_date', '2026-06-11',
      'source_transfer_no', current_setting('pgtap.v_transfer_b2'), 'source_transfer_date', '2026-06-10', 'remarks', 'Test B2 receipt'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_transfer_line_serial', 1,
      'product_id', current_setting('pgtap.v_product_b'),
      'uom_conversion_factor', 1, 'received_qty_pack', 9, 'received_qty_loose', 0, 'received_base_qty', 9)),
    '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM set_config('pgtap.v_receipt_b2', v_receipt_no, false);
  PERFORM fn_approve_stock_receipt(
    current_setting('pgtap.v_client_b')::uuid, current_setting('pgtap.v_company_b')::uuid,
    v_receipt_no, '2026-06-11'::date, current_setting('pgtap.v_user_b')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_receipts WHERE receipt_no = current_setting('pgtap.v_receipt_b2'))) = 'STXP',
  'ok 21 — Receipt B2 posts a dedicated STXP voucher'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_receipts WHERE receipt_no = current_setting('pgtap.v_receipt_b2'))) = 0,
  'ok 22 — STXP voucher balances on its own (stock 135 + loss 15 = payable 150)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_receipts WHERE receipt_no = current_setting('pgtap.v_receipt_b2'))
     AND account_id = current_setting('pgtap.v_g1_supplier_acc')::uuid) = 150,
  'ok 23 — Group1''s supplier_account Cr = FULL transferred qty x sales_price (10x15=150), unaffected by TO''s shortage'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client_b')::uuid AND location_id = current_setting('pgtap.v_loc_b2')::uuid
     AND product_id = current_setting('pgtap.v_product_b')::uuid) = 9,
  'ok 24 — TO location (Group2) receives exactly 9 units into its own stock'
);

-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
