-- ============================================================
-- Migration 171: Master Data Reports — Common Masters, Tax Master, Tax Group Master
-- ============================================================
-- Third of five Master-Data-reporting migrations.
-- ============================================================

-- ============================================================
-- Report 7 — Common Masters Report (GROUPED by Type)
-- ============================================================
CREATE OR REPLACE VIEW v_common_masters_report AS
SELECT
    m.client_id, m.company_id,
    t.id AS type_id, t.type_key, t.type_name,
    m.description, m.short_name, m.sort_order, m.is_active
FROM rim_common_masters m
JOIN rim_common_master_types t ON t.id = m.type_id
WHERE m.is_deleted = false;

GRANT SELECT ON v_common_masters_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_common_masters_report_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_type_id UUID DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (type_id UUID, type_name TEXT, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT type_id, MIN(type_name), COUNT(*)
    FROM v_common_masters_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_type_id   IS NULL OR type_id = p_type_id)
      AND (p_is_active IS NULL OR is_active = p_is_active)
    GROUP BY type_id;
$$;

GRANT EXECUTE ON FUNCTION fn_common_masters_report_group_summary(UUID, UUID, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_common_masters_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_type_id UUID DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_common_masters_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_type_id   IS NULL OR type_id = p_type_id)
      AND (p_is_active IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_common_masters_report_totals(UUID, UUID, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Report 8 — Tax Master Report (TABULAR, current effective rate)
-- ============================================================
CREATE OR REPLACE VIEW v_tax_master_report AS
SELECT
    t.client_id, t.company_id,
    t.tax_code, t.tax_name, t.tax_type_code, tt.type_name AS tax_type_name,
    t.applicable_on, t.calculation_type, t.is_price_inclusive, t.is_reverse_charge,
    out_a.account_name AS output_account_name, inp_a.account_name AS input_account_name,
    (SELECT r.rate FROM rim_tax_rates r
     WHERE r.tax_id = t.id AND r.is_active = true
       AND r.effective_from <= CURRENT_DATE AND (r.effective_to IS NULL OR r.effective_to >= CURRENT_DATE)
     ORDER BY r.effective_from DESC LIMIT 1) AS current_rate,
    t.is_active
FROM rim_taxes t
JOIN rim_tax_types tt ON tt.tax_type_code = t.tax_type_code
LEFT JOIN rim_accounts out_a ON out_a.id = t.gl_output_account_id
LEFT JOIN rim_accounts inp_a ON inp_a.id = t.gl_input_account_id
WHERE t.is_deleted = false;

GRANT SELECT ON v_tax_master_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_tax_master_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_tax_type_code TEXT DEFAULT NULL,
    p_applicable_on TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_tax_master_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_tax_type_code IS NULL OR tax_type_code = p_tax_type_code)
      AND (p_applicable_on IS NULL OR applicable_on = p_applicable_on)
      AND (p_is_active     IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_tax_master_report_totals(UUID, UUID, TEXT, TEXT, BOOLEAN) TO authenticated;


-- ============================================================
-- Report 9 — Tax Group Master Report (GROUPED by Tax Group)
-- ============================================================
CREATE OR REPLACE VIEW v_tax_group_master_report AS
SELECT
    g.client_id, g.company_id,
    g.id AS tax_group_id, g.group_code, g.group_name, g.applicable_on, g.is_active,
    m.sequence_no, t.tax_code AS member_tax_code, t.tax_name AS member_tax_name,
    (SELECT r.rate FROM rim_tax_rates r
     WHERE r.tax_id = t.id AND r.is_active = true
       AND r.effective_from <= CURRENT_DATE AND (r.effective_to IS NULL OR r.effective_to >= CURRENT_DATE)
     ORDER BY r.effective_from DESC LIMIT 1) AS member_tax_rate
FROM rim_tax_groups g
LEFT JOIN rim_tax_group_members m ON m.tax_group_id = g.id
LEFT JOIN rim_taxes t ON t.id = m.tax_id
WHERE g.is_deleted = false;

GRANT SELECT ON v_tax_group_master_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_tax_group_master_report_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_applicable_on TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (
    tax_group_id UUID, group_code TEXT, group_name TEXT, applicable_on TEXT, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT tax_group_id, MIN(group_code), MIN(group_name), MIN(applicable_on), COUNT(*)
    FROM v_tax_group_master_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_applicable_on IS NULL OR applicable_on = p_applicable_on)
      AND (p_is_active     IS NULL OR is_active = p_is_active)
    GROUP BY tax_group_id;
$$;

GRANT EXECUTE ON FUNCTION fn_tax_group_master_report_group_summary(UUID, UUID, TEXT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_tax_group_master_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_applicable_on TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(DISTINCT tax_group_id)
    FROM v_tax_group_master_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_applicable_on IS NULL OR applicable_on = p_applicable_on)
      AND (p_is_active     IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_tax_group_master_report_totals(UUID, UUID, TEXT, BOOLEAN) TO authenticated;


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

        -- ---------------- Report 7: Common Masters Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'COMMON_MASTERS_REPORT', 'Common Masters Report',
             'TABULAR', 'VIEW', 'v_common_masters_report', 'AD', 'type_name', 'ASC', 500,
             'fn_common_masters_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'type_name', 'Type', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'description', 'Description', 'TEXT', 'LEFT', true, true, 220, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'short_name', 'Short Name', 'TEXT', 'LEFT', true, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sort_order', 'Sort Order', 'NUMBER', 'RIGHT', true, true, 100, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 5, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'type_id', 'Type', 'DROPDOWN_LOOKUP', 'rim_common_master_types', 'type_name', NULL, 'type_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 2);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'type_id', 'type_name', 'fn_common_masters_report_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-CMN', 'Common Masters Report', '/reports/COMMON_MASTERS_REPORT', 7, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 8: Tax Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'TAX_MASTER_REPORT', 'Tax Master Report',
             'TABULAR', 'VIEW', 'v_tax_master_report', 'AD', 'tax_code', 'ASC', 200,
             'fn_tax_master_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_code', 'Tax Code', 'TEXT', 'LEFT', true, true, 110, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_name', 'Tax Name', 'TEXT', 'LEFT', true, true, 180, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_type_name', 'Tax Type', 'TEXT', 'LEFT', true, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'applicable_on', 'Applicable On', 'BADGE', 'CENTER', true, true, 120, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'current_rate', 'Current Rate %', 'NUMBER', 'RIGHT', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_price_inclusive', 'Price Inclusive', 'BOOLEAN', 'CENTER', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'output_account_name', 'Output GL Account', 'TEXT', 'LEFT', true, true, 180, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'input_account_name', 'Input GL Account', 'TEXT', 'LEFT', true, true, 180, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 9, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_type_code', 'Tax Type', 'DROPDOWN_LOOKUP', 'rim_tax_types', 'type_name', NULL, 'tax_type_code', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'applicable_on', 'Applicable On', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"SALES","label":"Sales"},{"value":"PURCHASE","label":"Purchase"},{"value":"BOTH","label":"Both"}]'::jsonb, 'applicable_on', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-TAX', 'Tax Master Report', '/reports/TAX_MASTER_REPORT', 8, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 9: Tax Group Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'TAX_GROUP_MASTER_REPORT', 'Tax Group Master Report',
             'TABULAR', 'VIEW', 'v_tax_group_master_report', 'AD', 'group_code', 'ASC', 200,
             'fn_tax_group_master_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'group_code', 'Group Code', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'group_name', 'Group Name', 'TEXT', 'LEFT', true, true, 200, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'applicable_on', 'Applicable On', 'BADGE', 'CENTER', true, true, 120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'member_tax_code', 'Member Tax Code', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'member_tax_name', 'Member Tax Name', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'member_tax_rate', 'Rate %', 'NUMBER', 'RIGHT', true, true, 100, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 7, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'applicable_on', 'Applicable On', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"SALES","label":"Sales"},{"value":"PURCHASE","label":"Purchase"},{"value":"BOTH","label":"Both"}]'::jsonb, 'applicable_on', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 2);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'tax_group_id', 'group_name', 'fn_tax_group_master_report_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-TXG', 'Tax Group Master Report', '/reports/TAX_GROUP_MASTER_REPORT', 9, 'MST-RPT', 'Master Reports', 6, false, false, false)
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
WHERE mm.feature_code IN ('MST-RPT-CMN', 'MST-RPT-TAX', 'MST-RPT-TXG')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
