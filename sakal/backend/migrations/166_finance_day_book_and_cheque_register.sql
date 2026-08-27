-- ============================================================
-- Migration 166: Finance Reports — Day Book / Voucher Register + Cheque Register
-- ============================================================
-- First of three Finance-reporting migrations covering the 8-report gap
-- analysis in sakal/docs/screens/artifact_finance_reports_plan.html.
-- Finance already has 14 reports (Trial Balance, P&L, Balance Sheet, Cash
-- Flow, Ageing, Pending Bills, Account Ledger, Expense Report) — this
-- batch fills the real remaining gaps, starting with the single most-
-- missing report: a chronological "everything that happened" register.
--
-- Comparative Profit & Loss / Balance Sheet (originally scoped as reports
-- 5-6) are DEFERRED — the HIERARCHICAL tree renderer (Flutter's `PlNode`
-- model / sakal_report_hierarchical_table.dart) is hardcoded to a single
-- `amount` value per row, confirmed by reading the widget directly. Adding
-- Current/Prior/Variance columns needs real Flutter widget work, not just
-- SQL, unlike every other report in this batch (all TABULAR/GROUPED on the
-- fully generic engine). Flagged as a follow-up, not silently dropped.
-- ============================================================

-- ============================================================
-- v_finance_voucher_lines — shared base VIEW for the Day Book
-- ============================================================
CREATE OR REPLACE VIEW v_finance_voucher_lines AS
SELECT
    h.client_id, h.company_id,
    h.trans_no, h.trans_date, h.voucher_type_code, h.payment_mode_code,
    h.reference_no, h.reference_date, h.remarks AS header_remarks,
    h.is_posted, h.posted_at, pu.full_name AS posted_by_name,
    h.source_doc_type, h.source_doc_no, h.source_doc_date,
    h.location_id, loc.location_name,
    l.serial_no AS line_serial,
    l.account_id, a.account_code, a.account_name,
    l.trans_nature, l.trans_amount, l.trans_currency,
    l.base_amount, l.local_amount,
    l.party_amount, l.party_currency,
    l.inv_bill_no, l.inv_bill_date, l.line_remarks
FROM rih_finance_headers h
JOIN rid_finance_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.location_id = h.location_id AND l.trans_no = h.trans_no AND l.trans_date = h.trans_date
JOIN rim_accounts a ON a.id = l.account_id
LEFT JOIN rim_users pu   ON pu.id  = h.posted_by
LEFT JOIN ric_locations loc ON loc.id = h.location_id
WHERE h.is_deleted = false AND l.is_deleted = false
AND (
    NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
    OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
);

GRANT SELECT ON v_finance_voucher_lines TO anon, authenticated, service_role;


-- ============================================================
-- Report — Day Book / Voucher Register (GROUPED by Voucher)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_day_book_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE DEFAULT NULL,
    p_date_to   DATE DEFAULT NULL,
    p_voucher_type_code TEXT DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_posted_only BOOLEAN DEFAULT NULL
) RETURNS TABLE (
    trans_no TEXT, trans_date DATE, voucher_type_code TEXT, reference_no TEXT, reference_date DATE,
    location_name TEXT, total_amount NUMERIC, posted_by_name TEXT, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT trans_no, trans_date, MIN(voucher_type_code), MIN(reference_no), MIN(reference_date),
           MIN(location_name),
           COALESCE(SUM(base_amount) FILTER (WHERE trans_nature = 'DR'), 0),
           MIN(posted_by_name), COUNT(*)
    FROM v_finance_voucher_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_date_from  IS NULL OR trans_date >= p_date_from)
      AND (p_date_to    IS NULL OR trans_date <= p_date_to)
      AND (p_voucher_type_code IS NULL OR voucher_type_code = p_voucher_type_code)
      AND (p_location_id IS NULL OR location_id = p_location_id)
      AND (p_posted_only IS NULL OR is_posted = p_posted_only)
    GROUP BY trans_no, trans_date;
$$;

