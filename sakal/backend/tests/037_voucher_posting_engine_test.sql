-- ============================================================
-- 037_voucher_posting_engine_test.sql — pgTAP tests for migration 037
--
-- Functions: fn_post_voucher (new),
--            fn_post_finance_voucher (amended: period check + posting_allowed check)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. All rows show "ok N — ..." with no "not ok" lines.
--   4. finish() returns no rows = all passed.
--
-- Hardcoded fixture UUIDs — no temp tables (Supabase auto-commits DO blocks).
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0037-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0037-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0037-000000000003';
  v_user_id     uuid := '00000000-0000-0000-0037-000000000004';
  v_stock_id    uuid := '00000000-0000-0000-0037-000000000005';  -- leaf, postable
  v_accrual_id  uuid := '00000000-0000-0000-0037-000000000006';  -- leaf, postable
  v_group_id    uuid := '00000000-0000-0000-0037-000000000007';  -- group node, NOT postable
  v_fy_id       uuid := '00000000-0000-0000-0037-000000000008';
  v_lock_id     uuid := '00000000-0000-0000-0037-000000000009';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST037', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST037 CO', 'USD', 'CDF', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test Loc', 'TL', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test037', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_stock_id,   v_client_id, v_company_id, '1300', 'Stock Account',    'General', 'OHADA', true,  true, false, now()),
    (v_accrual_id, v_client_id, v_company_id, '2200', 'Purchase Accrual', 'General', 'OHADA', true,  true, false, now()),
    (v_group_id,   v_client_id, v_company_id, '2000', 'Liabilities',      'General', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST037', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_period_locks (id, client_id, company_id, period_start_date, period_end_date, locked_by, is_active)
  VALUES (v_lock_id, v_client_id, v_company_id, '2026-01-01', '2026-01-31', v_user_id, true)
  ON CONFLICT (id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ── Plan ──────────────────────────────────────────────────────────────────────
SELECT plan(6);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section A: fn_post_voucher happy path + traceability
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_trans_no text;
BEGIN
  SELECT trans_no INTO v_trans_no FROM fn_post_voucher(
    '00000000-0000-0000-0037-000000000001', '00000000-0000-0000-0037-000000000002',
    '00000000-0000-0000-0037-000000000003', 'JV', '2026-06-01'::date,
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', '00000000-0000-0000-0037-000000000005',
        'trans_nature', 'DR', 'trans_amount', 100, 'trans_currency', 'USD',
        'base_amount', 100, 'base_rate', 1, 'local_amount', 100, 'local_rate', 1,
        'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1),
      jsonb_build_object('serial_no', 2, 'account_id', '00000000-0000-0000-0037-000000000006',
        'trans_nature', 'CR', 'trans_amount', 100, 'trans_currency', 'USD',
        'base_amount', 100, 'base_rate', 1, 'local_amount', 100, 'local_rate', 1,
        'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1)
    ),
    'GRN', 'GRN-TEST-037-1', '2026-06-01'::date,
    '00000000-0000-0000-0037-000000000004'
  );

  PERFORM set_config('pgtap.v_trans_no_037', v_trans_no, false);
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT is_posted FROM rih_finance_headers
   WHERE client_id = '00000000-0000-0000-0037-000000000001' AND source_doc_no = 'GRN-TEST-037-1') = true,
  'ok 1 — fn_post_voucher posts immediately, never leaves an AUTO voucher as draft'
);

