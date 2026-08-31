-- ============================================================
-- Migration 170: Master Data Reports — Chart of Accounts, Chart of Groups, Item Category Master
-- ============================================================
-- Second of five Master-Data-reporting migrations. All three masters here
-- are self-referencing trees (rim_accounts, rim_item_categories) — built
-- as TABULAR reports with a computed indent
-- (repeat('  ', level_depth) || name), NOT the existing HIERARCHICAL report
-- type. That renderer (PlNode/sakal_report_hierarchical_table.dart) is
-- hardcoded to a single monetary `amount` column per row — built for P&L/
-- Balance Sheet, not a pure structural tree with nothing to sum. A plain
-- indented TABULAR list prints cleanly with zero new widget work.
-- ============================================================

-- ============================================================
-- v_chart_of_accounts_tree — shared base for Reports 4 and 5, split by
-- posting_allowed downstream in each report's own WHERE/registry filter.
-- Recursive CTE walks the whole rim_accounts forest (all tenants at once,
-- same convention as every other report view — the reporting engine's own
-- client_id/company_id querystring filter scopes it to one tenant).
-- ============================================================
CREATE OR REPLACE VIEW v_chart_of_accounts_tree AS
WITH RECURSIVE tree AS (
    SELECT
        a.id, a.client_id, a.company_id, a.parent_id,
        a.account_code, a.account_name, a.account_nature, a.accounting_std,
        a.posting_allowed, a.is_active,
        0 AS level_depth,
        NULL::text AS parent_name
    FROM rim_accounts a
    WHERE a.parent_id IS NULL AND a.is_deleted = false
    UNION ALL
    SELECT
        a.id, a.client_id, a.company_id, a.parent_id,
        a.account_code, a.account_name, a.account_nature, a.accounting_std,
        a.posting_allowed, a.is_active,
        t.level_depth + 1,
        t.account_name AS parent_name
    FROM rim_accounts a
    JOIN tree t ON a.parent_id = t.id
    WHERE a.is_deleted = false
)
SELECT
    client_id, company_id, id AS account_id, account_code,
    (repeat('   ', level_depth) || account_name) AS indented_name,
    account_name, parent_name, level_depth, account_nature, accounting_std,
    posting_allowed, is_active
FROM tree;

