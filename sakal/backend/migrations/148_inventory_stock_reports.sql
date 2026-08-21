-- ============================================================
-- Migration 148: Reporting Engine "manual-run gate" + Inventory reports
--   1. Location scoping on the existing Stock Balance by Location report
--   2. New Stock Value by Location report
-- ============================================================
-- User-raised concern (verbatim, paraphrased in the plan doc): a report
-- whose row count scales with the product catalog (50,000+ products) must
-- not auto-fire an unfiltered query the instant the menu is clicked — the
-- user should set filters on a parameter screen first, then explicitly
-- run it, same as Odoo/SAP's classic wizard-then-print pattern for heavy
-- reports. This is layered ON TOP OF (not a replacement for) the existing
-- grouped-TABULAR lazy fetch (report_data_controller.dart's
-- _loadRootGroups()/expandNode() — already fetches only level-1 summary
-- rows on load, full detail only on group-expand) — that mechanism keeps
-- 50k rows from ever being rendered/fetched at once AFTER first load; this
-- migration's new auto_load flag stops the FIRST load itself from firing
-- automatically on screens where even that first summary scan is too
-- risky to run unfiltered.
--
-- Full design: sakal/docs/screens/plan_inventory_stock_reports.md
-- ============================================================

-- ============================================================
-- Part A — Reporting Engine: auto_load (generic, engine-level)
-- ============================================================
-- Default true: every existing report's behavior is completely unchanged
-- by this column's addition. Only reports explicitly set to false (Part B
-- and Part E below) show the new "Run Report" gate instead of auto-fetching.
ALTER TABLE ric_report_definitions
    ADD COLUMN IF NOT EXISTS auto_load BOOLEAN NOT NULL DEFAULT true;


-- ============================================================
-- Part B — Stock Balance by Location: real row-level location scoping
-- ============================================================
-- Real access-control gap: this view (118) has never filtered by the
-- viewing user's own ric_user_location_access rows at all — any user with
-- report access saw every location's stock. Same JWT-scoped WHERE block as
-- v_user_accessible_locations (127) — that view's own "zero active rows =
-- unrestricted, any rows = limited to that set" convention, inlined here
-- since this is a plain view over rim_product_location, not a
-- parameterized function.
CREATE OR REPLACE VIEW v_stock_balance_matrix_source AS
SELECT
    pl.client_id,
    pl.company_id,
    pl.product_id,
    p.product_code,
    p.product_name,
    pl.location_id,
    l.location_name,
    pl.current_stock
FROM rim_product_location pl
JOIN rim_products   p ON p.id = pl.product_id
JOIN ric_locations  l ON l.id = pl.location_id
WHERE pl.is_active = true
  AND (
      NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                  WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = pl.client_id AND ula.company_id = pl.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
      OR pl.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                      AND ula.client_id = pl.client_id AND ula.company_id = pl.company_id
                      AND ula.is_active = true AND ula.is_deleted = false)
  );

GRANT SELECT ON v_stock_balance_matrix_source TO authenticated;

-- New Location filter — location_id is a real column on the view above,
-- so this is a plain PostgREST column filter, no signature change needed.
INSERT INTO ric_report_filters
    (client_id, company_id, report_id, filter_key, label, filter_type,
     lookup_source, lookup_label_column, param_target, sort_order)
SELECT
    rd.client_id, rd.company_id, rd.id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
    'v_user_accessible_locations', 'location_name', 'location_id', 2
FROM ric_report_definitions rd
WHERE rd.report_key = 'STOCK_BALANCE_MATRIX'
ON CONFLICT (report_id, filter_key) DO NOTHING;

-- Gate it behind the new "Run Report" screen too (confirmed with the user
-- while already touching this report — same unbounded-row-count risk).
UPDATE ric_report_definitions SET auto_load = false WHERE report_key = 'STOCK_BALANCE_MATRIX';


-- ============================================================
-- Part C — v_product_brands: new filter lookup
-- ============================================================
-- rim_products.brand_id already references rim_common_masters
-- (type_key='BRAND') — this is just that existing convention exposed as
-- its own standalone lookup view for a report filter's lookup_source,
-- same shape as v_user_accessible_locations.
CREATE OR REPLACE VIEW v_product_brands AS
SELECT
    m.id,
    m.client_id,
    m.company_id,
    m.description AS brand_name
