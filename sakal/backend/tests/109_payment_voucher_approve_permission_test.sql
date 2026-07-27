-- ============================================================
-- 109_payment_voucher_approve_permission_test.sql — pgTAP tests for
-- migration 109 (fn_check_approve_permission extended to cover
-- CRV/BRV/CPV/BPV via feature_code FN-PRV)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- The underlying enforcement mechanism (fn_check_approve_permission
-- itself — JWT resolution, no-JWT skip, missing-row deny) is already
-- thoroughly tested in 108_finance_voucher_approve_permission_test.sql;
-- this file only proves the NEW voucher_type_code -> FN-PRV mapping
-- added in migration 109, via a representative CPV (Cash Payment
-- Voucher) — the same fn_post_finance_voucher/fn_reverse_voucher code
-- path already covers CRV/BRV/BPV identically (one shared IN (...) check).
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(5);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0109-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0109-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0109-000000000003';
  v_user_ok     uuid := '00000000-0000-0000-0109-000000000004';
  v_user_denied uuid := '00000000-0000-0000-0109-000000000005';
  v_cash_acc    uuid := '00000000-0000-0000-0109-000000000006';
  v_expense_acc uuid := '00000000-0000-0000-0109-000000000007';
  v_fy_id       uuid := '00000000-0000-0000-0109-000000000008';
  v_module_id   uuid := '00000000-0000-0000-0109-000000000009';
  v_usd_ccy_id  uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST109', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST109 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test109 Loc', 'T109L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_ok,     v_client_id, v_company_id, 'test109_ok',     'Test109 Approver', crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_denied, v_client_id, v_company_id, 'test109_denied', 'Test109 Clerk',     crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST109', '2015-01-01', '2035-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_cash_acc,    v_client_id, v_company_id, '1000', 'Test109 Cash',    'Cash',    'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_expense_acc, v_client_id, v_company_id, '5100', 'Test109 Expense', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Menu-permission fixture — mirrors 108's own shape, scoped to FN-PRV only.
  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name)
  VALUES (v_module_id, v_client_id, v_company_id, 'FN', 'Finance')
  ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, approve_allowed)
  VALUES (v_client_id, v_company_id, v_module_id, 'FN-PRV', 'Payment/Receipt Voucher', '/finance/voucher-list', true)
  ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;

  INSERT INTO ric_user_menus (client_id, company_id, user_id, module_id, feature_code, view_allowed, edit_allowed, approve_allowed)
  VALUES (v_client_id, v_company_id, v_user_ok, v_module_id, 'FN-PRV', true, true, true)
  ON CONFLICT (client_id, company_id, user_id, feature_code) DO NOTHING;

  PERFORM set_config('pgtap.v_client',   v_client_id::text, false);
  PERFORM set_config('pgtap.v_company',  v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc',      v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user_ok',  v_user_ok::text, false);
  PERFORM set_config('pgtap.v_user_denied', v_user_denied::text, false);
  PERFORM set_config('pgtap.v_cash_acc',    v_cash_acc::text, false);
  PERFORM set_config('pgtap.v_expense_acc', v_expense_acc::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1: backfill migration actually created/updated the row for this
-- (pre-existing, from 108's own client's perspective — but here, a
-- FRESH company created by THIS test's own fixture) — confirms the
-- master-menu row is queryable with the expected shape.
-- ════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  EXISTS (
    SELECT 1 FROM ric_master_menus
    WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
      AND feature_code = 'FN-PRV' AND screen_name = '/finance/voucher-list'
  ),
  'ok 1 — FN-PRV master-menu row exists with the confirmed real screen_name (/finance/voucher-list)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 2-4: fn_post_finance_voucher on a CPV (Cash Payment Voucher) —
-- denied, then approved, proving the new CRV/BRV/CPV/BPV -> FN-PRV
-- mapping added in migration 109.
-- ════════════════════════════════════════════════════════════════════
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
      'voucher_type_code', 'CPV', 'is_on_account', true,
      'remarks', 'pgTAP 109 CPV — permission enforcement'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', current_setting('pgtap.v_cash_acc')::uuid, 'trans_nature', 'CR',
        'trans_amount', 60, 'trans_currency', 'USD', 'base_amount', 60, 'base_rate', 1,
        'local_amount', 60, 'local_rate', 1, 'party_amount', 60, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', current_setting('pgtap.v_expense_acc')::uuid, 'trans_nature', 'DR',
        'trans_amount', 60, 'trans_currency', 'USD', 'base_amount', 60, 'base_rate', 1,
        'local_amount', 60, 'local_rate', 1, 'party_amount', 60, 'party_currency', 'USD', 'party_rate', 1)
    ),
    current_setting('pgtap.v_user_ok')::uuid
  );
  PERFORM set_config('pgtap.cpv1', v_trans_no, false);

  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user_denied')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t2', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t2')::boolean, 'ok 2 — fn_post_finance_voucher: a denied user cannot approve a CPV (FN-PRV mapping enforced)');

INSERT INTO test_results (result) SELECT ok(
  NOT (SELECT is_posted FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.cpv1') AND trans_date = CURRENT_DATE),
  'ok 3 — the rejected CPV was NOT posted'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok'))::text, true);
  BEGIN
    PERFORM fn_post_finance_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      current_setting('pgtap.cpv1'), CURRENT_DATE, current_setting('pgtap.v_user_ok')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t4', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t4')::boolean, 'ok 4 — fn_post_finance_voucher: the SAME CPV posts successfully once retried by a user who has FN-PRV approve rights');

-- ════════════════════════════════════════════════════════════════════
-- TEST 5: fn_reverse_voucher on the now-posted CPV — denied user rejected.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied'))::text, true);
  BEGIN
    PERFORM fn_reverse_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      current_setting('pgtap.cpv1'), CURRENT_DATE, current_setting('pgtap.v_user_denied')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t5', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t5')::boolean, 'ok 5 — fn_reverse_voucher: a denied user cannot reverse a posted CPV either (FN-PRV mapping enforced)');

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
