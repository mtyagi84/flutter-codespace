-- ============================================================
-- 111_finance_voucher_auto_post_permission_fix_test.sql — pgTAP tests
-- for migration 111 (fn_post_finance_voucher's source_doc_type guard)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Proves BOTH halves of the fix:
--   A. A user with PR-GRN approve rights (but NOT FN-JRN) CAN approve a
--      DIRECT GRN — the auto-posted 'JV' accrual voucher no longer
--      wrongly demands unrelated Journal Voucher permission.
--   B/C. A DIRECTLY-entered Journal Voucher (no source_doc_type) still
--      correctly requires FN-JRN — the regression this migration must
--      NOT reopen (that's the actual bug 108 fixed).
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(4);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id        uuid := '00000000-0000-0000-0111-000000000001';
  v_company_id       uuid := '00000000-0000-0000-0111-000000000002';
  v_loc_id           uuid := '00000000-0000-0000-0111-000000000003';
  v_user_grn_only    uuid := '00000000-0000-0000-0111-000000000004';
  v_user_jrn_only    uuid := '00000000-0000-0000-0111-000000000005';
  v_supplier_id      uuid := '00000000-0000-0000-0111-000000000006';
  v_stock_acc_id     uuid := '00000000-0000-0000-0111-000000000007';
  v_accrual_acc_id   uuid := '00000000-0000-0000-0111-000000000008';
  v_cash_acc_id      uuid := '00000000-0000-0000-0111-000000000009';
  v_expense_acc_id   uuid := '00000000-0000-0000-0111-000000000010';
  v_product_id       uuid := '00000000-0000-0000-0111-000000000011';
  v_fy_id            uuid := '00000000-0000-0000-0111-000000000012';
  v_pr_module_id     uuid := '00000000-0000-0000-0111-000000000013';
  v_fn_module_id     uuid := '00000000-0000-0000-0111-000000000014';
  v_usd_ccy_id       uuid;
  v_stock_link_type   uuid;
  v_accrual_link_type uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST111', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST111 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test111 Loc', 'T111', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_grn_only, v_client_id, v_company_id, 'test111_grn', 'Test111 GRN Approver', crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_jrn_only, v_client_id, v_company_id, 'test111_jrn', 'Test111 JV Approver',  crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';
  PERFORM set_config('pgtap.v_currency_111', v_usd_ccy_id::text, false);

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier_id,    v_client_id, v_company_id, '5111', 'Test111 Supplier', 'Supplier', 'OHADA', true, true, false, now()),
    (v_stock_acc_id,   v_client_id, v_company_id, '1311', 'Stock Account',    'General',  'OHADA', true, true, false, now()),
    (v_accrual_acc_id, v_client_id, v_company_id, '2211', 'Purchase Accrual', 'General',  'OHADA', true, true, false, now()),
    (v_cash_acc_id,    v_client_id, v_company_id, '1011', 'Test111 Cash',     'Cash',     'OHADA', true, true, false, now()),
    (v_expense_acc_id, v_client_id, v_company_id, '5211', 'Test111 Expense',  'General',  'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'PR111-001', 'Test111 Item', v_usd_ccy_id, v_user_grn_only)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST111', '2020-01-01', '2030-12-31', true, false)
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

  -- Menu-permission fixture: v_user_grn_only gets PR-GRN approve rights
  -- ONLY (deliberately no FN-JRN row); v_user_jrn_only gets FN-JRN approve
  -- rights ONLY (deliberately no PR-GRN row) — cross-checks that each
  -- check is scoped to its own feature_code, not accidentally shared.
  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name)
  VALUES
    (v_pr_module_id, v_client_id, v_company_id, 'PR', 'Purchase'),
    (v_fn_module_id, v_client_id, v_company_id, 'FN', 'Finance')
  ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_pr_module_id, 'PR-GRN', 'GRN',            '/purchase/grn', true),
    (v_client_id, v_company_id, v_fn_module_id, 'FN-JRN', 'Journal Voucher', '/finance/journal-voucher-list', true)
  ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;

  INSERT INTO ric_user_menus (client_id, company_id, user_id, module_id, feature_code, view_allowed, edit_allowed, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_user_grn_only, v_pr_module_id, 'PR-GRN', true, true, true),
    (v_client_id, v_company_id, v_user_jrn_only, v_fn_module_id, 'FN-JRN', true, true, true)
  ON CONFLICT (client_id, company_id, user_id, feature_code) DO NOTHING;

  PERFORM set_config('pgtap.v_client_111',        v_client_id::text, false);
  PERFORM set_config('pgtap.v_company_111',       v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc_111',           v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user_grn_only_111', v_user_grn_only::text, false);
  PERFORM set_config('pgtap.v_user_jrn_only_111', v_user_jrn_only::text, false);
  PERFORM set_config('pgtap.v_supplier_111',      v_supplier_id::text, false);
  PERFORM set_config('pgtap.v_product_111',       v_product_id::text, false);
  PERFORM set_config('pgtap.v_cash_acc_111',      v_cash_acc_id::text, false);
  PERFORM set_config('pgtap.v_expense_acc_111',   v_expense_acc_id::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST A: a PR-GRN-only user CAN approve a DIRECT GRN — its internal
-- auto-posted 'JV' accrual voucher no longer wrongly demands FN-JRN.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_111'), 'company_id', current_setting('pgtap.v_company_111'),
      'location_id', current_setting('pgtap.v_loc_111'),
      'grn_no', NULL, 'grn_date', '2026-06-01',
      'supplier_id', current_setting('pgtap.v_supplier_111'),
      'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_currency_111'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_111'),
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 100,
      'gross_amount', 1000, 'tax_amount', 0, 'final_amount', 1000, 'charge_amount', 0, 'landed_amount', 1000
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_grn_only_111')::uuid
  );
  PERFORM set_config('pgtap.v_grn_no_111', v_grn_no, false);

  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_grn_only_111'))::text, true);
  PERFORM fn_approve_grn(
    current_setting('pgtap.v_client_111')::uuid, current_setting('pgtap.v_company_111')::uuid,
    v_grn_no, '2026-06-01'::date, current_setting('pgtap.v_user_grn_only_111')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_grn_headers WHERE client_id = current_setting('pgtap.v_client_111')::uuid AND grn_no = current_setting('pgtap.v_grn_no_111')) = 'APPROVED',
  'ok 1 — a PR-GRN-only user (no FN-JRN) CAN approve a GRN — auto-posted JV no longer requires unrelated Journal Voucher permission'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT is_posted FROM rih_finance_headers
   WHERE client_id = current_setting('pgtap.v_client_111')::uuid
     AND trans_no = (SELECT posted_voucher_no FROM rih_grn_headers WHERE grn_no = current_setting('pgtap.v_grn_no_111'))) = true,
  'ok 2 — the GRN''s auto-posted accrual voucher is actually posted (proves the fix reached real posting, not just an unguarded status flip)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST B/C: a DIRECTLY-entered Journal Voucher (source_doc_type stays
