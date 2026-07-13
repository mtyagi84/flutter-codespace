-- ============================================================
-- 076_stock_adjustment_test.sql — pgTAP tests for Stock Adjustment
-- (migration 076).
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run) — only the final
--      SELECT's grid is shown; every assertion is captured into
--      test_results and dumped in one grid at the bottom. Any row NOT
--      starting with "ok " is the failure, with pgTAP's diagnostic text
--      right below it.
--
-- One company (SIMPLE), one location, four products:
--   v_product_new      (NONE)   — never stocked, proves COST_NOT_ESTABLISHED
--   v_product_plain    (NONE)   — opening stock 100 @ cost 10, proves
--                                  increase/decrease/negative-stock-block
--   v_product_batch    (BATCH)  — opening batch BATCH-A qty 20 @ cost 5,
--                                  proves new-batch increase / existing-
--                                  batch decrease / over-reduction block
--   v_product_serial   (SERIAL) — opening serials SN-1/SN-2 @ cost 50,
--                                  proves new-serial increase / existing-
--                                  serial decrease / already-removed block
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

-- pgTAP requires a plan() (or no_plan()) before any ok()/is()/throws_ok()
-- call — this file has 24 assertions across its several DO blocks below,
-- captured into test_results the same as every other test in this suite,
-- but was missing this declaration entirely (the only file in the suite
-- with that gap — every ok()/throws_ok() call would raise "You tried to
-- run a test without a plan!" the moment it executed).
SELECT plan(24);

-- ══════════════════════════════════════════════════════════════════════════
-- Fixture
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client   uuid := '00000000-0000-0000-0076-000000000001';
  v_company  uuid := '00000000-0000-0000-0076-000000000002';
  v_loc      uuid := '00000000-0000-0000-0076-000000000003';
  v_user     uuid := '00000000-0000-0000-0076-000000000004';
  v_usd      uuid;
  v_stock_acc uuid := '00000000-0000-0000-0076-000000000005';
  v_adj_acc   uuid := '00000000-0000-0000-0076-000000000006';
  v_product_new    uuid := '00000000-0000-0000-0076-000000000007';
  v_product_plain  uuid := '00000000-0000-0000-0076-000000000008';
  v_product_batch  uuid := '00000000-0000-0000-0076-000000000009';
  v_product_serial uuid := '00000000-0000-0000-0076-00000000000a';
  v_fy       uuid := '00000000-0000-0000-0076-00000000000b';
  v_reason_header uuid := '00000000-0000-0000-0076-00000000000c';
  v_reason_line   uuid := '00000000-0000-0000-0076-00000000000d';
  v_reason_type_id uuid;
  v_stock_link_type uuid;
  v_adj_link_type   uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client, 'TEST076', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company, v_client, 'TEST076 CO', 'USD', 'USD', 'SIMPLE', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES (v_loc, v_client, v_company, 'TEST076 Loc', 'T076L', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user, v_client, v_company, 'test076', 'Test User 076', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd FROM rim_currencies WHERE client_id = v_client AND company_id = v_company AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_stock_acc, v_client, v_company, '13X1', 'Stock Account 076',            'General', 'OHADA', true, true, false, now()),
    (v_adj_acc,   v_client, v_company, '61X1', 'Stock Adjustment Account 076', 'General', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_product_new,    v_client, v_company, 'ADJ-NEW', 'Never Stocked Item',  v_usd, 'NONE',   v_user),
    (v_product_plain,  v_client, v_company, 'ADJ-PLN', 'Plain Adjust Item',   v_usd, 'NONE',   v_user),
    (v_product_batch,  v_client, v_company, 'ADJ-BAT', 'Batch Adjust Item',   v_usd, 'BATCH',  v_user),
    (v_product_serial, v_client, v_company, 'ADJ-SER', 'Serial Adjust Item',  v_usd, 'SERIAL', v_user)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy, v_client, v_company, 'FY TEST076', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link_type FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_adj_link_type   FROM rim_account_link_types WHERE link_key = 'STOCK_ADJUSTMENT_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client, v_company, v_stock_link_type, 'COMPANY'),
    (v_client, v_company, v_adj_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client, v_company, v_stock_link_type, NULL, v_stock_acc),
    (v_client, v_company, v_adj_link_type, NULL, v_adj_acc)
  ON CONFLICT DO NOTHING;

  -- Opening stock: plain product 100 @ cost 10
  PERFORM fn_post_stock_movement(
    v_client, v_company, v_loc, v_product_plain,
    '2026-07-01'::date, 'OPENING_STOCK', 100,
    10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-076-001', '2026-07-01'::date, v_user
  );

  -- Opening stock: batch product, batch BATCH-A qty 20 @ cost 5
  PERFORM fn_post_stock_movement(
    v_client, v_company, v_loc, v_product_batch,
    '2026-07-01'::date, 'OPENING_STOCK', 20,
    5, 5, 'BATCH-A', NULL, NULL,
    'OPENING_BALANCE', 'OB-076-002', '2026-07-01'::date, v_user
  );

  -- Opening stock: serial product, SN-1 and SN-2 @ cost 50 each
  PERFORM fn_post_stock_movement(
    v_client, v_company, v_loc, v_product_serial,
    '2026-07-01'::date, 'OPENING_STOCK', 1,
    50, 50, NULL, NULL, 'SN-1',
    'OPENING_BALANCE', 'OB-076-003', '2026-07-01'::date, v_user
  );
  PERFORM fn_post_stock_movement(
    v_client, v_company, v_loc, v_product_serial,
    '2026-07-01'::date, 'OPENING_STOCK', 1,
    50, 50, NULL, NULL, 'SN-2',
    'OPENING_BALANCE', 'OB-076-004', '2026-07-01'::date, v_user
  );

  -- Reason common-master rows (header default + a distinct line override)
  SELECT id INTO v_reason_type_id FROM rim_common_master_types WHERE type_key = 'STOCK_ADJUSTMENT_REASON';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, sort_order, created_by)
  VALUES
    (v_reason_header, v_client, v_company, v_reason_type_id, 'TEST076 Header Reason', 90, v_user),
    (v_reason_line,   v_client, v_company, v_reason_type_id, 'TEST076 Line Reason',   91, v_user)
  ON CONFLICT (id) DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client::text, false);
  PERFORM set_config('pgtap.v_company', v_company::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc::text, false);
  PERFORM set_config('pgtap.v_user', v_user::text, false);
  PERFORM set_config('pgtap.v_stock_acc', v_stock_acc::text, false);
  PERFORM set_config('pgtap.v_adj_acc', v_adj_acc::text, false);
  PERFORM set_config('pgtap.v_product_new', v_product_new::text, false);
  PERFORM set_config('pgtap.v_product_plain', v_product_plain::text, false);
  PERFORM set_config('pgtap.v_product_batch', v_product_batch::text, false);
  PERFORM set_config('pgtap.v_product_serial', v_product_serial::text, false);
  PERFORM set_config('pgtap.v_reason_header', v_reason_header::text, false);
  PERFORM set_config('pgtap.v_reason_line', v_reason_line::text, false);
