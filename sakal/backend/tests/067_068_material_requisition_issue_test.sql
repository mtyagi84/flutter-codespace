-- ============================================================
-- 067_068_material_requisition_issue_test.sql — pgTAP tests for
-- migrations 066/067/068 (Department Consumption Areas, Material
-- Requisition, Material Issue for Consumption)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. Supabase's SQL editor only displays the LAST statement's result
--      grid, discarding each individual SELECT ok(...)'s own row along
--      the way — so every assertion result is captured into a temp table
--      (test_results) instead, and the final query at the bottom of this
--      file dumps them all in one grid. Look for any row NOT starting
--      with "ok " (i.e. starting with "not ok ") — that's your failure,
--      with pgTAP's own expected/actual diagnostic text right below it.
--
-- Fixture: one UNTRACKED product (via GRN, 10 units @ 20 = 200) and one
-- BATCH-tracked product (via GRN, 6 units as LOT-A). Department "Cutting"
-- has two consumption areas configured: "Machine Floor" (linked, has an
-- expense account) and a second area deliberately left UNLINKED to test
-- the mismatch rejection.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client_id       uuid := '00000000-0000-0000-0068-000000000001';
  v_company_id      uuid := '00000000-0000-0000-0068-000000000002';
  v_loc_id          uuid := '00000000-0000-0000-0068-000000000003';
  v_user_id         uuid := '00000000-0000-0000-0068-000000000004';
  v_usd_ccy_id      uuid;
  v_supplier_id     uuid := '00000000-0000-0000-0068-000000000006';
  v_stock_acc_id    uuid := '00000000-0000-0000-0068-000000000007';
  v_expense_acc_id  uuid := '00000000-0000-0000-0068-000000000008';
  v_accrual_acc_id  uuid := '00000000-0000-0000-0068-000000000009';
  v_product_id      uuid := '00000000-0000-0000-0068-000000000011';
  v_batch_product_id uuid := '00000000-0000-0000-0068-000000000012';
  v_fy_id           uuid := '00000000-0000-0000-0068-000000000013';
  v_stock_link_type uuid; v_accrual_link_type uuid;
  v_dept_type_id uuid; v_area_type_id uuid;
  v_dept_id uuid := '00000000-0000-0000-0068-000000000021';
  v_area_linked_id uuid := '00000000-0000-0000-0068-000000000022';
  v_area_unlinked_id uuid := '00000000-0000-0000-0068-000000000023';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST068', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST068 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test068 Loc', 'T68', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test068', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier_id,    v_client_id, v_company_id, '5068', 'Test068 Supplier', 'Supplier', 'OHADA', true, true, false, now()),
    (v_stock_acc_id,   v_client_id, v_company_id, '1368', 'Stock Account',    'General',  'OHADA', true, true, false, now()),
    (v_expense_acc_id, v_client_id, v_company_id, '6068', 'Consumption Expense - Cutting', 'General', 'OHADA', true, true, false, now()),
    (v_accrual_acc_id, v_client_id, v_company_id, '2268', 'Purchase Accrual', 'General',  'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'MIC-001', 'Consumable Item', v_usd_ccy_id, 'NONE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_batch_product_id, v_client_id, v_company_id, 'MIC-002', 'Consumable Batch Item', v_usd_ccy_id, 'BATCH', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST068', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link_type   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_accrual_link_type FROM rim_account_link_types WHERE link_key = 'PURCHASE_ACCRUAL_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_accrual_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, NULL, v_stock_acc_id),
    (v_client_id, v_company_id, v_accrual_link_type, NULL, v_accrual_acc_id)
  ON CONFLICT DO NOTHING;

  -- Department + Consumption Areas (066)
  SELECT id INTO v_dept_type_id FROM rim_common_master_types WHERE type_key = 'DEPARTMENT';
  SELECT id INTO v_area_type_id FROM rim_common_master_types WHERE type_key = 'CONSUMPTION_AREA';

  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES
    (v_dept_id,         v_client_id, v_company_id, v_dept_type_id, 'Cutting',       v_user_id),
    (v_area_linked_id,   v_client_id, v_company_id, v_area_type_id, 'Machine Floor', v_user_id),
    (v_area_unlinked_id, v_client_id, v_company_id, v_area_type_id, 'Unlinked Area', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_department_consumption_areas (client_id, company_id, department_id, consumption_area_id, account_id, created_by)
  VALUES (v_client_id, v_company_id, v_dept_id, v_area_linked_id, v_expense_acc_id, v_user_id)
  ON CONFLICT DO NOTHING;

  PERFORM set_config('pgtap.v_usd_ccy_068', v_usd_ccy_id::text, false);
END;
$$ LANGUAGE plpgsql;

-- ── GRN1: untracked product, 10 units @ 20 = 200 ─────────────────────────────
DO $$
DECLARE v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-01', 'supplier_id', '00000000-0000-0000-0068-000000000006',
      'receipt_mode', 'DIRECT', 'grn_currency_id', current_setting('pgtap.v_usd_ccy_068'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', '00000000-0000-0000-0068-000000000011',
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 20,
      'gross_amount', 200, 'tax_amount', 0, 'final_amount', 200, 'charge_amount', 0, 'landed_amount', 200
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM fn_approve_grn('00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
    v_grn_no, '2026-06-01'::date, '00000000-0000-0000-0068-000000000004');
END;
$$ LANGUAGE plpgsql;

-- ── GRN2: batch product, 6 units as LOT-A @ 50 = 300 ────────────────────────
DO $$
DECLARE v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-01', 'supplier_id', '00000000-0000-0000-0068-000000000006',
      'receipt_mode', 'DIRECT', 'grn_currency_id', current_setting('pgtap.v_usd_ccy_068'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', '00000000-0000-0000-0068-000000000012',
      'qty_pack', 6, 'qty_loose', 0, 'base_qty', 6, 'rate', 50,
      'gross_amount', 300, 'tax_amount', 0, 'final_amount', 300, 'charge_amount', 0, 'landed_amount', 300
    )),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'LOT-A', 'qty_pack', 6, 'qty_loose', 0, 'base_qty', 6)),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM fn_approve_grn('00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
    v_grn_no, '2026-06-01'::date, '00000000-0000-0000-0068-000000000004');
