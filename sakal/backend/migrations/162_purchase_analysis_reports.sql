-- ============================================================
-- Migration 162: Purchase Reports — Cross-module analysis
--   (Supplier-wise Purchase Analysis, Item-wise Purchase History,
--    Purchase Price Variance, Reorder/Replenishment)
-- ============================================================
-- Fifth and final Purchase-reporting migration. All four source their
-- "what we actually paid" figures from GRN lines (v_grn_lines, migration
-- 159) — the RECEIVED value, not the billed value — since that's the one
-- consistently-available per-line rate across both Direct and
-- Against-PO GRNs. (The design plan's original "GRN value vs Billed
-- value" toggle was simplified to GRN-value-only: Purchase Invoice has no
-- line-items of its own to break a lump sum back down to product level,
-- so a true per-product "billed value" isn't reconstructable without
-- re-deriving GRN's own line-level apportionment a second time — GRN
-- value is the correct, already-available per-product spend figure.)
--
-- Reorder/Replenishment needs no schema change — every field already
-- exists on rim_products/rim_product_location, and Open PO Qty reuses
-- v_pending_purchase_orders from migration 158.
--
-- Full design: sakal/docs/screens/artifact_purchase_reports_plan.html
-- ============================================================

-- ============================================================
-- Report 8 — Supplier-wise Purchase Analysis (GROUPED: Supplier → Product)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_supplier_purchase_analysis_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_grn_date_from DATE DEFAULT NULL,
    p_grn_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (
    supplier_id UUID, supplier_name TEXT, total_qty NUMERIC, total_value NUMERIC, grn_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT g.supplier_id, MIN(g.supplier_name), COALESCE(SUM(g.qty_received),0),
           COALESCE(SUM(g.landed_amount),0), COUNT(DISTINCT g.grn_no)
    FROM v_grn_lines g
    JOIN rim_products p ON p.id = g.product_id
    WHERE g.client_id = p_client_id AND g.company_id = p_company_id
      AND (p_grn_date_from IS NULL OR g.grn_date >= p_grn_date_from)
      AND (p_grn_date_to   IS NULL OR g.grn_date <= p_grn_date_to)
      AND (p_supplier_id   IS NULL OR g.supplier_id = p_supplier_id)
      AND (p_location_id   IS NULL OR g.location_id = p_location_id)
      AND (p_category_id   IS NULL OR p.category_id = p_category_id)
      AND (p_product_id    IS NULL OR g.product_id  = p_product_id)
    GROUP BY g.supplier_id;
$$;

GRANT EXECUTE ON FUNCTION fn_supplier_purchase_analysis_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, UUID) TO authenticated;

CREATE OR REPLACE VIEW v_supplier_purchase_analysis_lines AS
SELECT
    g.client_id, g.company_id, g.supplier_id, g.supplier_name, g.location_id,
    p.category_id,
    g.product_id, g.product_code, g.product_name,
    g.grn_no, g.grn_date,
    g.qty_received, g.rate, g.landed_amount
FROM v_grn_lines g
JOIN rim_products p ON p.id = g.product_id;

GRANT SELECT ON v_supplier_purchase_analysis_lines TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_supplier_purchase_analysis_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_grn_date_from DATE DEFAULT NULL,
    p_grn_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (qty_received NUMERIC, landed_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty_received),0), COALESCE(SUM(landed_amount),0), COUNT(*)
    FROM v_supplier_purchase_analysis_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_grn_date_from IS NULL OR grn_date >= p_grn_date_from)
      AND (p_grn_date_to   IS NULL OR grn_date <= p_grn_date_to)
      AND (p_supplier_id   IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id   IS NULL OR location_id = p_location_id)
      AND (p_category_id   IS NULL OR category_id = p_category_id)
      AND (p_product_id    IS NULL OR product_id  = p_product_id);
$$;

GRANT EXECUTE ON FUNCTION fn_supplier_purchase_analysis_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, UUID) TO authenticated;


-- ============================================================
-- Report 9 — Item-wise Purchase History (TABULAR, product-scoped)
-- ============================================================
CREATE OR REPLACE VIEW v_item_purchase_history AS
SELECT
    g.client_id, g.company_id, g.product_id,
    g.grn_no AS document_no, g.grn_date AS document_date,
    g.supplier_id, g.supplier_name, g.location_id,
    g.qty_received AS qty, g.rate,
    h.grn_currency_id AS currency_id, cur.currency_id AS currency_code,
    (g.rate * h.rate_to_base) AS rate_in_base, g.landed_amount
FROM v_grn_lines g
JOIN rih_grn_headers h ON h.client_id = g.client_id AND h.company_id = g.company_id
    AND h.grn_no = g.grn_no AND h.grn_date = g.grn_date
LEFT JOIN rim_currencies cur ON cur.id = h.grn_currency_id;

