-- ============================================================
-- Migration 173: Master Data Reports — Price List Report
-- ============================================================
-- Fifth and final Master-Data-reporting migration, completing the 13-report
-- design in sakal/docs/screens/artifact_master_data_reports_plan.html.
--
-- Scoped as a BATCH REGISTER for v1 (one row per Price Master entry,
-- expanding to its own priced lines) — the same safe, proven Register
-- shape used throughout this session — rather than a "resolve the one
-- currently-active price across overlapping batches" computation (which
-- would need to replicate fn_get_active_price's own fallback logic). A
-- future "Effective Price List" (resolved, one row per product, as-of a
-- date) is a genuinely different, more valuable report — flagged as a v2
-- candidate in the artifact, not silently substituted for what's built
-- here.
-- ============================================================

CREATE OR REPLACE VIEW v_price_master_lines_report AS
SELECT
    h.client_id, h.company_id,
    h.entry_no, h.entry_date, h.effective_date, h.price_type, h.status,
    h.location_id, loc.location_name,
    h.customer_id, cust.account_code AS customer_code, cust.account_name AS customer_name,
    cur.currency_id AS price_currency_code,
    l.serial_no AS line_serial,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.cost_price, l.selling_price, l.margin_percent
FROM rih_price_master_headers h
JOIN rid_price_master_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.entry_no = h.entry_no AND l.entry_date = h.entry_date
    AND l.is_deleted = false
JOIN rim_products p ON p.id = l.product_id
LEFT JOIN rim_common_masters u   ON u.id   = l.uom_id
LEFT JOIN ric_locations      loc ON loc.id = h.location_id
LEFT JOIN rim_accounts       cust ON cust.id = h.customer_id
LEFT JOIN rim_currencies     cur ON cur.id = h.price_currency_id
WHERE h.is_deleted = false;

GRANT SELECT ON v_price_master_lines_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_price_list_report_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_effective_date_from DATE DEFAULT NULL,
    p_effective_date_to   DATE DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_price_type TEXT DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_status TEXT DEFAULT NULL
) RETURNS TABLE (
    entry_no TEXT, entry_date DATE, effective_date DATE, price_type TEXT,
    customer_name TEXT, location_name TEXT, status TEXT, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT entry_no, entry_date, MIN(effective_date), MIN(price_type),
           MIN(customer_name), MIN(location_name), MIN(status), COUNT(*)
    FROM v_price_master_lines_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_effective_date_from IS NULL OR effective_date >= p_effective_date_from)
      AND (p_effective_date_to   IS NULL OR effective_date <= p_effective_date_to)
      AND (p_location_id         IS NULL OR location_id = p_location_id)
      AND (p_price_type          IS NULL OR price_type = p_price_type)
      AND (p_customer_id         IS NULL OR customer_id = p_customer_id)
      AND (p_status              IS NULL OR status = p_status)
    GROUP BY entry_no, entry_date;
$$;

GRANT EXECUTE ON FUNCTION fn_price_list_report_group_summary(
    UUID, UUID, DATE, DATE, UUID, TEXT, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_price_list_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_effective_date_from DATE DEFAULT NULL,
    p_effective_date_to   DATE DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_price_type TEXT DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_status TEXT DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_price_master_lines_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_effective_date_from IS NULL OR effective_date >= p_effective_date_from)
      AND (p_effective_date_to   IS NULL OR effective_date <= p_effective_date_to)
      AND (p_location_id         IS NULL OR location_id = p_location_id)
      AND (p_price_type          IS NULL OR price_type = p_price_type)
      AND (p_customer_id         IS NULL OR customer_id = p_customer_id)
      AND (p_status              IS NULL OR status = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_price_list_report_totals(
    UUID, UUID, DATE, DATE, UUID, TEXT, UUID, TEXT) TO authenticated;


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

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PRICE_LIST_REPORT', 'Price List Report',
             'TABULAR', 'VIEW', 'v_price_master_lines_report', 'AD', 'effective_date', 'DESC', 500,
             'fn_price_list_report_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'entry_no', 'Entry No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'entry_date', 'Entry Date', 'DATE', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'effective_date', 'Effective Date', 'DATE', 'LEFT', true, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'price_type', 'Price Type', 'BADGE', 'CENTER', true, true, 120, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 150, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'BADGE', 'CENTER', true, true, 120, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'cost_price', 'Cost Price', 'NUMBER', 'RIGHT', true, true, 120, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'selling_price', 'Selling Price', 'NUMBER', 'RIGHT', true, true, 130, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'margin_percent', 'Margin %', 'NUMBER', 'RIGHT', true, true, 100, 13, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Effective Date', 'DATE_RANGE', NULL, NULL, NULL, 'effective_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'price_type', 'Price Type', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"GENERIC","label":"Generic"},{"value":"CUSTOMER","label":"Customer"}]'::jsonb, 'price_type', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, 'APPROVED', 5);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'entry_no', 'entry_no', 'fn_price_list_report_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-PRC', 'Price List Report', '/reports/PRICE_LIST_REPORT', 13, 'MST-RPT', 'Master Reports', 6, false, false, false)
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
WHERE mm.feature_code IN ('MST-RPT-PRC')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
