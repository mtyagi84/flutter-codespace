-- ============================================================
-- Migration 165: Sales Reports — Fulfillment & Collections stage
--   (Sales Delivery Register, Pending Deliveries, Cash Receipt Register)
-- ============================================================
-- Third and final Sales-reporting migration. Completes the 12-report plan
-- from sakal/docs/screens/artifact_sales_reports_plan.html — Purchase
-- (158-162) covered Order->GRN->Bill->Return, Sales (163-165) now covers
-- Gross Profit (163), Pipeline (164), and here: post-sale fulfillment and
-- cash collection.
-- ============================================================


-- ============================================================
-- v_sales_delivery_lines — shared base VIEW for Report 10. No financial
-- columns anywhere, per the confirmed schema fact that Sales Delivery is
-- a pure logistics document (mirrors what migration 102 itself states).
-- ============================================================
CREATE OR REPLACE VIEW v_sales_delivery_lines AS
SELECT
    h.client_id, h.company_id,
    h.delivery_no, h.delivery_date, h.status,
    h.invoice_no, h.invoice_date,
    h.customer_id, c.account_code AS customer_code, c.account_name AS customer_name,
    h.location_id, loc.location_name,
    h.ship_to_location_name, h.received_by_name, h.reason,
    l.serial_no AS line_serial,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS qty_delivered
FROM rih_sales_delivery_headers h
JOIN rid_sales_delivery_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.delivery_no = h.delivery_no AND l.delivery_date = h.delivery_date
JOIN rim_products p ON p.id = l.product_id
JOIN rim_accounts c ON c.id = h.customer_id
LEFT JOIN rim_common_masters u   ON u.id   = l.uom_id
LEFT JOIN ric_locations      loc ON loc.id = h.location_id
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

GRANT SELECT ON v_sales_delivery_lines TO anon, authenticated, service_role;


-- ============================================================
-- v_sales_invoice_delivery_status (102) — widened, additively, with
-- days_since_invoice and location-access scoping so it can be reused
-- directly as a report source (Report 11). Column list is unchanged
-- except for the new trailing column, so CREATE OR REPLACE VIEW is safe
-- (no signature/type change) — the Flutter-side badge that already reads
-- this view (Sales Invoice screens) is unaffected.
-- ============================================================
CREATE OR REPLACE VIEW v_sales_invoice_delivery_status AS
SELECT h.client_id, h.company_id, h.invoice_no, h.invoice_date, h.location_id, h.customer_id,
       sum(l.base_qty) AS total_qty,
       sum(l.delivered_qty) AS delivered_qty,
       sum(l.base_qty - l.delivered_qty) AS pending_qty,
       CASE
           WHEN sum(l.base_qty - l.delivered_qty) <= 0 THEN 'DELIVERED'
           WHEN sum(l.delivered_qty) > 0 THEN 'PARTIALLY_DELIVERED'
           ELSE 'PENDING'
       END AS delivery_status,
       (CURRENT_DATE - h.invoice_date) AS days_since_invoice
FROM rih_sales_invoices h
JOIN rid_sales_invoice_lines l
  ON l.client_id = h.client_id AND l.company_id = h.company_id
 AND l.invoice_no = h.invoice_no AND l.invoice_date = h.invoice_date
 AND l.is_deleted = false
WHERE h.stock_dispatch_mode = 'DEFERRED' AND h.status = 'APPROVED' AND h.is_deleted = false
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
GROUP BY h.client_id, h.company_id, h.invoice_no, h.invoice_date, h.location_id, h.customer_id;

GRANT SELECT ON v_sales_invoice_delivery_status TO authenticated;


-- ============================================================
-- v_cash_receipt_lines — shared base VIEW for Report 12
-- ============================================================
CREATE OR REPLACE VIEW v_cash_receipt_lines AS
SELECT
    h.client_id, h.company_id,
    h.receipt_no, h.receipt_date, h.status,
    h.customer_id, c.account_code AS customer_code, c.account_name AS customer_name,
    h.location_id, loc.location_name,
    h.local_amount AS header_local_amount, h.base_amount AS header_base_amount,
    h.crv_local_voucher_no, h.crv_base_voucher_no, h.exc_voucher_no,
    l.serial_no AS line_serial,
    l.inv_bill_no, l.inv_bill_date, l.bill_currency, l.applied_amount_local