GRANT SELECT ON v_item_purchase_history TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_item_purchase_history_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_product_id  UUID,
    p_document_date_from DATE DEFAULT NULL,
    p_document_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL
) RETURNS TABLE (qty NUMERIC, landed_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty),0), COALESCE(SUM(landed_amount),0), COUNT(*)
    FROM v_item_purchase_history
    WHERE client_id = p_client_id AND company_id = p_company_id AND product_id = p_product_id
      AND (p_document_date_from IS NULL OR document_date >= p_document_date_from)
      AND (p_document_date_to   IS NULL OR document_date <= p_document_date_to)
      AND (p_supplier_id        IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id        IS NULL OR location_id = p_location_id);
$$;

GRANT EXECUTE ON FUNCTION fn_item_purchase_history_totals(UUID, UUID, UUID, DATE, DATE, UUID, UUID) TO authenticated;


-- ============================================================
-- Report 12 — Purchase Price Variance (TABULAR)
-- ============================================================
CREATE OR REPLACE VIEW v_purchase_price_variance AS
SELECT
    g.client_id, g.company_id,
    g.grn_date AS document_date, g.grn_no AS document_no,
    g.product_id, g.product_code, g.product_name,
    p.category_id,
    g.supplier_id, g.supplier_name, g.location_id,
    p.standard_cost,
    g.rate AS actual_rate,
    (g.rate - p.standard_cost) AS variance_amount,
    CASE WHEN p.standard_cost = 0 THEN NULL ELSE ((g.rate - p.standard_cost) / p.standard_cost) * 100 END AS variance_percent,
    g.qty_received,
    ((g.rate - p.standard_cost) * g.qty_received) AS total_variance_value
FROM v_grn_lines g
JOIN rim_products p ON p.id = g.product_id;

GRANT SELECT ON v_purchase_price_variance TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_purchase_price_variance_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_document_date_from DATE DEFAULT NULL,
    p_document_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL,
    p_min_variance_percent NUMERIC DEFAULT NULL
) RETURNS TABLE (total_variance_value NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(total_variance_value),0), COUNT(*)
    FROM v_purchase_price_variance
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_document_date_from IS NULL OR document_date >= p_document_date_from)
      AND (p_document_date_to   IS NULL OR document_date <= p_document_date_to)
      AND (p_supplier_id  IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id  IS NULL OR location_id = p_location_id)
      AND (p_category_id  IS NULL OR category_id = p_category_id)
      AND (p_product_id   IS NULL OR product_id  = p_product_id)
      AND (p_min_variance_percent IS NULL OR abs(variance_percent) >= p_min_variance_percent);
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_price_variance_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- Report 10 — Reorder / Replenishment (TABULAR, cross-module)
-- ============================================================
CREATE OR REPLACE VIEW v_reorder_replenishment AS
SELECT
    rpl.client_id, rpl.company_id,
    rpl.product_id, p.product_code, p.product_name, p.category_id, p.brand_id,
    rpl.location_id, loc.location_name,
    rpl.current_stock, rpl.reorder_level, rpl.min_stock_qty, rpl.max_stock_qty,
    GREATEST(rpl.max_stock_qty - rpl.current_stock, 0) AS suggested_reorder_qty,
    COALESCE((
        SELECT SUM(po.qty_pending) FROM v_pending_purchase_orders po
        WHERE po.client_id = rpl.client_id AND po.company_id = rpl.company_id
          AND po.product_id = rpl.product_id AND po.location_id = rpl.location_id
    ), 0) AS open_po_qty,
    p.main_supplier_id, ms.account_name AS main_supplier_name,
    p.lead_time_days, p.last_purchase_cost
FROM rim_product_location rpl
JOIN rim_products p ON p.id = rpl.product_id
LEFT JOIN ric_locations loc ON loc.id = rpl.location_id
LEFT JOIN rim_accounts ms ON ms.id = p.main_supplier_id
WHERE p.is_deleted = false AND p.is_active = true
AND (
    NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = rpl.client_id AND ula.company_id = rpl.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
    OR rpl.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = rpl.client_id AND ula.company_id = rpl.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
);

GRANT SELECT ON v_reorder_replenishment TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_reorder_replenishment_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_brand_id    UUID DEFAULT NULL,
    p_below_reorder_only BOOLEAN DEFAULT NULL
) RETURNS TABLE (suggested_reorder_qty NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(suggested_reorder_qty),0), COUNT(*)
    FROM v_reorder_replenishment
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_location_id IS NULL OR location_id = p_location_id)
      AND (p_category_id IS NULL OR category_id = p_category_id)
      AND (p_brand_id    IS NULL OR brand_id    = p_brand_id)
      AND (p_below_reorder_only IS NOT TRUE OR current_stock <= reorder_level);
$$;

