-- ============================================================
-- Migration 168: Finance Reports — Financial Ratio Analysis + Cash & Bank Position Summary
-- ============================================================
-- Third and final Finance-reporting migration in this batch. Both reports
-- are pure composition over EXISTING, already-tested functions — zero new
-- account classification is invented here.
--
-- Financial Ratio Analysis deliberately does NOT include Current Ratio or
-- Quick Ratio — those need a Current-vs-Non-Current asset/liability
-- classification that doesn't exist anywhere in this schema (no
-- is_current flag on rim_accounts, and inferring it from group NAME text
-- would be a fragile guess, not a real classification). Every ratio below
-- instead composes root-level sections the Balance Sheet/P&L engines
-- ALREADY correctly classify (fn_balance_sheet_totals_base's
-- ASSET/LIABILITY/EQUITY, fn_pl_totals_base's INCOME/EXPENSE) plus the
-- existing 'COGS' source_line_type tag (Sales Delivery/Invoice's own Cost
-- of Sales postings, migrations 090/102) — nothing here is a new guess.
-- ============================================================

-- ============================================================
-- Financial Ratio Analysis (TABULAR, one row per ratio)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_financial_ratio_analysis(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE,
    p_date_to   DATE,
    p_location_group_id UUID DEFAULT NULL,
    p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (
    ratio_name TEXT, formula TEXT, value NUMERIC, category TEXT
) LANGUAGE sql STABLE AS $$
    WITH pl AS (
        SELECT * FROM fn_pl_totals_base(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only)
    ),
    bs AS (
        SELECT * FROM fn_balance_sheet_totals_base(p_client_id, p_company_id, p_date_to, p_location_group_id, p_posted_only)
    ),
    cogs AS (
        SELECT COALESCE(SUM(l.base_amount), 0) AS cogs_amount
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON  h.client_id = l.client_id AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.source_line_type = 'COGS' AND l.is_deleted = false AND h.is_deleted = false
          AND (NOT p_posted_only OR h.is_posted = true)
          AND h.trans_date BETWEEN p_date_from AND p_date_to
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
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
    )
    SELECT 'Revenue', 'Total Income for the period', pl.income_total, 'Reference' FROM pl
    UNION ALL
    SELECT 'Cost of Sales', 'Sum of COGS-tagged GL lines for the period', cogs.cogs_amount, 'Reference' FROM cogs
    UNION ALL
    SELECT 'Net Profit', 'Income - Expense', pl.net_profit, 'Reference' FROM pl
    UNION ALL
    SELECT 'Total Assets', 'As of period end', bs.total_assets, 'Reference' FROM bs
    UNION ALL
    SELECT 'Gross Profit Margin %', '(Revenue - Cost of Sales) / Revenue x 100',
           CASE WHEN pl.income_total = 0 THEN NULL ELSE round((pl.income_total - cogs.cogs_amount) / pl.income_total * 100, 2) END,
           'Profitability'
    FROM pl, cogs
    UNION ALL
    SELECT 'Net Profit Margin %', 'Net Profit / Revenue x 100',
           CASE WHEN pl.income_total = 0 THEN NULL ELSE round(pl.net_profit / pl.income_total * 100, 2) END,
           'Profitability'
    FROM pl
    UNION ALL
    SELECT 'Return on Assets %', 'Net Profit / Total Assets x 100',
           CASE WHEN bs.total_assets = 0 THEN NULL ELSE round(pl.net_profit / bs.total_assets * 100, 2) END,
           'Profitability'
    FROM pl, bs
    UNION ALL
    SELECT 'Return on Equity %', 'Net Profit / Total Equity x 100',
           CASE WHEN bs.total_equity = 0 THEN NULL ELSE round(pl.net_profit / bs.total_equity * 100, 2) END,
           'Profitability'
    FROM pl, bs
    UNION ALL
    SELECT 'Debt-to-Equity Ratio', 'Total Liabilities / Total Equity',
           CASE WHEN bs.total_equity = 0 THEN NULL ELSE round(bs.total_liabilities / bs.total_equity, 2) END,
           'Leverage'
    FROM bs;
$$;

GRANT EXECUTE ON FUNCTION fn_financial_ratio_analysis(
    UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Cash & Bank Position Summary (TABULAR, one row per Cash/Bank account)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_cash_bank_position(
    p_client_id  UUID,
    p_company_id UUID,
    p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL,
    p_account_nature TEXT DEFAULT NULL
) RETURNS TABLE (
    account_id UUID, account_code TEXT, account_name TEXT, account_nature TEXT,
    currency_code TEXT, balance_base NUMERIC, balance_local NUMERIC
) LANGUAGE sql STABLE AS $$
    WITH fy AS (
        SELECT id, fy_start_date
        FROM   rim_financial_years
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND fy_start_date <= p_as_of_date AND fy_end_date >= p_as_of_date
        LIMIT 1
    ),
    opening_master AS (
        SELECT ob.account_id, ob.base_signed, ob.local_signed
        FROM v_opening_balance_summary ob, fy
        WHERE ob.client_id = p_client_id AND ob.company_id = p_company_id
          AND ob.fy_id = fy.id
          AND (p_location_group_id IS NULL OR ob.location_group_id = p_location_group_id)
    ),
    movement AS (
        SELECT l.account_id,
               SUM(CASE WHEN l.trans_nature = 'DR' THEN l.base_amount  ELSE -l.base_amount  END) AS base_signed,
               SUM(CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END) AS local_signed
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        JOIN fy ON true
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
          AND h.trans_date >= fy.fy_start_date AND h.trans_date <= p_as_of_date
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
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
        GROUP BY l.account_id
    ),
    accounts AS (
        SELECT a.id, a.account_code, a.account_name, a.account_nature, cur.currency_id AS currency_code
        FROM rim_accounts a
        LEFT JOIN rim_currencies cur ON cur.id = a.account_currency_id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id
          AND a.posting_allowed = true AND a.is_deleted = false
          AND a.account_nature IN ('Cash', 'Bank')
          AND (p_account_nature IS NULL OR a.account_nature = p_account_nature)
    )
    SELECT
        ac.id, ac.account_code, ac.account_name, ac.account_nature, ac.currency_code,
        COALESCE(om.base_signed, 0)  + COALESCE(mv.base_signed, 0)  AS balance_base,
        COALESCE(om.local_signed, 0) + COALESCE(mv.local_signed, 0) AS balance_local
    FROM accounts ac
    LEFT JOIN opening_master om ON om.account_id = ac.id
    LEFT JOIN movement       mv ON mv.account_id = ac.id
    ORDER BY ac.account_nature, ac.account_code;
$$;

GRANT EXECUTE ON FUNCTION fn_cash_bank_position(
    UUID, UUID, DATE, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_cash_bank_position_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL,
    p_account_nature TEXT DEFAULT NULL
) RETURNS TABLE (balance_base NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(balance_base), 0), COUNT(*)
    FROM fn_cash_bank_position(p_client_id, p_company_id, p_as_of_date, p_location_group_id, p_account_nature);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_bank_position_totals(
    UUID, UUID, DATE, UUID, TEXT) TO authenticated;


-- ============================================================
-- Registry rows, one per existing company
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

        -- ---------------- Financial Ratio Analysis ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'FINANCIAL_RATIO_ANALYSIS', 'Financial Ratio Analysis',
             'TABULAR', 'FUNCTION', 'fn_financial_ratio_analysis', 'FN', NULL, NULL, 50, true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'ratio_name', 'Ratio', 'TEXT', 'LEFT', false, true, 220, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'formula', 'Formula', 'TEXT', 'LEFT', false, true, 280, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'value', 'Value', 'NUMBER', 'RIGHT', false, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'category', 'Category', 'BADGE', 'CENTER', false, true, 140, 4, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Period', 'DATE_RANGE', NULL, NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_group_id', 'Location Group', 'DROPDOWN_LOOKUP', 'v_location_groups_lookup', 'group_name', NULL, 'location_group_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_only', 'Posted Only', 'BOOLEAN', NULL, NULL, NULL, 'posted_only', false, 'true', 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-RAT', 'Financial Ratio Analysis', '/reports/FINANCIAL_RATIO_ANALYSIS', 19, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Cash & Bank Position Summary ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'CASH_BANK_POSITION_SUMMARY', 'Cash & Bank Position Summary',
             'TABULAR', 'FUNCTION', 'fn_cash_bank_position', 'FN', 'account_nature', 'ASC', 100,
             'fn_cash_bank_position_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_code', 'Code', 'TEXT', 'LEFT', true, true, 100, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Account Name', 'TEXT', 'LEFT', true, true, 220, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_nature', 'Nature', 'BADGE', 'CENTER', true, true, 100, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'currency_code', 'Currency', 'TEXT', 'LEFT', true, true, 100, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'balance_base', 'Balance (Base)', 'NUMBER', 'RIGHT', true, true, 150, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'balance_local', 'Balance (Local)', 'NUMBER', 'RIGHT', true, true, 150, 6, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'as_of_date', 'As of Date', 'DATE', NULL, NULL, NULL, 'as_of_date', true, 'TODAY', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_group_id', 'Location Group', 'DROPDOWN_LOOKUP', 'v_location_groups_lookup', 'group_name', NULL, 'location_group_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_nature', 'Account Nature', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"Cash","label":"Cash"},{"value":"Bank","label":"Bank"}]'::jsonb, 'account_nature', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-CBP', 'Cash & Bank Position Summary', '/reports/CASH_BANK_POSITION_SUMMARY', 20, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


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
WHERE mm.feature_code IN ('FN-RPT-RAT', 'FN-RPT-CBP')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
