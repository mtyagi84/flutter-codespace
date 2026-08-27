-- ============================================================
-- Migration 164: Sales Reports — Pipeline stage
--   (Sales Quotation Register, Sales Order Register,
--    Quotation Conversion Analysis, Open Sales Orders)
-- ============================================================
-- Second of three Sales-reporting migrations. Unlike Reports 1-5 (163),
-- Quotation and Order have ZERO reports today — new views needed here,
-- mirroring the exact Purchase Order Register build (migration 158)
-- shape: header+line join view, GROUPED report + group-summary function,
-- location-access scoping.
--
-- Full design: sakal/docs/screens/artifact_sales_reports_plan.html
-- ============================================================


-- ============================================================
-- v_sales_quotation_lines — shared base VIEW for Reports 6 and 8
-- ============================================================
CREATE OR REPLACE VIEW v_sales_quotation_lines AS
SELECT
    h.client_id, h.company_id,
    h.quotation_no, h.quotation_date, h.valid_until_date, h.status,
    h.customer_type, h.customer_id, h.party_name,
    h.location_id, loc.location_name,
    h.sales_person_id, se.full_name AS sales_person_name,
    h.grand_total,
    l.serial_no AS line_serial,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS qty_quoted,
    l.converted_qty,
    (l.base_qty - l.converted_qty) AS qty_unconverted,
    CASE WHEN l.base_qty = 0 THEN 0 ELSE round(l.converted_qty / l.base_qty * 100, 2) END AS conversion_percent,
    l.rate, l.discount_percent, l.tax_amount, l.final_amount,
    l.charge_amount, l.landed_amount
FROM rih_sales_quotations h
JOIN rid_sales_quotation_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.quotation_no = h.quotation_no AND l.quotation_date = h.quotation_date
JOIN rim_products p ON p.id = l.product_id
LEFT JOIN rim_common_masters      u   ON u.id   = l.uom_id
LEFT JOIN ric_locations           loc ON loc.id = h.location_id
LEFT JOIN rim_sales_executives    se  ON se.id  = h.sales_person_id
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

GRANT SELECT ON v_sales_quotation_lines TO anon, authenticated, service_role;


-- ============================================================
-- v_sales_order_lines — shared base VIEW for Report 7
-- ============================================================
CREATE OR REPLACE VIEW v_sales_order_lines AS
SELECT
    h.client_id, h.company_id,
    h.order_no, h.order_date, h.order_mode, h.source_quotation_no, h.source_quotation_date,
    h.status, h.expected_delivery_date,
    h.customer_id, c.account_code AS customer_code, c.account_name AS customer_name,
    h.location_id, loc.location_name,
    h.sales_person_id, se.full_name AS sales_person_name,
    h.grand_total,
    l.serial_no AS line_serial,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS qty_ordered,
    l.delivered_qty,
    l.rate, l.price_source, l.discount_percent, l.tax_amount, l.final_amount,
    l.charge_amount, l.landed_amount
FROM rih_sales_orders h
JOIN rid_sales_order_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.order_no = h.order_no AND l.order_date = h.order_date
JOIN rim_products p ON p.id = l.product_id
JOIN rim_accounts c ON c.id = h.customer_id
LEFT JOIN rim_common_masters      u   ON u.id   = l.uom_id
LEFT JOIN ric_locations           loc ON loc.id = h.location_id
LEFT JOIN rim_sales_executives    se  ON se.id  = h.sales_person_id
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

GRANT SELECT ON v_sales_order_lines TO anon, authenticated, service_role;


-- ============================================================
-- v_open_sales_orders — for Report 9. Status-scoped only (NOT a
-- qty-fulfillment-gap report) — delivered_qty is never written by any
-- function in this schema (Delivery links to the Invoice, never the
-- Order), so a qty-gap report here would always show a gap that's
-- either 0 or the full ordered qty, meaningless for real reporting.
-- ============================================================
CREATE OR REPLACE VIEW v_open_sales_orders AS
SELECT
    h.client_id, h.company_id,
    h.order_no, h.order_date, (CURRENT_DATE - h.order_date) AS days_open,
    h.order_mode, h.status, h.grand_total,
    h.customer_id, c.account_code AS customer_code, c.account_name AS customer_name,
    h.location_id, loc.location_name,
    h.sales_person_id, se.full_name AS sales_person_name
