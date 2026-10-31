-- ============================================================
-- Migration 233: Day Book / Cheque Register — date-range filter
-- param_target mismatch fix
-- ============================================================
-- Found live during the 2026-10-25 browser-E2E pass: both reports'
-- `date_range` filter row has `param_target='trans_date'`, which the
-- generic reporting engine (report_repository.dart, line ~300-301)
-- turns into RPC params `p_trans_date_from`/`p_trans_date_to`. But
-- `fn_day_book_totals`, `fn_day_book_group_summary` (migration 166) and
-- `fn_cheque_register_totals` (migration 166) all actually declare
-- `p_date_from`/`p_date_to` — a straight copy-paste of
-- PENDING_BILLS_REGISTER's own filter config (whose
-- `fn_pending_bills_totals` genuinely DOES use `p_trans_date_from`/
-- `p_trans_date_to`) without checking that these two reports' own
-- functions use a different parameter-name convention. PostgREST
-- returns a plain 404 for an RPC call whose named parameters don't
-- match any overload — confirmed live via a direct network-request
-- trace, not assumed from the symptom alone (this exact failure shape
-- is also documented as a possible PostgREST-schema-cache issue in
-- project memory `feedback_supabase_fn_deployment.md`; that angle was
-- ruled out here first — EXECUTE privilege checks out, `NOTIFY pgrst,
-- 'reload schema'` made no difference, and the actual request URL shows
-- the wrong parameter NAME, not an unrecognized function).
--
-- Fix: correct the filter's own `param_target` to match the convention
-- already used correctly everywhere else (ACCOUNT_LEDGER, CASH_FLOW_*,
-- PROFIT_LOSS_*, FINANCIAL_RATIO_ANALYSIS all use `param_target='date'`
-- paired with `p_date_from`/`p_date_to` functions) — never touch a
-- shared backend function's parameter names for a one-report config bug.
-- ============================================================

UPDATE ric_report_filters
SET param_target = 'date'
WHERE filter_key = 'date_range'
  AND param_target = 'trans_date'
  AND report_id IN (
    SELECT id FROM ric_report_definitions
    WHERE report_key IN ('DAY_BOOK_REGISTER', 'CHEQUE_REGISTER')
  );
