-- ============================================================
-- 106_contra_voucher_test.sql — pgTAP tests for migration 106
-- (CONTRA voucher_nature, CTR voucher type, fn_reverse_voucher rename)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- No new posting function is exercised here — a Contra Voucher posts
-- through fn_save_finance_voucher/fn_post_finance_voucher completely
-- unchanged (same engine JV already proved generic in 105). Backend
-- amounts are hardcoded directly into each test's JSONB payload,
-- exactly like 105_journal_voucher_test.sql — the backend never
-- recomputes trans/base/local/party amounts, it only validates the
-- DR=CR balance on base_amount, so no real fn_get_exchange_rate data
-- is needed to prove either the CONTRA path or the rename.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(11);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0106-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0106-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0106-000000000003';
  v_user_id     uuid := '00000000-0000-0000-0106-000000000004';
  v_cash        uuid := '00000000-0000-0000-0106-000000000005';  -- Cash, USD
  v_bank_usd    uuid := '00000000-0000-0000-0106-000000000006';  -- Bank, USD
  v_bank_eur    uuid := '00000000-0000-0000-0106-000000000007';  -- Bank, EUR
  v_charge_acc  uuid := '00000000-0000-0000-0106-000000000008';  -- General, transfer-charge line
  v_acc_gen     uuid := '00000000-0000-0000-0106-000000000009';  -- General (for the JV regression test)
  v_fy_id       uuid := '00000000-0000-0000-0106-00000000000a';
  v_usd_ccy_id  uuid;
  v_eur_ccy_id  uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST106', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST106 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test106 Loc', 'T106L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test106_user', 'Test106 User', crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- EUR needs no explicit insert — fn_seed_company_currencies (007) already
  -- auto-seeds all ~155 ISO currencies, EUR included, the moment the
  -- ric_companies row above is created (inactive by default, which is
  -- fine here: this test only needs the row to exist for the FK below,
  -- never checks is_active). An earlier draft's own explicit INSERT was
  -- both redundant and NOT NULL-violating (missing currency_notation) —
  -- removed rather than patched.
  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';
  SELECT id INTO v_eur_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'EUR';

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST106', '2015-01-01', '2035-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_cash,       v_client_id, v_company_id, '1010', 'Test106 Petty Cash',   'Cash',    'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_bank_usd,   v_client_id, v_company_id, '1020', 'Test106 Bank USD',     'Bank',    'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_bank_eur,   v_client_id, v_company_id, '1030', 'Test106 Bank EUR',     'Bank',    'OHADA', true, v_eur_ccy_id, true, false, now()),
    (v_charge_acc, v_client_id, v_company_id, '5300', 'Test106 Bank Charges', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_acc_gen,    v_client_id, v_company_id, '5400', 'Test106 Misc Expense', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user', v_user_id::text, false);
  PERFORM set_config('pgtap.v_cash', v_cash::text, false);
  PERFORM set_config('pgtap.v_bank_usd', v_bank_usd::text, false);
  PERFORM set_config('pgtap.v_bank_eur', v_bank_eur::text, false);
  PERFORM set_config('pgtap.v_charge_acc', v_charge_acc::text, false);
  PERFORM set_config('pgtap.v_acc_gen', v_acc_gen::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1: the migration's own CTR system row exists with voucher_nature
-- = 'CONTRA' — proves the CHECK constraint extension actually took.
-- ════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rim_voucher_types WHERE voucher_type_code = 'CTR' AND voucher_nature = 'CONTRA' AND is_system = true),
  'ok 1 — CTR system voucher type exists with voucher_nature = CONTRA (CHECK constraint extension took effect)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 2-4: same-currency Cash -> Bank (deposit), 2 lines, no charge
-- line needed since both legs are USD and the amounts already agree.
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
      'voucher_type_code', 'CTR', 'is_on_account', true,
      'remarks', 'pgTAP CTR deposit test'
    ),
    jsonb_build_array(
      -- FROM (Cash) — always CR
      jsonb_build_object(
        'serial_no', 1, 'account_id', current_setting('pgtap.v_cash')::uuid, 'trans_nature', 'CR',
        'trans_amount', 500, 'trans_currency', 'USD', 'base_amount', 500, 'base_rate', 1,
        'local_amount', 500, 'local_rate', 1, 'party_amount', 500, 'party_currency', 'USD', 'party_rate', 1
      ),
      -- TO (Bank) — always DR
      jsonb_build_object(
        'serial_no', 2, 'account_id', current_setting('pgtap.v_bank_usd')::uuid, 'trans_nature', 'DR',
        'trans_amount', 500, 'trans_currency', 'USD', 'base_amount', 500, 'base_rate', 1,
        'local_amount', 500, 'local_rate', 1, 'party_amount', 500, 'party_currency', 'USD', 'party_rate', 1
      )
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_post_finance_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_ctr1', v_trans_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_ctr1') LIKE 'CTR%',
  'ok 2 — a same-currency Cash-to-Bank Contra Voucher saves and returns a CTR-numbered trans_no'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT is_posted FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr1') AND trans_date = CURRENT_DATE),
  'ok 3 — the deposit CTR posts successfully through the unchanged fn_post_finance_voucher engine'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_nature FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr1') AND account_id = current_setting('pgtap.v_cash')::uuid) = 'CR'
  AND
  (SELECT trans_nature FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr1') AND account_id = current_setting('pgtap.v_bank_usd')::uuid) = 'DR',
  'ok 4 — direction is correct and implicit: FROM (Cash) is CR, TO (Bank) is DR, exactly as the screen design requires (never a user-picked field)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 5-7: cross-currency Bank(USD) -> Bank(EUR) with a real gap
-- between what left and what arrived (a $5 wire fee), absorbed by a
-- third charge line — proves a 3-line Contra balances correctly.
-- USD 1000 sent, implied rate 1 USD = 0.90 EUR -> 900 EUR would
-- reconcile with no gap; here only 895 EUR actually arrived (a $5.56
-- shortfall in USD terms), so the charge line carries that shortfall.
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
      'voucher_type_code', 'CTR', 'is_on_account', true,
      'remarks', 'pgTAP CTR cross-currency test'
    ),
    jsonb_build_array(
      -- FROM (Bank USD) — CR, the full 1000 that left
      jsonb_build_object(
        'serial_no', 1, 'account_id', current_setting('pgtap.v_bank_usd')::uuid, 'trans_nature', 'CR',
        'trans_amount', 1000, 'trans_currency', 'USD', 'base_amount', 1000, 'base_rate', 1,
        'local_amount', 1000, 'local_rate', 1, 'party_amount', 1000, 'party_currency', 'USD', 'party_rate', 1
      ),
      -- TO (Bank EUR) — DR, only 994.44 USD-worth actually arrived (895 EUR at the implied 0.90 rate)
      jsonb_build_object(
        'serial_no', 2, 'account_id', current_setting('pgtap.v_bank_eur')::uuid, 'trans_nature', 'DR',
        'trans_amount', 994.44, 'trans_currency', 'USD', 'base_amount', 994.44, 'base_rate', 1,
        'local_amount', 994.44, 'local_rate', 1, 'party_amount', 895, 'party_currency', 'EUR', 'party_rate', 0.9
      ),
      -- Transfer Charge — DR, absorbs the shortfall so the voucher still balances
      jsonb_build_object(
        'serial_no', 3, 'account_id', current_setting('pgtap.v_charge_acc')::uuid, 'trans_nature', 'DR',
        'trans_amount', 5.56, 'trans_currency', 'USD', 'base_amount', 5.56, 'base_rate', 1,
        'local_amount', 5.56, 'local_rate', 1, 'party_amount', 5.56, 'party_currency', 'USD', 'party_rate', 1
      )
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_post_finance_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_ctr2', v_trans_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_ctr2') LIKE 'CTR%',
  'ok 5 — a cross-currency Contra Voucher with a 3rd charge line saves and posts'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature='DR' THEN base_amount ELSE -base_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr2') AND trans_date = CURRENT_DATE),
  'ok 6 — the 3-line cross-currency Contra is balanced (DR = CR on base_amount) once the charge line absorbs the gap'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT party_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr2') AND account_id = current_setting('pgtap.v_bank_eur')::uuid),
  895::numeric, 'ok 7 — the TO line''s party_amount stores the literal Amount Received (895 EUR) untouched, not a formula-recomputed value (the Odoo-style override)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 8-9: fn_reverse_voucher reverses a posted CTR correctly.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_reversal_no text;