FROM rih_sales_orders h
JOIN rim_accounts c ON c.id = h.customer_id
LEFT JOIN ric_locations        loc ON loc.id = h.location_id
LEFT JOIN rim_sales_executives se  ON se.id  = h.sales_person_id
WHERE h.is_deleted = false AND h.status NOT IN ('DELIVERED', 'CANCELLED')
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

GRANT SELECT ON v_open_sales_orders TO anon, authenticated, service_role;


-- ============================================================
-- Report 6 — Sales Quotation Register (GROUPED by Quotation)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_sales_quotation_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_quotation_date_from DATE DEFAULT NULL,
    p_quotation_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (
    quotation_no TEXT, quotation_date DATE, party_name TEXT, sales_person_name TEXT,
    location_name TEXT, status TEXT, grand_total NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT quotation_no, quotation_date, MIN(party_name), MIN(sales_person_name),
           MIN(location_name), MIN(status), MIN(grand_total), COUNT(*)
    FROM v_sales_quotation_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_quotation_date_from IS NULL OR quotation_date >= p_quotation_date_from)
      AND (p_quotation_date_to   IS NULL OR quotation_date <= p_quotation_date_to)
      AND (p_customer_id         IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id     IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id         IS NULL OR location_id = p_location_id)
      AND (p_status              IS NULL OR status = p_status)
      AND (p_product_id          IS NULL OR product_id = p_product_id)
    GROUP BY quotation_no, quotation_date;
$$;

GRANT EXECUTE ON FUNCTION fn_sales_quotation_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_sales_quotation_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_quotation_date_from DATE DEFAULT NULL,
    p_quotation_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount),0), COUNT(*)
    FROM v_sales_quotation_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_quotation_date_from IS NULL OR quotation_date >= p_quotation_date_from)
      AND (p_quotation_date_to   IS NULL OR quotation_date <= p_quotation_date_to)
      AND (p_customer_id         IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id     IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id         IS NULL OR location_id = p_location_id)
      AND (p_status              IS NULL OR status = p_status)
      AND (p_product_id          IS NULL OR product_id = p_product_id);
$$;

GRANT EXECUTE ON FUNCTION fn_sales_quotation_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT, UUID) TO authenticated;


-- ============================================================
-- Report 7 — Sales Order Register (GROUPED by Order)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_sales_order_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_order_date_from DATE DEFAULT NULL,
    p_order_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_order_mode  TEXT DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (
    order_no TEXT, order_date DATE, customer_name TEXT, sales_person_name TEXT,
    order_mode TEXT, source_quotation_no TEXT, location_name TEXT, status TEXT,
    grand_total NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT order_no, order_date, MIN(customer_name), MIN(sales_person_name),
           MIN(order_mode), MIN(source_quotation_no), MIN(location_name), MIN(status), MIN(grand_total), COUNT(*)
    FROM v_sales_order_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_order_date_from IS NULL OR order_date >= p_order_date_from)
      AND (p_order_date_to   IS NULL OR order_date <= p_order_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_order_mode      IS NULL OR order_mode = p_order_mode)
      AND (p_status          IS NULL OR status = p_status)
      AND (p_product_id      IS NULL OR product_id = p_product_id)
    GROUP BY order_no, order_date;
$$;

GRANT EXECUTE ON FUNCTION fn_sales_order_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT, TEXT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_sales_order_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_order_date_from DATE DEFAULT NULL,
    p_order_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_order_mode  TEXT DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount),0), COUNT(*)
    FROM v_sales_order_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_order_date_from IS NULL OR order_date >= p_order_date_from)
      AND (p_order_date_to   IS NULL OR order_date <= p_order_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_order_mode      IS NULL OR order_mode = p_order_mode)
      AND (p_status          IS NULL OR status = p_status)
      AND (p_product_id      IS NULL OR product_id = p_product_id);
