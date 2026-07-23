-- ============================================================
-- 105_journal_voucher_test.sql — pgTAP tests for migration 105
-- (fn_check_backdate_allowed reference-date fix, fn_post_finance_voucher's
-- new call to it, fn_reverse_journal_voucher)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- A Journal Voucher itself needs NO new posting logic (fn_save_finance_
-- voucher/fn_post_finance_voucher already handle it unchanged, per the
-- migration's own header comment) — most of this file proves the
-- reference-date fix, since that's the one genuinely new piece of SQL
-- logic. Bill-linkage auto-tagging (plan §7) and the Cash/Bank picker
-- exclusion (plan §6) are pure Flutter-side logic with no new backend
-- function to test directly; test 8 below confirms the EXISTING
-- generic inv_bill_no/settlement mechanism still works correctly when
-- the caller happens to be a JV-shaped voucher, which is what plan §7
-- actually relies on.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(12);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0105-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0105-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0105-000000000003';
  v_user_id     uuid := '00000000-0000-0000-0105-000000000004';
  v_grp         uuid := '00000000-0000-0000-0105-000000000005';
  v_acc_a       uuid := '00000000-0000-0000-0105-000000000006';  -- General
  v_acc_b       uuid := '00000000-0000-0000-0105-000000000007';  -- General
  v_customer    uuid := '00000000-0000-0000-0105-000000000008';
  v_fy_id       uuid := '00000000-0000-0000-0105-000000000009';
  v_usd_ccy_id  uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST105', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST105 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test105 Loc', 'T105L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test105_user', 'Test105 User', crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  -- Wide FY so both the historical backdate-fix dates AND today fall inside it.
  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST105', '2015-01-01', '2035-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_grp, v_client_id, v_company_id, '3000', 'Sundry Debtors 105', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_acc_a,    v_client_id, v_company_id, '5100', 'Test105 Office Expense', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_acc_b,    v_client_id, v_company_id, '5200', 'Test105 Misc Income',    'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES (v_customer, v_client_id, v_company_id, v_grp, '3000001', 'Test105 Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user', v_user_id::text, false);
  PERFORM set_config('pgtap.v_acc_a', v_acc_a::text, false);
  PERFORM set_config('pgtap.v_acc_b', v_acc_b::text, false);
  PERFORM set_config('pgtap.v_customer', v_customer::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1-3: fn_check_backdate_allowed's new p_reference_date param —
-- direct proof the comparison basis actually changed, independent of
-- whatever CURRENT_DATE happens to be when this test runs.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  INSERT INTO ric_backdated_entry_control (client_id, company_id, transaction_type, max_backdate_days, allow_future_date)
  VALUES (current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'TEST105_BACKDATE', 0, false)
  ON CONFLICT (client_id, company_id, transaction_type) DO UPDATE SET max_backdate_days = 0, allow_future_date = false;

  -- trans_date == reference_date, max_backdate_days=0 — must ALWAYS pass,
  -- regardless of how far in the past '2020-06-15' is from real CURRENT_DATE.
  BEGIN
    PERFORM fn_check_backdate_allowed(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      'TEST105_BACKDATE', '2020-06-15'::date, '2020-06-15'::date
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := true;
  END;
  PERFORM set_config('pgtap.v_test1', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test1')::boolean,
  'ok 1 — trans_date == reference_date never raises BACKDATE_NOT_ALLOWED, no matter how old the date is relative to real CURRENT_DATE (the actual bug fix, proven directly)'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  -- trans_date is 1 day BEFORE reference_date, max_backdate_days=0 — must fail.
  BEGIN
    PERFORM fn_check_backdate_allowed(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      'TEST105_BACKDATE', '2020-06-14'::date, '2020-06-15'::date
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%BACKDATE_NOT_ALLOWED%');
  END;
  PERFORM set_config('pgtap.v_test2', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test2')::boolean,
  'ok 2 — trans_date 1 day before reference_date with max_backdate_days=0 still correctly raises BACKDATE_NOT_ALLOWED'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  -- Old-style 4-arg call (no reference_date) — must still work, defaulting
  -- to CURRENT_DATE, exactly as every pre-existing call site relies on.
  BEGIN
    PERFORM fn_check_backdate_allowed(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      'TEST105_BACKDATE', CURRENT_DATE
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := true;
  END;
  PERFORM set_config('pgtap.v_test3', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test3')::boolean,
  'ok 3 — the old 4-arg call shape (no reference_date) still works unchanged, defaulting to CURRENT_DATE'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 4-6: a Journal Voucher itself — save+approve, no cash/bank line,
-- balanced multi-line entry, posts through the unchanged shared engine.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'JV', 'is_on_account', true,
      'remarks', 'pgTAP JV test'
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'account_id', current_setting('pgtap.v_acc_a')::uuid, 'trans_nature', 'DR',
        'trans_amount', 100, 'trans_currency', 'USD', 'base_amount', 100, 'base_rate', 1,
        'local_amount', 100, 'local_rate', 1, 'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1
      ),
      jsonb_build_object(
        'serial_no', 2, 'account_id', current_setting('pgtap.v_acc_b')::uuid, 'trans_nature', 'CR',
        'trans_amount', 100, 'trans_currency', 'USD', 'base_amount', 100, 'base_rate', 1,
        'local_amount', 100, 'local_rate', 1, 'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1
      )
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_post_finance_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_jv1', v_trans_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_jv1') LIKE 'JV%',
  'ok 4 — a Journal Voucher with NO cash/bank line saves and returns a JV-numbered trans_no'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT is_posted FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_jv1') AND trans_date = CURRENT_DATE),
  'ok 5 — the JV posts successfully (period + new backdate check both pass for a same-day entry)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature='DR' THEN base_amount ELSE -base_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_jv1') AND trans_date = CURRENT_DATE),
  'ok 6 — the posted JV is balanced (DR = CR on base_amount)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 7-9: fn_reverse_journal_voucher — one-click reversal.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_reversal_no text;
BEGIN
  v_reversal_no := fn_reverse_journal_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_jv1'), CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_reversal1', v_reversal_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT reversal_of_trans_no FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_reversal1') AND trans_date = CURRENT_DATE) = current_setting('pgtap.v_jv1'),
  'ok 7 — the reversal voucher is tagged reversal_of_trans_no pointing at the original JV'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_nature FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_reversal1') AND account_id = current_setting('pgtap.v_acc_a')::uuid) = 'CR',
  'ok 8 — the reversal flips the original DR line (account A, originally DR) to CR'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    PERFORM fn_reverse_journal_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      current_setting('pgtap.v_jv1'), CURRENT_DATE, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%ALREADY_REVERSED%');
  END;
  PERFORM set_config('pgtap.v_test9', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test9')::boolean,
  'ok 9 — attempting to reverse the same JV a second time raises ALREADY_REVERSED'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 10-12: a JV line tagged inv_bill_no (simulating plan §7's
-- Flutter-side auto-tagging) correctly creates a live pending bill via
-- the EXISTING, unchanged settlement engine — proving a JV-shaped
-- voucher can drive it exactly like Cash Receipt/Sales Invoice already do.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'JV', 'is_on_account', true,
      'remarks', 'pgTAP JV bill-linkage test'
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'account_id', current_setting('pgtap.v_customer')::uuid, 'trans_nature', 'DR',
        'trans_amount', 250, 'trans_currency', 'USD', 'base_amount', 250, 'base_rate', 1,
        'local_amount', 250, 'local_rate', 1, 'party_amount', 250, 'party_currency', 'USD', 'party_rate', 1,
        -- Simulates Flutter's own §7 cascade: reference no/date absent ->
        -- falls back to this same voucher's own (not-yet-known) trans_no,
        -- so the Flutter layer would resolve this AFTER save returns the
        -- real trans_no. Here we just confirm the mechanism, using a
        -- literal placeholder bill number as the Flutter screen would.
        'inv_bill_no', 'JVBILL-105-A', 'inv_bill_date', CURRENT_DATE
      ),
      jsonb_build_object(
        'serial_no', 2, 'account_id', current_setting('pgtap.v_acc_a')::uuid, 'trans_nature', 'CR',
        'trans_amount', 250, 'trans_currency', 'USD', 'base_amount', 250, 'base_rate', 1,
        'local_amount', 250, 'local_rate', 1, 'party_amount', 250, 'party_currency', 'USD', 'party_rate', 1
      )
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_post_finance_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_jv2', v_trans_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT party_amount - settled_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_jv2') AND account_id = current_setting('pgtap.v_customer')::uuid),
  250::numeric, 'ok 10 — a JV customer-debit line tagged inv_bill_no creates a live pending bill with the full outstanding balance'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (
    SELECT 1 FROM v_pending_bills
    WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
      AND account_id = current_setting('pgtap.v_customer')::uuid AND inv_bill_no = 'JVBILL-105-A'
  ),
  'ok 11 — that same bill is visible through v_pending_bills, the exact view Cash Receipt/Finance Voucher''s Against-Bill mode already query'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature='DR' THEN base_amount ELSE -base_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_jv2') AND trans_date = CURRENT_DATE),
  'ok 12 — the bill-creating JV is itself still balanced (DR = CR on base_amount), same as any other voucher'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