GRANT EXECUTE ON FUNCTION fn_day_book_group_summary(
    UUID, UUID, DATE, DATE, TEXT, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_day_book_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE DEFAULT NULL,
    p_date_to   DATE DEFAULT NULL,
    p_voucher_type_code TEXT DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_posted_only BOOLEAN DEFAULT NULL
) RETURNS TABLE (total_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    WITH filtered AS (
        SELECT * FROM v_finance_voucher_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND (p_date_from  IS NULL OR trans_date >= p_date_from)
          AND (p_date_to    IS NULL OR trans_date <= p_date_to)
          AND (p_voucher_type_code IS NULL OR voucher_type_code = p_voucher_type_code)
          AND (p_location_id IS NULL OR location_id = p_location_id)
          AND (p_posted_only IS NULL OR is_posted = p_posted_only)
    ),
    per_voucher AS (
        SELECT trans_no, trans_date, SUM(base_amount) FILTER (WHERE trans_nature = 'DR') AS voucher_total
        FROM filtered
        GROUP BY trans_no, trans_date
    )
    SELECT COALESCE((SELECT SUM(voucher_total) FROM per_voucher), 0), (SELECT COUNT(*) FROM filtered);
$$;

GRANT EXECUTE ON FUNCTION fn_day_book_totals(
    UUID, UUID, DATE, DATE, TEXT, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Report — Cheque Register (TABULAR, one row per voucher)
-- ============================================================
CREATE OR REPLACE VIEW v_cheque_register AS
SELECT
    h.client_id, h.company_id,
    h.trans_no, h.trans_date, h.voucher_type_code,
    h.cheque_no, h.cheque_date, h.is_posted,
    h.location_id, loc.location_name,
    l1.trans_amount, l1.trans_currency AS amount_currency,
    (SELECT string_agg(DISTINCT a2.account_name, ', ' ORDER BY a2.account_name)
     FROM rid_finance_lines l2
     JOIN rim_accounts a2 ON a2.id = l2.account_id
     WHERE l2.client_id = h.client_id AND l2.company_id = h.company_id AND l2.location_id = h.location_id
       AND l2.trans_no = h.trans_no AND l2.trans_date = h.trans_date
       AND l2.serial_no <> 1 AND l2.is_deleted = false) AS party_name
FROM rih_finance_headers h
JOIN rid_finance_lines l1
    ON  l1.client_id = h.client_id AND l1.company_id = h.company_id AND l1.location_id = h.location_id
    AND l1.trans_no = h.trans_no AND l1.trans_date = h.trans_date AND l1.serial_no = 1 AND l1.is_deleted = false
LEFT JOIN ric_locations loc ON loc.id = h.location_id
WHERE h.payment_mode_code = 'CHEQUE' AND h.is_deleted = false
AND (
    NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
    OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
);

GRANT SELECT ON v_cheque_register TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_cheque_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE DEFAULT NULL,
    p_date_to   DATE DEFAULT NULL,
    p_voucher_type_code TEXT DEFAULT NULL,
    p_location_id UUID DEFAULT NULL
) RETURNS TABLE (trans_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(trans_amount), 0), COUNT(*)
    FROM v_cheque_register
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_date_from  IS NULL OR trans_date >= p_date_from)
      AND (p_date_to    IS NULL OR trans_date <= p_date_to)
      AND (p_voucher_type_code IS NULL OR voucher_type_code = p_voucher_type_code)
      AND (p_location_id IS NULL OR location_id = p_location_id);
$$;

GRANT EXECUTE ON FUNCTION fn_cheque_register_totals(
    UUID, UUID, DATE, DATE, TEXT, UUID) TO authenticated;


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

        -- ---------------- Day Book / Voucher Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'DAY_BOOK_REGISTER', 'Day Book / Voucher Register',
             'TABULAR', 'VIEW', 'v_finance_voucher_lines', 'FN', 'trans_date', 'DESC', 200,
             'fn_day_book_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_no', 'Trans No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'voucher_type_code', 'Voucher Type', 'BADGE', 'CENTER', true, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reference_no', 'Reference No', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reference_date', 'Reference Date', 'DATE', 'LEFT', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'total_amount', 'Total Amount', 'NUMBER', 'RIGHT', true, true, 130, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_by_name', 'Posted By', 'TEXT', 'LEFT', true, true, 140, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Account', 'TEXT', 'LEFT', true, true, 180, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_nature', 'Dr/Cr', 'BADGE', 'CENTER', true, true, 80, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'base_amount', 'Line Amount', 'NUMBER', 'RIGHT', true, true, 130, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'line_remarks', 'Narration', 'TEXT', 'LEFT', true, true, 200, 11, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'voucher_type_code', 'Voucher Type', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"JV","label":"Journal Voucher"},{"value":"CTR","label":"Contra Voucher"},{"value":"CRV","label":"Cash Receipt"},{"value":"BRV","label":"Bank Receipt"},{"value":"CPV","label":"Cash Payment"},{"value":"BPV","label":"Bank Payment"},{"value":"EXP","label":"Expense Voucher"}]'::jsonb,
                'voucher_type_code', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_only', 'Posted Only', 'BOOLEAN', NULL, NULL, NULL, 'posted_only', false, NULL, 4);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'trans_no', 'trans_no', 'fn_day_book_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-DBK', 'Day Book / Voucher Register', '/reports/DAY_BOOK_REGISTER', 15, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Cheque Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'CHEQUE_REGISTER', 'Cheque Register',
             'TABULAR', 'VIEW', 'v_cheque_register', 'FN', 'trans_date', 'DESC', 200,
             'fn_cheque_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'cheque_no', 'Cheque No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'cheque_date', 'Cheque Date', 'DATE', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_no', 'Trans No', 'TEXT', 'LEFT', true, true, 140, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_date', 'Trans Date', 'DATE', 'LEFT', true, true, 110, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'voucher_type_code', 'Voucher Type', 'BADGE', 'CENTER', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'party_name', 'Party', 'TEXT', 'LEFT', true, true, 180, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_amount', 'Amount', 'NUMBER', 'RIGHT', true, true, 130, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_posted', 'Posted', 'BOOLEAN', 'CENTER', true, true, 90, 8, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'voucher_type_code', 'Voucher Type', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"CRV","label":"Cash Receipt"},{"value":"BRV","label":"Bank Receipt"},{"value":"CPV","label":"Cash Payment"},{"value":"BPV","label":"Bank Payment"}]'::jsonb,
                'voucher_type_code', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-CHQ', 'Cheque Register', '/reports/CHEQUE_REGISTER', 16, 'FN-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('FN-RPT-DBK', 'FN-RPT-CHQ')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