END $$ LANGUAGE plpgsql;


-- ══════════════════════════════════════════════════════════════════════════
-- 1. COST_NOT_ESTABLISHED — a '+' line on a never-stocked product is blocked
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'adjustment_no', NULL, 'adjustment_date', '2026-07-02',
      'reason_id', current_setting('pgtap.v_reason_header'), 'remarks', 'New item test'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_new'),
      'uom_conversion_factor', 1, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'adjust_flag', '+', 'system_qty', 0)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_adj_new', v_adj_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_new')) = 'DRAFT',
  'ok 1 — Stock Adjustment (never-stocked item, +5) saves as DRAFT'
);

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_stock_adjustment(%L::uuid, %L::uuid, %L, '2026-07-02'::date, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_adj_new'), current_setting('pgtap.v_user')),
  'COST_NOT_ESTABLISHED',
  'ok 2 — Approving a "+" line on a never-stocked product is blocked (COST_NOT_ESTABLISHED)'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 2. Plain product — increase, then decrease, then negative-stock block
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'adjustment_no', NULL, 'adjustment_date', '2026-07-02',
      'reason_id', current_setting('pgtap.v_reason_header'), 'remarks', 'Increase test'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_plain'),
      'uom_conversion_factor', 1, 'qty_pack', 20, 'qty_loose', 0, 'base_qty', 20, 'adjust_flag', '+', 'system_qty', 100,
      'reason_id', current_setting('pgtap.v_reason_line'))),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_adj_inc', v_adj_no, false);
  PERFORM fn_approve_stock_adjustment(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_adj_no, '2026-07-02'::date, current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_inc')) = 'APPROVED',
  'ok 3 — Plain product +20 adjustment approves'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_plain')::uuid) = 120,
  'ok 4 — Stock rises 100 -> 120'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT cost_price FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_plain')::uuid) = 10,
  'ok 5 — Moving-average cost stays 10 (blending "current average" into itself is a no-op on cost)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT unit_cost FROM rid_stock_adjustment_lines
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND adjustment_no = current_setting('pgtap.v_adj_inc') AND serial_no = 1) = 10
  AND (SELECT unit_cost_specific FROM rid_stock_adjustment_lines
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND adjustment_no = current_setting('pgtap.v_adj_inc') AND serial_no = 1) = 10,
  'ok 6 — unit_cost/unit_cost_specific are persisted onto the line by Approve (never user-entered)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT reason_id FROM rid_stock_adjustment_lines
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND adjustment_no = current_setting('pgtap.v_adj_inc') AND serial_no = 1)
     = current_setting('pgtap.v_reason_line')::uuid,
  'ok 7 — Per-line reason override is saved distinctly from the header reason'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_inc'))) = 'ADJV',
  'ok 8 — Posts a dedicated ADJV voucher (not generic JV)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_inc'))) = 0,
  'ok 9 — ADJV voucher balances on its own'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_inc'))
     AND account_id = current_setting('pgtap.v_stock_acc')::uuid AND trans_nature = 'DR') = 200,
  'ok 10 — Increase: Dr Stock Account = 20 x cost 10 = 200'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_inc'))
     AND account_id = current_setting('pgtap.v_adj_acc')::uuid AND trans_nature = 'CR') = 200,
  'ok 11 — Increase: Cr Stock Adjustment Account = 200'
);

