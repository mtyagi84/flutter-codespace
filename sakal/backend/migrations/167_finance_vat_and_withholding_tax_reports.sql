-- ============================================================
-- Migration 167: Finance Reports — VAT / Tax Return Summary + Withholding Tax Summary
-- ============================================================
-- Second of three Finance-reporting migrations. Both reports read straight
-- off the already-posted GL (rid_finance_lines/rih_finance_headers) rather
-- than any one module's own tax fields — every module (Sales Invoice,
-- GRN/Purchase Bill, Expense Voucher) posts VAT through the SAME
-- rim_taxes.gl_output_account_id/gl_input_account_id accounts, so this is
-- cross-module for free and can never drift from what actually posted.
-- ============================================================

-- ============================================================
-- v_vat_tax_lines — shared base VIEW for VAT / Tax Return Summary
-- ============================================================
CREATE OR REPLACE VIEW v_vat_tax_lines AS
SELECT
    l.client_id, l.company_id,
    h.trans_no, h.trans_date, h.voucher_type_code,
    h.source_doc_type, h.source_doc_no, h.source_doc_date,
    h.location_id, loc.location_name,
    t.id AS tax_id, t.tax_code, t.tax_name,
    CASE WHEN l.account_id = t.gl_output_account_id THEN 'OUTPUT' ELSE 'INPUT' END AS tax_direction,
    a.account_code, a.account_name,
    l.trans_nature, l.base_amount,
    -- Signed so a Sales Return / Purchase Return's own reversal correctly
    -- nets against the original posting rather than double-counting.
    CASE
        WHEN l.account_id = t.gl_output_account_id
            THEN (CASE WHEN l.trans_nature = 'CR' THEN l.base_amount ELSE -l.base_amount END)
        ELSE 0
    END AS output_tax_signed,
    CASE
        WHEN l.account_id = t.gl_input_account_id
            THEN (CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END)
        ELSE 0
    END AS input_tax_signed
FROM rid_finance_lines l
JOIN rih_finance_headers h
    ON  h.client_id = l.client_id AND h.company_id = l.company_id
    AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
JOIN rim_accounts a ON a.id = l.account_id
JOIN rim_taxes t
    ON  t.client_id = l.client_id AND t.company_id = l.company_id AND t.is_deleted = false
    AND (l.account_id = t.gl_output_account_id OR l.account_id = t.gl_input_account_id)
LEFT JOIN ric_locations loc ON loc.id = h.location_id
WHERE h.is_deleted = false AND l.is_deleted = false AND h.is_posted = true
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

GRANT SELECT ON v_vat_tax_lines TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION fn_vat_tax_summary_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE DEFAULT NULL,
    p_date_to   DATE DEFAULT NULL,
    p_tax_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL
) RETURNS TABLE (
    tax_id UUID, tax_code TEXT, tax_name TEXT,
    output_tax_amount NUMERIC, input_tax_amount NUMERIC, net_payable NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT tax_id, MIN(tax_code), MIN(tax_name),
           COALESCE(SUM(output_tax_signed), 0), COALESCE(SUM(input_tax_signed), 0),
           COALESCE(SUM(output_tax_signed), 0) - COALESCE(SUM(input_tax_signed), 0),
           COUNT(*)
    FROM v_vat_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_date_from  IS NULL OR trans_date >= p_date_from)
      AND (p_date_to    IS NULL OR trans_date <= p_date_to)
      AND (p_tax_id      IS NULL OR tax_id = p_tax_id)
      AND (p_location_id IS NULL OR location_id = p_location_id)
    GROUP BY tax_id;
$$;

GRANT EXECUTE ON FUNCTION fn_vat_tax_summary_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_vat_tax_summary_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE DEFAULT NULL,
    p_date_to   DATE DEFAULT NULL,
    p_tax_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL
) RETURNS TABLE (output_tax_amount NUMERIC, input_tax_amount NUMERIC, net_payable NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(output_tax_signed), 0), COALESCE(SUM(input_tax_signed), 0),
           COALESCE(SUM(output_tax_signed), 0) - COALESCE(SUM(input_tax_signed), 0), COUNT(*)
    FROM v_vat_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_date_from  IS NULL OR trans_date >= p_date_from)
      AND (p_date_to    IS NULL OR trans_date <= p_date_to)
      AND (p_tax_id      IS NULL OR tax_id = p_tax_id)
      AND (p_location_id IS NULL OR location_id = p_location_id);
$$;

GRANT EXECUTE ON FUNCTION fn_vat_tax_summary_totals(
    UUID, UUID, DATE, DATE, UUID, UUID) TO authenticated;


