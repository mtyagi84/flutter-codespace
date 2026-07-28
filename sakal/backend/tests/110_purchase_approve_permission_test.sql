-- ============================================================
-- 110_purchase_approve_permission_test.sql — pgTAP tests for migration 110
-- (fn_check_approve_permission wired into all 4 Purchase-module approve
-- functions: fn_approve_purchase_order/PR-PO, fn_approve_grn/PR-GRN,
-- fn_approve_purchase_invoice/PR-INV, fn_approve_purchase_return/PR-RET)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- The underlying enforcement mechanism itself (fn_check_approve_permission
-- — JWT resolution, no-JWT skip, missing-row deny) is already thoroughly
-- tested in 108_finance_voucher_approve_permission_test.sql; this file only
-- proves the NEW wiring on all 4 Purchase functions, via one denied/
-- approved assertion pair per function threaded through a single real
-- PO -> GRN -> Purchase Invoice chain, plus a second unbilled GRN for the
-- Purchase Return (JV-only) path — same fixture shapes already proven in
-- 031/038/054/061's own test files, not re-derived from scratch.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(12);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id       uuid := '00000000-0000-0000-0110-000000000001';
  v_company_id      uuid := '00000000-0000-0000-0110-000000000002';
  v_loc_id          uuid := '00000000-0000-0000-0110-000000000003';
  v_user_ok         uuid := '00000000-0000-0000-0110-000000000004';
  v_user_denied     uuid := '00000000-0000-0000-0110-000000000005';
  v_supplier_id     uuid := '00000000-0000-0000-0110-000000000006';
  v_stock_acc_id    uuid := '00000000-0000-0000-0110-000000000007';
  v_accrual_acc_id  uuid := '00000000-0000-0000-0110-000000000008';
  v_product_id      uuid := '00000000-0000-0000-0110-000000000010';
  v_fy_id           uuid := '00000000-0000-0000-0110-000000000012';
  v_tax_id          uuid := '00000000-0000-0000-0110-000000000013';
  v_tax_rate_id     uuid := '00000000-0000-0000-0110-000000000014';
  v_tax_group_id    uuid := '00000000-0000-0000-0110-000000000015';
  v_tax_member_id   uuid := '00000000-0000-0000-0110-000000000016';
  v_uom_id          uuid := '00000000-0000-0000-0110-000000000017';
  v_module_id       uuid := '00000000-0000-0000-0110-000000000018';
  v_usd_ccy_id      uuid;
  v_unit_type_id    uuid;
  v_stock_link_type uuid;
  v_accrual_link_type uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST110', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST110 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test110 Loc', 'T110', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_ok,     v_client_id, v_company_id, 'test110_ok',     'Test110 Approver', crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_denied, v_client_id, v_company_id, 'test110_denied', 'Test110 Clerk',     crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- ric_companies has an AFTER INSERT trigger that auto-seeds every world
  -- currency, including USD — read back the trigger-seeded id rather than
  -- inserting our own (same fix already used in 031/038/054/061's tests).
  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';
  PERFORM set_config('pgtap.v_currency_110', v_usd_ccy_id::text, false);

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier_id,    v_client_id, v_company_id, '5110', 'Test110 Supplier', 'Supplier', 'OHADA', true, true, false, now()),
    (v_stock_acc_id,   v_client_id, v_company_id, '1310', 'Stock Account',    'General',  'OHADA', true, true, false, now()),
    (v_accrual_acc_id, v_client_id, v_company_id, '2210', 'Purchase Accrual', 'General',  'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'PR110-001', 'Test110 Item', v_usd_ccy_id, v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST110', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- Tax: 16% VAT, one-member group. gl_input_account_id reuses the accrual
  -- account purely to keep the fixture list short (same shortcut 038's own
  -- test uses) — this test targets permission wiring, not GL correctness.
  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, gl_input_account_id, created_by)
  VALUES (v_tax_id, v_client_id, v_company_id, 'VAT16', 'VAT 16%', 'VAT', 'PURCHASE', v_accrual_acc_id, v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_tax_rate_id, v_client_id, v_company_id, v_tax_id, 'STANDARD', 16.0000, '2020-01-01', v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, created_by)
  VALUES (v_tax_group_id, v_client_id, v_company_id, 'VAT_STD', 'VAT Standard', 'PURCHASE', v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_tax_member_id, v_client_id, v_company_id, v_tax_group_id, v_tax_id, 1)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, is_active, is_deleted, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece110', true, false, v_user_ok)
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

  -- Menu-permission fixture — same shape as 108/109. v_user_ok gets
  -- approve_allowed=true on all 4 Purchase feature_codes; v_user_denied
  -- gets no ric_user_menus row at all (missing row = deny, per convention).
  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name)
  VALUES (v_module_id, v_client_id, v_company_id, 'PR', 'Purchase')
  ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_module_id, 'PR-PO',  'Purchase Order',    '/purchase/orders',  true),
    (v_client_id, v_company_id, v_module_id, 'PR-GRN', 'GRN',               '/purchase/grn',     true),
    (v_client_id, v_company_id, v_module_id, 'PR-INV', 'Purchase Invoice',  '/purchase/invoices',true),
    (v_client_id, v_company_id, v_module_id, 'PR-RET', 'Purchase Return',   '/purchase/returns', true)
  ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;

  INSERT INTO ric_user_menus (client_id, company_id, user_id, module_id, feature_code, view_allowed, edit_allowed, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'PR-PO',  true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'PR-GRN', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'PR-INV', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'PR-RET', true, true, true)
  ON CONFLICT (client_id, company_id, user_id, feature_code) DO NOTHING;

  PERFORM set_config('pgtap.v_client_110',   v_client_id::text, false);
  PERFORM set_config('pgtap.v_company_110',  v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc_110',      v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user_ok_110',  v_user_ok::text, false);
  PERFORM set_config('pgtap.v_user_denied_110', v_user_denied::text, false);
  PERFORM set_config('pgtap.v_supplier_110', v_supplier_id::text, false);
  PERFORM set_config('pgtap.v_product_110',  v_product_id::text, false);
  PERFORM set_config('pgtap.v_tax_group_110', v_tax_group_id::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- PURCHASE ORDER — create DRAFT, deny, then approve.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_order_no text;
BEGIN
  v_order_no := fn_save_purchase_order(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_110'), 'company_id', current_setting('pgtap.v_company_110'),
      'location_id', current_setting('pgtap.v_loc_110'),
      'order_no', NULL, 'order_date', '2026-06-01', 'po_type', 'LOCAL',
      'supplier_id', current_setting('pgtap.v_supplier_110'),
      'po_currency_id', current_setting('pgtap.v_currency_110'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_110'),
      'uom_id', '00000000-0000-0000-0110-000000000017',
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 100,
      'gross_amount', 1000, 'tax_group_id', current_setting('pgtap.v_tax_group_110'),
      'tax_amount', 160, 'final_amount', 1160
    )),
    '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_110')::uuid
  );
  PERFORM set_config('pgtap.v_po_no_110', v_order_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_110'))::text, true);
  BEGIN
    PERFORM fn_approve_purchase_order(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_po_no_110'), '2026-06-01'::date, current_setting('pgtap.v_user_denied_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t1_110', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t1_110')::boolean, 'ok 1 — fn_approve_purchase_order: a denied user cannot approve (PR-PO mapping enforced)');

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_purchase_orders WHERE client_id = current_setting('pgtap.v_client_110')::uuid AND order_no = current_setting('pgtap.v_po_no_110')) = 'DRAFT',
  'ok 2 — the rejected PO stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_110'))::text, true);
  BEGIN
    PERFORM fn_approve_purchase_order(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_po_no_110'), '2026-06-01'::date, current_setting('pgtap.v_user_ok_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t3_110', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t3_110')::boolean, 'ok 3 — fn_approve_purchase_order: an approved user CAN approve it (PO now APPROVED)');

