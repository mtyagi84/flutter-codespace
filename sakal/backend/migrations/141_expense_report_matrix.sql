-- ============================================================
-- Migration 141: Month-wise Expense Report (MATRIX) — Finance
-- ============================================================
-- User spec: one dynamic column per calendar month in the selected date
-- range, net Debit-Credit for that account that month, rows labeled by
-- Group Name (immediate parent) + Account Name, a Total Expense row
-- total. Built on the Reporting Engine's existing MATRIX mechanism
-- (Stock Balance by Location, migration 118) — dynamic columns are
-- already a solved, generic, client-side pivot
-- (lib/core/reporting/report_matrix_pivot.dart), so this is purely a
-- migration, no new Flutter rendering code.
--
-- The hard question this migration had to resolve: rim_accounts has no
-- account_nature='Expense' value. Expense accounts are descendants of a
-- seeded root account, and the two accounting standards this app
-- supports (rim_accounts.accounting_std) use DIFFERENT root codes:
--   INDIAN root: ('5000', 'Expense')
--   OHADA  root: ('6000', 'Class 6 - Expenses')
-- (confirmed by reading both seed blocks in 013_chart_of_accounts.sql —
-- neither a fixed account_code LIKE '5%' nor a fixed '5000' check works
-- for both). v_expense_accounts below walks each leaf account to its
-- root ancestor via a recursive CTE and classifies it by whichever
-- standard-specific root code actually matches. Deliberately scoped to
-- "is this an expense account" only — not a general 5-way financial
-- statement classifier, since OHADA's own class structure (Treasury and
-- Cost Accounting as separate top-level classes) doesn't map cleanly
-- onto Asset/Liability/Equity/Income/Expense the way INDIAN's does; a
-- future P&L/Balance Sheet report should make its own classification
-- call using this same recursive-walk-to-root technique, not inherit a
-- guess made here.
-- ============================================================

-- ------------------------------------------------------------
-- Generic capability: cap a report's own DATE_RANGE filter span,
-- enforced client-side in sakal_report_screen.dart's onApply BEFORE the
-- report ever fetches — needed because this report's column count is
-- driven directly by the date range (one column per month). NULL (every
-- report before this one) means no limit. Registry-driven so a future
-- report opts in via its own migration, no Flutter change needed.
-- ------------------------------------------------------------
ALTER TABLE ric_report_definitions
    ADD COLUMN IF NOT EXISTS max_date_range_months INTEGER;


-- ------------------------------------------------------------
-- v_expense_accounts — global (not per-company), reusable.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_expense_accounts AS
WITH RECURSIVE ancestry AS (
    SELECT id AS leaf_id, id, parent_id, account_code, accounting_std, client_id, company_id
    FROM rim_accounts
    WHERE is_deleted = false
    UNION ALL
    SELECT anc.leaf_id, p.id, p.parent_id, p.account_code, p.accounting_std, p.client_id, p.company_id
    FROM rim_accounts p
    JOIN ancestry anc ON p.id = anc.parent_id
)
SELECT DISTINCT client_id, company_id, leaf_id AS account_id
FROM ancestry
WHERE parent_id IS NULL
  AND ((accounting_std = 'INDIAN' AND account_code = '5000')
    OR (accounting_std = 'OHADA'  AND account_code = '6000'));

GRANT SELECT ON v_expense_accounts TO authenticated;

-- Group Name filter lookup — parent accounts with >=1 expense-account
-- child, mirrors v_party_account_groups_lookup's own shape (137).
CREATE OR REPLACE VIEW v_expense_account_groups_lookup AS
SELECT DISTINCT p.id, p.client_id, p.company_id, p.account_name AS group_name
FROM rim_accounts p
JOIN rim_accounts c
    ON  c.parent_id  = p.id
    AND c.client_id  = p.client_id
    AND c.company_id = p.company_id
JOIN v_expense_accounts ea ON ea.account_id = c.id AND ea.client_id = c.client_id AND ea.company_id = c.company_id
WHERE c.is_deleted = false AND p.is_deleted = false;

GRANT SELECT ON v_expense_account_groups_lookup TO authenticated;


-- ------------------------------------------------------------
-- fn_expense_report_matrix_base / _local — MATRIX source functions.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_expense_report_matrix_base(
    p_client_id  UUID,
    p_company_id UUID,
    p_trans_date_from  DATE,
    p_trans_date_to    DATE,
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
    p_trans_date_from  DATE,
    p_trans_date_to    DATE,
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


-- ============================================================
-- Registry — per company.
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_fn_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_fn_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'FN';

        CONTINUE WHEN v_fn_module_id IS NULL;

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             source_object_local, max_date_range_months)
        VALUES
            (v_company.client_id, v_company.company_id, 'EXPENSE_REPORT_MATRIX', 'Expense Report',
             'MATRIX', 'FUNCTION', 'fn_expense_report_matrix_base', 'FN', 'group_name', 'ASC', 5000,
             'fn_expense_report_matrix_local', 12)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object = excluded.source_object,
                source_object_local = excluded.source_object_local,
                max_date_range_months = excluded.max_date_range_months
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, is_pivot_row_group, is_pivot_dimension, is_pivot_measure)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'group_name',   'Group Name',   'TEXT',   'LEFT',  false, true, 160, 1, true,  false, false),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Account Name', 'TEXT',   'LEFT',  false, true, 220, 2, true,  false, false),
            (v_company.client_id, v_company.company_id, v_report_id, 'month_label',  'Month',        'TEXT',   'RIGHT', false, true, 120, 3, false, true,  false),
            (v_company.client_id, v_company.company_id, v_report_id, 'net_amount',   'Amount',       'NUMBER', 'RIGHT', false, true, 120, 4, false, false, true);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Trans Date', 'DATE_RANGE',
                NULL, NULL, 'trans_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_only', 'Posted Only', 'BOOLEAN',
                NULL, NULL, 'posted_only', false, 'true', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'group_id', 'Group Name', 'DROPDOWN_LOOKUP',
                'v_expense_account_groups_lookup', 'group_name', 'group_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-EXR', 'Expense Report',
             '/reports/EXPENSE_REPORT_MATRIX', 10, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill — same pattern as every prior report migration.
-- ============================================================
INSERT INTO ric_user_menus (
    client_id, company_id, user_id, module_id, feature_code, serial_no,
    view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT DISTINCT
    mm.client_id, mm.company_id, existing.user_id, mm.module_id, mm.feature_code, mm.serial_no,
    true, false, mm.approve_allowed, mm.copy_allowed, mm.excel_upload_allowed
FROM ric_master_menus mm
JOIN (
    SELECT DISTINCT user_id, client_id, company_id, module_id
    FROM ric_user_menus
    WHERE view_allowed = true AND is_deleted = false
) existing
    ON  existing.client_id  = mm.client_id
    AND existing.company_id = mm.company_id
    AND existing.module_id  = mm.module_id
WHERE mm.feature_code = 'FN-RPT-EXR'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
