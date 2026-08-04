-- ============================================================
-- Migration 118: Reporting Engine — 3 pilot reports
-- ============================================================
-- Validates the whole MVP1 pipeline (filter bar -> sort -> resize ->
-- hide/show -> totals bar -> PDF/Excel export) end to end before any real
-- module report depends on it. See sakal/docs/reporting_engine_design.md
-- "Build phases" for the pilot rationale.
--
-- Part A — SQL objects (created once, global; not per-company):
--   v_stock_balance_matrix_source          detail VIEW, Matrix pilot
--   fn_pending_bills_totals                totals FUNCTION, Tabular pilot
--   fn_pending_bills_summary_by_customer            level-1 summary FUNCTION, Grouped pilot
--   fn_pending_bills_summary_by_customer_currency    level-2 summary FUNCTION, Grouped pilot
--
-- Part B — registry rows, seeded identically for every EXISTING company
-- (same "for every existing company at migration time" pattern already
-- used for Incoterms, migration 086 — a company created after this
-- migration runs does not automatically get these rows; that's a known,
-- accepted limitation matching the Incoterm precedent, not a bug).
-- ============================================================

-- ------------------------------------------------------------
-- Part A.1 — Matrix pilot detail source
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_stock_balance_matrix_source AS
SELECT
    pl.client_id,
    pl.company_id,
    pl.product_id,
    p.product_code,
    p.product_name,
    pl.location_id,
    l.location_name,
    pl.current_stock
FROM rim_product_location pl
JOIN rim_products   p ON p.id = pl.product_id
JOIN ric_locations  l ON l.id = pl.location_id
WHERE pl.is_active = true;

GRANT SELECT ON v_stock_balance_matrix_source TO authenticated;

