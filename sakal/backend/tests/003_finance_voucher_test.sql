-- ============================================================
-- 003_finance_voucher_test.sql — pgTAP tests for finance voucher functions
--
-- Functions tested:
--   fn_next_trans_no
--   fn_save_finance_voucher    (new, update, blocked-when-posted)
--   fn_post_finance_voucher    (happy path, cheque, bill settlement, imbalance guard)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste this entire file and run.
--   3. All pass → "Success. No rows returned".
--      Any fail → red error with "not ok N" detail.
--
-- Transaction is rolled back — no permanent data changes.
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0000-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0000-000000000010';
  v_user_id     uuid := '00000000-0000-0000-0000-000000000003';
  v_cash_id     uuid := '11111111-0000-0000-0000-000000000001';
  v_bank_id     uuid := '11111111-0000-0000-0000-000000000004';
  v_debtor_id   uuid := '11111111-0000-0000-0000-000000000002';
  v_supplier_id uuid := '11111111-0000-0000-0000-000000000003';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST CLIENT', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency,
                              is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST COMPANY', 'USD', 'CDF', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short,
                              is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Head Office', 'HO', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name,
                         password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test_user', 'Test User',
          'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- accounting_std is NOT NULL (added after this fixture was first written)
  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name,
                             account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_cash_id,     v_client_id, v_company_id, '1001', 'Petty Cash',     'Cash',     'OHADA', true, true, false, now()),
    (v_bank_id,     v_client_id, v_company_id, '1100', 'HDFC Bank',      'Bank',     'OHADA', true, true, false, now()),
    (v_debtor_id,   v_client_id, v_company_id, '4001', 'Customer Alpha', 'Customer', 'OHADA', true, true, false, now()),
    (v_supplier_id, v_client_id, v_company_id, '5001', 'Supplier Beta',  'Supplier', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;
END;
$$;

-- ── Tests ─────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v            text;
  all_results  text := '';

  v_client_id   uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0000-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0000-000000000010';
  v_user_id     uuid := '00000000-0000-0000-0000-000000000003';
  v_cash_id     uuid := '11111111-0000-0000-0000-000000000001';
  v_bank_id     uuid := '11111111-0000-0000-0000-000000000004';
  v_debtor_id   uuid := '11111111-0000-0000-0000-000000000002';
  v_supplier_id uuid := '11111111-0000-0000-0000-000000000003';

  v_trans_no    text;
  v_trans_no2   text;
  v_trans_no3   text;
  v_header      jsonb;
  v_lines       jsonb;
  v_is_posted   boolean;
  v_cheque_cnt  integer;
  v_settle_cnt  integer;

  -- Dates for composite key
  d1 constant date := '2026-06-01';
  d2 constant date := '2026-06-02';
  d3 constant date := '2026-06-03';
  d4 constant date := '2026-06-04';
BEGIN
  PERFORM plan(14);

  -- ──────────────────────────────────────────────────────────────────────────
  -- 1. fn_next_trans_no returns a non-null value for CRV
  -- ──────────────────────────────────────────────────────────────────────────
  v_trans_no := fn_next_trans_no(v_client_id, v_company_id, v_loc_id, 'CRV');
  v := isnt(v_trans_no, NULL, 'fn_next_trans_no returns a non-null trans_no for CRV');
  all_results := all_results || v || E'\n';

  -- 2. Trans_no contains the voucher type code
  v := ok(v_trans_no LIKE '%CRV%', 'trans_no embeds the voucher type code CRV');
  all_results := all_results || v || E'\n';

  -- 3. Sequential call returns a different number
  v_trans_no2 := fn_next_trans_no(v_client_id, v_company_id, v_loc_id, 'CRV');
  v := isnt(v_trans_no2, v_trans_no, 'Second fn_next_trans_no call produces a different number');
  all_results := all_results || v || E'\n';

  -- 4. Unknown voucher type raises exception
  v := throws_ok(
    format($q$ SELECT fn_next_trans_no(%L::uuid, %L::uuid, %L::uuid, 'XYZZY') $q$,
           v_client_id, v_company_id, v_loc_id),
    'P0001', NULL,
    'fn_next_trans_no raises exception for unknown voucher type');
  all_results := all_results || v || E'\n';

  -- ──────────────────────────────────────────────────────────────────────────
  -- 5-7. fn_save_finance_voucher — new Cash Receipt, On Account
  -- ──────────────────────────────────────────────────────────────────────────
  v_header := jsonb_build_object(
    'client_id',         v_client_id,
    'company_id',        v_company_id,
    'location_id',       v_loc_id,
    'trans_no',          '',
    'trans_date',        d1,
    'voucher_type_code', 'CRV',
    'payment_mode_code', 'CASH',
    'is_on_account',     true,
    'reference_no',      '',
    'reference_date',    '',
    'cheque_no',         '',
    'cheque_date',       '',
    'remarks',           'Test receipt'
  );
  v_lines := jsonb_build_array(
    jsonb_build_object(
      'serial_no', 1, 'account_id', v_cash_id,
      'trans_nature', 'DR', 'trans_amount', 1000, 'trans_currency', 'USD',
      'base_amount', 1000, 'base_rate', 1,
      'local_amount', 2800000, 'local_rate', 2800,
      'party_amount', 1000, 'party_currency', 'USD', 'party_rate', 1,
      'inv_bill_no', '', 'inv_bill_date', '', 'line_remarks', ''
    ),
    jsonb_build_object(
      'serial_no', 2, 'account_id', v_debtor_id,
      'trans_nature', 'CR', 'trans_amount', 1000, 'trans_currency', 'USD',
      'base_amount', 1000, 'base_rate', 1,
      'local_amount', 2800000, 'local_rate', 2800,
      'party_amount', 1000, 'party_currency', 'USD', 'party_rate', 1,
      'inv_bill_no', '', 'inv_bill_date', '', 'line_remarks', 'Received'
    )
  );

  v_trans_no := fn_save_finance_voucher(v_header, v_lines, v_user_id);

  -- 5. Returns a trans_no
  v := isnt(v_trans_no, NULL, 'fn_save_finance_voucher returns trans_no on new save');
  all_results := all_results || v || E'\n';

  -- 6. Header row exists
  v := ok(
    EXISTS(SELECT 1 FROM rih_finance_headers
           WHERE trans_no = v_trans_no AND company_id = v_company_id),
    'Header row inserted in rih_finance_headers');
  all_results := all_results || v || E'\n';

  -- 7. Two lines inserted
  v := is(
    (SELECT COUNT(*)::integer FROM rid_finance_lines
      WHERE trans_no = v_trans_no AND company_id = v_company_id),
    2,
    'Two lines inserted for the new voucher');
  all_results := all_results || v || E'\n';

  -- ──────────────────────────────────────────────────────────────────────────
  -- 8. fn_save_finance_voucher — update draft (same trans_no)
  -- ──────────────────────────────────────────────────────────────────────────
  v_header := v_header
    || jsonb_build_object('trans_no', v_trans_no, 'remarks', 'Updated remark');
  PERFORM fn_save_finance_voucher(v_header, v_lines, v_user_id);

  v := is(
    (SELECT remarks FROM rih_finance_headers
      WHERE trans_no = v_trans_no AND company_id = v_company_id),
    'Updated remark',
    'fn_save_finance_voucher updates remarks on draft re-save');
  all_results := all_results || v || E'\n';

  -- ──────────────────────────────────────────────────────────────────────────
  -- 9-11. fn_post_finance_voucher — happy path, guard against re-post/re-save
  -- ──────────────────────────────────────────────────────────────────────────
  PERFORM fn_post_finance_voucher(
    v_client_id, v_company_id, v_loc_id, v_trans_no, d1, v_user_id
  );

  -- 9. is_posted = true after post
  SELECT is_posted INTO v_is_posted FROM rih_finance_headers
  WHERE trans_no = v_trans_no AND company_id = v_company_id;
  v := ok(v_is_posted, 'fn_post_finance_voucher sets is_posted = true');
  all_results := all_results || v || E'\n';

  -- 10. Saving a posted voucher raises exception
  v := throws_ok(
    format($q$
      SELECT fn_save_finance_voucher(
        jsonb_build_object(
          'client_id',         %L::uuid,
          'company_id',        %L::uuid,
          'location_id',       %L::uuid,
          'trans_no',          %L,
          'trans_date',        '2026-06-01',
          'voucher_type_code', 'CRV',
          'payment_mode_code', 'CASH',
          'is_on_account',     true,
          'reference_no', '', 'reference_date', '',
          'cheque_no',    '', 'cheque_date',    '',
          'remarks',      ''
        ),
        %L::jsonb,
        %L::uuid)
    $q$, v_client_id, v_company_id, v_loc_id, v_trans_no,
         v_lines::text, v_user_id),
    'P0001', NULL,
    'Saving an already-posted voucher raises exception');
  all_results := all_results || v || E'\n';

  -- 11. Posting an already-posted voucher raises exception
  v := throws_ok(
    format($q$
      SELECT fn_post_finance_voucher(
        %L::uuid, %L::uuid, %L::uuid, %L, '2026-06-01'::date, %L::uuid)
    $q$, v_client_id, v_company_id, v_loc_id, v_trans_no, v_user_id),
    'P0001', NULL,
    'Posting an already-posted voucher raises exception');
  all_results := all_results || v || E'\n';

  -- ──────────────────────────────────────────────────────────────────────────
  -- 12. Cheque register row created when payment_mode = CHEQUE
  -- ──────────────────────────────────────────────────────────────────────────
  v_header := jsonb_build_object(
    'client_id',         v_client_id,
    'company_id',        v_company_id,
    'location_id',       v_loc_id,
    'trans_no',          '',
    'trans_date',        d2,
    'voucher_type_code', 'BPV',
    'payment_mode_code', 'CHEQUE',
    'is_on_account',     true,
    'reference_no',      '',
    'reference_date',    '',
    'cheque_no',         'CHQ-99001',
    'cheque_date',       d2::text,
    'remarks',           ''
  );
  v_lines := jsonb_build_array(
    jsonb_build_object(
      'serial_no', 1, 'account_id', v_bank_id,
      'trans_nature', 'CR', 'trans_amount', 500, 'trans_currency', 'USD',
      'base_amount', 500, 'base_rate', 1,
      'local_amount', 1400000, 'local_rate', 2800,
      'party_amount', 500, 'party_currency', 'USD', 'party_rate', 1,
      'inv_bill_no', '', 'inv_bill_date', '', 'line_remarks', ''
    ),
    jsonb_build_object(
      'serial_no', 2, 'account_id', v_supplier_id,
      'trans_nature', 'DR', 'trans_amount', 500, 'trans_currency', 'USD',
      'base_amount', 500, 'base_rate', 1,
      'local_amount', 1400000, 'local_rate', 2800,
      'party_amount', 500, 'party_currency', 'USD', 'party_rate', 1,
      'inv_bill_no', '', 'inv_bill_date', '', 'line_remarks', ''
    )
  );
  v_trans_no2 := fn_save_finance_voucher(v_header, v_lines, v_user_id);
  PERFORM fn_post_finance_voucher(
    v_client_id, v_company_id, v_loc_id, v_trans_no2, d2, v_user_id
  );

  SELECT COUNT(*)::integer INTO v_cheque_cnt
  FROM rid_cheque_register
  WHERE trans_no = v_trans_no2 AND company_id = v_company_id;

  v := is(v_cheque_cnt, 1, 'Cheque register row created when cheque_no is set');
  all_results := all_results || v || E'\n';

  -- ──────────────────────────────────────────────────────────────────────────
  -- 13. Against Bill: settlement row created on post
  -- ──────────────────────────────────────────────────────────────────────────
  v_header := jsonb_build_object(
    'client_id',         v_client_id,
    'company_id',        v_company_id,
    'location_id',       v_loc_id,
    'trans_no',          '',
    'trans_date',        d3,
    'voucher_type_code', 'CRV',
    'payment_mode_code', 'CASH',
    'is_on_account',     false,
    'reference_no',      'INV-001',
    'reference_date',    '',
    'cheque_no',         '',
    'cheque_date',       '',
    'remarks',           ''
  );
  v_lines := jsonb_build_array(
    jsonb_build_object(
      'serial_no', 1, 'account_id', v_cash_id,
      'trans_nature', 'DR', 'trans_amount', 750, 'trans_currency', 'USD',
      'base_amount', 750, 'base_rate', 1,
      'local_amount', 2100000, 'local_rate', 2800,
      'party_amount', 750, 'party_currency', 'USD', 'party_rate', 1,
      'inv_bill_no', '', 'inv_bill_date', '', 'line_remarks', ''
    ),
    jsonb_build_object(
      'serial_no', 2, 'account_id', v_debtor_id,
      'trans_nature', 'CR', 'trans_amount', 750, 'trans_currency', 'USD',
      'base_amount', 750, 'base_rate', 1,
      'local_amount', 2100000, 'local_rate', 2800,
      'party_amount', 750, 'party_currency', 'USD', 'party_rate', 1,
      'inv_bill_no', 'SIV/HO/2026/00001',
      'inv_bill_date', '2026-05-01',
      'line_remarks', ''
    )
  );
  v_trans_no3 := fn_save_finance_voucher(v_header, v_lines, v_user_id);
  PERFORM fn_post_finance_voucher(
    v_client_id, v_company_id, v_loc_id, v_trans_no3, d3, v_user_id
  );

  SELECT COUNT(*)::integer INTO v_settle_cnt
  FROM rid_invoice_bill_settlement
  WHERE trans_no = v_trans_no3 AND company_id = v_company_id;

  v := is(v_settle_cnt, 1, 'Settlement row created for Against Bill voucher on post');
  all_results := all_results || v || E'\n';

  -- ──────────────────────────────────────────────────────────────────────────
  -- 14. Imbalanced voucher raises exception on post
  -- ──────────────────────────────────────────────────────────────────────────
  DECLARE
    v_imbal_no text;
  BEGIN
    v_header := jsonb_build_object(
      'client_id', v_client_id, 'company_id', v_company_id,
      'location_id', v_loc_id, 'trans_no', '',
      'trans_date', d4,
      'voucher_type_code', 'CRV', 'payment_mode_code', 'CASH',
      'is_on_account', true,
      'reference_no', '', 'reference_date', '',
      'cheque_no', '', 'cheque_date', '', 'remarks', ''
    );
    v_lines := jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'account_id', v_cash_id,
        'trans_nature', 'DR', 'trans_amount', 100, 'trans_currency', 'USD',
        'base_amount', 100, 'base_rate', 1,
        'local_amount', 280000, 'local_rate', 2800,
        'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1,
        'inv_bill_no', '', 'inv_bill_date', '', 'line_remarks', ''
      ),
      jsonb_build_object(
        'serial_no', 2, 'account_id', v_debtor_id,
        'trans_nature', 'CR', 'trans_amount', 200, 'trans_currency', 'USD',  -- intentional mismatch
        'base_amount', 200, 'base_rate', 1,
        'local_amount', 560000, 'local_rate', 2800,
        'party_amount', 200, 'party_currency', 'USD', 'party_rate', 1,
        'inv_bill_no', '', 'inv_bill_date', '', 'line_remarks', ''
      )
    );
    v_imbal_no := fn_save_finance_voucher(v_header, v_lines, v_user_id);

    v := throws_ok(
      format($q$
        SELECT fn_post_finance_voucher(
          %L::uuid, %L::uuid, %L::uuid, %L, '2026-06-04'::date, %L::uuid)
      $q$, v_client_id, v_company_id, v_loc_id, v_imbal_no, v_user_id),
      'P0001', NULL,
      'fn_post_finance_voucher raises exception when DR ≠ CR (imbalanced voucher)');
    all_results := all_results || v || E'\n';
  END;

  -- ── Finish ────────────────────────────────────────────────────────────────
  FOR v IN SELECT * FROM finish() LOOP
    all_results := all_results || v || E'\n';
  END LOOP;

  IF all_results LIKE '%not ok%' THEN
    RAISE EXCEPTION E'TESTS FAILED — see detail below:\n\n%', all_results;
  END IF;
END;
$$;

ROLLBACK;
