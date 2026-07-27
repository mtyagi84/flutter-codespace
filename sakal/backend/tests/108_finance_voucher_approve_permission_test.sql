-- ============================================================
-- 108_finance_voucher_approve_permission_test.sql — pgTAP tests for
-- migration 108 (fn_check_approve_permission, wired into
-- fn_post_finance_voucher / fn_approve_expense_voucher / fn_reverse_voucher)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Tests both design decisions directly:
-- - no request.jwt.claims set at all (the existing 105/106/107 test-suite
--   convention, and any direct-SQL/migration caller) => skipped, not denied.
-- - request.jwt.claims set to a real user with/without approve_allowed
--   for the relevant feature_code => the actual enforcement path.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(16);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id    uuid := '00000000-0000-0000-0108-000000000001';
  v_company_id   uuid := '00000000-0000-0000-0108-000000000002';
  v_loc_id       uuid := '00000000-0000-0000-0108-000000000003';
  v_user_ok      uuid := '00000000-0000-0000-0108-000000000004';  -- has approve_allowed on all 3
  v_user_denied  uuid := '00000000-0000-0000-0108-000000000005';  -- no ric_user_menus row at all
  v_acc_a        uuid := '00000000-0000-0000-0108-000000000006';  -- General DR
  v_acc_b        uuid := '00000000-0000-0000-0108-000000000007';  -- General CR
  v_supplier     uuid := '00000000-0000-0000-0108-000000000008';
  v_exp_acc      uuid := '00000000-0000-0000-0108-000000000009';
  v_fy_id        uuid := '00000000-0000-0000-0108-00000000000a';
  v_module_id    uuid := '00000000-0000-0000-0108-00000000000b';
  v_usd_ccy_id   uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST108', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST108 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test108 Loc', 'T108L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_ok,     v_client_id, v_company_id, 'test108_ok',     'Test108 Approver', crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_denied, v_client_id, v_company_id, 'test108_denied', 'Test108 Clerk',     crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST108', '2015-01-01', '2035-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_acc_a,    v_client_id, v_company_id, '5100', 'Test108 Office Expense', 'General',  'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_acc_b,    v_client_id, v_company_id, '5200', 'Test108 Misc Income',    'General',  'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_supplier, v_client_id, v_company_id, '2010', 'Test108 Supplier',      'Supplier', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_exp_acc,  v_client_id, v_company_id, '5500', 'Test108 Expense Acc',   'General',  'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Menu-permission fixture: one system module, one master-menu row per
  -- feature code, and ric_user_menus rows ONLY for v_user_ok — v_user_denied
  -- deliberately gets NO row at all, testing the "missing row = deny" path.
  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name)
  VALUES (v_module_id, v_client_id, v_company_id, 'FN', 'Finance')
  ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_module_id, 'FN-JRN', 'Journal Entry',    '/finance/journal',            true),
    (v_client_id, v_company_id, v_module_id, 'FN-CTR', 'Contra Voucher',  '/finance/contra',              true),
    (v_client_id, v_company_id, v_module_id, 'FN-EXP', 'Expense Voucher', '/finance/expense-vouchers',    true)
  ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;

  INSERT INTO ric_user_menus (client_id, company_id, user_id, module_id, feature_code, view_allowed, edit_allowed, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'FN-JRN', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'FN-CTR', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'FN-EXP', true, true, true)
  ON CONFLICT (client_id, company_id, user_id, feature_code) DO NOTHING;

  PERFORM set_config('pgtap.v_client',   v_client_id::text, false);
  PERFORM set_config('pgtap.v_company',  v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc',      v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user_ok',  v_user_ok::text, false);
  PERFORM set_config('pgtap.v_user_denied', v_user_denied::text, false);
  PERFORM set_config('pgtap.v_acc_a',    v_acc_a::text, false);
  PERFORM set_config('pgtap.v_acc_b',    v_acc_b::text, false);
  PERFORM set_config('pgtap.v_supplier', v_supplier::text, false);
  PERFORM set_config('pgtap.v_exp_acc',  v_exp_acc::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1-3: fn_check_approve_permission direct unit tests (all 3
-- feature codes) — no JWT / denied user / approved user.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean;
BEGIN
  -- No JWT context at all — must skip (never raise).
  v_error_raised := false;
  BEGIN
    PERFORM fn_check_approve_permission(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'FN-JRN');
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t1', (NOT v_error_raised)::text, false);

  -- Denied user's JWT set — must raise APPROVE_NOT_PERMITTED.
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  v_error_raised := false;
  BEGIN
    PERFORM fn_check_approve_permission(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'FN-JRN');
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t2', v_error_raised::text, false);

  -- Approved user's JWT set — must succeed.
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok'))::text, true);
  v_error_raised := false;
  BEGIN
    PERFORM fn_check_approve_permission(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'FN-JRN');
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t3', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t1')::boolean, 'ok 1 — FN-JRN: no JWT context at all skips the check (never raises)');
INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t2')::boolean, 'ok 2 — FN-JRN: a user with no ric_user_menus row raises APPROVE_NOT_PERMITTED');
INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t3')::boolean, 'ok 3 — FN-JRN: a user with approve_allowed=true succeeds');