BEGIN
  v_reversal_no := fn_reverse_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_ctr1'), CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_ctr1_reversal', v_reversal_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT reversal_of_trans_no FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr1_reversal') AND trans_date = CURRENT_DATE) = current_setting('pgtap.v_ctr1')
  AND
  (SELECT voucher_type_code FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr1_reversal') AND trans_date = CURRENT_DATE) = 'CTR',
  'ok 8 — fn_reverse_voucher (the renamed function) reverses a CTR voucher, tags reversal_of_trans_no, and re-posts under the SAME voucher_type_code (CTR, not JV)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_nature FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ctr1_reversal') AND account_id = current_setting('pgtap.v_cash')::uuid) = 'DR',
  'ok 9 — the reversal flips the original Cash line (originally CR) to DR'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 10-11: regression — fn_reverse_voucher still correctly reverses
-- a JOURNAL voucher after the rename (protects Journal Voucher's own
-- Reverse feature, built in migration 105, from silently breaking).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_jv_trans_no text;
  v_jv_reversal text;
BEGIN
  v_jv_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'trans_no', null, 'trans_date', CURRENT_DATE,
      'voucher_type_code', 'JV', 'is_on_account', true,
      'remarks', 'pgTAP JV regression fixture for fn_reverse_voucher rename'
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'account_id', current_setting('pgtap.v_acc_gen')::uuid, 'trans_nature', 'DR',
        'trans_amount', 50, 'trans_currency', 'USD', 'base_amount', 50, 'base_rate', 1,
        'local_amount', 50, 'local_rate', 1, 'party_amount', 50, 'party_currency', 'USD', 'party_rate', 1
      ),
      jsonb_build_object(
        'serial_no', 2, 'account_id', current_setting('pgtap.v_charge_acc')::uuid, 'trans_nature', 'CR',
        'trans_amount', 50, 'trans_currency', 'USD', 'base_amount', 50, 'base_rate', 1,
        'local_amount', 50, 'local_rate', 1, 'party_amount', 50, 'party_currency', 'USD', 'party_rate', 1
      )
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_post_finance_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_jv_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  v_jv_reversal := fn_reverse_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_jv_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_jv_trans_no', v_jv_trans_no, false);
  PERFORM set_config('pgtap.v_jv_reversal', v_jv_reversal, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_jv_reversal') LIKE 'JV%'
  AND
  (SELECT reversal_of_trans_no FROM rih_finance_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_jv_reversal') AND trans_date = CURRENT_DATE) = current_setting('pgtap.v_jv_trans_no'),
  'ok 10 — REGRESSION: fn_reverse_voucher still correctly reverses a JOURNAL voucher and re-posts it as JV, not CTR (the rename did not break Journal Voucher''s existing Reverse feature)'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    PERFORM fn_reverse_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      current_setting('pgtap.v_jv_trans_no'), CURRENT_DATE, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%ALREADY_REVERSED%');
  END;
  PERFORM set_config('pgtap.v_test11', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test11')::boolean,
  'ok 11 — the ALREADY_REVERSED guard still works under the renamed fn_reverse_voucher'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
