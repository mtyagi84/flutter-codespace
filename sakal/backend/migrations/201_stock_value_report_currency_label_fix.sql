-- ============================================================
-- Migration 201: Stock Value by Location — currency-label fix
-- ============================================================
-- Real bug found live 2026-09-20 via a Shanju screenshot: "As on Price
-- (USD)" showed the BASE-currency (ZMW) figure and "Price (CDF)" showed
-- the LOCAL-currency (USD) figure — labels and values didn't match at
-- all for a Zambia tenant (base=ZMW, local=USD; CDF isn't even Shanju's
-- currency).
--
-- Root cause: migration 148's own per-company DO-loop was "the first
-- report to build labels from each company's own base_currency/
-- local_currency" (its own comment) — a deliberate UX improvement over
-- every other report in this schema, which instead stores the generic,
-- currency-agnostic literal text "(Base)"/"(Local)" (confirmed by
-- grepping every other report's ric_report_columns.label — e.g.
-- CASH_BANK_POSITION_SUMMARY's 'Balance (Base)', PENDING_BILLS_*'s
-- 'Bill Amount (Local)'). That's fine as long as a company's own
-- registration is the thing computing the label — but
-- fn_seed_report_definitions_for_company (added 2026-09-13, after 148)
-- provisions a BRAND NEW company's ~75 reports by copying an existing
-- company's ric_report_columns rows VERBATIM, including whatever real
-- currency codes happen to be baked into these 4 labels. Every company
-- registered since then (QA Automation Co, QA Isolation Test Co,
-- SHANJU, Test India Co, Test Zambia Co — confirmed via a live query)
-- inherited the SAME "(USD)"/"(CDF)" text regardless of its own actual
-- currencies, since the copy never re-derives currency-dependent text.
-- Confirmed via a schema-wide grep: this exact bug pattern (a label with
-- a real currency code baked in) exists for ONLY these 4 columns on
-- ONLY this one report — every other report already uses the
-- copy-safe generic convention and was never at risk.
--
-- Fix, in two parts:
--   1. fn_seed_report_definitions_for_company: after copying columns,
--      re-derive these 4 specific labels from the TARGET company's own
--      base_currency/local_currency (same label templates migration 148
--      itself uses) — every future new-company registration gets this
--      right from day one, no matter which company it copies from.
--   2. One-time backfill, generic over every EXISTING company (not
--      hardcoded to Shanju) — idempotent, so a company whose label was
--      already correct (e.g. a genuine base=USD/local=CDF company) is
--      simply recomputed to the same value.
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
    v_base_ccy             TEXT;
    v_local_ccy            TEXT;
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

    -- Re-derive the 4 STOCK_VALUE_BY_LOCATION labels that bake in a real
    -- currency code -- these must NEVER be blindly copied from the
    -- template company, since the target company's own base/local
    -- currency can (and usually will) differ. Same label templates as
    -- migration 148's own per-company DO-loop.
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy
    FROM ric_companies WHERE id = p_company_id;

    IF v_base_ccy IS NOT NULL AND v_local_ccy IS NOT NULL THEN
        UPDATE ric_report_columns rc
        SET label = CASE rc.column_key
            WHEN 'price_base'  THEN 'As on Price (' || v_base_ccy  || ')'
            WHEN 'value_base'  THEN 'Value (' || v_base_ccy  || ')'
            WHEN 'price_local' THEN 'Price (' || v_local_ccy || ')'
            WHEN 'value_local' THEN 'Value (' || v_local_ccy || ')'
        END
        FROM ric_report_definitions rd
        WHERE rd.id = rc.report_id
          AND rd.company_id = p_company_id
          AND rd.report_key = 'STOCK_VALUE_BY_LOCATION'
          AND rc.column_key IN ('price_base', 'value_base', 'price_local', 'value_local');
    END IF;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- One-time backfill — generic over every existing company, idempotent
-- (a company whose label already happened to be correct is recomputed
-- to the same value).
UPDATE ric_report_columns rc
SET label = CASE rc.column_key
    WHEN 'price_base'  THEN 'As on Price (' || co.base_currency  || ')'
    WHEN 'value_base'  THEN 'Value (' || co.base_currency  || ')'
    WHEN 'price_local' THEN 'Price (' || co.local_currency || ')'
    WHEN 'value_local' THEN 'Value (' || co.local_currency || ')'
END
FROM ric_report_definitions rd
JOIN ric_companies co ON co.id = rd.company_id
WHERE rd.id = rc.report_id
  AND rd.report_key = 'STOCK_VALUE_BY_LOCATION'
  AND rc.column_key IN ('price_base', 'value_base', 'price_local', 'value_local')
  AND co.base_currency IS NOT NULL
  AND co.local_currency IS NOT NULL;
