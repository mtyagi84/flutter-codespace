-- ============================================================
-- Migration 234: Cheque Register — correct migration 233's overreach
-- ============================================================
-- Migration 233 fixed DAY_BOOK_REGISTER and CHEQUE_REGISTER identically
-- (param_target 'trans_date' -> 'date'), assuming both reports' broken
-- RPC call shared the same root cause. Re-verified live immediately
-- after deploying 233 (never assume a fix worked without re-checking,
-- per this project's own established discipline) and found this was
-- WRONG for Cheque Register specifically: it broke a previously-working
-- report. Root cause is actually DIFFERENT between the two:
--
-- - DAY_BOOK_REGISTER has a `ric_report_group_levels` row (level 1,
--   group_by_column='trans_no') registering `fn_day_book_group_summary`
--   as its GROUPED-mode summary source — the Flutter reporting engine
--   uses this RPC for the report's own MAIN grid query (not just
--   totals), so `param_target` genuinely needs to match the RPC's own
--   `p_date_from`/`p_date_to` parameter names. 233's fix was correct
--   here.
-- - CHEQUE_REGISTER has NO group-level config at all — a plain TABULAR
--   report whose main grid queries the `v_cheque_register` VIEW directly
--   via PostgREST column filters (`trans_date=gte...`), where
--   `param_target` must match the VIEW's own column name (`trans_date`,
--   confirmed via information_schema). 233's change to `'date'` broke
--   this main query (verified live: HTTP 400, "date" is not a column on
--   `v_cheque_register`). The ACTUAL bug for this report is narrower:
--   only `fn_cheque_register_totals` (used for the footer Total row, a
--   separate RPC call) was ever genuinely broken, declaring
--   `p_date_from`/`p_date_to` instead of `p_trans_date_from`/
--   `p_trans_date_to` to match its own report's `param_target`.
--
-- Fix: (1) revert CHEQUE_REGISTER's `param_target` back to
-- 'trans_date'; (2) rename `fn_cheque_register_totals`'s own IN
-- parameters to match (CREATE OR REPLACE is sufficient — renaming an IN
-- parameter, unlike a RETURNS TABLE out-parameter, does not change the
-- function's signature/overload identity, so no DROP FUNCTION needed).
-- Full body reproduced verbatim from migration 166.
--
-- Lesson for next time: when two reports look superficially identical
-- (same filter_key, same old param_target value), check each one's own
-- `ric_report_group_levels` presence/absence before assuming they share
-- a fix — a GROUPED report's main query path and a plain TABULAR
-- report's main query path read `param_target` completely differently.
-- ============================================================

UPDATE ric_report_filters
SET param_target = 'trans_date'
WHERE filter_key = 'date_range'
  AND param_target = 'date'
  AND report_id IN (
    SELECT id FROM ric_report_definitions WHERE report_key = 'CHEQUE_REGISTER'
  );

DROP FUNCTION IF EXISTS fn_cheque_register_totals(UUID, UUID, DATE, DATE, TEXT, UUID);

CREATE OR REPLACE FUNCTION fn_cheque_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_trans_date_from DATE DEFAULT NULL,
    p_trans_date_to   DATE DEFAULT NULL,
    p_voucher_type_code TEXT DEFAULT NULL,
    p_location_id UUID DEFAULT NULL
) RETURNS TABLE (trans_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(trans_amount), 0), COUNT(*)
    FROM v_cheque_register
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_voucher_type_code IS NULL OR voucher_type_code = p_voucher_type_code)
      AND (p_location_id IS NULL OR location_id = p_location_id);
$$;

GRANT EXECUTE ON FUNCTION fn_cheque_register_totals(
    UUID, UUID, DATE, DATE, TEXT, UUID) TO authenticated;
