-- ============================================================
-- Migration 176: Bank Reconciliation Statement report
-- ============================================================
-- Third and final Bank Reconciliation migration — registers the two-sided
-- reconciliation schedule (fn_bank_reconciliation_summary, migration 175)
-- on the existing generic reporting engine, same as every other report
-- built this session. FUNCTION-sourced, one row (the schedule itself).
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
             module_code, default_sort_column, default_sort_dir, default_page_size, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'BANK_RECONCILIATION_STATEMENT', 'Bank Reconciliation Statement',
             'TABULAR', 'FUNCTION', 'fn_bank_reconciliation_summary', 'FN', NULL, NULL, 10, false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'book_balance', 'Book Balance', 'NUMBER', 'RIGHT', false, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unbooked_bank_credits', 'Unbooked Bank Credits', 'NUMBER', 'RIGHT', false, true, 170, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unbooked_bank_debits', 'Unbooked Bank Debits', 'NUMBER', 'RIGHT', false, true, 170, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjusted_book_balance', 'Adjusted Book Balance', 'NUMBER', 'RIGHT', false, true, 170, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bank_statement_balance', 'Bank Statement Balance', 'NUMBER', 'RIGHT', false, true, 170, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'deposits_in_transit', 'Deposits in Transit', 'NUMBER', 'RIGHT', false, true, 160, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'outstanding_cheques', 'Outstanding Cheques', 'NUMBER', 'RIGHT', false, true, 160, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjusted_bank_balance', 'Adjusted Bank Balance', 'NUMBER', 'RIGHT', false, true, 170, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reconciliation_diff', 'Reconciliation Diff', 'NUMBER', 'RIGHT', false, true, 150, 9, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'bank_account_id', 'Bank Account', 'DROPDOWN_LOOKUP', 'rim_bank_accounts', 'bank_name', NULL, 'bank_account_id', true, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'as_of_date', 'As of Date', 'DATE', NULL, NULL, NULL, 'as_of_date', true, 'TODAY', 2);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-BRS', 'Bank Reconciliation Statement', '/reports/BANK_RECONCILIATION_STATEMENT', 21, 'FN-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('FN-RPT-BRS')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