FROM rih_cash_receipt_headers h
JOIN rid_cash_receipt_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.receipt_no = h.receipt_no AND l.receipt_date = h.receipt_date
JOIN rim_accounts c ON c.id = h.customer_id
LEFT JOIN ric_locations loc ON loc.id = h.location_id
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

GRANT SELECT ON v_cash_receipt_lines TO anon, authenticated, service_role;


-- ============================================================
-- Report 10 — Sales Delivery Register (GROUPED by Delivery)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_sales_delivery_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_delivery_date_from DATE DEFAULT NULL,
    p_delivery_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    delivery_no TEXT, delivery_date DATE, customer_name TEXT, invoice_no TEXT, invoice_date DATE,
    ship_to_location_name TEXT, received_by_name TEXT, status TEXT, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT delivery_no, delivery_date, MIN(customer_name), MIN(invoice_no), MIN(invoice_date),
           MIN(ship_to_location_name), MIN(received_by_name), MIN(status), COUNT(*)
    FROM v_sales_delivery_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_delivery_date_from IS NULL OR delivery_date >= p_delivery_date_from)
      AND (p_delivery_date_to   IS NULL OR delivery_date <= p_delivery_date_to)
      AND (p_customer_id        IS NULL OR customer_id = p_customer_id)
      AND (p_location_id        IS NULL OR location_id = p_location_id)
      AND (p_status             IS NULL OR status = p_status)
    GROUP BY delivery_no, delivery_date;
$$;

GRANT EXECUTE ON FUNCTION fn_sales_delivery_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_sales_delivery_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_delivery_date_from DATE DEFAULT NULL,
    p_delivery_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (qty_delivered NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty_delivered),0), COUNT(*)
    FROM v_sales_delivery_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_delivery_date_from IS NULL OR delivery_date >= p_delivery_date_from)
      AND (p_delivery_date_to   IS NULL OR delivery_date <= p_delivery_date_to)
      AND (p_customer_id        IS NULL OR customer_id = p_customer_id)
      AND (p_location_id        IS NULL OR location_id = p_location_id)
      AND (p_status             IS NULL OR status = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_sales_delivery_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Report 11 — Pending Deliveries (TABULAR, reuses v_sales_invoice_
-- delivery_status directly — zero new view for the report data itself)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_pending_deliveries_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_customer_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_days_since_invoice_over INTEGER DEFAULT NULL
) RETURNS TABLE (total_qty NUMERIC, delivered_qty NUMERIC, pending_qty NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(total_qty),0), COALESCE(SUM(delivered_qty),0), COALESCE(SUM(pending_qty),0), COUNT(*)
    FROM v_sales_invoice_delivery_status
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND delivery_status IN ('PENDING', 'PARTIALLY_DELIVERED')
      AND (p_customer_id IS NULL OR customer_id = p_customer_id)
      AND (p_location_id IS NULL OR location_id = p_location_id)
      AND (p_days_since_invoice_over IS NULL OR days_since_invoice >= p_days_since_invoice_over);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_deliveries_totals(
    UUID, UUID, UUID, UUID, INTEGER) TO authenticated;


