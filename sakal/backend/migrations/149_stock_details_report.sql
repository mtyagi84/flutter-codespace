-- ============================================================
-- Migration 149: Stock Details report (Opening/Inward/Outward/Closing)
--   + Reporting Engine: cascading (parent-scoped) lookup filters
-- ============================================================
-- Third Inventory report. Reads ril_stock_ledger directly (the immutable,
-- append-only movement log) rather than rim_product_location.current_stock
-- — Opening/Inward/Outward/Closing over an arbitrary date range has no
-- other source of truth in this schema.
--
-- Also adds a small, generic Reporting Engine capability: a filter whose
-- own option list depends on another filter's current value (here, the
-- Product filter scoped to whatever Category is selected) — user-specified
-- as something that will be reused across future Sales/Inventory reports,
-- not a one-off for this report.
--
-- Full design: sakal/docs/screens/plan_stock_details_report.md
-- ============================================================

-- ============================================================
-- Part A — Reporting Engine: cascading lookup filters (generic, engine-level)
-- ============================================================
-- All three nullable — every existing filter row is unaffected (NULL =
-- "not a cascading filter", exactly today's behavior).
ALTER TABLE ric_report_filters
    ADD COLUMN IF NOT EXISTS depends_on_filter_key TEXT,
    ADD COLUMN IF NOT EXISTS depends_on_column      TEXT,
    ADD COLUMN IF NOT EXISTS depends_on_expand_fn    TEXT;


-- ============================================================
-- Part B — ril_stock_ledger: new date-range index
-- ============================================================
-- Every existing index is (client_id, company_id, location_id, product_id)
-- or (source_doc_type, source_doc_no, source_doc_date) — neither helps an
-- unfiltered-by-product date-range scan, the common case here since
-- Location/Category/Product are all optional on this report.
CREATE INDEX IF NOT EXISTS idx_stock_ledger_client_company_date
    ON ril_stock_ledger (client_id, company_id, trans_date);


-- ============================================================
-- Part C — fn_stock_details / fn_stock_details_totals
-- ============================================================
-- No Base/Local currency split (pure quantities) and no category grouping
-- was asked for — a plain flat TABULAR report, ungrouped.
--
-- p_trans_date_from/p_trans_date_to have NO SQL-level default (unlike
-- every other optional param here) — a missing date would silently
-- produce a wrong Opening figure rather than an obvious error, so the
-- caller must always supply both.
CREATE OR REPLACE FUNCTION fn_stock_details(
    p_client_id        UUID,
    p_company_id       UUID,
    p_trans_date_from  DATE,
    p_trans_date_to    DATE,
    p_location_id      UUID DEFAULT NULL,
    p_category_id      UUID DEFAULT NULL,
    p_product_id       UUID DEFAULT NULL,
    p_include_zero     BOOLEAN DEFAULT false
) RETURNS TABLE (
    row_key       TEXT,
    barcode       TEXT,
    serial_no     TEXT,
    product_code  TEXT,
    product_name  TEXT,
    unit_name     TEXT,
    opening_qty   NUMERIC,
    inward_qty    NUMERIC,
    outward_qty   NUMERIC,
    closing_qty   NUMERIC
) LANGUAGE sql STABLE AS $$
    WITH accessible_locations AS (
        SELECT loc.id
        FROM ric_locations loc
        WHERE loc.client_id = p_client_id AND loc.company_id = p_company_id
          AND loc.is_deleted = false
          AND (p_location_id IS NULL OR loc.id = p_location_id)
          AND (
              NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                          WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                            AND ula.client_id = loc.client_id AND ula.company_id = loc.company_id
                            AND ula.is_active = true AND ula.is_deleted = false)
              OR loc.id IN (SELECT ula.location_id FROM ric_user_location_access ula
                            WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                              AND ula.client_id = loc.client_id AND ula.company_id = loc.company_id
                              AND ula.is_active = true AND ula.is_deleted = false)
          )
    ),
    -- Enumerated FROM rim_products (LEFT JOIN the ledger, not INNER) so a
    -- product with literally zero ledger history still produces a
    -- (zero-valued) row here — the only way Include Zero can surface a
    -- truly never-stocked catalog item, not just one whose net movement
    -- happens to cancel out to zero.
    non_serial AS (
        SELECT
            'P:' || p.id::text AS row_key,
            p.barcode,
            NULL::TEXT AS serial_no,
            p.product_code,
            p.product_name,
            u.description AS unit_name,
            COALESCE(SUM(sl.qty_change) FILTER (WHERE sl.trans_date < p_trans_date_from), 0) AS opening_qty,
            COALESCE(SUM(sl.qty_change) FILTER (
                WHERE sl.trans_date BETWEEN p_trans_date_from AND p_trans_date_to AND sl.qty_change > 0), 0) AS inward_qty,
            COALESCE(ABS(SUM(sl.qty_change) FILTER (
                WHERE sl.trans_date BETWEEN p_trans_date_from AND p_trans_date_to AND sl.qty_change < 0)), 0) AS outward_qty
        FROM rim_products p
        LEFT JOIN ril_stock_ledger sl
               ON sl.product_id = p.id
              AND sl.client_id = p_client_id AND sl.company_id = p_company_id
              AND sl.location_id IN (SELECT id FROM accessible_locations)
        LEFT JOIN rim_common_masters u ON u.id = p.base_uom_id
        WHERE p.client_id = p_client_id AND p.company_id = p_company_id
          AND p.is_deleted = false
          AND p.tracking_type != 'SERIAL'
          AND (p_category_id IS NULL OR p.category_id IN (SELECT id FROM fn_category_subtree(p_category_id)))
          AND (p_product_id IS NULL OR p.id = p_product_id)
        GROUP BY p.id, p.barcode, p.product_code, p.product_name, u.description
    ),
    -- serial_no only ever exists on a real ril_stock_ledger row (no
    -- separate serial master table) — driven FROM the ledger itself, so a
    -- serial-tracked product with zero history produces no row at all,
    -- even with Include Zero checked (there's no serial identity to
    -- attach a placeholder to).
    serial_rows AS (
        SELECT
            'S:' || p.id::text || ':' || sl.serial_no AS row_key,
            p.barcode,
            sl.serial_no,
            p.product_code,
            p.product_name,
            u.description AS unit_name,
            COALESCE(SUM(sl.qty_change) FILTER (WHERE sl.trans_date < p_trans_date_from), 0) AS opening_qty,
            COALESCE(SUM(sl.qty_change) FILTER (
                WHERE sl.trans_date BETWEEN p_trans_date_from AND p_trans_date_to AND sl.qty_change > 0), 0) AS inward_qty,
            COALESCE(ABS(SUM(sl.qty_change) FILTER (
                WHERE sl.trans_date BETWEEN p_trans_date_from AND p_trans_date_to AND sl.qty_change < 0)), 0) AS outward_qty
        FROM ril_stock_ledger sl
        JOIN rim_products p ON p.id = sl.product_id
        LEFT JOIN rim_common_masters u ON u.id = p.base_uom_id
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.serial_no IS NOT NULL
          AND sl.location_id IN (SELECT id FROM accessible_locations)
          AND p.tracking_type = 'SERIAL'
          AND (p_category_id IS NULL OR p.category_id IN (SELECT id FROM fn_category_subtree(p_category_id)))
          AND (p_product_id IS NULL OR p.id = p_product_id)
        GROUP BY p.id, p.barcode, p.product_code, p.product_name, u.description, sl.serial_no
    ),
    combined AS (
        SELECT row_key, barcode, serial_no, product_code, product_name, unit_name,
               opening_qty, inward_qty, outward_qty,
               (opening_qty + inward_qty - outward_qty) AS closing_qty
        FROM non_serial
        UNION ALL
        SELECT row_key, barcode, serial_no, product_code, product_name, unit_name,
               opening_qty, inward_qty, outward_qty,
               (opening_qty + inward_qty - outward_qty) AS closing_qty
        FROM serial_rows
    )
    SELECT * FROM combined
    WHERE p_include_zero
       OR opening_qty <> 0 OR inward_qty <> 0 OR outward_qty <> 0 OR closing_qty <> 0;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_details(UUID, UUID, DATE, DATE, UUID, UUID, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_stock_details_totals(
    p_client_id        UUID,
    p_company_id       UUID,
    p_trans_date_from  DATE,
    p_trans_date_to    DATE,
    p_location_id      UUID DEFAULT NULL,
    p_category_id      UUID DEFAULT NULL,
    p_product_id       UUID DEFAULT NULL,
    p_include_zero     BOOLEAN DEFAULT false
) RETURNS TABLE (
    opening_qty NUMERIC,
    inward_qty    NUMERIC,
    outward_qty     NUMERIC,
    closing_qty       NUMERIC,
    row_count           BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(opening_qty), 0), COALESCE(SUM(inward_qty), 0),
        COALESCE(SUM(outward_qty), 0), COALESCE(SUM(closing_qty), 0), COUNT(*)
    FROM fn_stock_details(p_client_id, p_company_id, p_trans_date_from, p_trans_date_to,
                           p_location_id, p_category_id, p_product_id, p_include_zero);
$$;

GRANT EXECUTE ON FUNCTION fn_stock_details_totals(UUID, UUID, DATE, DATE, UUID, UUID, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Part D — registry rows, one full set per existing company
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_in_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_in_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'IN';

        CONTINUE WHEN v_in_module_id IS NULL;

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_DETAILS', 'Stock Details',
             'TABULAR', 'FUNCTION', 'fn_stock_details', 'IN', 'product_code', 'ASC', 200,
             'fn_stock_details_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 220, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'opening_qty', 'Opening Qty', 'NUMBER', 'RIGHT', true, true, 120, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'inward_qty', 'Inward', 'NUMBER', 'RIGHT', true, true, 110, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'outward_qty', 'Outward', 'NUMBER', 'RIGHT', true, true, 110, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'closing_qty', 'Closing Qty', 'NUMBER', 'RIGHT', true, true, 120, 9, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, param_target, required, default_value, sort_order,
             depends_on_filter_key, depends_on_column, depends_on_expand_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Trans Date', 'DATE_RANGE',
                NULL, NULL, 'trans_date', true, 'THIS_MONTH', 1, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', 'location_id', false, NULL, 2, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Item Category', 'DROPDOWN_LOOKUP',
                'rim_item_categories', 'category_name', 'category_id', false, NULL, 3, NULL, NULL, NULL),
            -- Cascading: scoped to whatever category_id is currently
            -- selected above, via fn_category_subtree's own descendant
            -- expansion — same generic mechanism any future Sales/
            -- Inventory report's own parent-scoped filter can reuse.
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', 'product_id', false, NULL, 4,
                'category_id', 'category_id', 'fn_category_subtree'),
            (v_company.client_id, v_company.company_id, v_report_id, 'include_zero', 'Include Zero Activity', 'BOOLEAN',
                NULL, NULL, 'include_zero', false, 'false', 5, NULL, NULL, NULL);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SDT', 'Stock Details',
             '/reports/STOCK_DETAILS', 2, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- Part E — ric_user_menus backfill, same shape as migration 148's own
-- Part F (which itself mirrors 119's original reporting-engine pattern).
-- ============================================================
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
WHERE mm.feature_code = 'IN-RPT-SDT'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
