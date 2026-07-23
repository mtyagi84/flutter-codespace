-- ============================================================
-- 107_expense_voucher_test.sql — pgTAP tests for migration 107
-- (EXPENSE voucher_nature, EXV voucher type, default_tax_group_id,
-- fn_save_expense_voucher, fn_approve_expense_voucher — first real
-- consumer of rim_tax_types.is_withholding)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(14);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id    uuid := '00000000-0000-0000-0107-000000000001';
  v_company_id   uuid := '00000000-0000-0000-0107-000000000002';
  v_loc_id       uuid := '00000000-0000-0000-0107-000000000003';
  v_user_id      uuid := '00000000-0000-0000-0107-000000000004';
  v_supplier     uuid := '00000000-0000-0000-0107-000000000005';  -- Electricity Board
  v_exp_acc      uuid := '00000000-0000-0000-0107-000000000006';  -- Electricity Expense
  v_vat_input    uuid := '00000000-0000-0000-0107-000000000007';  -- Input VAT account
  v_wht_payable  uuid := '00000000-0000-0000-0107-000000000008';  -- WHT Payable account
  v_fy_id        uuid := '00000000-0000-0000-0107-000000000009';
  v_tax_vat      uuid := '00000000-0000-0000-0107-00000000000a';
  v_tax_wht      uuid := '00000000-0000-0000-0107-00000000000b';
  v_tax_wht_big  uuid := '00000000-0000-0000-0107-00000000000c';  -- 150% WHT, for the Net<=0 test
  v_grp_vat_only uuid := '00000000-0000-0000-0107-00000000000d';
  v_grp_mixed    uuid := '00000000-0000-0000-0107-00000000000e';
  v_grp_wht_big  uuid := '00000000-0000-0000-0107-00000000000f';
  v_usd_ccy_id   uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST107', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST107 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test107 Loc', 'T107L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test107_user', 'Test107 User', crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST107', '2015-01-01', '2035-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_supplier,    v_client_id, v_company_id, '2010', 'Test107 Electricity Board', 'Supplier', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_exp_acc,     v_client_id, v_company_id, '5500', 'Test107 Electricity Expense','General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_vat_input,   v_client_id, v_company_id, '1310', 'Test107 Input VAT',         'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_wht_payable, v_client_id, v_company_id, '2310', 'Test107 WHT Payable',       'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Taxes: VAT 16% (adds), WHT 10% (subtracts), WHT 150% (subtracts, for the Net<=0 boundary test).
  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, gl_input_account_id, gl_expense_account_id, is_active, is_deleted)
  VALUES
    (v_tax_vat,     v_client_id, v_company_id, 'TEST107-VAT16', 'Test107 VAT 16%',      'VAT',         'PURCHASE', v_vat_input,   NULL,          true, false),
    (v_tax_wht,     v_client_id, v_company_id, 'TEST107-WHT10', 'Test107 WHT 10%',      'WITHHOLDING', 'PURCHASE', NULL,          v_wht_payable, true, false),
    (v_tax_wht_big, v_client_id, v_company_id, 'TEST107-WHT150','Test107 WHT 150% (test)','WITHHOLDING','PURCHASE', NULL,        v_wht_payable, true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES
    (gen_random_uuid(), v_client_id, v_company_id, v_tax_vat,     'STANDARD', 16.0000,  '2015-01-01', v_user_id),
    (gen_random_uuid(), v_client_id, v_company_id, v_tax_wht,     'STANDARD', 10.0000,  '2015-01-01', v_user_id),
    (gen_random_uuid(), v_client_id, v_company_id, v_tax_wht_big, 'STANDARD', 150.0000, '2015-01-01', v_user_id)
  ON CONFLICT (client_id, company_id, tax_id, rate_label, effective_from) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, is_active, is_deleted)
  VALUES
    (v_grp_vat_only, v_client_id, v_company_id, 'TEST107-GVAT', 'Test107 VAT Only',     'PURCHASE', true, false),
    (v_grp_mixed,    v_client_id, v_company_id, 'TEST107-GMIX', 'Test107 VAT + WHT',    'PURCHASE', true, false),
    (v_grp_wht_big,  v_client_id, v_company_id, 'TEST107-GBIG', 'Test107 WHT 150% Only','PURCHASE', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES
    (v_client_id, v_company_id, v_grp_vat_only, v_tax_vat,     1),
    (v_client_id, v_company_id, v_grp_mixed,    v_tax_vat,     1),
    (v_client_id, v_company_id, v_grp_mixed,    v_tax_wht,     2),
    (v_client_id, v_company_id, v_grp_wht_big,  v_tax_wht_big, 1)
  ON CONFLICT (client_id, company_id, tax_group_id, tax_id) DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user', v_user_id::text, false);
  PERFORM set_config('pgtap.v_supplier', v_supplier::text, false);
  PERFORM set_config('pgtap.v_exp_acc', v_exp_acc::text, false);
  PERFORM set_config('pgtap.v_vat_input', v_vat_input::text, false);
  PERFORM set_config('pgtap.v_wht_payable', v_wht_payable::text, false);
  PERFORM set_config('pgtap.v_usd_ccy_id', v_usd_ccy_id::text, false);
  PERFORM set_config('pgtap.v_grp_vat_only', v_grp_vat_only::text, false);
  PERFORM set_config('pgtap.v_grp_mixed', v_grp_mixed::text, false);
  PERFORM set_config('pgtap.v_grp_wht_big', v_grp_wht_big::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- TEST 1: CHECK constraint allows EXPENSE; EXV system row exists.
-- ════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rim_voucher_types WHERE voucher_type_code = 'EXV' AND voucher_nature = 'EXPENSE' AND is_system = true)
  AND
  EXISTS (SELECT 1 FROM rim_voucher_types WHERE voucher_type_code = 'EXP' AND voucher_nature = 'EXPENSE' AND is_system = true),
  'ok 1 — both EXV (document numbering) and EXP (GL posting) system voucher types exist with voucher_nature = EXPENSE'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 2: rim_accounts.default_tax_group_id column exists and is settable.
-- ════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  UPDATE rim_accounts SET default_tax_group_id = current_setting('pgtap.v_grp_vat_only')::uuid
  WHERE id = current_setting('pgtap.v_exp_acc')::uuid;
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT default_tax_group_id FROM rim_accounts WHERE id = current_setting('pgtap.v_exp_acc')::uuid) = current_setting('pgtap.v_grp_vat_only')::uuid,
  'ok 2 — rim_accounts.default_tax_group_id column exists and is settable'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 3-6: no-tax single-line bill — save, approve, balance, Supplier