FROM rim_common_masters m
JOIN rim_common_master_types t ON t.id = m.type_id
WHERE t.type_key = 'BRAND'
  AND m.is_active = true
  AND m.is_deleted = false;

GRANT SELECT ON v_product_brands TO authenticated;


-- ============================================================
-- Part D — Stock Value by Location: fn_stock_value_by_location
-- ============================================================
-- One row per product (aggregated across every in-scope location) or, for
-- a serial-tracked product, one row per serial currently IN_STOCK — never
-- a location column (Location is filter-only; the PDF header prints the
-- selected location name or "All Locations" — Flutter-side, no SQL here).
-- Balance Qty / Value / As-on Price are all summed/derived across the
-- accessible-and-selected location set:
--   qty         = SUM(current_stock)
--   value       = SUM(current_stock * cost_price)
--   price       = value / qty            -- quantity-weighted average
-- Zero-balance rows are excluded (qty > 0). Current-moment only — no
-- As-Of-Date filter, reads rim_product_location directly, matching the
-- existing Stock Balance report's own precedent.
--
-- Base AND local columns are returned TOGETHER on the same row (not a
-- Base/Local currency TOGGLE, unlike Sales Register's own
-- source_object_local mechanism) — this report needs group-level
-- subtotals (ric_report_group_levels), and ReportDataController's own
-- grouped-tree fetch path (_loadRootGroups/expandNode) deliberately does
-- not consult currencyMode/sourceObjectLocal yet (see report_models.dart's
-- ReportDefinition.sourceObjectLocal doc comment) — so a toggle-based twin
-- function would silently never switch for this report. One function
-- computing both currencies at once sidesteps that gap entirely, and
-- matches what the user actually asked for: both Price/Value pairs shown
-- as columns simultaneously, not a switch between them.
CREATE OR REPLACE FUNCTION fn_stock_value_by_location(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_brand_id    UUID DEFAULT NULL
) RETURNS TABLE (
    row_key                 TEXT,
    barcode                 TEXT,
    serial_no               TEXT,
    product_code             TEXT,
    product_name             TEXT,
    unit_name                TEXT,
    balance_qty              NUMERIC,
    price_base                NUMERIC,
    value_base                 NUMERIC,
    price_local                 NUMERIC,
    value_local                   NUMERIC,
    top_level_category_name        TEXT
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base_ccy  TEXT;
    v_local_ccy TEXT;
BEGIN
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy
    FROM ric_companies WHERE id = p_company_id;

    RETURN QUERY
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
    -- Walk each matching product's category up to its level-1 ("Main")
    -- ancestor — same recursive technique as 032's own CATEGORY account-
    -- link resolution, adapted to select the root (parent_id IS NULL)
    -- instead of the nearest configured ancestor.
    top_category AS (
        SELECT DISTINCT ON (start_id)
            start_id AS category_id, c.category_name AS top_level_category_name
        FROM (
            WITH RECURSIVE ancestors AS (
                SELECT c.id AS start_id, c.id, c.parent_id, 0 AS depth
                FROM rim_item_categories c
                WHERE c.client_id = p_client_id AND c.company_id = p_company_id
                UNION ALL
                SELECT a.start_id, c.id, c.parent_id, a.depth + 1
                FROM rim_item_categories c
                JOIN ancestors a ON c.id = a.parent_id
            )
            SELECT start_id, id, parent_id, depth FROM ancestors
        ) walked
        JOIN rim_item_categories c ON c.id = walked.id
        WHERE walked.parent_id IS NULL
        ORDER BY start_id, depth DESC
    ),
    -- Per-location base->local rate. fn_get_exchange_rate already
    -- short-circuits to 1 when the two currencies are equal, so a
    -- single-currency company pays no extra lookup cost of consequence.
    loc_rates AS (
        SELECT id AS location_id,
               fn_get_exchange_rate(p_company_id, id, v_base_ccy, v_local_ccy, CURRENT_DATE) AS rate
        FROM accessible_locations
    ),
    non_serial_rows AS (
        SELECT
            'P:' || p.id::text AS row_key,
            p.barcode,
            NULL::TEXT AS serial_no,
            p.product_code,
            p.product_name,
            u.description AS unit_name,
            SUM(pl.current_stock) AS balance_qty,
            CASE WHEN SUM(pl.current_stock) = 0 THEN 0
                 ELSE SUM(pl.current_stock * pl.cost_price) / SUM(pl.current_stock) END AS price_base,
            SUM(pl.current_stock * pl.cost_price) AS value_base,
            CASE WHEN SUM(pl.current_stock) = 0 THEN 0
                 ELSE SUM(pl.current_stock * pl.cost_price * lr.rate) / SUM(pl.current_stock) END AS price_local,
            SUM(pl.current_stock * pl.cost_price * lr.rate) AS value_local,
            COALESCE(tc.top_level_category_name, 'Uncategorized') AS top_level_category_name
        FROM rim_product_location pl
        JOIN rim_products p ON p.id = pl.product_id
        JOIN loc_rates lr ON lr.location_id = pl.location_id
        LEFT JOIN rim_common_masters u ON u.id = p.base_uom_id
        LEFT JOIN top_category tc ON tc.category_id = p.category_id
        WHERE pl.client_id = p_client_id AND pl.company_id = p_company_id
          AND pl.is_active = true
          AND pl.location_id IN (SELECT id FROM accessible_locations)
          AND p.tracking_type != 'SERIAL'
          AND (p_category_id IS NULL OR p.category_id IN (SELECT id FROM fn_category_subtree(p_category_id)))
          AND (p_brand_id IS NULL OR p.brand_id = p_brand_id)
        GROUP BY p.id, p.barcode, p.product_code, p.product_name, u.description, tc.top_level_category_name
        HAVING SUM(pl.current_stock) > 0
    ),
    serial_rows AS (
        SELECT
            'S:' || p.id::text || ':' || s.serial_no AS row_key,
            p.barcode,
            s.serial_no,
            p.product_code,
            p.product_name,
            u.description AS unit_name,
            1::NUMERIC AS balance_qty,
            pl.cost_price AS price_base,
            pl.cost_price AS value_base,
            pl.cost_price * lr.rate AS price_local,
            pl.cost_price * lr.rate AS value_local,
            COALESCE(tc.top_level_category_name, 'Uncategorized') AS top_level_category_name
        FROM v_serial_stock_status s
        JOIN rim_products p ON p.id = s.product_id
        JOIN rim_product_location pl
            ON pl.client_id = s.client_id AND pl.company_id = s.company_id
           AND pl.location_id = s.location_id AND pl.product_id = s.product_id
        JOIN loc_rates lr ON lr.location_id = s.location_id
        LEFT JOIN rim_common_masters u ON u.id = p.base_uom_id
        LEFT JOIN top_category tc ON tc.category_id = p.category_id
        WHERE s.client_id = p_client_id AND s.company_id = p_company_id
          AND s.status = 'IN_STOCK'
          AND s.location_id IN (SELECT id FROM accessible_locations)
          AND (p_category_id IS NULL OR p.category_id IN (SELECT id FROM fn_category_subtree(p_category_id)))
          AND (p_brand_id IS NULL OR p.brand_id = p_brand_id)
    )
    SELECT * FROM non_serial_rows
    UNION ALL
    SELECT * FROM serial_rows;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_value_by_location(UUID, UUID, UUID, UUID, UUID) TO authenticated;

-- Level-1 group summary — subtotal by top-level ("Main") category, same
-- shape as fn_pending_bills_summary_by_customer (118) / Ageing's own
-- per-currency summary functions (137). No ancestor-key parameter needed
-- — this is a 1-level report, same as Ageing's own single-level grouping.
CREATE OR REPLACE FUNCTION fn_stock_value_by_location_summary(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_brand_id    UUID DEFAULT NULL
) RETURNS TABLE (
    top_level_category_name TEXT,
    balance_qty              NUMERIC,
    value_base                 NUMERIC,
    value_local                   NUMERIC,
    row_count                       BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        top_level_category_name,
        COALESCE(SUM(balance_qty), 0),
        COALESCE(SUM(value_base), 0),
        COALESCE(SUM(value_local), 0),
        COUNT(*)
    FROM fn_stock_value_by_location(p_client_id, p_company_id, p_location_id, p_category_id, p_brand_id)
    GROUP BY top_level_category_name;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_value_by_location_summary(UUID, UUID, UUID, UUID, UUID) TO authenticated;

-- No separate report-level totals function: this report is grouped
-- (ric_report_group_levels below), and ReportDataController.refresh()'s
-- grouped path never calls fetchTotals at all — the grand total is
-- instead free client-side arithmetic over the already-loaded level-1
-- summary rows (ReportDataController.groupedGrandTotal, summing each
-- aggregate_fn column across bundle.aggregateColumns). Same reason
-- migration 118's own Pilot 2 (Pending Bills by Customer, also grouped)
-- sets no totals_source_object either — confirmed by reading that INSERT.


-- ============================================================
-- Part E — registry rows, one full set per existing company
-- ============================================================
-- The one genuinely new registry usage this migration needs: dynamic,
-- per-company currency-code column labels. Every prior report's per-
-- company DO-loop inserts identical static label text — this is the
-- first to build labels from each company's own base_currency/
-- local_currency, and to skip the Local column pair entirely when they're
-- equal (same precedent as Ageing's own currency-columns-sometimes-
-- irrelevant handling, 137).
DO $$
DECLARE
    v_company RECORD;
    v_in_module_id UUID;
    v_report_id UUID;
    v_base_ccy TEXT;
    v_local_ccy TEXT;
    v_same_ccy BOOLEAN;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id, base_currency, local_currency FROM ric_companies LOOP

        SELECT id INTO v_in_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'IN';

        CONTINUE WHEN v_in_module_id IS NULL;

        v_base_ccy  := COALESCE(v_company.base_currency, 'Base');
        v_local_ccy := COALESCE(v_company.local_currency, 'Local');
        v_same_ccy  := (v_company.base_currency IS NOT NULL AND v_company.base_currency = v_company.local_currency);

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_VALUE_BY_LOCATION', 'Stock Value by Location',
             'TABULAR', 'FUNCTION', 'fn_stock_value_by_location', 'IN', 'product_code', 'ASC', 200, false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, auto_load = excluded.auto_load
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
            (v_company.client_id, v_company.company_id, v_report_id, 'balance_qty', 'Balance Qty', 'NUMBER', 'RIGHT', true, true, 110, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'price_base', 'As on Price (' || v_base_ccy || ')', 'NUMBER', 'RIGHT', true, true, 140, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'value_base', 'Value (' || v_base_ccy || ')', 'NUMBER', 'RIGHT', true, true, 140, 8, 'SUM'),
            -- group-level label column, hidden from the grid itself (same convention as
            -- fn_pending_bills_summary_by_customer's account_label — populated on SUMMARY
            -- rows only, harmless on detail rows).
            (v_company.client_id, v_company.company_id, v_report_id, 'top_level_category_name', 'Category', 'TEXT', 'LEFT', false, false, 160, 9, NULL);

        -- Local-currency columns only when base != local — a single-
        -- currency company genuinely shows only one Price/Value pair.
        IF NOT v_same_ccy THEN
            INSERT INTO ric_report_columns
                (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
                 default_width, sort_order, aggregate_fn)
            VALUES
                (v_company.client_id, v_company.company_id, v_report_id, 'price_local', 'Price (' || v_local_ccy || ')', 'NUMBER', 'RIGHT', true, true, 140, 10, NULL),
                (v_company.client_id, v_company.company_id, v_report_id, 'value_local', 'Value (' || v_local_ccy || ')', 'NUMBER', 'RIGHT', true, true, 140, 11, 'SUM');
        END IF;

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, param_target, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
             'v_user_accessible_locations', 'location_name', 'location_id', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Item Category', 'DROPDOWN_LOOKUP',
             'rim_item_categories', 'category_name', 'category_id', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'brand_id', 'Brand', 'DROPDOWN_LOOKUP',
             'v_product_brands', 'brand_name', 'brand_id', 3);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'top_level_category_name', 'top_level_category_name',
             'fn_stock_value_by_location_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SVL', 'Stock Value by Location',
             '/reports/STOCK_VALUE_BY_LOCATION', 1, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- Part F — ric_user_menus backfill, same shape/pattern as migration 119's
-- own reporting-engine-pilot backfill (a ric_master_menus row alone makes
-- a feature ELIGIBLE, it grants nobody anything — fn_get_user_menu, the
-- sidebar builder, reads ric_user_menus per-USER grants separately).
-- Grants VIEW access to the new report for every user who already has
-- view access to any Inventory (IN) feature — "if you can already use
-- Inventory, you can now see the new stock-value report too."
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
WHERE mm.feature_code = 'IN-RPT-SVL'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