-- ════════════════════════════════════════════════════════════════════
-- GRN (against the now-approved PO) — create DRAFT, deny, then approve.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_110'), 'company_id', current_setting('pgtap.v_company_110'),
      'location_id', current_setting('pgtap.v_loc_110'),
      'grn_no', NULL, 'grn_date', '2026-06-02',
      'supplier_id', current_setting('pgtap.v_supplier_110'),
      'receipt_mode', 'AGAINST_PO',
      'grn_currency_id', current_setting('pgtap.v_currency_110'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_110'),
      'source_po_order_no', current_setting('pgtap.v_po_no_110'), 'source_po_order_date', '2026-06-01', 'source_po_line_serial', 1,
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 100,
      'gross_amount', 1000, 'tax_group_id', current_setting('pgtap.v_tax_group_110'),
      'tax_amount', 160, 'final_amount', 1160, 'charge_amount', 0, 'landed_amount', 1160
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_110')::uuid
  );
  PERFORM set_config('pgtap.v_grn1_no_110', v_grn_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_110'))::text, true);
  BEGIN
    PERFORM fn_approve_grn(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_grn1_no_110'), '2026-06-02'::date, current_setting('pgtap.v_user_denied_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t4_110', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t4_110')::boolean, 'ok 4 — fn_approve_grn: a denied user cannot approve (PR-GRN mapping enforced)');

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_grn_headers WHERE client_id = current_setting('pgtap.v_client_110')::uuid AND grn_no = current_setting('pgtap.v_grn1_no_110')) = 'DRAFT',
  'ok 5 — the rejected GRN stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_110'))::text, true);
  BEGIN
    PERFORM fn_approve_grn(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_grn1_no_110'), '2026-06-02'::date, current_setting('pgtap.v_user_ok_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t6_110', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t6_110')::boolean, 'ok 6 — fn_approve_grn: an approved user CAN approve it (GRN now APPROVED, posts stock+voucher)');

