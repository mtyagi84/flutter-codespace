-- ============================================================
-- Migration 153: Stock Adjustment Register — two report variants
--   (with / without Value)
-- ============================================================
-- Eighth Inventory report. Document-register style (one row per
-- adjustment LINE, header fields repeated), same shape/conventions as
-- Stock Transfer/Receipt Register (151/152).
--
-- Built as TWO separate ric_report_definitions rows off the SAME
-- underlying view, per explicit user correction to the first draft:
-- Unit Cost/Value must not be visible to every user. Rather than a new
-- column-level permission concept, this reuses the existing per-report
-- permission system (ric_master_menus feature_code + ric_user_menus.
-- view_allowed per user) every report in this app already has — an admin
-- grants "Stock Adjustment Register (with Value)" only to users who
-- should see cost data, same familiar workflow as every other screen.
--
-- Report A "Stock Adjustment Register" (IN-RPT-SAD) gets the normal
-- ric_user_menus backfill (everyone who already has Inventory access).
-- Report B "Stock Adjustment Register (with Value)" (IN-RPT-SAV) gets NO
-- automatic backfill — deliberately left for an admin to grant per-user.
--
-- Full design: sakal/docs/screens/plan_stock_adjustment_reports.md
-- ============================================================

-- ============================================================
-- v_stock_adjustment_reasons — small lookup view (mirrors v_product_brands, 148)
-- ============================================================
CREATE OR REPLACE VIEW v_stock_adjustment_reasons AS
SELECT
    m.id,
    m.client_id,
    m.company_id,
    m.description AS reason_name
FROM rim_common_masters m
JOIN rim_common_master_types t ON t.id = m.type_id
WHERE t.type_key = 'STOCK_ADJUSTMENT_REASON'
  AND m.is_active = true
  AND m.is_deleted = false;

GRANT SELECT ON v_stock_adjustment_reasons TO authenticated;


-- ============================================================
-- v_stock_adjustment_lines — shared base VIEW, same UNION ALL (non-serial
-- + serial-expanded) convention as v_stock_transfer_lines/
-- v_stock_receipt_lines. Always includes unit_cost/value in its own
-- SELECT regardless of which report variant is querying it — permission
-- is enforced at the report/menu level (which report a user can even
-- open), not by hiding columns inside the view itself.
--
-- Location-access scoping checks the header's OWN SINGLE location_id
-- (unlike Transfer/Receipt's from/to pair — an adjustment happens at one
-- location only).
-- ============================================================
DROP VIEW IF EXISTS v_stock_adjustment_lines;
CREATE VIEW v_stock_adjustment_lines AS
SELECT
    h.client_id, h.company_id,
    h.adjustment_no, h.adjustment_date, h.status,
    h.location_id, loc.location_name,
    COALESCE(l.reason_id, h.reason_id) AS effective_reason_id,
    r.description AS reason_name,
    h.remarks AS doc_remarks,
    l.serial_no AS line_serial,
    l.barcode,
    NULL::text AS serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    CASE WHEN l.adjust_flag = '+' THEN 'Increase' ELSE 'Decrease' END AS adjustment_type,
    l.system_qty,
    l.base_qty AS adjusted_qty,
    l.unit_cost,
    (l.base_qty * COALESCE(l.unit_cost, 0)) AS value
FROM rih_stock_adjustment_headers h
JOIN rid_stock_adjustment_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.adjustment_no = h.adjustment_no AND l.adjustment_date = h.adjustment_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type != 'SERIAL'
LEFT JOIN rim_common_masters u   ON u.id   = l.uom_id
LEFT JOIN ric_locations      loc ON loc.id = h.location_id
LEFT JOIN rim_common_masters r   ON r.id   = COALESCE(l.reason_id, h.reason_id)
WHERE h.is_deleted = false AND l.is_deleted = false
  AND (
      NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                  WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
      OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                      AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                      AND ula.is_active = true AND ula.is_deleted = false)
  )

UNION ALL

SELECT
    h.client_id, h.company_id,
    h.adjustment_no, h.adjustment_date, h.status,
    h.location_id, loc.location_name,
    COALESCE(l.reason_id, h.reason_id) AS effective_reason_id,
    r.description AS reason_name,
    h.remarks AS doc_remarks,
    l.serial_no AS line_serial,
    l.barcode,
    ts.serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    CASE WHEN l.adjust_flag = '+' THEN 'Increase' ELSE 'Decrease' END AS adjustment_type,
    l.system_qty,
    1::NUMERIC AS adjusted_qty,
    l.unit_cost,
    -- Unit Cost/Value stay at their LINE-level figure, repeated per
    -- serial row (not divided) — the line's own unit_cost is already a
    -- per-unit figure, so each serial genuinely represents unit_cost's
    -- worth of value, same as Transfer/Receipt's own per-serial qty=1
    -- convention.
    COALESCE(l.unit_cost, 0) AS value
FROM rih_stock_adjustment_headers h
JOIN rid_stock_adjustment_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.adjustment_no = h.adjustment_no AND l.adjustment_date = h.adjustment_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type = 'SERIAL'
JOIN rid_transaction_line_serials ts
    ON  ts.client_id = h.client_id AND ts.company_id = h.company_id
    AND ts.source_doc_type = 'STOCK_ADJUSTMENT'
    AND ts.source_doc_no = h.adjustment_no AND ts.source_doc_date = h.adjustment_date
    AND ts.line_serial = l.serial_no