-- Decrease: -30 (120 -> 90)
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'adjustment_no', NULL, 'adjustment_date', '2026-07-03',
      'reason_id', current_setting('pgtap.v_reason_header'), 'remarks', 'Decrease test'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_plain'),
      'uom_conversion_factor', 1, 'qty_pack', 30, 'qty_loose', 0, 'base_qty', 30, 'adjust_flag', '-', 'system_qty', 120)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_adj_dec', v_adj_no, false);
  PERFORM fn_approve_stock_adjustment(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_adj_no, '2026-07-03'::date, current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_plain')::uuid) = 90,
  'ok 12 — Stock falls 120 -> 90'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_dec'))
     AND account_id = current_setting('pgtap.v_adj_acc')::uuid AND trans_nature = 'DR') = 300,
  'ok 13 — Decrease: Dr Stock Adjustment Account = 30 x cost 10 = 300'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_adj_dec'))
     AND account_id = current_setting('pgtap.v_stock_acc')::uuid AND trans_nature = 'CR') = 300,
  'ok 14 — Decrease: Cr Stock Account = 300'
);

-- Attempt to reduce beyond on-hand (90) with negative stock disallowed
INSERT INTO test_results (result) SELECT throws_ok(
  format($$
    SELECT fn_approve_stock_adjustment(%L::uuid, %L::uuid, fn_save_stock_adjustment(
      jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'adjustment_no', NULL, 'adjustment_date', '2026-07-04',
        'reason_id', %L, 'remarks', 'Over-reduce test'),
      jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L,
        'uom_conversion_factor', 1, 'qty_pack', 100, 'qty_loose', 0, 'base_qty', 100, 'adjust_flag', '-', 'system_qty', 90)),
      '[]'::jsonb, '[]'::jsonb, %L::uuid
    ), '2026-07-04'::date, %L::uuid)
  $$,
  current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
  current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
  current_setting('pgtap.v_reason_header'), current_setting('pgtap.v_product_plain'),
  current_setting('pgtap.v_user'), current_setting('pgtap.v_user')
  ),
  'NEGATIVE_STOCK_NOT_ALLOWED',
  'ok 15 — Reducing beyond on-hand (90) is blocked when negative stock is not allowed'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 3. Batch-tracked product — new-batch increase, existing-batch decrease,
--    over-reduction block
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'adjustment_no', NULL, 'adjustment_date', '2026-07-02',
      'reason_id', current_setting('pgtap.v_reason_header'), 'remarks', 'New batch test'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_batch'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'adjust_flag', '+', 'system_qty', 20)),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'BATCH-B', 'expiry_date', NULL,
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10)),
    '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_stock_adjustment(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_adj_no, '2026-07-02'::date, current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_batch')::uuid) = 30,
  'ok 16 — Batch product: new batch BATCH-B (+10) brings stock 20 -> 30'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT balance FROM v_batch_stock_balance
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_batch')::uuid AND batch_no = 'BATCH-B') = 10,
  'ok 17 — BATCH-B balance is exactly 10'
);

