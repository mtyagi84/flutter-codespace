-- ============================================================
-- fn_seed_report_definitions_for_company
--
-- Real, systemic bug found live 2026-09-13: every one of the ~15+
-- report-registration migrations (135 Trial Balance, 144 Balance Sheet,
-- 148-155 Inventory reports, 158-168 Purchase/Sales/Finance batches,
-- 169-173 Master reports, etc.) only ever looped over companies that
-- EXISTED AT THE TIME that migration ran, inserting rows into
-- ric_report_definitions/ric_report_columns/ric_report_filters/
-- ric_report_group_levels for each one. None of that seeding logic was
-- ever wired into fn_register_client/fn_seed_client_modules -- so a
-- BRAND NEW company registered today gets a menu with ~75 report items
-- that ALL fail with "Unable to load this report", because there is
-- literally no ric_report_definitions row for any of them. Confirmed:
-- the QA Automation tenant (registered today) had 0 report definitions
-- vs. 75 for the real production tenant.
--
-- Fix: rather than trying to reconstruct 75 rows across 4 tables by hand
-- from 15+ migration files (slow, error-prone, and re-drifts the moment
-- a 16th report migration is added later), this function COPIES an
-- already-correct company's report setup as a template for a new one --
-- the report definitions/columns/filters/group-levels are identical in
-- content for every tenant (same report_key, same source_object function
-- names, same column layout) and only ever differ by client_id/company_id.
--
-- Call this once per new company registration (wired into
-- fn_register_client below) and it stays correct automatically as new
-- reports are added, as long as at least one company has them -- no
-- per-report maintenance needed here ever again.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_seed_report_definitions_for_company(
    p_client_id           UUID,
    p_company_id          UUID,
    p_template_company_id UUID DEFAULT NULL  -- NULL = auto-pick whichever company currently has the most reports
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_template_company_id UUID;
    v_count                INTEGER;
BEGIN
    v_template_company_id := COALESCE(
        p_template_company_id,
        (SELECT company_id FROM ric_report_definitions
         GROUP BY company_id ORDER BY count(*) DESC LIMIT 1)
    );

    IF v_template_company_id IS NULL THEN
        RETURN 0; -- no template exists anywhere yet -- nothing to copy
    END IF;

    -- Pre-generate new UUIDs for the target company's own report_definitions
    -- rows so child tables (columns/filters/group_levels) can be inserted
    -- against the correct NEW report_id in the same statement, same
    -- temp-table-remap pattern as fn_seed_chart_of_accounts.
    CREATE TEMP TABLE _report_id_map ON COMMIT DROP AS
    SELECT id AS old_id, gen_random_uuid() AS new_id
    FROM ric_report_definitions
    WHERE company_id = v_template_company_id AND is_deleted = false;

    INSERT INTO ric_report_definitions (
        id, client_id, company_id, report_key, report_name, report_type, source_type, source_object,
        module_code, default_sort_column, default_sort_dir, default_page_size, use_exact_count,
        max_export_rows, totals_source_object, is_active, source_object_local, totals_source_object_local,
        max_date_range_months, auto_load
    )
    SELECT
        m.new_id, p_client_id, p_company_id, d.report_key, d.report_name, d.report_type, d.source_type, d.source_object,
        d.module_code, d.default_sort_column, d.default_sort_dir, d.default_page_size, d.use_exact_count,
        d.max_export_rows, d.totals_source_object, d.is_active, d.source_object_local, d.totals_source_object_local,
        d.max_date_range_months, d.auto_load
    FROM ric_report_definitions d
    JOIN _report_id_map m ON m.old_id = d.id
    ON CONFLICT (client_id, company_id, report_key) DO NOTHING;

    INSERT INTO ric_report_columns (
        client_id, company_id, report_id, column_key, label, data_type, format, align, sortable,
        default_visible, default_width, sort_order, aggregate_fn, is_pivot_row_group, is_pivot_dimension,
        is_pivot_measure, currency_code_column, drilldown_route, drilldown_key_column, parent_key_column,
        level_column, is_active
    )
    SELECT
        p_client_id, p_company_id, m.new_id, c.column_key, c.label, c.data_type, c.format, c.align, c.sortable,
        c.default_visible, c.default_width, c.sort_order, c.aggregate_fn, c.is_pivot_row_group, c.is_pivot_dimension,
        c.is_pivot_measure, c.currency_code_column, c.drilldown_route, c.drilldown_key_column, c.parent_key_column,
        c.level_column, c.is_active
    FROM ric_report_columns c
    JOIN _report_id_map m ON m.old_id = c.report_id
    WHERE c.company_id = v_template_company_id;

    INSERT INTO ric_report_filters (
        client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column,
        static_options, param_target, required, default_value, sort_order, is_active,
        depends_on_filter_key, depends_on_column, depends_on_expand_fn
    )
    SELECT
        p_client_id, p_company_id, m.new_id, f.filter_key, f.label, f.filter_type, f.lookup_source, f.lookup_label_column,
        f.static_options, f.param_target, f.required, f.default_value, f.sort_order, f.is_active,
        f.depends_on_filter_key, f.depends_on_column, f.depends_on_expand_fn
    FROM ric_report_filters f
    JOIN _report_id_map m ON m.old_id = f.report_id
    WHERE f.company_id = v_template_company_id;

    INSERT INTO ric_report_group_levels (
        client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object
    )
    SELECT
        p_client_id, p_company_id, m.new_id, g.level_no, g.group_by_column, g.group_label_column, g.summary_source_object
    FROM ric_report_group_levels g
    JOIN _report_id_map m ON m.old_id = g.report_id
    WHERE g.company_id = v_template_company_id;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_seed_report_definitions_for_company(UUID, UUID, UUID) TO authenticated;