DO $$
DECLARE
  v_error_raised boolean;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  v_error_raised := false;
  BEGIN
    PERFORM fn_check_approve_permission(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'FN-CTR');
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t4', v_error_raised::text, false);

  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok'))::text, true);
  v_error_raised := false;
  BEGIN
    PERFORM fn_check_approve_permission(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'FN-CTR');
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t5', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t4')::boolean, 'ok 4 — FN-CTR: a denied user raises APPROVE_NOT_PERMITTED');
INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t5')::boolean, 'ok 5 — FN-CTR: an approved user succeeds');

DO $$
DECLARE
  v_error_raised boolean;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  v_error_raised := false;
  BEGIN
    PERFORM fn_check_approve_permission(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'FN-EXP');
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t6', v_error_raised::text, false);

  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok'))::text, true);
  v_error_raised := false;
  BEGIN
    PERFORM fn_check_approve_permission(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'FN-EXP');
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t7', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t6')::boolean, 'ok 6 — FN-EXP: a denied user raises APPROVE_NOT_PERMITTED');
INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t7')::boolean, 'ok 7 — FN-EXP: an approved user succeeds');

-- ════════════════════════════════════════════════════════════════════
-- TEST 8-11: integration — fn_post_finance_voucher on a real JV, proving
-- the wiring (not just the helper in isolation), including the
-- no-JWT-at-all regression path existing 105/106/107 suites rely on.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
  v_trans_no     text;
BEGIN
  -- Reset to "no JWT context" by clearing the GUC (empty string fails the
  -- ::json cast inside fn_check_approve_permission, which is caught and
  -- treated identically to "never set" — see its own exception handler).
  PERFORM set_config('request.jwt.claims', '', true);

  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'JV', 'is_on_account', true,
      'remarks', 'pgTAP 108 JV — no JWT regression'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', current_setting('pgtap.v_acc_a')::uuid, 'trans_nature', 'DR',
        'trans_amount', 100, 'trans_currency', 'USD', 'base_amount', 100, 'base_rate', 1,
        'local_amount', 100, 'local_rate', 1, 'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', current_setting('pgtap.v_acc_b')::uuid, 'trans_nature', 'CR',
        'trans_amount', 100, 'trans_currency', 'USD', 'base_amount', 100, 'base_rate', 1,
        'local_amount', 100, 'local_rate', 1, 'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1)
    ),
    current_setting('pgtap.v_user_ok')::uuid
  );
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user_ok')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.jv1', v_trans_no, false);
  PERFORM set_config('pgtap.t8', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t8')::boolean, 'ok 8 — fn_post_finance_voucher: no JWT context at all still posts a JV successfully (regression, matches every existing pgTAP call site)');

DO $$
DECLARE
  v_error_raised boolean := false;
  v_trans_no     text;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'JV', 'is_on_account', true,
      'remarks', 'pgTAP 108 JV — permission enforcement'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', current_setting('pgtap.v_acc_a')::uuid, 'trans_nature', 'DR',
        'trans_amount', 50, 'trans_currency', 'USD', 'base_amount', 50, 'base_rate', 1,
        'local_amount', 50, 'local_rate', 1, 'party_amount', 50, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', current_setting('pgtap.v_acc_b')::uuid, 'trans_nature', 'CR',
        'trans_amount', 50, 'trans_currency', 'USD', 'base_amount', 50, 'base_rate', 1,
        'local_amount', 50, 'local_rate', 1, 'party_amount', 50, 'party_currency', 'USD', 'party_rate', 1)
    ),
    current_setting('pgtap.v_user_ok')::uuid
  );
  PERFORM set_config('pgtap.jv2', v_trans_no, false);

  -- Denied user attempts to approve — must raise APPROVE_NOT_PERMITTED.
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user_denied')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t9', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t9')::boolean, 'ok 9 — fn_post_finance_voucher: a JWT-authenticated user without FN-JRN approve rights is rejected with APPROVE_NOT_PERMITTED');