LEFT JOIN rim_common_masters u   ON u.id   = l.uom_id
LEFT JOIN ric_locations      loc ON loc.id = h.location_id
LEFT JOIN rim_common_masters r   ON r.id   = COALESCE(l.reason_id, h.reason_id)
WHERE h.is_deleted = false AND l.is_deleted = false
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

GRANT SELECT ON v_stock_adjustment_lines TO anon, authenticated, service_role;


-- ============================================================
-- fn_stock_adjustment_register_totals — wraps the view with the report's
-- own filter params (fetchTotals always calls its target as a FUNCTION
-- even when the main report source is a VIEW, same reasoning as 151/152).
-- Shared by BOTH report variants — Report A's own ric_report_columns
-- simply never declares a 'value' column, so this function's extra
-- returned column is harmless/unused there.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_stock_adjustment_register_totals(
    p_client_id          UUID,
    p_company_id         UUID,
    p_adjustment_date_from DATE DEFAULT NULL,
    p_adjustment_date_to   DATE DEFAULT NULL,
    p_location_id        UUID DEFAULT NULL,
    p_effective_reason_id UUID DEFAULT NULL,
    p_adjustment_type     TEXT DEFAULT NULL,
    p_status              TEXT DEFAULT NULL
) RETURNS TABLE (
    adjusted_qty NUMERIC,
    value          NUMERIC,
    row_count        BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(adjusted_qty), 0), COALESCE(SUM(value), 0), COUNT(*)
    FROM v_stock_adjustment_lines
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_adjustment_date_from IS NULL OR adjustment_date >= p_adjustment_date_from)
      AND (p_adjustment_date_to   IS NULL OR adjustment_date <= p_adjustment_date_to)
      AND (p_location_id          IS NULL OR location_id          = p_location_id)
      AND (p_effective_reason_id  IS NULL OR effective_reason_id  = p_effective_reason_id)
      AND (p_adjustment_type      IS NULL OR adjustment_type      = p_adjustment_type)
      AND (p_status                IS NULL OR status                = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_stock_adjustment_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT) TO authenticated;


-- ============================================================
-- Registry rows, one full set per existing company — TWO report
-- definitions off the same source_object.
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

        -- ============================================================
        -- Report A — Stock Adjustment Register (Qty only)
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_ADJUSTMENT_REGISTER', 'Stock Adjustment Register',
             'TABULAR', 'VIEW', 'v_stock_adjustment_lines', 'IN', 'adjustment_date', 'DESC', 200,
             'fn_stock_adjustment_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_no', 'Adjustment No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_date', 'Adjustment Date', 'DATE', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_name', 'Reason', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_remarks', 'Remarks', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'BADGE', 'CENTER', true, true, 130, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'system_qty', 'System Qty', 'NUMBER', 'RIGHT', true, true, 110, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjusted_qty', 'Adjusted Qty', 'NUMBER', 'RIGHT', true, true, 120, 13, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Adjustment Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'adjustment_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_id', 'Reason', 'DROPDOWN_LOOKUP',
                'v_stock_adjustment_reasons', 'reason_name', NULL, 'effective_reason_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"Increase","label":"Increase"},{"value":"Decrease","label":"Decrease"}]'::jsonb,
                'adjustment_type', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb,
                'status', false, 'APPROVED', 5);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SAD', 'Stock Adjustment Register',
             '/reports/STOCK_ADJUSTMENT_REGISTER', 7, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ============================================================
        -- Report B — Stock Adjustment Register (with Value)
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_ADJUSTMENT_REGISTER_VALUE', 'Stock Adjustment Register (with Value)',
             'TABULAR', 'VIEW', 'v_stock_adjustment_lines', 'IN', 'adjustment_date', 'DESC', 200,
             'fn_stock_adjustment_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_no', 'Adjustment No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_date', 'Adjustment Date', 'DATE', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_name', 'Reason', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_remarks', 'Remarks', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'BADGE', 'CENTER', true, true, 130, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'system_qty', 'System Qty', 'NUMBER', 'RIGHT', true, true, 110, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjusted_qty', 'Adjusted Qty', 'NUMBER', 'RIGHT', true, true, 120, 13, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_cost', 'Unit Cost', 'NUMBER', 'RIGHT', true, true, 110, 14, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'value', 'Value', 'NUMBER', 'RIGHT', true, true, 130, 15, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Adjustment Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'adjustment_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_id', 'Reason', 'DROPDOWN_LOOKUP',
                'v_stock_adjustment_reasons', 'reason_name', NULL, 'effective_reason_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"Increase","label":"Increase"},{"value":"Decrease","label":"Decrease"}]'::jsonb,
                'adjustment_type', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb,
                'status', false, 'APPROVED', 5);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SAV', 'Stock Adjustment Register (with Value)',
             '/reports/STOCK_ADJUSTMENT_REGISTER_VALUE', 8, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- ric_user_menus backfill — Report A ONLY. Report B (with Value)
-- deliberately gets NO automatic backfill, per the user's own explicit
-- requirement — cost/value data must not be retroactively exposed to
-- every existing Inventory user. An admin grants IN-RPT-SAV per-user
-- afterward via the standard user-permission screen.
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
WHERE mm.feature_code = 'IN-RPT-SAD'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
