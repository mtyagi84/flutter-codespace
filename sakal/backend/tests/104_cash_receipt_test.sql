-- ============================================================
-- 104_cash_receipt_test.sql — pgTAP tests for migration 104
-- (fn_save_cash_receipt, fn_approve_cash_receipt)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Fixture: base=USD, local=CDF (the app's real DRC target scenario,
-- not the base=local=USD simplification most other tests use) — this
-- module's whole point is currency conversion + FX gain/loss, so the
-- fixture needs two genuinely different currencies. rim_currencies is
-- auto-seeded by ric_companies' own insert trigger (007_currencies.sql)
-- — no manual currency row inserts needed.
--
-- "Bills" (pending invoices) are fabricated directly as
-- rih_finance_headers/rid_finance_lines rows (a posted, self-referencing
-- inv_bill_no Customer DR line — exactly the shape fn_approve_sales_
-- invoice's own Customer DR line takes, see 089/090) rather than
-- replaying a full Sales Invoice fixture — this module only ever reads
-- that one line via fn_approve_cash_receipt, so a lighter fixture
-- suffices (same simplification precedent as 102's own delivery test,
-- which skips fabricating a full GRN/PO chain for its cost basis).
--
-- Test 5 reproduces the user's own worked example EXACTLY (confirmed
-- correct during planning): a 25,000 CDF invoice = 10 USD booked
-- @2500 CDF/USD; a partial receipt of 12,500 CDF @2600 → loss; the
-- remaining 12,500 CDF @2400 on a later receipt → gain. The user's own
-- hand math (0.192307 / 0.208333) is at 6 decimal places; every amount
-- column in this schema is NUMERIC(18,4), so the actually-POSTED
-- figures round to 0.1923 / 0.2083 — same numbers, standard 4dp
-- rounding, not a discrepancy.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(16);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0104-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0104-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0104-000000000003';
  v_user_id     uuid := '00000000-0000-0000-0104-000000000004';
  v_customer    uuid := '00000000-0000-0000-0104-000000000005';
  v_cust_grp    uuid := '00000000-0000-0000-0104-000000000006';
  v_local_cash  uuid := '00000000-0000-0000-0104-000000000007';
  v_base_cash   uuid := '00000000-0000-0000-0104-000000000008';
  v_fx_acc      uuid := '00000000-0000-0000-0104-000000000009';
  v_fy_id       uuid := '00000000-0000-0000-0104-00000000000a';
  v_usd_ccy_id  uuid;
  v_fx_link     uuid;

  v_bill_a text := 'SLS-104-A';    -- simple, same-rate, no FX
  v_bill_b text := 'SLS-104-B';    -- multi-bill settlement test
  v_bill_c text := 'SLS-104-C';    -- multi-bill settlement test
  v_bill_d text := 'SLS-104-D';    -- straddles local+base pools
  v_bill_fx text := 'SLS-104-FX';  -- the worked FX example
  v_booking_date date := '2026-01-01';   -- rate 2500 CDF/USD
  v_receipt1_date date := '2026-02-01';  -- rate 2600 CDF/USD
  v_receipt2_date date := '2026-03-01';  -- rate 2400 CDF/USD
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST104', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST104 CO', 'USD', 'CDF', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test104 Loc', 'T104L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test104_user', 'Test104 User', crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST104', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_cust_grp, v_client_id, v_company_id, '3000', 'Sundry Debtors 104', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES (v_customer, v_client_id, v_company_id, v_cust_grp, '3000001', 'Test104 Customer', 'Customer', 'OHADA', true, (SELECT id FROM rim_currencies WHERE client_id=v_client_id AND company_id=v_company_id AND currency_id='CDF'), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_local_cash, v_client_id, v_company_id, '1010', 'Test104 Cash CDF', 'General', 'OHADA', true, (SELECT id FROM rim_currencies WHERE client_id=v_client_id AND company_id=v_company_id AND currency_id='CDF'), true, false, now()),
    (v_base_cash,  v_client_id, v_company_id, '1020', 'Test104 Cash USD', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_fx_acc,     v_client_id, v_company_id, '7900', 'Test104 Exchange Gain/Loss', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_fx_link FROM rim_account_link_types WHERE link_key = 'EXCHANGE_GAIN_LOSS_ACCOUNT';
  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES (v_client_id, v_company_id, v_fx_link, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;
  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES (v_client_id, v_company_id, v_fx_link, NULL, v_fx_acc)
  ON CONFLICT DO NOTHING;

  INSERT INTO ric_user_quick_invoice_setup (client_id, company_id, user_id, location_id, cash_customer_id, local_cash_account_id, base_cash_account_id)
  VALUES (v_client_id, v_company_id, v_user_id, v_loc_id, v_customer, v_local_cash, v_base_cash)
  ON CONFLICT (client_id, company_id, user_id) DO NOTHING;

  -- Exchange rates: USD -> CDF, three dates.
  INSERT INTO rim_exchange_rates (client_id, company_id, location_id, rate_date, from_currency, to_currency, buying_rate, selling_rate, source)
  VALUES
    (v_client_id, v_company_id, v_loc_id, v_booking_date,   'USD', 'CDF', 2500, 2500, 'MANUAL'),
    (v_client_id, v_company_id, v_loc_id, v_receipt1_date,  'USD', 'CDF', 2600, 2600, 'MANUAL'),
    (v_client_id, v_company_id, v_loc_id, v_receipt2_date,  'USD', 'CDF', 2400, 2400, 'MANUAL')
  ON CONFLICT (client_id, company_id, location_id, rate_date, from_currency, to_currency) DO NOTHING;

  -- ── Fabricated "bills" — a posted Customer DR finance line each,
  -- self-referencing inv_bill_no, exactly the shape fn_approve_sales_
  -- invoice's own Customer DR line takes.
  INSERT INTO rih_finance_headers (client_id, company_id, location_id, trans_no, trans_date, voucher_type_code, is_on_account, is_posted, posted_at, posted_by, created_by, updated_by)
  VALUES
    (v_client_id, v_company_id, v_loc_id, v_bill_a,  v_booking_date, 'SLS', false, true, now(), v_user_id, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_bill_b,  v_booking_date, 'SLS', false, true, now(), v_user_id, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_bill_c,  v_booking_date, 'SLS', false, true, now(), v_user_id, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_bill_d,  v_booking_date, 'SLS', false, true, now(), v_user_id, v_user_id, v_user_id),
    (v_client_id, v_company_id, v_loc_id, v_bill_fx, v_booking_date, 'SLS', false, true, now(), v_user_id, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  -- Bill A: 250,000 CDF = 100 USD @2500. Full local test, same-rate (no FX).
  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, inv_bill_no, inv_bill_date, created_by, updated_by)
  VALUES (v_client_id, v_company_id, v_loc_id, v_bill_a, v_booking_date, 1, v_customer, 'DR', 250000, 'CDF', 100, 0.0004, 250000, 1, 250000, 'CDF', 1, v_bill_a, v_booking_date, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  -- Bill B: 50,000 CDF = 20 USD @2500.
  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, inv_bill_no, inv_bill_date, created_by, updated_by)
  VALUES (v_client_id, v_company_id, v_loc_id, v_bill_b, v_booking_date, 1, v_customer, 'DR', 50000, 'CDF', 20, 0.0004, 50000, 1, 50000, 'CDF', 1, v_bill_b, v_booking_date, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  -- Bill C: 30,000 CDF = 12 USD @2500.
  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, inv_bill_no, inv_bill_date, created_by, updated_by)
  VALUES (v_client_id, v_company_id, v_loc_id, v_bill_c, v_booking_date, 1, v_customer, 'DR', 30000, 'CDF', 12, 0.0004, 30000, 1, 30000, 'CDF', 1, v_bill_c, v_booking_date, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  -- Bill D: 100,000 CDF = 40 USD @2500. Used to test a single line
  -- straddling both the local and base cash pools.
  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, inv_bill_no, inv_bill_date, created_by, updated_by)
  VALUES (v_client_id, v_company_id, v_loc_id, v_bill_d, v_booking_date, 1, v_customer, 'DR', 100000, 'CDF', 40, 0.0004, 100000, 1, 100000, 'CDF', 1, v_bill_d, v_booking_date, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  -- Bill FX: the user's own worked example — 25,000 CDF = 10 USD @2500.
  INSERT INTO rid_finance_lines (client_id, company_id, location_id, trans_no, trans_date, serial_no, account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, inv_bill_no, inv_bill_date, created_by, updated_by)
  VALUES (v_client_id, v_company_id, v_loc_id, v_bill_fx, v_booking_date, 1, v_customer, 'DR', 25000, 'CDF', 10, 0.0004, 25000, 1, 25000, 'CDF', 1, v_bill_fx, v_booking_date, v_user_id, v_user_id)
  ON CONFLICT DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user', v_user_id::text, false);
  PERFORM set_config('pgtap.v_customer', v_customer::text, false);
  PERFORM set_config('pgtap.v_bill_a', v_bill_a, false);
  PERFORM set_config('pgtap.v_bill_b', v_bill_b, false);
  PERFORM set_config('pgtap.v_bill_c', v_bill_c, false);
  PERFORM set_config('pgtap.v_bill_d', v_bill_d, false);
  PERFORM set_config('pgtap.v_bill_fx', v_bill_fx, false);
  PERFORM set_config('pgtap.v_booking_date', v_booking_date::text, false);
  PERFORM set_config('pgtap.v_receipt1_date', v_receipt1_date::text, false);
  PERFORM set_config('pgtap.v_receipt2_date', v_receipt2_date::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1: simple local-only receipt, same rate as booking — no FX.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_receipt_no text;
BEGIN
  v_receipt_no := fn_save_cash_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'receipt_no', null, 'receipt_date', current_setting('pgtap.v_booking_date')::date,
      'customer_id', current_setting('pgtap.v_customer')::uuid,
      'local_amount', 250000, 'base_amount', 0, 'remarks', 'pgTAP test 1'
    ),
    jsonb_build_array(jsonb_build_object(
      'inv_bill_no', current_setting('pgtap.v_bill_a'), 'inv_bill_date', current_setting('pgtap.v_booking_date'),
      'bill_currency', 'CDF', 'applied_amount_local', 250000
    )),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_receipt1', v_receipt_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_receipt1') LIKE 'CREC%',
  'ok 1 — fn_save_cash_receipt returns a CREC-numbered receipt_no'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_receipt1')),
  'DRAFT', 'ok 2 — saved receipt is DRAFT'
);

DO $$
BEGIN
  PERFORM fn_approve_cash_receipt(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_receipt1'), current_setting('pgtap.v_booking_date')::date,
    current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT status FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_receipt1')),
  'APPROVED', 'ok 3 — approved receipt status is APPROVED'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT crv_local_voucher_no IS NOT NULL AND crv_base_voucher_no IS NULL AND exc_voucher_no IS NULL
   FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_receipt1')),
  'ok 4 — only a CRV-LOCAL voucher posted, no CRV-BASE, no EXC (same rate as booking — zero FX)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature='DR' THEN base_amount ELSE -base_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT crv_local_voucher_no FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_receipt1'))),
  'ok 5 — CRV-LOCAL voucher is balanced (DR = CR on base_amount)'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT party_amount - settled_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_bill_a') AND account_id = current_setting('pgtap.v_customer')::uuid),
  0::numeric, 'ok 6 — Bill A fully settled (balance now 0)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 2: one receipt settling TWO bills at once.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_receipt_no text;