$$;

GRANT EXECUTE ON FUNCTION fn_sales_order_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT, TEXT, UUID) TO authenticated;


-- ============================================================
-- Report 8 — Quotation Conversion Analysis (TABULAR, one row per line)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_quotation_conversion_analysis_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_quotation_date_from DATE DEFAULT NULL,
    p_quotation_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (qty_quoted NUMERIC, converted_qty NUMERIC, qty_unconverted NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty_quoted),0), COALESCE(SUM(converted_qty),0), COALESCE(SUM(qty_unconverted),0), COUNT(*)
    FROM v_sales_quotation_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_quotation_date_from IS NULL OR quotation_date >= p_quotation_date_from)
      AND (p_quotation_date_to   IS NULL OR quotation_date <= p_quotation_date_to)
      AND (p_customer_id         IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id     IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_status              IS NULL OR status = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_quotation_conversion_analysis_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Report 9 — Open Sales Orders (TABULAR, status-scoped)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_open_sales_orders_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_order_mode  TEXT DEFAULT NULL,
    p_days_open_over INTEGER DEFAULT NULL
) RETURNS TABLE (grand_total NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(grand_total),0), COUNT(*)
    FROM v_open_sales_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_order_mode      IS NULL OR order_mode = p_order_mode)
      AND (p_days_open_over  IS NULL OR days_open >= p_days_open_over);
$$;

GRANT EXECUTE ON FUNCTION fn_open_sales_orders_totals(
    UUID, UUID, UUID, UUID, UUID, TEXT, INTEGER) TO authenticated;