INSERT INTO test_results (result) SELECT ok(
  NOT (SELECT is_posted FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.jv2') AND trans_date = CURRENT_DATE),
  'ok 10 — the rejected JV was NOT posted (the deny actually blocked the GL posting, not just raised cosmetically)'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  -- Approved user retries the SAME JV — must succeed this time.
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      current_setting('pgtap.jv2'), CURRENT_DATE, current_setting('pgtap.v_user_ok')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t11', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t11')::boolean, 'ok 11 — fn_post_finance_voucher: the SAME JV posts successfully once retried by a user who actually has FN-JRN approve rights');

-- ════════════════════════════════════════════════════════════════════
-- TEST 12-13: fn_reverse_voucher on the now-posted JV (pgtap.jv2) —
-- denied then approved.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  BEGIN
    PERFORM fn_reverse_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      current_setting('pgtap.jv2'), CURRENT_DATE, current_setting('pgtap.v_user_denied')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t12', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t12')::boolean, 'ok 12 — fn_reverse_voucher: a denied user cannot reverse a posted JV either (APPROVE_NOT_PERMITTED)');

DO $$
DECLARE
  v_error_raised boolean := false;
  v_reversal_no  text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok'))::text, true);
  BEGIN
    v_reversal_no := fn_reverse_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      current_setting('pgtap.jv2'), CURRENT_DATE, current_setting('pgtap.v_user_ok')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t13', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t13')::boolean, 'ok 13 — fn_reverse_voucher: an approved user CAN reverse the same posted JV');

-- ════════════════════════════════════════════════════════════════════
-- TEST 14-16: fn_approve_expense_voucher — denied, approved, and confirms
-- the reject didn't leave the document silently APPROVED.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_expense_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'supplier_id', current_setting('pgtap.v_supplier')::uuid,
      'currency_id', (SELECT id FROM rim_currencies WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'bill_no', 'TEST108-BILL-1', 'bill_date', CURRENT_DATE,
      'remarks', 'pgTAP 108 Expense Voucher'
    ),
    jsonb_build_array(
      jsonb_build_object('account_id', current_setting('pgtap.v_exp_acc')::uuid, 'amount', 75, 'tax_group_id', null, 'line_remarks', 'test')
    ),
    current_setting('pgtap.v_user_ok')::uuid
  );
  PERFORM set_config('pgtap.exv1', v_trans_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  BEGIN
    PERFORM fn_approve_expense_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      current_setting('pgtap.exv1'), CURRENT_DATE, current_setting('pgtap.v_user_denied')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t14', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t14')::boolean, 'ok 14 — fn_approve_expense_voucher: a denied user is rejected with APPROVE_NOT_PERMITTED');

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_expense_voucher_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.exv1') AND trans_date = CURRENT_DATE) = 'DRAFT',
  'ok 15 — the rejected Expense Voucher is still DRAFT, not silently APPROVED'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok'))::text, true);
  BEGIN
    PERFORM fn_approve_expense_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      current_setting('pgtap.exv1'), CURRENT_DATE, current_setting('pgtap.v_user_ok')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t16', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t16')::boolean, 'ok 16 — fn_approve_expense_voucher: an approved user CAN approve the same Expense Voucher');

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