-- is serial_no=1 with the right net (== the plain expense amount).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_expense_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid, 'trans_no', null, 'trans_date', CURRENT_DATE,
      'supplier_id', current_setting('pgtap.v_supplier')::uuid, 'currency_id', current_setting('pgtap.v_usd_ccy_id')::uuid,
      'rate_to_base', 1, 'rate_to_local', 1,
      'bill_no', 'ELEC-JAN-001', 'bill_date', '2026-01-15', 'remarks', 'pgTAP no-tax test'
    ),
    jsonb_build_array(
      jsonb_build_object('account_id', current_setting('pgtap.v_exp_acc')::uuid, 'amount', 100, 'tax_group_id', null, 'line_remarks', 'January electricity')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_expense_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_ev1', v_trans_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_ev1') LIKE 'EXV%',
  'ok 3 — a no-tax single-line Expense Voucher saves and returns an EXV-numbered trans_no'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_expense_voucher_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ev1')) = 'APPROVED',
  'ok 4 — the voucher approves successfully (period/backdate checks both pass for a same-day entry)'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT serial_no FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND trans_no = (SELECT posted_voucher_no FROM rih_expense_voucher_headers WHERE trans_no = current_setting('pgtap.v_ev1'))
     AND account_id = current_setting('pgtap.v_supplier')::uuid),
  1, 'ok 5 — the Supplier line is posted as serial_no = 1, even though it was computed last'
);

