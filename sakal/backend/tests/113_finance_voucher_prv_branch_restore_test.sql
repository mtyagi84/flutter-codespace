-- ============================================================
-- 113_finance_voucher_prv_branch_restore_test.sql — pgTAP tests for
-- migration 113 (restores the CRV/BRV/CPV/BPV branch in
-- fn_post_finance_voucher that migration 111 accidentally dropped)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Proves three things:
--   A. FN-PRV is enforced again for a DIRECT CPV (source_doc_type NULL)
--      — the actual regression this migration fixes.
--   B. A CPV whose source_doc_type has been set (simulating what
--      migration 114 will do for Sales Invoice's own composed CRV) is
--      correctly EXEMPTED — proves the guard extension works, ahead of
--      114 actually using it.
--   C. JV still correctly requires FN-JRN (regression check — this
--      migration touches the same function 111 touched, so re-verify
--      the branch 111 originally fixed wasn't itself broken again).
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(5);

DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0113-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0113-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0113-000000000003';
  v_user_prv    uuid := '00000000-0000-0000-0113-000000000004';
  v_user_denied uuid := '00000000-0000-0000-0113-000000000005';
  v_cash_acc    uuid := '00000000-0000-0000-0113-000000000006';
  v_expense_acc uuid := '00000000-0000-0000-0113-000000000007';
  v_fy_id       uuid := '00000000-0000-0000-0113-000000000008';
  v_fn_module_id uuid := '00000000-0000-0000-0113-000000000009';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST113', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST113 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test113 Loc', 'T113', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_prv,    v_client_id, v_company_id, 'test113_prv', 'Test113 PRV Approver', crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_denied, v_client_id, v_company_id, 'test113_den', 'Test113 Clerk',        crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_cash_acc,    v_client_id, v_company_id, '1013', 'Test113 Cash',    'Cash',    'OHADA', true, true, false, now()),
    (v_expense_acc, v_client_id, v_company_id, '5113', 'Test113 Expense', 'General', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST113', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name)
  VALUES (v_fn_module_id, v_client_id, v_company_id, 'FN', 'Finance')
  ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_fn_module_id, 'FN-PRV', 'Payment/Receipt Voucher', '/finance/voucher-list', true),
    (v_client_id, v_company_id, v_fn_module_id, 'FN-JRN', 'Journal Voucher', '/finance/journal-voucher-list', true)
  ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;

  -- v_user_prv holds FN-PRV ONLY (deliberately not FN-JRN, for test C).
  INSERT INTO ric_user_menus (client_id, company_id, user_id, module_id, feature_code, view_allowed, edit_allowed, approve_allowed)
  VALUES (v_client_id, v_company_id, v_user_prv, v_fn_module_id, 'FN-PRV', true, true, true)
  ON CONFLICT (client_id, company_id, user_id, feature_code) DO NOTHING;

  PERFORM set_config('pgtap.v_client_113',   v_client_id::text, false);
  PERFORM set_config('pgtap.v_company_113',  v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc_113',      v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user_prv_113', v_user_prv::text, false);
  PERFORM set_config('pgtap.v_user_denied_113', v_user_denied::text, false);
  PERFORM set_config('pgtap.v_cash_acc_113',    v_cash_acc::text, false);
  PERFORM set_config('pgtap.v_expense_acc_113', v_expense_acc::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- A. FN-PRV enforced again for a DIRECT CPV — the actual regression fix.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_trans_no text;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_113'), 'company_id', current_setting('pgtap.v_company_113'),
      'location_id', current_setting('pgtap.v_loc_113'),
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'CPV', 'is_on_account', true,
      'remarks', 'pgTAP 113 direct CPV — restore check'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', current_setting('pgtap.v_cash_acc_113')::uuid, 'trans_nature', 'CR',
        'trans_amount', 25, 'trans_currency', 'USD', 'base_amount', 25, 'base_rate', 1,
        'local_amount', 25, 'local_rate', 1, 'party_amount', 25, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', current_setting('pgtap.v_expense_acc_113')::uuid, 'trans_nature', 'DR',
        'trans_amount', 25, 'trans_currency', 'USD', 'base_amount', 25, 'base_rate', 1,
        'local_amount', 25, 'local_rate', 1, 'party_amount', 25, 'party_currency', 'USD', 'party_rate', 1)
    ),
    current_setting('pgtap.v_user_prv_113')::uuid
  );
  PERFORM set_config('pgtap.v_cpv1_113', v_trans_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_113'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client_113')::uuid, current_setting('pgtap.v_company_113')::uuid, current_setting('pgtap.v_loc_113')::uuid,
      current_setting('pgtap.v_cpv1_113'), CURRENT_DATE, current_setting('pgtap.v_user_denied_113')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t1_113', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t1_113')::boolean, 'ok 1 — a denied user cannot post a DIRECT CPV (FN-PRV branch restored — the actual regression)');
