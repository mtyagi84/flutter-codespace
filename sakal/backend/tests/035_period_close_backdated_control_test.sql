-- ============================================================
-- 035_period_close_backdated_control_test.sql — pgTAP tests for migration 035
--
-- Tables: ric_period_locks, ric_backdated_entry_control
-- Functions: fn_check_period_open, fn_check_backdate_allowed
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
  v_client_id  uuid := '00000000-0000-0000-0035-000000000001';
  v_company_id uuid := '00000000-0000-0000-0035-000000000002';
  v_user_id    uuid := '00000000-0000-0000-0035-000000000003';
  v_fy_open    uuid := '00000000-0000-0000-0035-000000000004';  -- 2026, active, not closed
  v_fy_closed  uuid := '00000000-0000-0000-0035-000000000005';  -- 2025, closed
  v_lock_jan   uuid := '00000000-0000-0000-0035-000000000006';  -- 2026-01-01..2026-01-31 locked
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST035', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST035 CO', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test035', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Financial years: 2025 closed, 2026 open/active
  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_closed, v_client_id, v_company_id, 'FY 2025', '2025-01-01', '2025-12-31', false, true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_open, v_client_id, v_company_id, 'FY 2026', '2026-01-01', '2026-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- Period lock: January 2026 locked (GST filed)
  INSERT INTO ric_period_locks (id, client_id, company_id, period_start_date, period_end_date, locked_by, is_active)
  VALUES (v_lock_jan, v_client_id, v_company_id, '2026-01-01', '2026-01-31', v_user_id, true)
  ON CONFLICT (id) DO NOTHING;

  -- Backdated entry control: GRN allows up to 7 days back, no future dates
  INSERT INTO ric_backdated_entry_control (client_id, company_id, transaction_type, max_backdate_days, allow_future_date)
  VALUES (v_client_id, v_company_id, 'GRN', 7, false)
  ON CONFLICT (client_id, company_id, transaction_type) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ── Plan ──────────────────────────────────────────────────────────────────────
SELECT plan(9);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section A: fn_check_period_open
-- ══════════════════════════════════════════════════════════════════════════════

SELECT throws_ok(
  $$ SELECT fn_check_period_open('00000000-0000-0000-0035-000000000002', '2026-01-15') $$,
  'PERIOD_LOCKED',
  'ok 1 — date inside locked January 2026 raises PERIOD_LOCKED'
);

SELECT lives_ok(
  $$ SELECT fn_check_period_open('00000000-0000-0000-0035-000000000002', '2026-02-15') $$,
  'ok 2 — date in open FY, outside any lock, passes cleanly'
);

SELECT throws_ok(
  $$ SELECT fn_check_period_open('00000000-0000-0000-0035-000000000002', '2025-06-15') $$,
  'FY_CLOSED',
  'ok 3 — date inside the closed FY 2025 raises FY_CLOSED'
);

SELECT throws_ok(
  $$ SELECT fn_check_period_open('00000000-0000-0000-0035-000000000002', '2027-06-15') $$,
  'FY_CLOSED',
  'ok 4 — date outside every financial year raises FY_CLOSED'
);

SELECT lives_ok(
  $$ SELECT fn_check_period_open('00000000-0000-0000-0035-000000000002', '2026-12-31') $$,
  'ok 5 — last day of open FY, outside lock, passes cleanly'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section B: fn_check_backdate_allowed
-- ══════════════════════════════════════════════════════════════════════════════

SELECT lives_ok(
  $$ SELECT fn_check_backdate_allowed('00000000-0000-0000-0035-000000000001','00000000-0000-0000-0035-000000000002','GRN', current_date - 3) $$,
  'ok 6 — GRN dated 3 days back is within the configured 7-day window'
);

SELECT throws_ok(
  $$ SELECT fn_check_backdate_allowed('00000000-0000-0000-0035-000000000001','00000000-0000-0000-0035-000000000002','GRN', current_date - 10) $$,
  'BACKDATE_NOT_ALLOWED',
  'ok 7 — GRN dated 10 days back exceeds the 7-day window'
);

SELECT throws_ok(
  $$ SELECT fn_check_backdate_allowed('00000000-0000-0000-0035-000000000001','00000000-0000-0000-0035-000000000002','GRN', current_date + 1) $$,
  'FUTURE_DATE_NOT_ALLOWED',
  'ok 8 — GRN dated tomorrow is rejected (allow_future_date = false)'
);

SELECT lives_ok(
  $$ SELECT fn_check_backdate_allowed('00000000-0000-0000-0035-000000000001','00000000-0000-0000-0035-000000000002','SALES_INVOICE', current_date - 400) $$,
  'ok 9 — no control row for SALES_INVOICE means unlimited backdating (opt-in control, not opt-out)'
);

SELECT * FROM finish();
ROLLBACK;