INSERT INTO test_results (result) SELECT is(
  (SELECT trans_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND trans_no = (SELECT posted_voucher_no FROM rih_expense_voucher_headers WHERE trans_no = current_setting('pgtap.v_ev1'))
     AND account_id = current_setting('pgtap.v_supplier')::uuid),
  100::numeric, 'ok 6 — with no tax, the Supplier''s net equals the plain expense amount (100)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 7-9: VAT-only line — Supplier net = 100 + 16% VAT = 116, the
-- VAT line posts DR to the Input VAT account, and the whole posted
-- voucher balances (DR = CR on base_amount).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_expense_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid, 'trans_no', null, 'trans_date', CURRENT_DATE,
      'supplier_id', current_setting('pgtap.v_supplier')::uuid, 'currency_id', current_setting('pgtap.v_usd_ccy_id')::uuid,
      'rate_to_base', 1, 'rate_to_local', 1,
      'bill_no', 'ELEC-JAN-002', 'bill_date', '2026-01-16', 'remarks', 'pgTAP VAT-only test'
    ),
    jsonb_build_array(
      jsonb_build_object('account_id', current_setting('pgtap.v_exp_acc')::uuid, 'amount', 100, 'tax_group_id', current_setting('pgtap.v_grp_vat_only')::uuid, 'line_remarks', 'January electricity')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_expense_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_ev2', v_trans_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT trans_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND trans_no = (SELECT posted_voucher_no FROM rih_expense_voucher_headers WHERE trans_no = current_setting('pgtap.v_ev2'))
     AND account_id = current_setting('pgtap.v_supplier')::uuid),
  116::numeric, 'ok 7 — VAT-only: Supplier''s net is 100 + 16 VAT = 116'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
    AND trans_no = (SELECT posted_voucher_no FROM rih_expense_voucher_headers WHERE trans_no = current_setting('pgtap.v_ev2'))
    AND account_id = current_setting('pgtap.v_vat_input')::uuid AND trans_nature = 'DR' AND trans_amount = 16),
  'ok 8 — the VAT line posts DR 16 to the Input VAT account (a normal VAT-type tax ADDS to the payable)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(abs(sum(CASE WHEN trans_nature='DR' THEN base_amount ELSE -base_amount END)), 999) < 0.01
   FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
   AND trans_no = (SELECT posted_voucher_no FROM rih_expense_voucher_headers WHERE trans_no = current_setting('pgtap.v_ev2'))),
  'ok 9 — the VAT-only voucher is balanced (DR = CR on base_amount)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 10-11: mixed VAT+WHT line — Supplier net = 100 + 16 VAT − 10 WHT