GRANT EXECUTE ON FUNCTION fn_reorder_replenishment_totals(UUID, UUID, UUID, UUID, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Registry rows, one per existing company
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_pr_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_pr_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'PR';

        CONTINUE WHEN v_pr_module_id IS NULL;

        -- ---------------- Report 8: Supplier-wise Purchase Analysis ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SUPPLIER_PURCHASE_ANALYSIS', 'Supplier-wise Purchase Analysis',
             'TABULAR', 'VIEW', 'v_supplier_purchase_analysis_lines', 'PR', 'grn_date', 'DESC', 200,
             'fn_supplier_purchase_analysis_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_received', 'Qty', 'NUMBER', 'RIGHT', true, true, 110, 4, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Avg Rate', 'NUMBER', 'RIGHT', true, true, 110, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'landed_amount', 'Total Value', 'NUMBER', 'RIGHT', true, true, 130, 6, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'GRN Date', 'DATE_RANGE', NULL, NULL, NULL, 'grn_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP', 'rim_item_categories', 'category_name', NULL, 'category_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 5);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'supplier_id', 'supplier_name', 'fn_supplier_purchase_analysis_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-SUP', 'Supplier-wise Purchase Analysis', '/reports/SUPPLIER_PURCHASE_ANALYSIS', 8, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 9: Item-wise Purchase History ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'ITEM_PURCHASE_HISTORY', 'Item-wise Purchase History',
             'TABULAR', 'VIEW', 'v_item_purchase_history', 'PR', 'document_date', 'DESC', 200,
             'fn_item_purchase_history_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'document_date', 'Date', 'DATE', 'LEFT', true, true, 110, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'document_no', 'Document', 'TEXT', 'LEFT', true, true, 130, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty', 'Qty', 'NUMBER', 'RIGHT', true, true, 100, 4, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'currency_code', 'Currency', 'TEXT', 'LEFT', true, true, 90, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate_in_base', 'Rate (Base)', 'NUMBER', 'RIGHT', true, true, 110, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'landed_amount', 'Landed Amount', 'NUMBER', 'RIGHT', true, true, 130, 8, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', true, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'document_date', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-ITM', 'Item-wise Purchase History', '/reports/ITEM_PURCHASE_HISTORY', 9, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 12: Purchase Price Variance ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PURCHASE_PRICE_VARIANCE', 'Purchase Price Variance',
             'TABULAR', 'VIEW', 'v_purchase_price_variance', 'PR', 'document_date', 'DESC', 200,
             'fn_purchase_price_variance_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'document_date', 'Date', 'DATE', 'LEFT', true, true, 110, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'document_no', 'GRN No', 'TEXT', 'LEFT', true, true, 130, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'standard_cost', 'Standard Cost', 'NUMBER', 'RIGHT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'actual_rate', 'Actual Rate', 'NUMBER', 'RIGHT', true, true, 120, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'variance_amount', 'Variance Amount', 'NUMBER', 'RIGHT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'variance_percent', 'Variance %', 'NUMBER', 'RIGHT', true, true, 110, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_received', 'Qty', 'NUMBER', 'RIGHT', true, true, 100, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'total_variance_value', 'Total Variance Value', 'NUMBER', 'RIGHT', true, true, 150, 11, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'GRN Date', 'DATE_RANGE', NULL, NULL, NULL, 'document_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP', 'rim_item_categories', 'category_name', NULL, 'category_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'min_variance_percent', 'Variance Over % Only', 'TEXT', NULL, NULL, NULL, 'min_variance_percent', false, NULL, 6);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-PPV', 'Purchase Price Variance', '/reports/PURCHASE_PRICE_VARIANCE', 12, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 10: Reorder / Replenishment ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'REORDER_REPLENISHMENT', 'Reorder / Replenishment',
             'TABULAR', 'VIEW', 'v_reorder_replenishment', 'PR', 'product_code', 'ASC', 200,
             'fn_reorder_replenishment_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 140, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'current_stock', 'Current Stock', 'NUMBER', 'RIGHT', true, true, 120, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reorder_level', 'Reorder Level', 'NUMBER', 'RIGHT', true, true, 120, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'min_stock_qty', 'Min Stock', 'NUMBER', 'RIGHT', true, true, 110, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'max_stock_qty', 'Max Stock', 'NUMBER', 'RIGHT', true, true, 110, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'suggested_reorder_qty', 'Suggested Reorder Qty', 'NUMBER', 'RIGHT', true, true, 150, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'open_po_qty', 'Open PO Qty', 'NUMBER', 'RIGHT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'main_supplier_name', 'Main Supplier', 'TEXT', 'LEFT', true, true, 180, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'lead_time_days', 'Lead Time (days)', 'NUMBER', 'RIGHT', true, true, 120, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'last_purchase_cost', 'Last Purchase Cost', 'NUMBER', 'RIGHT', true, true, 140, 12, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP', 'rim_item_categories', 'category_name', NULL, 'category_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'brand_id', 'Brand', 'DROPDOWN_LOOKUP', 'v_product_brands', 'brand_name', NULL, 'brand_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'below_reorder_only', 'Below Reorder Level Only', 'BOOLEAN', NULL, NULL, NULL, 'below_reorder_only', false, 'true', 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-ROR', 'Reorder / Replenishment', '/reports/REORDER_REPLENISHMENT', 10, 'PR-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('PR-RPT-SUP', 'PR-RPT-ITM', 'PR-RPT-PPV', 'PR-RPT-ROR')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