END;
$$ LANGUAGE plpgsql;

SELECT plan(20);

INSERT INTO test_results (result) SELECT ok(
  (SELECT cost_price FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0068-000000000001' AND product_id = '00000000-0000-0000-0068-000000000011') = 20,
  'ok 1 — untracked product cost_price = 20 after its GRN'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Requisition A: 4 units untracked (dept/area OK) + 6 units batch product
-- (dept/area OK). Save succeeds; Approve validates.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_req_no text;
BEGIN
  v_req_no := fn_save_material_requisition(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'requisition_no', NULL, 'requisition_date', '2026-06-05',
      'requested_by', 'Floor Supervisor', 'reason', 'Production run'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0068-000000000011',
        'uom_conversion_factor', 1, 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4,
        'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022'),
      jsonb_build_object('serial_no', 2, 'product_id', '00000000-0000-0000-0068-000000000012',
        'uom_conversion_factor', 1, 'qty_pack', 6, 'qty_loose', 0, 'base_qty', 6,
        'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022')
    ),
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM set_config('pgtap.v_req_a_068', v_req_no, false);
  PERFORM fn_approve_material_requisition('00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
    v_req_no, '2026-06-05'::date, '00000000-0000-0000-0068-000000000004');
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_requisition_headers WHERE requisition_no = current_setting('pgtap.v_req_a_068')) = 'APPROVED',
  'ok 2 — Requisition A approved (department/area pair valid)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Requisition B: single line using the UNLINKED consumption area — Approve