-- ════════════════════════════════════════════════════════════════════
-- PURCHASE INVOICE (against the now-approved GRN) — create DRAFT, deny,
-- then approve.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_invoice_no text;
BEGIN
  v_invoice_no := fn_save_purchase_invoice(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_110'), 'company_id', current_setting('pgtap.v_company_110'),
      'location_id', current_setting('pgtap.v_loc_110'),
      'invoice_no', NULL, 'invoice_date', '2026-06-05',
      'supplier_id', current_setting('pgtap.v_supplier_110'),
      'supplier_invoice_no', 'SUPP-INV-110', 'supplier_invoice_date', '2026-06-04',
      'invoice_currency_id', current_setting('pgtap.v_currency_110'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 1000, 'tax_amount', 160, 'invoice_total', 1160
    ),
    jsonb_build_array(jsonb_build_object('grn_no', current_setting('pgtap.v_grn1_no_110'), 'grn_date', '2026-06-02')),
    current_setting('pgtap.v_user_ok_110')::uuid
  );
  PERFORM set_config('pgtap.v_invoice_no_110', v_invoice_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_110'))::text, true);
  BEGIN
    PERFORM fn_approve_purchase_invoice(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_invoice_no_110'), '2026-06-05'::date, current_setting('pgtap.v_user_denied_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t7_110', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t7_110')::boolean, 'ok 7 — fn_approve_purchase_invoice: a denied user cannot approve (PR-INV mapping enforced)');

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_purchase_invoices WHERE client_id = current_setting('pgtap.v_client_110')::uuid AND invoice_no = current_setting('pgtap.v_invoice_no_110')) = 'DRAFT',
  'ok 8 — the rejected Purchase Invoice stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_110'))::text, true);
  BEGIN
    PERFORM fn_approve_purchase_invoice(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_invoice_no_110'), '2026-06-05'::date, current_setting('pgtap.v_user_ok_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t9_110', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t9_110')::boolean, 'ok 9 — fn_approve_purchase_invoice: an approved user CAN approve it (Bill now APPROVED)');

-- ════════════════════════════════════════════════════════════════════
-- PURCHASE RETURN — a SECOND, unbilled DIRECT GRN (JV-only reversal
-- path, no SDN/tax complexity needed just to prove permission wiring),
-- approved directly with v_user_ok (already proven above — no need to
-- re-test GRN permission a second time), then a return against it.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_110'), 'company_id', current_setting('pgtap.v_company_110'),
      'location_id', current_setting('pgtap.v_loc_110'),
      'grn_no', NULL, 'grn_date', '2026-06-03',
      'supplier_id', current_setting('pgtap.v_supplier_110'),
      'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_currency_110'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_110'),
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 50,
      'gross_amount', 500, 'tax_amount', 0, 'final_amount', 500, 'charge_amount', 0, 'landed_amount', 500
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_110')::uuid
  );
  PERFORM set_config('pgtap.v_grn2_no_110', v_grn_no, false);

  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_110'))::text, true);
  PERFORM fn_approve_grn(
    current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
    v_grn_no, '2026-06-03'::date, current_setting('pgtap.v_user_ok_110')::uuid
  );
END $$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_110'), 'company_id', current_setting('pgtap.v_company_110'),
      'location_id', current_setting('pgtap.v_loc_110'),
      'return_no', NULL, 'return_date', '2026-06-10',
      'supplier_id', current_setting('pgtap.v_supplier_110'),
      'return_currency_id', current_setting('pgtap.v_currency_110'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 150, 'tax_amount', 0, 'return_total', 150,
      'reason', 'Test110 Defective'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'source_grn_no', current_setting('pgtap.v_grn2_no_110'), 'source_grn_date', '2026-06-03', 'source_grn_line_serial', 1,
      'product_id', current_setting('pgtap.v_product_110'), 'uom_conversion_factor', 1,
      'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3, 'rate', 50,
      'gross_amount', 150, 'tax_amount', 0, 'final_amount', 150
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_110')::uuid
  );
  PERFORM set_config('pgtap.v_return_no_110', v_return_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_110'))::text, true);
  BEGIN
    PERFORM fn_approve_purchase_return(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_return_no_110'), '2026-06-10'::date, false, current_setting('pgtap.v_user_denied_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t10_110', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t10_110')::boolean, 'ok 10 — fn_approve_purchase_return: a denied user cannot approve (PR-RET mapping enforced)');

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_purchase_return_headers WHERE client_id = current_setting('pgtap.v_client_110')::uuid AND return_no = current_setting('pgtap.v_return_no_110')) = 'DRAFT',
  'ok 11 — the rejected Purchase Return stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_110'))::text, true);
  BEGIN
    PERFORM fn_approve_purchase_return(
      current_setting('pgtap.v_client_110')::uuid, current_setting('pgtap.v_company_110')::uuid,
      current_setting('pgtap.v_return_no_110'), '2026-06-10'::date, false, current_setting('pgtap.v_user_ok_110')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t12_110', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t12_110')::boolean, 'ok 12 — fn_approve_purchase_return: an approved user CAN approve it (Return now APPROVED)');

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
