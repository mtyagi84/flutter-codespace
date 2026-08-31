-- ============================================================
-- Migration 172: Master Data Reports — Payment Terms, Sales Executives, Additional Charges
-- ============================================================
-- Fourth of five Master-Data-reporting migrations.
-- ============================================================

-- ============================================================
-- Report 10 — Payment Terms Master Report (GROUPED by Term)
-- ============================================================
CREATE OR REPLACE VIEW v_payment_terms_report AS
SELECT
    h.client_id, h.company_id,
    h.id AS term_id, h.term_code, h.term_name, h.description, h.is_active,
    l.sequence, l.value_type, l.value_amount, l.due_days, l.is_end_of_month
FROM rim_payment_terms h
LEFT JOIN rim_payment_term_lines l ON l.term_id = h.id AND l.is_deleted = false
WHERE h.is_deleted = false;

GRANT SELECT ON v_payment_terms_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_payment_terms_report_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (
    term_id UUID, term_code TEXT, term_name TEXT, description TEXT, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT term_id, MIN(term_code), MIN(term_name), MIN(description), COUNT(*)
    FROM v_payment_terms_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_is_active IS NULL OR is_active = p_is_active)
    GROUP BY term_id;
$$;

GRANT EXECUTE ON FUNCTION fn_payment_terms_report_group_summary(UUID, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_payment_terms_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(DISTINCT term_id)
    FROM v_payment_terms_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_is_active IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_payment_terms_report_totals(UUID, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Report 11 — Sales Executives Master Report (TABULAR)
-- ============================================================
CREATE OR REPLACE VIEW v_sales_executives_report AS
SELECT
    se.client_id, se.company_id,
    se.employee_code, se.full_name, se.phone, se.email,
    u.full_name AS linked_user_name, se.is_active
FROM rim_sales_executives se
LEFT JOIN rim_users u ON u.id = se.linked_user_id
WHERE se.is_deleted = false;

GRANT SELECT ON v_sales_executives_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_sales_executives_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_sales_executives_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_is_active IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_sales_executives_report_totals(UUID, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Report 12 — Additional Charges Master Report (TABULAR)
-- ============================================================
CREATE OR REPLACE VIEW v_additional_charges_report AS
SELECT
    c.client_id, c.company_id,
    c.charge_code, c.charge_name, c.applicable_on, c.is_taxable,
    t.tax_code, c.nature, c.amount_or_percent, c.default_percent, c.default_amount,
    ga.account_name AS default_gl_account_name, c.is_active
FROM rim_additional_charges c
LEFT JOIN rim_taxes t ON t.id = c.tax_id
LEFT JOIN rim_accounts ga ON ga.id = c.default_gl_account_id
WHERE c.is_deleted = false;

GRANT SELECT ON v_additional_charges_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_additional_charges_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_applicable_on TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_additional_charges_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_applicable_on IS NULL OR applicable_on = p_applicable_on)
      AND (p_is_active     IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_additional_charges_report_totals(UUID, UUID, TEXT, BOOLEAN) TO authenticated;


-- ============================================================
-- Registry rows, one per existing company
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_ad_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_ad_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'AD';

        CONTINUE WHEN v_ad_module_id IS NULL;

        -- ---------------- Report 10: Payment Terms Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PAYMENT_TERMS_MASTER_REPORT', 'Payment Terms Master Report',
             'TABULAR', 'VIEW', 'v_payment_terms_report', 'AD', 'term_code', 'ASC', 200,
             'fn_payment_terms_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'term_code', 'Term Code', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'term_name', 'Term Name', 'TEXT', 'LEFT', true, true, 180, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'description', 'Description', 'TEXT', 'LEFT', true, true, 240, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'value_type', 'Installment Type', 'BADGE', 'CENTER', true, true, 130, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'value_amount', 'Value', 'NUMBER', 'RIGHT', true, true, 100, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'due_days', 'Due Days', 'NUMBER', 'RIGHT', true, true, 100, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_end_of_month', 'End of Month', 'BOOLEAN', 'CENTER', true, true, 110, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 8, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 1);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'term_id', 'term_name', 'fn_payment_terms_report_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-PYT', 'Payment Terms Master Report', '/reports/PAYMENT_TERMS_MASTER_REPORT', 10, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 11: Sales Executives Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SALES_EXECUTIVES_MASTER_REPORT', 'Sales Executives Master Report',
             'TABULAR', 'VIEW', 'v_sales_executives_report', 'AD', 'full_name', 'ASC', 200,
             'fn_sales_executives_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'employee_code', 'Employee Code', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'full_name', 'Full Name', 'TEXT', 'LEFT', true, true, 200, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'phone', 'Phone', 'TEXT', 'LEFT', true, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'email', 'Email', 'TEXT', 'LEFT', true, true, 200, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'linked_user_name', 'Linked User', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 6, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 1);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-SEX', 'Sales Executives Master Report', '/reports/SALES_EXECUTIVES_MASTER_REPORT', 11, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 12: Additional Charges Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'ADDITIONAL_CHARGES_MASTER_REPORT', 'Additional Charges Master Report',
             'TABULAR', 'VIEW', 'v_additional_charges_report', 'AD', 'charge_code', 'ASC', 200,
             'fn_additional_charges_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_code', 'Charge Code', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_name', 'Charge Name', 'TEXT', 'LEFT', true, true, 180, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'applicable_on', 'Applicable On', 'BADGE', 'CENTER', true, true, 120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'nature', 'Nature', 'BADGE', 'CENTER', true, true, 100, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_taxable', 'Taxable', 'BOOLEAN', 'CENTER', true, true, 90, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_code', 'Tax', 'TEXT', 'LEFT', true, true, 110, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'amount_or_percent', 'Amount/Percent', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'default_percent', 'Default %', 'NUMBER', 'RIGHT', true, true, 100, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'default_amount', 'Default Amount', 'NUMBER', 'RIGHT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'default_gl_account_name', 'Default GL Account', 'TEXT', 'LEFT', true, true, 180, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 11, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'applicable_on', 'Applicable On', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"SALES","label":"Sales"},{"value":"PURCHASE","label":"Purchase"},{"value":"BOTH","label":"Both"}]'::jsonb, 'applicable_on', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 2);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-CHG', 'Additional Charges Master Report', '/reports/ADDITIONAL_CHARGES_MASTER_REPORT', 12, 'MST-RPT', 'Master Reports', 6, false, false, false)
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
WHERE mm.feature_code IN ('MST-RPT-PYT', 'MST-RPT-SEX', 'MST-RPT-CHG')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