GRANT SELECT ON v_chart_of_accounts_tree TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_chart_of_accounts_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_account_nature TEXT DEFAULT NULL,
    p_accounting_std TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_chart_of_accounts_tree
    WHERE client_id = p_client_id AND company_id = p_company_id AND posting_allowed = true
      AND (p_account_nature IS NULL OR account_nature = p_account_nature)
      AND (p_accounting_std IS NULL OR accounting_std = p_accounting_std)
      AND (p_is_active      IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_chart_of_accounts_report_totals(UUID, UUID, TEXT, TEXT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_chart_of_groups_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_account_nature TEXT DEFAULT NULL,
    p_accounting_std TEXT DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_chart_of_accounts_tree
    WHERE client_id = p_client_id AND company_id = p_company_id AND posting_allowed = false
      AND (p_account_nature IS NULL OR account_nature = p_account_nature)
      AND (p_accounting_std IS NULL OR accounting_std = p_accounting_std);
$$;

GRANT EXECUTE ON FUNCTION fn_chart_of_groups_report_totals(UUID, UUID, TEXT, TEXT) TO authenticated;


-- ============================================================
-- v_item_category_tree — Report 6
-- ============================================================
CREATE OR REPLACE VIEW v_item_category_tree AS
WITH RECURSIVE tree AS (
    SELECT
        c.id, c.client_id, c.company_id, c.parent_id,
        c.category_short, c.category_name, c.level_no, c.is_active,
        0 AS level_depth,
        NULL::text AS parent_name
    FROM rim_item_categories c
    WHERE c.parent_id IS NULL AND c.is_deleted = false
    UNION ALL
    SELECT
        c.id, c.client_id, c.company_id, c.parent_id,
        c.category_short, c.category_name, c.level_no, c.is_active,
        t.level_depth + 1,
        t.category_name AS parent_name
    FROM rim_item_categories c
    JOIN tree t ON c.parent_id = t.id
    WHERE c.is_deleted = false
)
SELECT
    client_id, company_id, id AS category_id, category_short,
    (repeat('   ', level_depth) || category_name) AS indented_name,
    category_name, parent_name, level_depth, level_no, is_active
FROM tree;

GRANT SELECT ON v_item_category_tree TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_item_category_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_level_no SMALLINT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_item_category_tree
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_level_no  IS NULL OR level_no = p_level_no)
      AND (p_is_active IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_item_category_report_totals(UUID, UUID, SMALLINT, BOOLEAN) TO authenticated;


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

        -- ---------------- Report 4: Chart of Accounts Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'CHART_OF_ACCOUNTS_REPORT', 'Chart of Accounts Report',
             'TABULAR', 'VIEW', 'v_chart_of_accounts_tree', 'AD', 'account_code', 'ASC', 1000,
             'fn_chart_of_accounts_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_code', 'Account Code', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'indented_name', 'Account Name', 'TEXT', 'LEFT', false, true, 280, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'parent_name', 'Parent Group', 'TEXT', 'LEFT', true, true, 200, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_nature', 'Account Nature', 'BADGE', 'CENTER', true, true, 130, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'accounting_std', 'Accounting Std', 'TEXT', 'LEFT', true, true, 120, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 6, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_nature', 'Account Nature', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"General","label":"General"},{"value":"Customer","label":"Customer"},{"value":"Supplier","label":"Supplier"},{"value":"Cash","label":"Cash"},{"value":"Bank","label":"Bank"},{"value":"Employee","label":"Employee"},{"value":"Tax","label":"Tax"}]'::jsonb, 'account_nature', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'accounting_std', 'Accounting Standard', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"INDIAN","label":"Indian"},{"value":"OHADA","label":"OHADA"}]'::jsonb, 'accounting_std', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-COA', 'Chart of Accounts Report', '/reports/CHART_OF_ACCOUNTS_REPORT', 4, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 5: Chart of Groups Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'CHART_OF_GROUPS_REPORT', 'Chart of Groups Report',
             'TABULAR', 'VIEW', 'v_chart_of_accounts_tree', 'AD', 'account_code', 'ASC', 500,
             'fn_chart_of_groups_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_code', 'Group Code', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'indented_name', 'Group Name', 'TEXT', 'LEFT', false, true, 280, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'parent_name', 'Parent Group', 'TEXT', 'LEFT', true, true, 200, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'level_depth', 'Level', 'NUMBER', 'RIGHT', true, true, 80, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_nature', 'Account Nature', 'BADGE', 'CENTER', true, true, 130, 5, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_nature', 'Account Nature', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"General","label":"General"},{"value":"Customer","label":"Customer"},{"value":"Supplier","label":"Supplier"},{"value":"Cash","label":"Cash"},{"value":"Bank","label":"Bank"},{"value":"Employee","label":"Employee"},{"value":"Tax","label":"Tax"}]'::jsonb, 'account_nature', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'accounting_std', 'Accounting Standard', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"INDIAN","label":"Indian"},{"value":"OHADA","label":"OHADA"}]'::jsonb, 'accounting_std', false, NULL, 2);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-GRP', 'Chart of Groups Report', '/reports/CHART_OF_GROUPS_REPORT', 5, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 6: Item Category Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'ITEM_CATEGORY_MASTER_REPORT', 'Item Category Master Report',
             'TABULAR', 'VIEW', 'v_item_category_tree', 'AD', 'category_name', 'ASC', 500,
             'fn_item_category_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'category_short', 'Short Code', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'indented_name', 'Category Name', 'TEXT', 'LEFT', false, true, 280, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'parent_name', 'Parent Category', 'TEXT', 'LEFT', true, true, 200, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'level_no', 'Level', 'NUMBER', 'RIGHT', true, true, 80, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 5, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'level_no', 'Level', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"1","label":"Level 1"},{"value":"2","label":"Level 2"},{"value":"3","label":"Level 3"},{"value":"4","label":"Level 4"}]'::jsonb, 'level_no', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 2);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-ITC', 'Item Category Master Report', '/reports/ITEM_CATEGORY_MASTER_REPORT', 6, 'MST-RPT', 'Master Reports', 6, false, false, false)
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
WHERE mm.feature_code IN ('MST-RPT-COA', 'MST-RPT-GRP', 'MST-RPT-ITC')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
