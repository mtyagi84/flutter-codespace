-- ============================================================
-- Migration 142: fix fn_expense_report_matrix_base/_local parameter
-- names — PostgREST "no matches were found in the schema cache"
-- ============================================================
-- 141_expense_report_matrix.sql's date_range filter uses
-- param_target='trans_date' (matching the established convention from
-- 118/140), which makes ReportRepository._buildFilterParams synthesize
-- p_trans_date_from/p_trans_date_to as the RPC argument names for a
-- FUNCTION source. The two functions themselves were declared with
-- p_date_from/p_date_to instead — a naming mismatch, not a migration
-- script error (CREATE FUNCTION succeeded fine; the failure only shows
-- up when Flutter actually calls the RPC with argument names that don't
-- match any parameter on the function). Caught live by the user running
-- the report.
--
-- CREATE OR REPLACE FUNCTION with the SAME type signature (UUID, UUID,
-- DATE, DATE, BOOLEAN, UUID) but different parameter NAMES is safe here
-- — parameter names aren't part of Postgres's overload-resolution
-- signature (only types are), so this is a plain rename, not the
-- RETURNS-TABLE-shape or new-parameter overload gotcha documented
-- elsewhere in this project's own conventions.
--
-- Fixed at the source in 141_expense_report_matrix.sql's own file too
-- (won't re-apply itself, per this project's "editing a run migration
-- does nothing" rule) — this migration is what actually fixes the live
-- database.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_expense_report_matrix_base(
    p_client_id  UUID,
    p_company_id UUID,
    p_trans_date_from DATE,
    p_trans_date_to   DATE,
    p_posted_only BOOLEAN DEFAULT true,
    p_group_id    UUID DEFAULT NULL
) RETURNS TABLE (
    group_name   TEXT,
    account_name TEXT,
    month_label  TEXT,
    net_amount   NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(p.account_name, a.account_name) AS group_name,
        '[' || a.account_code || '] ' || a.account_name AS account_name,
        to_char(date_trunc('month', h.trans_date), 'YYYY-MM') AS month_label,
        SUM(CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END) AS net_amount
    FROM rid_finance_lines l
    JOIN rih_finance_headers h
        ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
        AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
        AND h.trans_date  = l.trans_date
    JOIN v_expense_accounts ea ON ea.account_id = l.account_id AND ea.client_id = l.client_id AND ea.company_id = l.company_id
    JOIN rim_accounts a ON a.id = l.account_id
    LEFT JOIN rim_accounts p ON p.id = a.parent_id AND p.client_id = a.client_id AND p.company_id = a.company_id
    WHERE l.client_id = p_client_id AND l.company_id = p_company_id
      AND h.trans_date BETWEEN p_trans_date_from AND p_trans_date_to
      AND (NOT p_posted_only OR h.is_posted = true)
      AND h.is_deleted = false AND l.is_deleted = false
      AND (p_group_id IS NULL OR a.parent_id = p_group_id)
      AND (
          NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                      WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                        AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                        AND ula.is_active = true AND ula.is_deleted = false)
          OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                  AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                  AND ula.is_active = true AND ula.is_deleted = false)
      )
    GROUP BY p.account_name, a.account_name, a.account_code, date_trunc('month', h.trans_date)
    HAVING SUM(CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END) <> 0;
$$;

GRANT EXECUTE ON FUNCTION fn_expense_report_matrix_base(UUID, UUID, DATE, DATE, BOOLEAN, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_expense_report_matrix_local(
    p_client_id  UUID,
    p_company_id UUID,
    p_trans_date_from DATE,
    p_trans_date_to   DATE,
    p_posted_only BOOLEAN DEFAULT true,
    p_group_id    UUID DEFAULT NULL
) RETURNS TABLE (
    group_name   TEXT,
    account_name TEXT,
    month_label  TEXT,
    net_amount   NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(p.account_name, a.account_name) AS group_name,
        '[' || a.account_code || '] ' || a.account_name AS account_name,
        to_char(date_trunc('month', h.trans_date), 'YYYY-MM') AS month_label,
        SUM(CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END) AS net_amount
    FROM rid_finance_lines l
    JOIN rih_finance_headers h
        ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
        AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
        AND h.trans_date  = l.trans_date
    JOIN v_expense_accounts ea ON ea.account_id = l.account_id AND ea.client_id = l.client_id AND ea.company_id = l.company_id
    JOIN rim_accounts a ON a.id = l.account_id
    LEFT JOIN rim_accounts p ON p.id = a.parent_id AND p.client_id = a.client_id AND p.company_id = a.company_id
    WHERE l.client_id = p_client_id AND l.company_id = p_company_id
      AND h.trans_date BETWEEN p_trans_date_from AND p_trans_date_to
      AND (NOT p_posted_only OR h.is_posted = true)
      AND h.is_deleted = false AND l.is_deleted = false
      AND (p_group_id IS NULL OR a.parent_id = p_group_id)
      AND (
          NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                      WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                        AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                        AND ula.is_active = true AND ula.is_deleted = false)
          OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                  AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                  AND ula.is_active = true AND ula.is_deleted = false)
      )
    GROUP BY p.account_name, a.account_name, a.account_code, date_trunc('month', h.trans_date)
    HAVING SUM(CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END) <> 0;
$$;

GRANT EXECUTE ON FUNCTION fn_expense_report_matrix_local(UUID, UUID, DATE, DATE, BOOLEAN, UUID) TO authenticated;