BEGIN
  v_receipt_no := fn_save_cash_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'receipt_no', null, 'receipt_date', current_setting('pgtap.v_booking_date')::date,
      'customer_id', current_setting('pgtap.v_customer')::uuid,
      'local_amount', 80000, 'base_amount', 0, 'remarks', 'pgTAP test 2'
    ),
    jsonb_build_array(
      jsonb_build_object('inv_bill_no', current_setting('pgtap.v_bill_b'), 'inv_bill_date', current_setting('pgtap.v_booking_date'), 'bill_currency', 'CDF', 'applied_amount_local', 50000),
      jsonb_build_object('inv_bill_no', current_setting('pgtap.v_bill_c'), 'inv_bill_date', current_setting('pgtap.v_booking_date'), 'bill_currency', 'CDF', 'applied_amount_local', 30000)
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_cash_receipt(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_receipt_no, current_setting('pgtap.v_booking_date')::date, current_setting('pgtap.v_user')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT (party_amount - settled_amount) = 0 FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_bill_b') AND account_id = current_setting('pgtap.v_customer')::uuid)
  AND
  (SELECT (party_amount - settled_amount) = 0 FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_bill_c') AND account_id = current_setting('pgtap.v_customer')::uuid),
  'ok 7 — one receipt knocks off BOTH Bill B and Bill C in a single CRV voucher'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 3: single applied line straddling both the local and base pools.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_receipt_no text;
BEGIN
  -- Bill D: 100,000 CDF pending. Local pool = 60,000 CDF, base pool =
  -- 16 USD (= 40,000 CDF equivalent @2500) — together exactly cover the
  -- bill, forcing this single applied line to split across both pools.
  v_receipt_no := fn_save_cash_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'receipt_no', null, 'receipt_date', current_setting('pgtap.v_booking_date')::date,
      'customer_id', current_setting('pgtap.v_customer')::uuid,
      'local_amount', 60000, 'base_amount', 16, 'remarks', 'pgTAP test 3'
    ),
    jsonb_build_array(jsonb_build_object(
      'inv_bill_no', current_setting('pgtap.v_bill_d'), 'inv_bill_date', current_setting('pgtap.v_booking_date'),
      'bill_currency', 'CDF', 'applied_amount_local', 100000
    )),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_cash_receipt(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_receipt_no, current_setting('pgtap.v_booking_date')::date, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_receipt3', v_receipt_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT crv_local_voucher_no IS NOT NULL AND crv_base_voucher_no IS NOT NULL
   FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_receipt3')),
  'ok 8 — a single bill straddling both pools posts BOTH a CRV-LOCAL and a CRV-BASE voucher'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT party_amount - settled_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_bill_d') AND account_id = current_setting('pgtap.v_customer')::uuid),
  0::numeric, 'ok 9 — Bill D fully settled across both fragments'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 4: the user's own worked FX example, exactly.
-- 25,000 CDF invoice = 10 USD booked @2500.
-- Receipt 1: 12,500 CDF @2600 -> proportional original base = 5.0 USD;
--   actual base collected = 12500/2600 = 4.807692... -> LOSS ~0.1923.
-- Receipt 2 (remaining 12,500 CDF) @2400 -> actual base = 12500/2400 =
--   5.208333... -> GAIN ~0.2083.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_receipt_no text;
BEGIN
  v_receipt_no := fn_save_cash_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'receipt_no', null, 'receipt_date', current_setting('pgtap.v_receipt1_date')::date,
      'customer_id', current_setting('pgtap.v_customer')::uuid,
      'local_amount', 12500, 'base_amount', 0, 'remarks', 'pgTAP FX test — receipt 1'
    ),
    jsonb_build_array(jsonb_build_object(
      'inv_bill_no', current_setting('pgtap.v_bill_fx'), 'inv_bill_date', current_setting('pgtap.v_booking_date'),
      'bill_currency', 'CDF', 'applied_amount_local', 12500
    )),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_cash_receipt(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_receipt_no, current_setting('pgtap.v_receipt1_date')::date, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_fx_receipt1', v_receipt_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT exc_voucher_no IS NOT NULL FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_fx_receipt1')),
  'ok 10 — receipt 1 (rate moved 2500->2600) posts an EXC voucher'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT round(trans_amount, 4) FROM rid_finance_lines
   WHERE trans_no = (SELECT exc_voucher_no FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_fx_receipt1'))
     AND trans_nature = 'DR'),
  0.1923::numeric,
  'ok 11 — EXC voucher DR (Exchange Loss) = 0.1923 USD (user''s own hand figure 0.192307, rounded to this schema''s standard 4dp)'
);