-- Decrease BATCH-A by 5 (existing lot, picked from on-hand)
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'adjustment_no', NULL, 'adjustment_date', '2026-07-03',
      'reason_id', current_setting('pgtap.v_reason_header'), 'remarks', 'Existing batch reduce'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_batch'),
      'uom_conversion_factor', 1, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'adjust_flag', '-', 'system_qty', 30)),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'BATCH-A', 'expiry_date', NULL,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5)),
    '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_stock_adjustment(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_adj_no, '2026-07-03'::date, current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT balance FROM v_batch_stock_balance
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_batch')::uuid AND batch_no = 'BATCH-A') = 15,
  'ok 18 — BATCH-A balance drops 20 -> 15'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_batch')::uuid) = 25,
  'ok 19 — Total batch-product stock falls 30 -> 25'
);

-- Attempt to over-reduce BATCH-A (only 15 left, ask for 20) — must be
-- rejected regardless of allow_negative_stock, since a batch is a specific
-- identifiable lot, never a fungible aggregate quantity.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$
    SELECT fn_approve_stock_adjustment(%L::uuid, %L::uuid, fn_save_stock_adjustment(
      jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'adjustment_no', NULL, 'adjustment_date', '2026-07-04',
        'reason_id', %L, 'remarks', 'Over-reduce batch test'),
      jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L,
        'uom_conversion_factor', 1, 'qty_pack', 20, 'qty_loose', 0, 'base_qty', 20, 'adjust_flag', '-', 'system_qty', 25)),
      jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'BATCH-A', 'expiry_date', NULL,
        'qty_pack', 20, 'qty_loose', 0, 'base_qty', 20)),
      '[]'::jsonb, %L::uuid
    ), '2026-07-04'::date, %L::uuid)
  $$,
  current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
  current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
  current_setting('pgtap.v_reason_header'), current_setting('pgtap.v_product_batch'),
  current_setting('pgtap.v_user'), current_setting('pgtap.v_user')
  ),
  'BATCH_INSUFFICIENT_STOCK',
  'ok 20 — Reducing BATCH-A by more than its own 15 remaining is blocked (batch can never go negative)'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 4. Serial-tracked product — new-serial increase, existing-serial decrease,
--    already-removed block
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'adjustment_no', NULL, 'adjustment_date', '2026-07-02',
      'reason_id', current_setting('pgtap.v_reason_header'), 'remarks', 'New serial test'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_serial'),
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'adjust_flag', '+', 'system_qty', 2)),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'serial_no', 'SN-3')),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_stock_adjustment(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_adj_no, '2026-07-02'::date, current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_serial')::uuid) = 3,
  'ok 21 — Serial product: new serial SN-3 (+1) brings stock 2 -> 3'
);

-- Decrease: remove SN-1
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'adjustment_no', NULL, 'adjustment_date', '2026-07-03',
      'reason_id', current_setting('pgtap.v_reason_header'), 'remarks', 'Existing serial reduce'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_serial'),
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'adjust_flag', '-', 'system_qty', 3)),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'serial_no', 'SN-1')),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_stock_adjustment(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_adj_no, '2026-07-03'::date, current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM v_serial_stock_status
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_serial')::uuid AND serial_no = 'SN-1') = 'OUT',
  'ok 22 — SN-1 status flips to OUT after removal'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_product_serial')::uuid) = 2,
  'ok 23 — Serial-product stock falls 3 -> 2'
);

-- Attempt to remove SN-1 again — already OUT, must be rejected regardless
-- of allow_negative_stock, since a serial is a specific identifiable unit.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$
    SELECT fn_approve_stock_adjustment(%L::uuid, %L::uuid, fn_save_stock_adjustment(
      jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'adjustment_no', NULL, 'adjustment_date', '2026-07-04',
        'reason_id', %L, 'remarks', 'Re-remove SN-1 test'),
      jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L,
        'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'adjust_flag', '-', 'system_qty', 2)),
      '[]'::jsonb,
      jsonb_build_array(jsonb_build_object('line_serial', 1, 'serial_no', 'SN-1')),
      %L::uuid
    ), '2026-07-04'::date, %L::uuid)
  $$,
  current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
  current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
  current_setting('pgtap.v_reason_header'), current_setting('pgtap.v_product_serial'),
  current_setting('pgtap.v_user'), current_setting('pgtap.v_user')
  ),
  'SERIAL_NOT_IN_STOCK',
  'ok 24 — Removing SN-1 a second time is blocked (already OUT)'
);


-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