-- must reject with LINE_DEPARTMENT_AREA_MISMATCH.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_req_no text;
BEGIN
  v_req_no := fn_save_material_requisition(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'requisition_no', NULL, 'requisition_date', '2026-06-05', 'requested_by', 'Floor Supervisor'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0068-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1,
      'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000023')),
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM set_config('pgtap.v_req_b_068', v_req_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_approve_material_requisition(
       '00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
       current_setting('pgtap.v_req_b_068'), '2026-06-05'::date, '00000000-0000-0000-0068-000000000004'
     ) $$,
  'LINE_DEPARTMENT_AREA_MISMATCH',
  'ok 3 — an unlinked consumption area is rejected at Approve time'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Requisition C: future-dated — Approve must reject with FUTURE_DATE_NOT_ALLOWED.
-- Deliberately just 30 days ahead of CURRENT_DATE (not a hardcoded far-future
-- literal like 2099-01-01) — it must stay INSIDE the fixture's own FY
-- TEST068 window (2020-01-01..2030-12-31), or fn_check_period_open rejects
-- it with FY_CLOSED before the future-date check ever gets a chance to fire
-- (period/backdate checks correctly run first, matching every other module).
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_req_no text; v_future_date date := current_date + 30;
BEGIN
  v_req_no := fn_save_material_requisition(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'requisition_no', NULL, 'requisition_date', v_future_date, 'requested_by', 'Floor Supervisor'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0068-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1,
      'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022')),
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM set_config('pgtap.v_req_c_068', v_req_no, false);
  PERFORM set_config('pgtap.v_future_date_068', v_future_date::text, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_approve_material_requisition(
       '00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
       current_setting('pgtap.v_req_c_068'), current_setting('pgtap.v_future_date_068')::date, '00000000-0000-0000-0068-000000000004'
     ) $$,
  'FUTURE_DATE_NOT_ALLOWED',
  'ok 4 — a future-dated requisition is rejected at Approve time'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Material Issue A: partial issue of the untracked line (2 of 4 requested)
-- + full issue of the batch line (6 of 6, allocated to LOT-A).
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_issue_no text;
BEGIN
  v_issue_no := fn_save_material_issue(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'issue_no', NULL, 'issue_date', '2026-06-10'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1,
        'source_requisition_no', current_setting('pgtap.v_req_a_068'), 'source_requisition_date', '2026-06-05', 'source_requisition_line_serial', 1,
        'product_id', '00000000-0000-0000-0068-000000000011',
        'uom_conversion_factor', 1, 'qty_pack', 2, 'qty_loose', 0, 'base_qty', 2,
        'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022'),
      jsonb_build_object('serial_no', 2,
        'source_requisition_no', current_setting('pgtap.v_req_a_068'), 'source_requisition_date', '2026-06-05', 'source_requisition_line_serial', 2,
        'product_id', '00000000-0000-0000-0068-000000000012',
        'uom_conversion_factor', 1, 'qty_pack', 6, 'qty_loose', 0, 'base_qty', 6,
        'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022')
    ),
    jsonb_build_array(jsonb_build_object('line_serial', 2, 'batch_no', 'LOT-A', 'qty_pack', 6, 'qty_loose', 0, 'base_qty', 6)),
    '[]'::jsonb,
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM set_config('pgtap.v_issue_a_068', v_issue_no, false);
  PERFORM fn_approve_material_issue('00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
    v_issue_no, '2026-06-10'::date, '00000000-0000-0000-0068-000000000004');
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_issue_headers WHERE issue_no = current_setting('pgtap.v_issue_a_068')) = 'APPROVED',
  'ok 5 — Material Issue A approved'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0068-000000000001' AND product_id = '00000000-0000-0000-0068-000000000011') = 8,
  'ok 6 — untracked product stock drops 10 -> 8 (issued 2)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0068-000000000001' AND product_id = '00000000-0000-0000-0068-000000000012') = 0,
  'ok 7 — batch product stock drops 6 -> 0 (issued all 6, all from LOT-A)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT balance FROM v_batch_stock_balance
   WHERE client_id = '00000000-0000-0000-0068-000000000001' AND product_id = '00000000-0000-0000-0068-000000000012' AND batch_no = 'LOT-A') = 0,
  'ok 8 — LOT-A balance is exactly 0 after the batch issue'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_material_issue_headers WHERE issue_no = current_setting('pgtap.v_issue_a_068'))) = 'MIC',
  'ok 9 — posts a dedicated MIC voucher, not JV'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_material_issue_headers WHERE issue_no = current_setting('pgtap.v_issue_a_068'))
     AND is_deleted = false) = 4,
  'ok 10 — 4 lines total: Dr Expense + Cr Stock, once per issue line (2 lines x 2)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(trans_amount) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_material_issue_headers WHERE issue_no = current_setting('pgtap.v_issue_a_068'))
     AND source_line_type = 'CONSUMPTION_EXPENSE' AND source_line_no = 1) = 40,
  'ok 11 — untracked line Dr Expense = 2 units x cost_price 20 = 40'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT account_id FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_material_issue_headers WHERE issue_no = current_setting('pgtap.v_issue_a_068'))
     AND source_line_type = 'CONSUMPTION_EXPENSE' AND source_line_no = 1) = '00000000-0000-0000-0068-000000000008',
  'ok 12 — Dr posts to the resolved Consumption Expense account for Cutting/Machine Floor'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_material_issue_headers WHERE issue_no = current_setting('pgtap.v_issue_a_068'))
     AND source_line_type = 'CONSUMPTION_EXPENSE' AND source_line_no = 2) = 300,
  'ok 13 — batch line Dr Expense = 6 units x cost_price 50 = 300'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_material_issue_headers WHERE issue_no = current_setting('pgtap.v_issue_a_068'))) = 0,
  'ok 14 — MIC voucher balances exactly on its own'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT issued_qty FROM rid_material_requisition_lines
   WHERE requisition_no = current_setting('pgtap.v_req_a_068') AND serial_no = 1) = 2
  AND
  (SELECT issued_qty FROM rid_material_requisition_lines
   WHERE requisition_no = current_setting('pgtap.v_req_a_068') AND serial_no = 2) = 6,
  'ok 15 — requisition lines'' issued_qty rolled up correctly (2 and 6)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_requisition_headers WHERE requisition_no = current_setting('pgtap.v_req_a_068')) = 'PARTIALLY_ISSUED',
  'ok 16 — requisition status is PARTIALLY_ISSUED (line 1 only 2 of 4 issued)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Over-issue: try to issue 3 more of the untracked line (only 2 remain: 4-2).
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_issue_no text;
BEGIN
  v_issue_no := fn_save_material_issue(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'issue_no', NULL, 'issue_date', '2026-06-11'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1,
      'source_requisition_no', current_setting('pgtap.v_req_a_068'), 'source_requisition_date', '2026-06-05', 'source_requisition_line_serial', 1,
      'product_id', '00000000-0000-0000-0068-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3,
      'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022')),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM set_config('pgtap.v_issue_b_068', v_issue_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_approve_material_issue(
       '00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
       current_setting('pgtap.v_issue_b_068'), '2026-06-11'::date, '00000000-0000-0000-0068-000000000004'
     ) $$,
  'ISSUE_QTY_EXCEEDS_REQUESTED',
  'ok 17 — issuing 3 more (only 2 remain) is rejected'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Material Issue B (corrected): issue exactly the remaining 2 -> requisition
-- fully issued, status CLOSED.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_issue_no text;
BEGIN
  v_issue_no := fn_save_material_issue(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'issue_no', NULL, 'issue_date', '2026-06-12'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1,
      'source_requisition_no', current_setting('pgtap.v_req_a_068'), 'source_requisition_date', '2026-06-05', 'source_requisition_line_serial', 1,
      'product_id', '00000000-0000-0000-0068-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 2, 'qty_loose', 0, 'base_qty', 2,
      'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022')),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM set_config('pgtap.v_issue_c_068', v_issue_no, false);
  PERFORM fn_approve_material_issue('00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
    v_issue_no, '2026-06-12'::date, '00000000-0000-0000-0068-000000000004');
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_requisition_headers WHERE requisition_no = current_setting('pgtap.v_req_a_068')) = 'CLOSED',
  'ok 18 — requisition status flips to CLOSED once fully issued (4 of 4)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0068-000000000001' AND product_id = '00000000-0000-0000-0068-000000000011') = 6,
  'ok 19 — untracked product stock drops further 8 -> 6'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Batch strict check plumbing: attempt to issue against LOT-A again — none