DO $$
DECLARE
  v_receipt_no text;
BEGIN
  v_receipt_no := fn_save_cash_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'receipt_no', null, 'receipt_date', current_setting('pgtap.v_receipt2_date')::date,
      'customer_id', current_setting('pgtap.v_customer')::uuid,
      'local_amount', 12500, 'base_amount', 0, 'remarks', 'pgTAP FX test — receipt 2 (remaining balance)'
    ),
    jsonb_build_array(jsonb_build_object(
      'inv_bill_no', current_setting('pgtap.v_bill_fx'), 'inv_bill_date', current_setting('pgtap.v_booking_date'),
      'bill_currency', 'CDF', 'applied_amount_local', 12500
    )),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_cash_receipt(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_receipt_no, current_setting('pgtap.v_receipt2_date')::date, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_fx_receipt2', v_receipt_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT round(trans_amount, 4) FROM rid_finance_lines
   WHERE trans_no = (SELECT exc_voucher_no FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND receipt_no = current_setting('pgtap.v_fx_receipt2'))
     AND trans_nature = 'CR' AND account_id != current_setting('pgtap.v_customer')::uuid),
  0.2083::numeric,
  'ok 12 — receipt 2 (rate moved 2500->2400) posts a GAIN of 0.2083 USD (user''s own hand figure 0.208333) CR to the Exchange Gain account'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT party_amount - settled_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_bill_fx') AND account_id = current_setting('pgtap.v_customer')::uuid),
  0::numeric, 'ok 13 — Bill FX fully settled across the two receipts, despite the FX gain/loss on each'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 5: over-application against a bill's live remaining balance.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    PERFORM fn_approve_cash_receipt(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      fn_save_cash_receipt(
        jsonb_build_object(
          'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
          'location_id', current_setting('pgtap.v_loc')::uuid,
          'receipt_no', null, 'receipt_date', current_setting('pgtap.v_booking_date')::date,
          'customer_id', current_setting('pgtap.v_customer')::uuid,
          'local_amount', 1, 'base_amount', 0, 'remarks', 'over-application test'
        ),
        jsonb_build_array(jsonb_build_object(
          'inv_bill_no', current_setting('pgtap.v_bill_a'), 'inv_bill_date', current_setting('pgtap.v_booking_date'),
          'bill_currency', 'CDF', 'applied_amount_local', 1
        )),
        current_setting('pgtap.v_user')::uuid
      ),
      current_setting('pgtap.v_booking_date')::date, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE%');
  END;
  PERFORM set_config('pgtap.v_test14', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test14')::boolean,
  'ok 14 — applying against Bill A (already fully settled in test 1) raises RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 6: future-dated receipt rejected at Approve (unconditional hard
-- guard, not a company-configurable opt-in).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_receipt_no text;
  v_error_raised boolean := false;