-- = 106, the WHT line posts CR to the WHT Payable account (first real
-- consumer of rim_tax_types.is_withholding).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_expense_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid, 'trans_no', null, 'trans_date', CURRENT_DATE,
      'supplier_id', current_setting('pgtap.v_supplier')::uuid, 'currency_id', current_setting('pgtap.v_usd_ccy_id')::uuid,
      'rate_to_base', 1, 'rate_to_local', 1,
      'bill_no', 'ELEC-JAN-003', 'bill_date', '2026-01-17', 'remarks', 'pgTAP mixed VAT+WHT test'
    ),
    jsonb_build_array(
      jsonb_build_object('account_id', current_setting('pgtap.v_exp_acc')::uuid, 'amount', 100, 'tax_group_id', current_setting('pgtap.v_grp_mixed')::uuid, 'line_remarks', 'January electricity')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_approve_expense_voucher(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_ev3', v_trans_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT is(
  (SELECT trans_amount FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND trans_no = (SELECT posted_voucher_no FROM rih_expense_voucher_headers WHERE trans_no = current_setting('pgtap.v_ev3'))
     AND account_id = current_setting('pgtap.v_supplier')::uuid),
  106::numeric, 'ok 10 — mixed VAT+WHT: Supplier''s net is 100 + 16 VAT - 10 WHT = 106'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rid_finance_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
    AND trans_no = (SELECT posted_voucher_no FROM rih_expense_voucher_headers WHERE trans_no = current_setting('pgtap.v_ev3'))
    AND account_id = current_setting('pgtap.v_wht_payable')::uuid AND trans_nature = 'CR' AND trans_amount = 10),
  'ok 11 — the WHT line posts CR 10 to the WHT Payable account (a withholding-type tax SUBTRACTS from the payable)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 12: Net <= 0 is rejected (150% WHT on a 100 expense with no VAT
-- would leave the supplier owed -50, which doesn't fit "create a bill").
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
  v_error_raised boolean := false;
BEGIN
  v_trans_no := fn_save_expense_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid, 'trans_no', null, 'trans_date', CURRENT_DATE,
      'supplier_id', current_setting('pgtap.v_supplier')::uuid, 'currency_id', current_setting('pgtap.v_usd_ccy_id')::uuid,
      'rate_to_base', 1, 'rate_to_local', 1,
      'bill_no', 'ELEC-JAN-004', 'bill_date', '2026-01-18', 'remarks', 'pgTAP Net<=0 test'
    ),
    jsonb_build_array(
      jsonb_build_object('account_id', current_setting('pgtap.v_exp_acc')::uuid, 'amount', 100, 'tax_group_id', current_setting('pgtap.v_grp_wht_big')::uuid, 'line_remarks', 'Deliberately oversized WHT')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  BEGIN
    PERFORM fn_approve_expense_voucher(
      current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
      v_trans_no, CURRENT_DATE, current_setting('pgtap.v_user')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    v_error_raised := (SQLERRM LIKE '%EXPENSE_NET_NOT_POSITIVE%');
  END;
  PERFORM set_config('pgtap.v_test12', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_test12')::boolean,
  'ok 12 — a WHT deduction large enough to make Net <= 0 is correctly rejected (EXPENSE_NET_NOT_POSITIVE)'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 13: the Supplier line surfaces in v_pending_bills, tagged with
-- the real bill_no — bill-linkage is mandatory (never opt-in like JV's).
-- ════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  EXISTS (
    SELECT 1 FROM v_pending_bills
    WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
      AND account_id = current_setting('pgtap.v_supplier')::uuid AND inv_bill_no = 'ELEC-JAN-002'
  ),
  'ok 13 — the Expense Voucher''s Supplier line is visible in v_pending_bills, tagged with the real bill_no, ready for a later Payment Voucher to settle'
);

-- ════════════════════════════════════════════════════════════════════
-- TEST 14: REGRESSION — editing a DRAFT's own trans_date must not hit
-- a foreign-key violation. rid_expense_voucher_lines has a real FK on
-- (client_id, company_id, trans_no, trans_date); a first draft of this
-- function updated the header's trans_date and THEN deleted lines using
-- that NEW date (matching nothing, since existing lines are still
-- filed under the OLD date) — the header UPDATE itself would have
-- failed outright with "violates foreign key constraint" the moment a
-- user changed the date on an existing draft with lines already saved.
-- Fixed by capturing the old trans_date first and deleting under it
-- BEFORE the header changes, same fix GRN's own fn_save_grn already
-- uses (v_old_grn_date). This test proves an edit-with-date-change
-- succeeds and the line actually moved to the new date.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_trans_no text;
  v_new_date date := CURRENT_DATE - 1;
BEGIN
  v_trans_no := fn_save_expense_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid, 'trans_no', null, 'trans_date', CURRENT_DATE,
      'supplier_id', current_setting('pgtap.v_supplier')::uuid, 'currency_id', current_setting('pgtap.v_usd_ccy_id')::uuid,
      'rate_to_base', 1, 'rate_to_local', 1,
      'bill_no', 'ELEC-JAN-005', 'bill_date', '2026-01-19', 'remarks', 'pgTAP date-change-on-edit regression test'
    ),
    jsonb_build_array(
      jsonb_build_object('account_id', current_setting('pgtap.v_exp_acc')::uuid, 'amount', 50, 'tax_group_id', null, 'line_remarks', 'Original')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  -- Re-save the SAME draft with a different trans_date — this is the
  -- exact edit path that used to violate the FK.
  PERFORM fn_save_expense_voucher(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client')::uuid, 'company_id', current_setting('pgtap.v_company')::uuid,
      'location_id', current_setting('pgtap.v_loc')::uuid, 'trans_no', v_trans_no, 'trans_date', v_new_date,
      'supplier_id', current_setting('pgtap.v_supplier')::uuid, 'currency_id', current_setting('pgtap.v_usd_ccy_id')::uuid,
      'rate_to_base', 1, 'rate_to_local', 1,
      'bill_no', 'ELEC-JAN-005', 'bill_date', '2026-01-19', 'remarks', 'pgTAP date-change-on-edit regression test'
    ),
    jsonb_build_array(
      jsonb_build_object('account_id', current_setting('pgtap.v_exp_acc')::uuid, 'amount', 50, 'tax_group_id', null, 'line_remarks', 'Original')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_ev5', v_trans_no, false);
  PERFORM set_config('pgtap.v_ev5_newdate', v_new_date::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_date FROM rih_expense_voucher_headers WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ev5')) = current_setting('pgtap.v_ev5_newdate')::date
  AND
  EXISTS (SELECT 1 FROM rid_expense_voucher_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ev5') AND trans_date = current_setting('pgtap.v_ev5_newdate')::date)
  AND NOT EXISTS (SELECT 1 FROM rid_expense_voucher_lines WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND trans_no = current_setting('pgtap.v_ev5') AND trans_date = CURRENT_DATE),
  'ok 14 — REGRESSION: editing a DRAFT to a different trans_date succeeds with no FK violation, and its line correctly moved to the new date (not duplicated or orphaned under the old one)'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