-- ============================================================
-- Report 12 — Cash Receipt / Collections Register (TABULAR)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_cash_receipt_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_receipt_date_from DATE DEFAULT NULL,
    p_receipt_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (applied_amount_local NUMERIC, header_local_amount NUMERIC, header_base_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    WITH filtered AS (
        SELECT * FROM v_cash_receipt_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND (p_receipt_date_from IS NULL OR receipt_date >= p_receipt_date_from)
          AND (p_receipt_date_to   IS NULL OR receipt_date <= p_receipt_date_to)
          AND (p_customer_id       IS NULL OR customer_id = p_customer_id)
          AND (p_location_id       IS NULL OR location_id = p_location_id)
          AND (p_status            IS NULL OR status = p_status)
    ),
    headers AS (
        -- header_local_amount/header_base_amount repeat per line — sum
        -- once per (receipt_no, receipt_date) to avoid double-counting.
        SELECT DISTINCT receipt_no, receipt_date, header_local_amount, header_base_amount FROM filtered
    )
    SELECT
        COALESCE((SELECT SUM(applied_amount_local) FROM filtered), 0),
        COALESCE((SELECT SUM(header_local_amount) FROM headers), 0),
        COALESCE((SELECT SUM(header_base_amount) FROM headers), 0),
        (SELECT COUNT(*) FROM filtered);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_receipt_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT) TO authenticated;


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

        -- ---------------- Report 10: Sales Delivery Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SALES_DELIVERY_REGISTER', 'Sales Delivery Register',
             'TABULAR', 'VIEW', 'v_sales_delivery_lines', 'SL', 'delivery_date', 'DESC', 200,
             'fn_sales_delivery_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'delivery_no', 'Delivery No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'delivery_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 190, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no', 'Source Invoice No', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_date', 'Invoice Date', 'DATE', 'LEFT', true, true, 120, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'ship_to_location_name', 'Ship To', 'TEXT', 'LEFT', true, true, 160, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'received_by_name', 'Received By', 'TEXT', 'LEFT', true, true, 140, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'BADGE', 'CENTER', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_delivered', 'Qty Delivered', 'NUMBER', 'RIGHT', true, true, 130, 11, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'delivery_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, 'APPROVED', 4);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'delivery_no', 'delivery_no', 'fn_sales_delivery_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-SDR', 'Sales Delivery Register', '/reports/SALES_DELIVERY_REGISTER', 11, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 11: Pending Deliveries ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PENDING_DELIVERIES', 'Pending Deliveries',
             'TABULAR', 'VIEW', 'v_sales_invoice_delivery_status', 'SL', 'days_since_invoice', 'DESC', 200,
             'fn_pending_deliveries_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no', 'Invoice No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_since_invoice', 'Days Since Invoice', 'NUMBER', 'RIGHT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'total_qty', 'Total Qty', 'NUMBER', 'RIGHT', true, true, 110, 4, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'delivered_qty', 'Delivered Qty', 'NUMBER', 'RIGHT', true, true, 130, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'pending_qty', 'Pending Qty', 'NUMBER', 'RIGHT', true, true, 120, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'delivery_status', 'Delivery Status', 'BADGE', 'CENTER', true, true, 160, 7, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_since_invoice_over', 'Aging Over (days)', 'TEXT', NULL, NULL, NULL, 'days_since_invoice_over', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-PDL', 'Pending Deliveries', '/reports/PENDING_DELIVERIES', 12, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 12: Cash Receipt / Collections Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'CASH_RECEIPT_REGISTER', 'Cash Receipt / Collections Register',
             'TABULAR', 'VIEW', 'v_cash_receipt_lines', 'SL', 'receipt_date', 'DESC', 200,
             'fn_cash_receipt_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'receipt_no', 'Receipt No', 'TEXT', 'LEFT', true, true, 140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'receipt_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 190, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_no', 'Bill No', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_date', 'Bill Date', 'DATE', 'LEFT', true, true, 110, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_currency', 'Bill Currency', 'TEXT', 'LEFT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'applied_amount_local', 'Applied Amount', 'NUMBER', 'RIGHT', true, true, 140, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'header_local_amount', 'Local Amount', 'NUMBER', 'RIGHT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'header_base_amount', 'Base Amount', 'NUMBER', 'RIGHT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'BADGE', 'CENTER', true, true, 130, 10, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'receipt_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, 'APPROVED', 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-CRR', 'Cash Receipt / Collections Register', '/reports/CASH_RECEIPT_REGISTER', 13, 'SL-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('SL-RPT-SDR', 'SL-RPT-PDL', 'SL-RPT-CRR')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