-- ============================================================
-- Registry rows, one per existing company
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_sl_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_sl_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'SL';

        CONTINUE WHEN v_sl_module_id IS NULL;

        -- ---------------- Report 6: Sales Quotation Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SALES_QUOTATION_REGISTER', 'Sales Quotation Register',
             'TABULAR', 'VIEW', 'v_sales_quotation_lines', 'SL', 'quotation_date', 'DESC', 200,
             'fn_sales_quotation_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'quotation_no', 'Quotation No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'quotation_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'party_name', 'Customer / Prospect', 'TEXT', 'LEFT', true, true, 200, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_name', 'Sales Person', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'BADGE', 'CENTER', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grand_total', 'Grand Total', 'NUMBER', 'RIGHT', true, true, 130, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_quoted', 'Qty Quoted', 'NUMBER', 'RIGHT', true, true, 110, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'converted_qty', 'Qty Converted', 'NUMBER', 'RIGHT', true, true, 120, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Final Amount', 'NUMBER', 'RIGHT', true, true, 130, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_amount', 'Charge Amount', 'NUMBER', 'RIGHT', true, true, 130, 13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'landed_amount', 'Landed Amount', 'NUMBER', 'RIGHT', true, true, 130, 14, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'quotation_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"SENT","label":"Sent"},{"value":"ACCEPTED","label":"Accepted"},{"value":"REJECTED","label":"Rejected"},{"value":"PARTIALLY_CONVERTED","label":"Partially Converted"},{"value":"CONVERTED","label":"Converted"}]'::jsonb, 'status', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 6);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'quotation_no', 'quotation_no', 'fn_sales_quotation_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-SQR', 'Sales Quotation Register', '/reports/SALES_QUOTATION_REGISTER', 7, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 7: Sales Order Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SALES_ORDER_REGISTER', 'Sales Order Register',
             'TABULAR', 'VIEW', 'v_sales_order_lines', 'SL', 'order_date', 'DESC', 200,
             'fn_sales_order_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'order_no', 'Order No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 200, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_name', 'Sales Person', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_mode', 'Mode', 'BADGE', 'CENTER', true, true, 140, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_quotation_no', 'Source Quotation No', 'TEXT', 'LEFT', true, true, 150, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'BADGE', 'CENTER', true, true, 150, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grand_total', 'Grand Total', 'NUMBER', 'RIGHT', true, true, 130, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_ordered', 'Qty Ordered', 'NUMBER', 'RIGHT', true, true, 110, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'price_source', 'Price Source', 'TEXT', 'LEFT', true, true, 130, 13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Final Amount', 'NUMBER', 'RIGHT', true, true, 130, 14, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_amount', 'Charge Amount', 'NUMBER', 'RIGHT', true, true, 130, 15, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'landed_amount', 'Landed Amount', 'NUMBER', 'RIGHT', true, true, 130, 16, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'order_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_mode', 'Order Mode', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DIRECT","label":"Direct"},{"value":"AGAINST_QUOTATION","label":"Against Quotation"}]'::jsonb, 'order_mode', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"PARTIALLY_DELIVERED","label":"Partially Delivered"},{"value":"DELIVERED","label":"Delivered"},{"value":"CANCELLED","label":"Cancelled"}]'::jsonb, 'status', false, NULL, 6),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 7);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'order_no', 'order_no', 'fn_sales_order_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-SOR', 'Sales Order Register', '/reports/SALES_ORDER_REGISTER', 8, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 8: Quotation Conversion Analysis ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'QUOTATION_CONVERSION_ANALYSIS', 'Quotation Conversion Analysis',
             'TABULAR', 'VIEW', 'v_sales_quotation_lines', 'SL', 'quotation_date', 'DESC', 200,
             'fn_quotation_conversion_analysis_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'quotation_no', 'Quotation No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'quotation_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'party_name', 'Customer / Prospect', 'TEXT', 'LEFT', true, true, 190, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_quoted', 'Qty Quoted', 'NUMBER', 'RIGHT', true, true, 110, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'converted_qty', 'Qty Converted', 'NUMBER', 'RIGHT', true, true, 120, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_unconverted', 'Qty Unconverted', 'NUMBER', 'RIGHT', true, true, 130, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'conversion_percent', 'Conversion %', 'NUMBER', 'RIGHT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'BADGE', 'CENTER', true, true, 150, 10, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'quotation_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"SENT","label":"Sent"},{"value":"ACCEPTED","label":"Accepted"},{"value":"REJECTED","label":"Rejected"},{"value":"PARTIALLY_CONVERTED","label":"Partially Converted"},{"value":"CONVERTED","label":"Converted"}]'::jsonb, 'status', false, NULL, 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-QCA', 'Quotation Conversion Analysis', '/reports/QUOTATION_CONVERSION_ANALYSIS', 9, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 9: Open Sales Orders ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'OPEN_SALES_ORDERS', 'Open Sales Orders',
             'TABULAR', 'VIEW', 'v_open_sales_orders', 'SL', 'days_open', 'DESC', 200,
             'fn_open_sales_orders_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'order_no', 'Order No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_open', 'Days Open', 'NUMBER', 'RIGHT', true, true, 110, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 200, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_name', 'Sales Person', 'TEXT', 'LEFT', true, true, 150, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_mode', 'Mode', 'BADGE', 'CENTER', true, true, 140, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'BADGE', 'CENTER', true, true, 150, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grand_total', 'Grand Total', 'NUMBER', 'RIGHT', true, true, 130, 8, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_mode', 'Order Mode', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DIRECT","label":"Direct"},{"value":"AGAINST_QUOTATION","label":"Against Quotation"}]'::jsonb, 'order_mode', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_open_over', 'Aging Over (days)', 'NUMBER_INPUT', NULL, NULL, NULL, 'days_open_over', false, NULL, 5);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-OSO', 'Open Sales Orders', '/reports/OPEN_SALES_ORDERS', 10, 'SL-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('SL-RPT-SQR', 'SL-RPT-SOR', 'SL-RPT-QCA', 'SL-RPT-OSO')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