INSERT INTO test_results (result) SELECT ok(
  NOT (SELECT is_posted FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client_113')::uuid AND company_id = current_setting('pgtap.v_company_113')::uuid AND trans_no = current_setting('pgtap.v_cpv1_113') AND trans_date = CURRENT_DATE),
  'ok 2 — the rejected CPV was NOT posted'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_prv_113'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client_113')::uuid, current_setting('pgtap.v_company_113')::uuid, current_setting('pgtap.v_loc_113')::uuid,
      current_setting('pgtap.v_cpv1_113'), CURRENT_DATE, current_setting('pgtap.v_user_prv_113')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t3_113', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t3_113')::boolean, 'ok 3 — a user WITH FN-PRV can post the same CPV');

-- ════════════════════════════════════════════════════════════════════
-- B. A CPV whose source_doc_type is already set (simulating migration
-- 114's Sales Invoice composition) is correctly EXEMPTED.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_trans_no text;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_113'), 'company_id', current_setting('pgtap.v_company_113'),
      'location_id', current_setting('pgtap.v_loc_113'),
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'CPV', 'is_on_account', true,
      'remarks', 'pgTAP 113 composed CPV — guard exemption check'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', current_setting('pgtap.v_cash_acc_113')::uuid, 'trans_nature', 'CR',
        'trans_amount', 15, 'trans_currency', 'USD', 'base_amount', 15, 'base_rate', 1,
        'local_amount', 15, 'local_rate', 1, 'party_amount', 15, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', current_setting('pgtap.v_expense_acc_113')::uuid, 'trans_nature', 'DR',
        'trans_amount', 15, 'trans_currency', 'USD', 'base_amount', 15, 'base_rate', 1,
        'local_amount', 15, 'local_rate', 1, 'party_amount', 15, 'party_currency', 'USD', 'party_rate', 1)
    ),
    current_setting('pgtap.v_user_prv_113')::uuid
  );
  -- Simulates the tagging migration 114 will add to Sales Invoice's own
  -- composed CRV — same shape fn_post_voucher already uses for GRN/JV.
  UPDATE rih_finance_headers SET source_doc_type = 'SALES_INVOICE', source_doc_no = 'SI-113-TEST', source_doc_date = CURRENT_DATE
  WHERE client_id = current_setting('pgtap.v_client_113')::uuid AND company_id = current_setting('pgtap.v_company_113')::uuid
    AND location_id = current_setting('pgtap.v_loc_113')::uuid AND trans_no = v_trans_no AND trans_date = CURRENT_DATE;
  PERFORM set_config('pgtap.v_cpv2_113', v_trans_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_113'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client_113')::uuid, current_setting('pgtap.v_company_113')::uuid, current_setting('pgtap.v_loc_113')::uuid,
      current_setting('pgtap.v_cpv2_113'), CURRENT_DATE, current_setting('pgtap.v_user_denied_113')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t4_113', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t4_113')::boolean, 'ok 4 — GUARD: a user with NO FN-PRV CAN post a CPV whose source_doc_type is already set (proves the auto-posted-composition exemption works, ahead of migration 114 actually using it)');

-- ════════════════════════════════════════════════════════════════════
-- C. Regression check — JV still correctly requires FN-JRN, not FN-PRV.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_trans_no text; v_error_raised boolean := false;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_113'), 'company_id', current_setting('pgtap.v_company_113'),
      'location_id', current_setting('pgtap.v_loc_113'),
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'JV', 'is_on_account', true,
      'remarks', 'pgTAP 113 direct JV — regression check'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', current_setting('pgtap.v_cash_acc_113')::uuid, 'trans_nature', 'CR',
        'trans_amount', 10, 'trans_currency', 'USD', 'base_amount', 10, 'base_rate', 1,
        'local_amount', 10, 'local_rate', 1, 'party_amount', 10, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', current_setting('pgtap.v_expense_acc_113')::uuid, 'trans_nature', 'DR',
        'trans_amount', 10, 'trans_currency', 'USD', 'base_amount', 10, 'base_rate', 1,
        'local_amount', 10, 'local_rate', 1, 'party_amount', 10, 'party_currency', 'USD', 'party_rate', 1)
    ),
    current_setting('pgtap.v_user_prv_113')::uuid
  );
  -- v_user_prv holds FN-PRV but NOT FN-JRN — must still be denied.
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_prv_113'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client_113')::uuid, current_setting('pgtap.v_company_113')::uuid, current_setting('pgtap.v_loc_113')::uuid,
      v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user_prv_113')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t5_113', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t5_113')::boolean, 'ok 5 — REGRESSION: a user with FN-PRV (but not FN-JRN) still cannot post a direct JV — the branches are not cross-wired');

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