SELECT ok(
  (SELECT posting_source FROM rih_finance_headers
   WHERE client_id = '00000000-0000-0000-0037-000000000001' AND source_doc_no = 'GRN-TEST-037-1') = 'AUTO'
  AND (SELECT source_doc_type FROM rih_finance_headers
       WHERE client_id = '00000000-0000-0000-0037-000000000001' AND source_doc_no = 'GRN-TEST-037-1') = 'GRN',
  'ok 2 — header is tagged posting_source=AUTO and traceable back to its GRN source doc'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section B: fn_post_voucher imbalance pre-check
-- ══════════════════════════════════════════════════════════════════════════════

SELECT throws_ok(
  $$ SELECT trans_no FROM fn_post_voucher(
       '00000000-0000-0000-0037-000000000001', '00000000-0000-0000-0037-000000000002',
       '00000000-0000-0000-0037-000000000003', 'JV', '2026-06-01'::date,
       jsonb_build_array(
         jsonb_build_object('serial_no', 1, 'account_id', '00000000-0000-0000-0037-000000000005',
           'trans_nature', 'DR', 'trans_amount', 100, 'trans_currency', 'USD',
           'base_amount', 100, 'base_rate', 1, 'local_amount', 100, 'local_rate', 1,
           'party_amount', 100, 'party_currency', 'USD', 'party_rate', 1),
         jsonb_build_object('serial_no', 2, 'account_id', '00000000-0000-0000-0037-000000000006',
           'trans_nature', 'CR', 'trans_amount', 50, 'trans_currency', 'USD',
           'base_amount', 50, 'base_rate', 1, 'local_amount', 50, 'local_rate', 1,
           'party_amount', 50, 'party_currency', 'USD', 'party_rate', 1)
       ),
       'GRN', 'GRN-TEST-037-BAD', '2026-06-01'::date,
       '00000000-0000-0000-0037-000000000004'
     ) $$,
  'VOUCHER_POSTING_IMBALANCE',
  'ok 3 — an unbalanced lines array is rejected before a draft is even created'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section C: fn_post_finance_voucher gap fixes (period lock + posting_allowed)
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0037-000000000001',
      'company_id', '00000000-0000-0000-0037-000000000002',
      'location_id', '00000000-0000-0000-0037-000000000003',
      'trans_no', NULL, 'trans_date', '2026-01-15',
      'voucher_type_code', 'JV', 'is_on_account', true
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', '00000000-0000-0000-0037-000000000005',
        'trans_nature', 'DR', 'trans_amount', 100, 'trans_currency', 'USD'),
      jsonb_build_object('serial_no', 2, 'account_id', '00000000-0000-0000-0037-000000000006',
        'trans_nature', 'CR', 'trans_amount', 100, 'trans_currency', 'USD')
    ),
    '00000000-0000-0000-0037-000000000004'
  );
  PERFORM set_config('pgtap.v_locked_trans_no_037', v_trans_no, false);
END;
$$ LANGUAGE plpgsql;

SELECT throws_ok(
  format(
    $$ SELECT fn_post_finance_voucher(
         '00000000-0000-0000-0037-000000000001'::uuid, '00000000-0000-0000-0037-000000000002'::uuid,
         '00000000-0000-0000-0037-000000000003'::uuid, %L, '2026-01-15'::date,
         '00000000-0000-0000-0037-000000000004'::uuid
       ) $$,
    current_setting('pgtap.v_locked_trans_no_037')
  ),
  'PERIOD_LOCKED',
  'ok 4 — posting a manually-entered voucher dated inside a locked period is now blocked (gap fix 1)'
);

DO $$
DECLARE
  v_trans_no text;
BEGIN
  v_trans_no := fn_save_finance_voucher(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0037-000000000001',
      'company_id', '00000000-0000-0000-0037-000000000002',
      'location_id', '00000000-0000-0000-0037-000000000003',
      'trans_no', NULL, 'trans_date', '2026-06-05',
      'voucher_type_code', 'JV', 'is_on_account', true
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'account_id', '00000000-0000-0000-0037-000000000007', -- group account
        'trans_nature', 'DR', 'trans_amount', 100, 'trans_currency', 'USD'),
      jsonb_build_object('serial_no', 2, 'account_id', '00000000-0000-0000-0037-000000000006',
        'trans_nature', 'CR', 'trans_amount', 100, 'trans_currency', 'USD')
    ),
    '00000000-0000-0000-0037-000000000004'
  );
  PERFORM set_config('pgtap.v_group_trans_no_037', v_trans_no, false);
END;
$$ LANGUAGE plpgsql;

SELECT throws_ok(
  format(
    $$ SELECT fn_post_finance_voucher(
         '00000000-0000-0000-0037-000000000001'::uuid, '00000000-0000-0000-0037-000000000002'::uuid,
         '00000000-0000-0000-0037-000000000003'::uuid, %L, '2026-06-05'::date,
         '00000000-0000-0000-0037-000000000004'::uuid
       ) $$,
    current_setting('pgtap.v_group_trans_no_037')
  ),
  'ACCOUNT_NOT_POSTABLE',
  'ok 5 — posting a line against a group (posting_allowed=false) account is now blocked (gap fix 2)'
);

SELECT ok(
  (SELECT count(*)::int FROM rih_finance_headers
   WHERE client_id = '00000000-0000-0000-0037-000000000001' AND posting_source = 'MANUAL') >= 1,
  'ok 6 — manually-entered vouchers (fn_save_finance_voucher directly) still default to posting_source=MANUAL'
);

SELECT * FROM finish();
ROLLBACK;