-- ============================================================
-- v_withholding_tax_lines — shared base VIEW for Withholding Tax Summary
-- Joins the WITHHOLDING-tagged line (050) back to the same voucher's own
-- Supplier party line to resolve who the WHT was deducted from.
-- Gross Amount = Net Payable (the supplier line's own amount) + WHT
-- Amount — the standard WHT identity, correct regardless of which exact
-- account each leg posted to.
-- ============================================================
CREATE OR REPLACE VIEW v_withholding_tax_lines AS
SELECT
    h.client_id, h.company_id,
    h.trans_no, h.trans_date, h.voucher_type_code,
    h.location_id, loc.location_name,
    sup.id AS supplier_id, sup.account_code AS supplier_code, sup.account_name AS supplier_name,
    spl.inv_bill_no, spl.inv_bill_date,
    wa.account_code AS tax_account_code, wa.account_name AS tax_account_name,
    wl.base_amount AS wht_amount,
    (spl.base_amount + wl.base_amount) AS gross_amount,
    CASE WHEN (spl.base_amount + wl.base_amount) = 0 THEN 0
         ELSE round(wl.base_amount / (spl.base_amount + wl.base_amount) * 100, 2) END AS wht_percent
FROM rih_finance_headers h
JOIN rid_finance_lines wl
    ON  wl.client_id = h.client_id AND wl.company_id = h.company_id AND wl.location_id = h.location_id
    AND wl.trans_no = h.trans_no AND wl.trans_date = h.trans_date
    AND wl.source_line_type = 'WITHHOLDING' AND wl.is_deleted = false
JOIN rim_accounts wa ON wa.id = wl.account_id
JOIN rid_finance_lines spl
    ON  spl.client_id = h.client_id AND spl.company_id = h.company_id AND spl.location_id = h.location_id
    AND spl.trans_no = h.trans_no AND spl.trans_date = h.trans_date AND spl.is_deleted = false
JOIN rim_accounts sup ON sup.id = spl.account_id AND sup.account_nature = 'Supplier'
LEFT JOIN ric_locations loc ON loc.id = h.location_id
WHERE h.is_deleted = false AND h.is_posted = true
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

GRANT SELECT ON v_withholding_tax_lines TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION fn_wht_summary_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE DEFAULT NULL,
    p_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL
) RETURNS TABLE (
    supplier_id UUID, supplier_name TEXT, gross_amount NUMERIC, wht_amount NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT supplier_id, MIN(supplier_name), COALESCE(SUM(gross_amount), 0), COALESCE(SUM(wht_amount), 0), COUNT(*)
    FROM v_withholding_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_date_from   IS NULL OR trans_date >= p_date_from)
      AND (p_date_to     IS NULL OR trans_date <= p_date_to)
      AND (p_supplier_id IS NULL OR supplier_id = p_supplier_id)
    GROUP BY supplier_id;
$$;

GRANT EXECUTE ON FUNCTION fn_wht_summary_group_summary(
    UUID, UUID, DATE, DATE, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_wht_summary_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from DATE DEFAULT NULL,
    p_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL
) RETURNS TABLE (gross_amount NUMERIC, wht_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(gross_amount), 0), COALESCE(SUM(wht_amount), 0), COUNT(*)
    FROM v_withholding_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_date_from   IS NULL OR trans_date >= p_date_from)
      AND (p_date_to     IS NULL OR trans_date <= p_date_to)
      AND (p_supplier_id IS NULL OR supplier_id = p_supplier_id);
$$;

GRANT EXECUTE ON FUNCTION fn_wht_summary_totals(
    UUID, UUID, DATE, DATE, UUID) TO authenticated;


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

        -- ---------------- VAT / Tax Return Summary ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'VAT_TAX_RETURN_SUMMARY', 'VAT / Tax Return Summary',
             'TABULAR', 'VIEW', 'v_vat_tax_lines', 'FN', 'trans_date', 'DESC', 200,
             'fn_vat_tax_summary_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_code', 'Tax Code', 'TEXT', 'LEFT', true, true, 110, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_name', 'Tax Name', 'TEXT', 'LEFT', true, true, 180, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'output_tax_amount', 'Output Tax Amount', 'NUMBER', 'RIGHT', true, true, 150, 3, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'input_tax_amount', 'Input Tax Amount', 'NUMBER', 'RIGHT', true, true, 150, 4, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'net_payable', 'Net Payable', 'NUMBER', 'RIGHT', true, true, 140, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_doc_type', 'Source Doc Type', 'TEXT', 'LEFT', true, true, 140, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_doc_no', 'Source Doc No', 'TEXT', 'LEFT', true, true, 140, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Account', 'TEXT', 'LEFT', true, true, 180, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'base_amount', 'Amount', 'NUMBER', 'RIGHT', true, true, 130, 9, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_id', 'Tax', 'DROPDOWN_LOOKUP', 'rim_taxes', 'tax_name', NULL, 'tax_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'tax_id', 'tax_name', 'fn_vat_tax_summary_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-VAT', 'VAT / Tax Return Summary', '/reports/VAT_TAX_RETURN_SUMMARY', 17, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Withholding Tax Summary ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'WITHHOLDING_TAX_SUMMARY', 'Withholding Tax Summary',
             'TABULAR', 'VIEW', 'v_withholding_tax_lines', 'FN', 'trans_date', 'DESC', 200,
             'fn_wht_summary_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 190, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_amount', 'Gross Amount', 'NUMBER', 'RIGHT', true, true, 140, 2, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'wht_amount', 'WHT Amount', 'NUMBER', 'RIGHT', true, true, 130, 3, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'wht_percent', 'WHT %', 'NUMBER', 'RIGHT', true, true, 100, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_no', 'Bill No', 'TEXT', 'LEFT', true, true, 140, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_date', 'Bill Date', 'DATE', 'LEFT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_account_name', 'Tax Code', 'TEXT', 'LEFT', true, true, 160, 7, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'supplier_id', 'supplier_name', 'fn_wht_summary_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-WHT', 'Withholding Tax Summary', '/reports/WITHHOLDING_TAX_SUMMARY', 18, 'FN-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('FN-RPT-VAT', 'FN-RPT-WHT')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