-- left (balance 0) — proves the shared 063 check fires through this new
-- caller too, even though both flags could otherwise allow negative stock.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_grn2_no text; v_req2_no text; v_issue_no text;
BEGIN
  -- A fresh 1-unit requisition against the (empty) batch product so an
  -- Issue can be attempted against LOT-A with nothing left in it.
  v_req2_no := fn_save_material_requisition(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'requisition_no', NULL, 'requisition_date', '2026-06-13', 'requested_by', 'Floor Supervisor'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0068-000000000012',
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1,
      'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022')),
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM fn_approve_material_requisition('00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
    v_req2_no, '2026-06-13'::date, '00000000-0000-0000-0068-000000000004');

  v_issue_no := fn_save_material_issue(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0068-000000000001', 'company_id', '00000000-0000-0000-0068-000000000002',
      'location_id', '00000000-0000-0000-0068-000000000003',
      'issue_no', NULL, 'issue_date', '2026-06-14'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1,
      'source_requisition_no', v_req2_no, 'source_requisition_date', '2026-06-13', 'source_requisition_line_serial', 1,
      'product_id', '00000000-0000-0000-0068-000000000012',
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1,
      'department_id', '00000000-0000-0000-0068-000000000021', 'consumption_area_id', '00000000-0000-0000-0068-000000000022')),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'LOT-A', 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1)),
    '[]'::jsonb,
    '00000000-0000-0000-0068-000000000004'
  );
  PERFORM set_config('pgtap.v_issue_d_068', v_issue_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_approve_material_issue(
       '00000000-0000-0000-0068-000000000001', '00000000-0000-0000-0068-000000000002',
       current_setting('pgtap.v_issue_d_068'), '2026-06-14'::date, '00000000-0000-0000-0068-000000000004'
     ) $$,
  'BATCH_INSUFFICIENT_STOCK',
  'ok 20 — issuing from an empty batch (LOT-A) is rejected by the shared per-batch check, proven through this new caller'
);

-- Final result: every one of the 20 assertions, in order. Look for any row
-- NOT starting with "ok " — that's the failing one, with pgTAP's own
-- expected-vs-actual diagnostic text right below it in the same column.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