-- ------------------------------------------------------------
-- Part A.2 — Tabular pilot: report-level totals
-- ------------------------------------------------------------
-- STABLE FUNCTION, not a VIEW — see design doc's correction note under
-- "Grouping & subtotals": a plain aggregate VIEW would have already
-- collapsed away trans_date/inv_bill_no, leaving nothing for PostgREST's
-- own column filters to apply to. Filter values arrive as real function
-- arguments and are applied in the WHERE clause BEFORE aggregating.
CREATE OR REPLACE FUNCTION fn_pending_bills_totals(
    p_client_id UUID,
    p_company_id UUID,
    p_trans_date_from DATE DEFAULT NULL,
    p_trans_date_to   DATE DEFAULT NULL,
    p_inv_bill_no     TEXT DEFAULT NULL
) RETURNS TABLE (
    bill_amount_base  NUMERIC,
    bill_amount_local NUMERIC,
    row_count         BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(bill_amount_base), 0),
        COALESCE(SUM(bill_amount_local), 0),
        COUNT(*)
    FROM v_pending_bills
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_inv_bill_no     IS NULL OR inv_bill_no ILIKE '%' || p_inv_bill_no || '%');
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_totals(UUID, UUID, DATE, DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Part A.3 — Grouped pilot: level-1 summary (by customer)
-- ------------------------------------------------------------
-- MIN(text) is used for the label, not MIN(uuid) — this schema already
-- knows MIN()/MAX() don't exist for uuid (see CLAUDE.md's "Postgres
-- aggregate gotcha"); account_code/account_name are TEXT, so this is
-- safe, and MIN() is only being used here as an arbitrary-but-consistent
-- "pick one" over what is in practice always a single value per
-- account_id anyway.
CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_customer(
    p_client_id UUID,
    p_company_id UUID,
    p_trans_date_from DATE DEFAULT NULL,
    p_trans_date_to   DATE DEFAULT NULL,
    p_inv_bill_no     TEXT DEFAULT NULL
) RETURNS TABLE (
    account_id        UUID,
    account_label     TEXT,
    bill_amount_base  NUMERIC,
    bill_amount_local NUMERIC,
    row_count         BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        account_id,
        MIN(account_code || ' - ' || account_name),
        COALESCE(SUM(bill_amount_base), 0),
        COALESCE(SUM(bill_amount_local), 0),
        COUNT(*)
    FROM v_pending_bills
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_inv_bill_no     IS NULL OR inv_bill_no ILIKE '%' || p_inv_bill_no || '%')
    GROUP BY account_id;
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_customer(UUID, UUID, DATE, DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Part A.4 — Grouped pilot: level-2 summary (by customer + currency)
-- ------------------------------------------------------------
-- p_account_id is the ancestor key passed down from level 1 — parameter
-- name is `p_` + level 1's own group_by_column ('account_id'), the
-- naming convention ReportRepository.fetchGroupSummary relies on.
CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_customer_currency(
    p_client_id UUID,
    p_company_id UUID,
    p_account_id UUID,
    p_trans_date_from DATE DEFAULT NULL,
    p_trans_date_to   DATE DEFAULT NULL,
    p_inv_bill_no     TEXT DEFAULT NULL
) RETURNS TABLE (
    account_id        UUID,
    party_currency     TEXT,
    bill_amount_base  NUMERIC,
    bill_amount_local NUMERIC,
    row_count         BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        account_id,
        party_currency,
        COALESCE(SUM(bill_amount_base), 0),
        COALESCE(SUM(bill_amount_local), 0),
        COUNT(*)
    FROM v_pending_bills
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND account_id = p_account_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_inv_bill_no     IS NULL OR inv_bill_no ILIKE '%' || p_inv_bill_no || '%')
    GROUP BY account_id, party_currency;
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_customer_currency(UUID, UUID, UUID, DATE, DATE, TEXT) TO authenticated;


-- ============================================================
-- Part B — registry rows, one full set per existing company
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_fn_module_id UUID;
    v_in_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_fn_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'FN';
        SELECT id INTO v_in_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'IN';

        -- Skip a company that hasn't had Finance/Inventory modules seeded
        -- at all (shouldn't happen for a real company, defensive only).
        CONTINUE WHEN v_fn_module_id IS NULL OR v_in_module_id IS NULL;

        -- ============================================================
        -- Pilot 1 — Tabular: Pending Bills Register
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, 'PENDING_BILLS_REGISTER', 'Pending Bills Register',
             'TABULAR', 'VIEW', 'v_pending_bills', 'FN', 'trans_date', 'DESC', 50, 'fn_pending_bills_totals')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE SET report_name = excluded.report_name
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn, currency_code_column)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_no', 'Trans No', 'TEXT', 'LEFT', true, true, 120, 1, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_date', 'Trans Date', 'DATE', 'LEFT', true, true, 110, 2, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Customer', 'TEXT', 'LEFT', true, true, 200, 3, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_no', 'Bill No', 'TEXT', 'LEFT', true, true, 130, 4, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_date', 'Bill Date', 'DATE', 'LEFT', true, true, 110, 5, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount', 'Bill Amount (Original)', 'NUMBER', 'RIGHT', false, true, 160, 6, NULL, 'party_currency'),
            (v_company.client_id, v_company.company_id, v_report_id, 'balance_amount', 'Balance (Original)', 'NUMBER', 'RIGHT', false, true, 160, 7, NULL, 'party_currency'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount_base', 'Bill Amount (Base)', 'NUMBER', 'RIGHT', true, true, 150, 8, 'SUM', NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount_local', 'Bill Amount (Local)', 'NUMBER', 'RIGHT', true, false, 150, 9, 'SUM', NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, param_target, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Trans Date', 'DATE_RANGE', 'trans_date', 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_search', 'Bill No', 'TEXT', 'inv_bill_no', NULL, 2);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-PBR', 'Pending Bills Register',
             '/reports/PENDING_BILLS_REGISTER', 3, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ============================================================
        -- Pilot 2 — Grouped Tabular: Pending Bills by Customer
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size)
        VALUES
            (v_company.client_id, v_company.company_id, 'PENDING_BILLS_BY_CUSTOMER', 'Pending Bills by Customer',
             'TABULAR', 'VIEW', 'v_pending_bills', 'FN', 'trans_date', 'DESC', 50)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE SET report_name = excluded.report_name
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn, currency_code_column)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_no', 'Trans No', 'TEXT', 'LEFT', true, true, 120, 1, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_date', 'Trans Date', 'DATE', 'LEFT', true, true, 110, 2, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Customer', 'TEXT', 'LEFT', true, true, 200, 3, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_no', 'Bill No', 'TEXT', 'LEFT', true, true, 130, 4, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_date', 'Bill Date', 'DATE', 'LEFT', true, true, 110, 5, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount', 'Bill Amount (Original)', 'NUMBER', 'RIGHT', false, true, 160, 6, NULL, 'party_currency'),
            (v_company.client_id, v_company.company_id, v_report_id, 'balance_amount', 'Balance (Original)', 'NUMBER', 'RIGHT', false, true, 160, 7, NULL, 'party_currency'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount_base', 'Bill Amount (Base)', 'NUMBER', 'RIGHT', true, true, 150, 8, 'SUM', NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount_local', 'Bill Amount (Local)', 'NUMBER', 'RIGHT', true, false, 150, 9, 'SUM', NULL),
            -- account_label/party_currency only ever populated on SUMMARY rows (see the two
            -- group-level functions above) — never present on a plain detail row, harmless either way.
            (v_company.client_id, v_company.company_id, v_report_id, 'account_label', 'Customer (Group)', 'TEXT', 'LEFT', false, false, 220, 10, NULL, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, param_target, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Trans Date', 'DATE_RANGE', 'trans_date', 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_search', 'Bill No', 'TEXT', 'inv_bill_no', NULL, 2);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'account_id', 'account_label', 'fn_pending_bills_summary_by_customer'),
            (v_company.client_id, v_company.company_id, v_report_id, 2, 'party_currency', 'party_currency', 'fn_pending_bills_summary_by_customer_currency');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-PBG', 'Pending Bills by Customer',
             '/reports/PENDING_BILLS_BY_CUSTOMER', 4, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ============================================================
        -- Pilot 3 — Matrix: Stock Balance by Location
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_BALANCE_MATRIX', 'Stock Balance by Location',
             'MATRIX', 'VIEW', 'v_stock_balance_matrix_source', 'IN', 'product_code', 'ASC', 5000)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE SET report_name = excluded.report_name
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn, is_pivot_row_group, is_pivot_dimension, is_pivot_measure)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Product Code', 'TEXT', 'LEFT', false, true, 140, 1, NULL, true, false, false),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Product Name', 'TEXT', 'LEFT', false, true, 220, 2, NULL, true, false, false),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', false, true, 140, 3, NULL, false, true, false),
            (v_company.client_id, v_company.company_id, v_report_id, 'current_stock', 'Current Stock', 'NUMBER', 'RIGHT', false, true, 120, 4, 'SUM', false, false, true);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, param_target, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'product_search', 'Product', 'TEXT', 'product_name', 1);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SBM', 'Stock Balance by Location',
             '/reports/STOCK_BALANCE_MATRIX', 10, 'IN-RPT', 'Reports', 5, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;