-- NULL — never touched by fn_post_voucher) still correctly requires
-- FN-JRN. This is the regression this migration must NOT reopen.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
  v_error_raised boolean := false;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_111'), 'company_id', current_setting('pgtap.v_company_111'),
      'location_id', current_setting('pgtap.v_loc_111'),
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'JV', 'is_on_account', true,
      'remarks', 'pgTAP 111 direct JV — regression check'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', current_setting('pgtap.v_cash_acc_111')::uuid, 'trans_nature', 'CR',
        'trans_amount', 40, 'trans_currency', 'USD', 'base_amount', 40, 'base_rate', 1,
        'local_amount', 40, 'local_rate', 1, 'party_amount', 40, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', current_setting('pgtap.v_expense_acc_111')::uuid, 'trans_nature', 'DR',
        'trans_amount', 40, 'trans_currency', 'USD', 'base_amount', 40, 'base_rate', 1,
        'local_amount', 40, 'local_rate', 1, 'party_amount', 40, 'party_currency', 'USD', 'party_rate', 1)
    ),
    current_setting('pgtap.v_user_jrn_only_111')::uuid
  );
  PERFORM set_config('pgtap.v_jv_no_111', v_trans_no, false);

  -- The GRN approver (has PR-GRN, NOT FN-JRN) tries to approve this DIRECT
  -- JV — must still be rejected. This is the exact check the migration
  -- must NOT weaken.
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_grn_only_111'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client_111')::uuid, current_setting('pgtap.v_company_111')::uuid, current_setting('pgtap.v_loc_111')::uuid,
      v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user_grn_only_111')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t3_111', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t3_111')::boolean, 'ok 3 — a direct Journal Voucher entry still correctly requires FN-JRN (PR-GRN alone is NOT enough) — the regression this fix must not reopen');

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_jrn_only_111'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client_111')::uuid, current_setting('pgtap.v_company_111')::uuid, current_setting('pgtap.v_loc_111')::uuid,
      current_setting('pgtap.v_jv_no_111'), CURRENT_DATE, current_setting('pgtap.v_user_jrn_only_111')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t4_111', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t4_111')::boolean, 'ok 4 — the SAME direct JV posts successfully once retried by a user who actually holds FN-JRN');

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
