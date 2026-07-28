-- ============================================================
-- 112_inventory_approve_permission_test.sql — pgTAP tests for migration
-- 112 (fn_check_approve_permission wired into all 8 Inventory approve
-- functions: Material Requisition/Issue, Stock Transfer Request/Transfer/
-- Receipt, Stock Adjustment, Opening Stock, Stock Count Review)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- The underlying enforcement mechanism (fn_check_approve_permission
-- itself) is already thoroughly tested in
-- 108_finance_voucher_approve_permission_test.sql; this file proves the
-- NEW wiring on all 8 Inventory functions via one denied/approved
-- assertion pair per function, PLUS a dedicated proof of the IN-ADJ
-- guard added in this same migration: a user with IN-CNR (Stock Count
-- Review) approve rights but explicitly WITHOUT IN-ADJ (Stock Adjustment)
-- must still be able to approve a Review — since it composes
-- fn_approve_stock_adjustment internally with source_doc_type=
-- 'STOCK_COUNT_REVIEW', that internal call must skip the IN-ADJ check —
-- while a DIRECT Stock Adjustment approval by that SAME user (source_
-- doc_type IS NULL) must still be correctly denied. This is the exact
-- guard shape migration 111 already proved once for GRN/JV; here it's
-- verified from day one rather than discovered as a live regression.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(26);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id      uuid := '00000000-0000-0000-0112-000000000001';
  v_company_id     uuid := '00000000-0000-0000-0112-000000000002';
  v_loc_id         uuid := '00000000-0000-0000-0112-000000000003';
  v_loc_from_id    uuid := '00000000-0000-0000-0112-000000000004';
  v_loc_to_id      uuid := '00000000-0000-0000-0112-000000000005';
  v_user_ok        uuid := '00000000-0000-0000-0112-000000000006';
  v_user_cnr_only  uuid := '00000000-0000-0000-0112-000000000007';
  v_user_denied    uuid := '00000000-0000-0000-0112-000000000008';
  v_stock_acc      uuid := '00000000-0000-0000-0112-000000000009';
  v_transit_acc    uuid := '00000000-0000-0000-0112-00000000000a';
  v_adjustment_acc uuid := '00000000-0000-0000-0112-00000000000b';
  v_expense_acc    uuid := '00000000-0000-0000-0112-00000000000c';
  v_product_mrq    uuid := '00000000-0000-0000-0112-00000000000d';
  v_product_str    uuid := '00000000-0000-0000-0112-00000000000e';
  v_product_opn    uuid := '00000000-0000-0000-0112-00000000000f';
  v_product_adj    uuid := '00000000-0000-0000-0112-000000000010';
  v_product_cnr    uuid := '00000000-0000-0000-0112-000000000011';
  v_fy_id          uuid := '00000000-0000-0000-0112-000000000012';
  v_module_id      uuid := '00000000-0000-0000-0112-000000000013';
  v_dept_id        uuid := '00000000-0000-0000-0112-000000000014';
  v_area_id        uuid := '00000000-0000-0000-0112-000000000015';
  v_reason_id      uuid := '00000000-0000-0000-0112-000000000016';
  v_usd_ccy_id     uuid;
  v_stock_link_type uuid; v_transit_link_type uuid; v_adjustment_link_type uuid;
  v_dept_type_id uuid; v_area_type_id uuid; v_reason_type_id uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST112', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST112 CO', 'USD', 'USD', 'SIMPLE', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES
    (v_loc_id,      v_client_id, v_company_id, 'Test112 Loc',      'T112',  true, false, false, true, now()),
    (v_loc_from_id, v_client_id, v_company_id, 'Test112 Loc From', 'T112F', true, false, false, true, now()),
    (v_loc_to_id,   v_client_id, v_company_id, 'Test112 Loc To',   'T112T', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_ok,       v_client_id, v_company_id, 'test112_ok',  'Test112 Approver',      crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_cnr_only, v_client_id, v_company_id, 'test112_cnr', 'Test112 CNR-Only User', crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_denied,   v_client_id, v_company_id, 'test112_den', 'Test112 Clerk',         crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_stock_acc,      v_client_id, v_company_id, '1312', 'Stock Account',      'General', 'OHADA', true, true, false, now()),
    (v_transit_acc,    v_client_id, v_company_id, '1313', 'Stock In Transit',   'General', 'OHADA', true, true, false, now()),
    (v_adjustment_acc, v_client_id, v_company_id, '6112', 'Stock Adjustment',   'General', 'OHADA', true, true, false, now()),
    (v_expense_acc,    v_client_id, v_company_id, '6212', 'Consumption Expense','General', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_product_mrq, v_client_id, v_company_id, 'IN112-MRQ', 'Test112 MRQ Item', v_usd_ccy_id, 'NONE', v_user_ok),
    (v_product_str, v_client_id, v_company_id, 'IN112-STR', 'Test112 STR Item', v_usd_ccy_id, 'NONE', v_user_ok),
    (v_product_opn, v_client_id, v_company_id, 'IN112-OPN', 'Test112 OPN Item', v_usd_ccy_id, 'NONE', v_user_ok),
    (v_product_adj, v_client_id, v_company_id, 'IN112-ADJ', 'Test112 ADJ Item', v_usd_ccy_id, 'NONE', v_user_ok),
    (v_product_cnr, v_client_id, v_company_id, 'IN112-CNR', 'Test112 CNR Item', v_usd_ccy_id, 'NONE', v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST112', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link_type      FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_transit_link_type    FROM rim_account_link_types WHERE link_key = 'STOCK_IN_TRANSIT_ACCOUNT';
  SELECT id INTO v_adjustment_link_type FROM rim_account_link_types WHERE link_key = 'STOCK_ADJUSTMENT_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_transit_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_adjustment_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, NULL, v_stock_acc),
    (v_client_id, v_company_id, v_transit_link_type, NULL, v_transit_acc),
    (v_client_id, v_company_id, v_adjustment_link_type, NULL, v_adjustment_acc)
  ON CONFLICT DO NOTHING;

  -- Department + Consumption Area (066) for Material Issue's expense account.
  SELECT id INTO v_dept_type_id FROM rim_common_master_types WHERE type_key = 'DEPARTMENT';
  SELECT id INTO v_area_type_id FROM rim_common_master_types WHERE type_key = 'CONSUMPTION_AREA';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES
    (v_dept_id, v_client_id, v_company_id, v_dept_type_id, 'Test112 Dept', v_user_ok),
    (v_area_id, v_client_id, v_company_id, v_area_type_id, 'Test112 Area', v_user_ok)
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO rim_department_consumption_areas (client_id, company_id, department_id, consumption_area_id, account_id, created_by)
  VALUES (v_client_id, v_company_id, v_dept_id, v_area_id, v_expense_acc, v_user_ok)
  ON CONFLICT DO NOTHING;

  -- Reason master (STOCK_ADJUSTMENT_REASON) for Stock Adjustment/Review.
  SELECT id INTO v_reason_type_id FROM rim_common_master_types WHERE type_key = 'STOCK_ADJUSTMENT_REASON';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, sort_order, created_by)
  VALUES (v_reason_id, v_client_id, v_company_id, v_reason_type_id, 'Test112 Variance Reason', 90, v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  -- Menu-permission fixture. v_user_ok gets approve_allowed=true on every
  -- IN-* feature code EXCEPT it deliberately also gets IN-CNR (fine — it's
  -- never used for the guard proof). v_user_cnr_only gets ONLY IN-CNR —
  -- deliberately NOT IN-ADJ, the crux of the guard proof below.
  -- v_user_denied gets no rows at all.
  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name)
  VALUES (v_module_id, v_client_id, v_company_id, 'IN', 'Inventory')
  ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_module_id, 'IN-MRQ', 'Material Requisition',   '/inventory/material-requisition', true),
    (v_client_id, v_company_id, v_module_id, 'IN-MIS', 'Material Issue',         '/inventory/material-issue',       true),
    (v_client_id, v_company_id, v_module_id, 'IN-STR', 'Stock Transfer Request', '/inventory/transfer-request',     true),
    (v_client_id, v_company_id, v_module_id, 'IN-TRF', 'Stock Transfer',         '/inventory/transfer',             true),
    (v_client_id, v_company_id, v_module_id, 'IN-SRC', 'Stock Receipt',         '/inventory/receipt',              true),
    (v_client_id, v_company_id, v_module_id, 'IN-ADJ', 'Stock Adjustment',      '/inventory/adjustments',          true),
    (v_client_id, v_company_id, v_module_id, 'IN-OPN', 'Opening Stock',         '/inventory/opening-stock',        true),
    (v_client_id, v_company_id, v_module_id, 'IN-CNR', 'Stock Count Review',    '/inventory/stock-count-review',   true)
  ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;

  INSERT INTO ric_user_menus (client_id, company_id, user_id, module_id, feature_code, view_allowed, edit_allowed, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'IN-MRQ', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'IN-MIS', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'IN-STR', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'IN-TRF', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'IN-SRC', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'IN-ADJ', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'IN-OPN', true, true, true),
    (v_client_id, v_company_id, v_user_cnr_only, v_module_id, 'IN-CNR', true, true, true)
  ON CONFLICT (client_id, company_id, user_id, feature_code) DO NOTHING;

  PERFORM set_config('pgtap.v_client_112',   v_client_id::text, false);
  PERFORM set_config('pgtap.v_company_112',  v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc_112',      v_loc_id::text, false);
  PERFORM set_config('pgtap.v_loc_from_112', v_loc_from_id::text, false);
  PERFORM set_config('pgtap.v_loc_to_112',   v_loc_to_id::text, false);
  PERFORM set_config('pgtap.v_user_ok_112',       v_user_ok::text, false);
  PERFORM set_config('pgtap.v_user_cnr_only_112', v_user_cnr_only::text, false);
  PERFORM set_config('pgtap.v_user_denied_112',   v_user_denied::text, false);
  PERFORM set_config('pgtap.v_product_mrq_112', v_product_mrq::text, false);
  PERFORM set_config('pgtap.v_product_str_112', v_product_str::text, false);
  PERFORM set_config('pgtap.v_product_opn_112', v_product_opn::text, false);
  PERFORM set_config('pgtap.v_product_adj_112', v_product_adj::text, false);
  PERFORM set_config('pgtap.v_product_cnr_112', v_product_cnr::text, false);
  PERFORM set_config('pgtap.v_dept_112', v_dept_id::text, false);
  PERFORM set_config('pgtap.v_area_112', v_area_id::text, false);
  PERFORM set_config('pgtap.v_reason_112', v_reason_id::text, false);
END $$ LANGUAGE plpgsql;

-- Seed stock for v_product_mrq — Material Requisition itself is pure
-- intent (no stock effect), but Material Issue's own approval posts a
-- REAL outward movement, and this location has is_negative_stock_allowed
-- = false (matching real production default) — so the product needs an
-- actual on-hand balance before Issue can be approved, same shortcut
-- (fn_post_stock_movement directly) already used for v_product_str/adj/cnr.
DO $$
BEGIN
  PERFORM fn_post_stock_movement(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_loc_112')::uuid, current_setting('pgtap.v_product_mrq_112')::uuid,
    '2026-05-25'::date, 'OPENING_STOCK', 20, 5, 5, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-112-MRQ', '2026-05-25'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- MATERIAL REQUISITION (IN-MRQ)
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_req_no text;
BEGIN
  v_req_no := fn_save_material_requisition(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'location_id', current_setting('pgtap.v_loc_112'),
      'requisition_no', NULL, 'requisition_date', '2026-06-01',
      'requested_by', 'Test112 Supervisor', 'reason', 'Test112 run'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_mrq_112'),
      'uom_conversion_factor', 1, 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4,
      'department_id', current_setting('pgtap.v_dept_112'), 'consumption_area_id', current_setting('pgtap.v_area_112')
    )),
    current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_req_no_112', v_req_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_material_requisition(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_req_no_112'), '2026-06-01'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t1_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t1_112')::boolean, 'ok 1 — fn_approve_material_requisition: a denied user cannot approve (IN-MRQ mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_requisition_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND requisition_no = current_setting('pgtap.v_req_no_112')) = 'DRAFT',
  'ok 2 — the rejected requisition stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_112'))::text, true);
  PERFORM fn_approve_material_requisition(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_req_no_112'), '2026-06-01'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_requisition_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND requisition_no = current_setting('pgtap.v_req_no_112')) = 'APPROVED',
  'ok 3 — fn_approve_material_requisition: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- MATERIAL ISSUE (IN-MIS) — against the now-approved requisition.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_issue_no text;
BEGIN
  v_issue_no := fn_save_material_issue(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'location_id', current_setting('pgtap.v_loc_112'),
      'issue_no', NULL, 'issue_date', '2026-06-02'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1,
      'source_requisition_no', current_setting('pgtap.v_req_no_112'), 'source_requisition_date', '2026-06-01', 'source_requisition_line_serial', 1,
      'product_id', current_setting('pgtap.v_product_mrq_112'),
      'uom_conversion_factor', 1, 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4,
      'department_id', current_setting('pgtap.v_dept_112'), 'consumption_area_id', current_setting('pgtap.v_area_112')
    )),
    '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_issue_no_112', v_issue_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_material_issue(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_issue_no_112'), '2026-06-02'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t4_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t4_112')::boolean, 'ok 4 — fn_approve_material_issue: a denied user cannot approve (IN-MIS mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_issue_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND issue_no = current_setting('pgtap.v_issue_no_112')) = 'DRAFT',
  'ok 5 — the rejected issue stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_112'))::text, true);
  PERFORM fn_approve_material_issue(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_issue_no_112'), '2026-06-02'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_material_issue_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND issue_no = current_setting('pgtap.v_issue_no_112')) = 'APPROVED',
  'ok 6 — fn_approve_material_issue: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- STOCK TRANSFER REQUEST (IN-STR)
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_req_no text;
BEGIN
  v_req_no := fn_save_stock_transfer_request(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'from_location_id', current_setting('pgtap.v_loc_from_112'), 'to_location_id', current_setting('pgtap.v_loc_to_112'),
      'request_no', NULL, 'request_date', '2026-06-03', 'remarks', 'Test112 STR'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_str_112'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10)),
    current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_str_no_112', v_req_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_stock_transfer_request(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_str_no_112'), '2026-06-03'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t7_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t7_112')::boolean, 'ok 7 — fn_approve_stock_transfer_request: a denied user cannot approve (IN-STR mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_transfer_requests WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND request_no = current_setting('pgtap.v_str_no_112')) = 'DRAFT',
  'ok 8 — the rejected request stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_112'))::text, true);
  PERFORM fn_approve_stock_transfer_request(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_str_no_112'), '2026-06-03'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_transfer_requests WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND request_no = current_setting('pgtap.v_str_no_112')) = 'APPROVED',
  'ok 9 — fn_approve_stock_transfer_request: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- STOCK TRANSFER (IN-TRF) — against the now-approved request. Cost
-- established at the FROM location directly via fn_post_stock_movement
-- (same shortcut 074's own test uses) — no GRN/Purchase dependency.
-- ════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_post_stock_movement(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_loc_from_112')::uuid, current_setting('pgtap.v_product_str_112')::uuid,
    '2026-06-01'::date, 'OPENING_STOCK', 20, 15, 15, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-112-STR', '2026-06-01'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_transfer_no text;
BEGIN
  v_transfer_no := fn_save_stock_transfer(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'from_location_id', current_setting('pgtap.v_loc_from_112'), 'to_location_id', current_setting('pgtap.v_loc_to_112'),
      'transfer_no', NULL, 'transfer_date', '2026-06-04', 'against_request', true,
      'source_request_no', current_setting('pgtap.v_str_no_112'), 'source_request_date', '2026-06-03', 'remarks', 'Test112 Transfer'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1,
      'source_request_no', current_setting('pgtap.v_str_no_112'), 'source_request_date', '2026-06-03', 'source_request_line_serial', 1,
      'product_id', current_setting('pgtap.v_product_str_112'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'charge_amount', 0)),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_transfer_no_112', v_transfer_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_stock_transfer(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_transfer_no_112'), '2026-06-04'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t10_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t10_112')::boolean, 'ok 10 — fn_approve_stock_transfer: a denied user cannot approve (IN-TRF mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_transfers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND transfer_no = current_setting('pgtap.v_transfer_no_112')) = 'DRAFT',
  'ok 11 — the rejected transfer stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_112'))::text, true);
  PERFORM fn_approve_stock_transfer(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_transfer_no_112'), '2026-06-04'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_transfers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND transfer_no = current_setting('pgtap.v_transfer_no_112')) = 'APPROVED',
  'ok 12 — fn_approve_stock_transfer: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- STOCK RECEIPT (IN-SRC) — against the now-approved (and CLOSED-on-
-- receipt) transfer. Receives exactly the transferred qty, so no Loss
-- account is ever needed.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_receipt_no text;
BEGIN
  v_receipt_no := fn_save_stock_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'receipt_no', NULL, 'receipt_date', '2026-06-05',
      'source_transfer_no', current_setting('pgtap.v_transfer_no_112'), 'source_transfer_date', '2026-06-04', 'remarks', 'Test112 Receipt'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_transfer_line_serial', 1,
      'product_id', current_setting('pgtap.v_product_str_112'),
      'uom_conversion_factor', 1, 'received_qty_pack', 10, 'received_qty_loose', 0, 'received_base_qty', 10)),
    '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_receipt_no_112', v_receipt_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_stock_receipt(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_receipt_no_112'), '2026-06-05'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t13_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t13_112')::boolean, 'ok 13 — fn_approve_stock_receipt: a denied user cannot approve (IN-SRC mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_receipts WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND receipt_no = current_setting('pgtap.v_receipt_no_112')) = 'DRAFT',
  'ok 14 — the rejected receipt stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_112'))::text, true);
  PERFORM fn_approve_stock_receipt(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_receipt_no_112'), '2026-06-05'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_receipts WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND receipt_no = current_setting('pgtap.v_receipt_no_112')) = 'APPROVED',
  'ok 15 — fn_approve_stock_receipt: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- OPENING STOCK (IN-OPN) — fresh product, never touched before.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_opening_no text;
BEGIN
  v_opening_no := fn_save_opening_stock(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'location_id', current_setting('pgtap.v_loc_112'), 'opening_no', NULL, 'opening_date', '2026-06-01',
      'remarks', 'Test112 Opening'
    ),
    jsonb_build_array(jsonb_build_object('line_no', 1, 'product_id', current_setting('pgtap.v_product_opn_112'),
      'uom_conversion_factor', 1, 'pack_qty', 10, 'loose_qty', 0, 'base_qty', 10, 'unit_cost', 5)),
    current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_opening_no_112', v_opening_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_opening_stock(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_opening_no_112'), '2026-06-01'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t16_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t16_112')::boolean, 'ok 16 — fn_approve_opening_stock: a denied user cannot approve (IN-OPN mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_opening_stock_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND opening_no = current_setting('pgtap.v_opening_no_112')) = 'DRAFT',
  'ok 17 — the rejected opening entry stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_112'))::text, true);
  PERFORM fn_approve_opening_stock(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_opening_no_112'), '2026-06-01'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_opening_stock_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND opening_no = current_setting('pgtap.v_opening_no_112')) = 'APPROVED',
  'ok 18 — fn_approve_opening_stock: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- STOCK ADJUSTMENT DIRECT ENTRY (IN-ADJ) — proves the guard is correctly
-- SCOPED, not just "always skip": a direct entry (source_doc_type IS
-- NULL) must still require IN-ADJ specifically, even for a user who
-- holds IN-CNR (a different, unrelated feature_code).
-- ════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_post_stock_movement(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_loc_112')::uuid, current_setting('pgtap.v_product_adj_112')::uuid,
    '2026-06-01'::date, 'OPENING_STOCK', 50, 20, 20, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-112-ADJ', '2026-06-01'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_save_stock_adjustment(
    jsonb_build_object('client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'location_id', current_setting('pgtap.v_loc_112'), 'adjustment_no', NULL, 'adjustment_date', '2026-06-06',
      'reason_id', current_setting('pgtap.v_reason_112'), 'remarks', 'Test112 direct adjustment'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_adj_112'),
      'uom_conversion_factor', 1, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'adjust_flag', '+', 'system_qty', 50,
      'reason_id', current_setting('pgtap.v_reason_112'))),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_adj_no_112', v_adj_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_stock_adjustment(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_adj_no_112'), '2026-06-06'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t19_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t19_112')::boolean, 'ok 19 — fn_approve_stock_adjustment: a denied user cannot approve a DIRECT entry (IN-ADJ mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_adjustment_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND adjustment_no = current_setting('pgtap.v_adj_no_112')) = 'DRAFT',
  'ok 20 — the rejected direct adjustment stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  -- Critical guard-scope proof: v_user_cnr_only holds IN-CNR but NOT
  -- IN-ADJ. A DIRECT Stock Adjustment (source_doc_type IS NULL) must
  -- still reject this user — proving the guard added in this migration
  -- narrows to auto-posted-from-Review adjustments only, not "skip
  -- IN-ADJ for everyone."
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_cnr_only_112'))::text, true);
  BEGIN
    PERFORM fn_approve_stock_adjustment(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_adj_no_112'), '2026-06-06'::date, current_setting('pgtap.v_user_cnr_only_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t21_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t21_112')::boolean, 'ok 21 — GUARD SCOPE: a user with IN-CNR but NOT IN-ADJ still cannot approve a DIRECT Stock Adjustment (proves the guard is not "skip IN-ADJ for everyone")');

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_112'))::text, true);
  PERFORM fn_approve_stock_adjustment(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_adj_no_112'), '2026-06-06'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_adjustment_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND adjustment_no = current_setting('pgtap.v_adj_no_112')) = 'APPROVED',
  'ok 22 — fn_approve_stock_adjustment: a user WITH IN-ADJ can approve the direct entry'
);

-- ════════════════════════════════════════════════════════════════════
-- STOCK COUNT REVIEW (IN-CNR) + the IN-ADJ guard's real payoff: v_user_
-- cnr_only (IN-CNR only, proven above to NOT have IN-ADJ) must be able
-- to approve a Review whose internal composition auto-posts a Stock
-- Adjustment (source_doc_type='STOCK_COUNT_REVIEW') without ever
-- hitting IN-ADJ's own check.
-- ════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_post_stock_movement(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    current_setting('pgtap.v_loc_112')::uuid, current_setting('pgtap.v_product_cnr_112')::uuid,
    '2026-06-01'::date, 'OPENING_STOCK', 50, 10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-112-CNR', '2026-06-01'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_count_no text;
BEGIN
  v_count_no := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'location_id', current_setting('pgtap.v_loc_112'), 'count_no', NULL, 'count_date', '2026-06-10'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_cnr_112'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 45, 'counted_qty_loose', 0, 'counted_base_qty', 45)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM fn_submit_stock_count(
    current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
    v_count_no, '2026-06-10'::date, current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_count_no_112', v_count_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_rev_no text;
BEGIN
  v_rev_no := fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client_112'), 'company_id', current_setting('pgtap.v_company_112'),
      'location_id', current_setting('pgtap.v_loc_112'), 'review_no', NULL, 'review_date', '2026-06-11',
      'as_of_date', '2026-06-10', 'reason_id', current_setting('pgtap.v_reason_112'), 'remarks', 'Test112 Review'),
    jsonb_build_array(jsonb_build_object('source_count_no', current_setting('pgtap.v_count_no_112'), 'source_count_date', '2026-06-10')),
    current_setting('pgtap.v_user_ok_112')::uuid
  );
  PERFORM set_config('pgtap.v_rev_no_112', v_rev_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_112'))::text, true);
  BEGIN
    PERFORM fn_approve_stock_count_review(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_rev_no_112'), '2026-06-11'::date, current_setting('pgtap.v_user_denied_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t23_112', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t23_112')::boolean, 'ok 23 — fn_approve_stock_count_review: a denied user cannot approve (IN-CNR mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_count_review_headers WHERE client_id = current_setting('pgtap.v_client_112')::uuid AND review_no = current_setting('pgtap.v_rev_no_112')) = 'DRAFT',
  'ok 24 — the rejected review stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  -- The real guard payoff: v_user_cnr_only has IN-CNR but explicitly NOT
  -- IN-ADJ (proven in tests 20-21 above). If the guard were missing, this
  -- would fail with APPROVE_NOT_PERMITTED from the INNER
  -- fn_approve_stock_adjustment call, not from this function's own check.
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_cnr_only_112'))::text, true);
  BEGIN
    PERFORM fn_approve_stock_count_review(
      current_setting('pgtap.v_client_112')::uuid, current_setting('pgtap.v_company_112')::uuid,
      current_setting('pgtap.v_rev_no_112'), '2026-06-11'::date, current_setting('pgtap.v_user_cnr_only_112')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t25_112', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t25_112')::boolean, 'ok 25 — fn_approve_stock_count_review: a user with IN-CNR (but NOT IN-ADJ) CAN approve — the internal fn_approve_stock_adjustment composition correctly skips its own IN-ADJ check');

INSERT INTO test_results (result) SELECT ok(
  (SELECT h.status = 'APPROVED' AND a.status = 'APPROVED' AND a.source_doc_type = 'STOCK_COUNT_REVIEW'
   FROM rih_stock_count_review_headers h
   JOIN rih_stock_adjustment_headers a
     ON a.client_id = h.client_id AND a.company_id = h.company_id
    AND a.adjustment_no = h.posted_adjustment_no AND a.adjustment_date = h.posted_adjustment_date
   WHERE h.client_id = current_setting('pgtap.v_client_112')::uuid AND h.review_no = current_setting('pgtap.v_rev_no_112')),
  'ok 26 — the Review is APPROVED and its auto-posted adjustment is APPROVED with source_doc_type=STOCK_COUNT_REVIEW (proves the composition actually completed, not just skipped the check and stalled)'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