BEGIN
  v_receipt_no := fn_save_cash_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid,
      'receipt_no', null, 'receipt_date', (CURRENT_DATE + 1),
      'customer_id', current_setting('pgtap.v_customer')::uuid,
      'local_amount', 30000, 'base_amount', 0, 'remarks', 'future date test'
    ),
    jsonb_build_array(jsonb_build_object(
      'inv_bill_no', current_setting('pgtap.v_bill_c'), 'inv_bill_date', current_setting('pgtap.v_booking_date'),
      'bill_currency', 'CDF', 'applied_amount_local', 30000
    )),
    current_setting('pgtap.v_user')::uuid
  );
  BEGIN
    PERFORM fn_approve_cash_receipt(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
      v_receipt_no, (CURRENT_DATE + 1), current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%FUTURE_DATE_NOT_ALLOWED%');
  END;
  PERFORM set_config('pgtap.v_test15', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test15')::boolean,
  'ok 15 — a future-dated receipt is rejected at Approve with FUTURE_DATE_NOT_ALLOWED'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 7: header/line total mismatch rejected at Save.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    PERFORM fn_save_cash_receipt(
      jsonb_build_object(
        'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
        'location_id', current_setting('pgtap.v_loc')::uuid,
        'receipt_no', null, 'receipt_date', current_setting('pgtap.v_booking_date')::date,
        'customer_id', current_setting('pgtap.v_customer')::uuid,
        'local_amount', 30000, 'base_amount', 0, 'remarks', 'mismatch test'
      ),
      jsonb_build_array(jsonb_build_object(
        'inv_bill_no', current_setting('pgtap.v_bill_c'), 'inv_bill_date', current_setting('pgtap.v_booking_date'),
        'bill_currency', 'CDF', 'applied_amount_local', 20000
      )),
      current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%RECEIPT_AMOUNT_MISMATCH%');
  END;
  PERFORM set_config('pgtap.v_test16', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test16')::boolean,
  'ok 16 — header total (30,000) not matching applied lines total (20,000) raises RECEIPT_AMOUNT_MISMATCH at Save'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
