-- ============================================================
-- Migration 158: Purchase Reports — Order stage
--   (Purchase Order Register, Pending Purchase Orders, Vendor On-Time Delivery)
-- ============================================================
-- First of five Purchase-reporting migrations (158-162) — Purchase has had
-- zero reports until now. This one covers the ORDER stage: what we've
-- asked suppliers for, what's still outstanding, and (new) whether it
-- arrived on time.
--
-- New column: rid_purchase_order_lines.expected_delivery_date — LINE
-- level, not header, since different items on one PO commonly have
-- different promised arrival dates (mirrors Odoo's own
-- purchase.order.line.date_planned design). Nullable — a PO can be saved
-- without setting it; Report 3 below simply excludes such lines from its
-- "due" logic.
--
-- Full design: sakal/docs/screens/artifact_purchase_reports_plan.html
-- ============================================================

ALTER TABLE rid_purchase_order_lines
    ADD COLUMN IF NOT EXISTS expected_delivery_date DATE;


-- ============================================================
-- v_purchase_order_lines — shared base VIEW for Reports 1 and 2.
-- Location-access scoping matches every other report this session.
-- ============================================================
CREATE OR REPLACE VIEW v_purchase_order_lines AS
SELECT
    h.client_id, h.company_id,
    h.order_no, h.order_date, h.po_type, h.payment_terms, h.status,
    h.location_id, loc.location_name,
    h.supplier_id, s.account_code AS supplier_code, s.account_name AS supplier_name,
    h.grand_total,
    l.serial_no AS line_serial,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS qty_ordered,
    l.qty_received,
    (l.base_qty - l.qty_received) AS qty_pending,
    l.rate, l.discount_percent, l.tax_amount, l.final_amount,
    l.charge_amount, l.landed_amount,
    l.expected_delivery_date
FROM rih_purchase_orders h
JOIN rid_purchase_order_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.order_no = h.order_no AND l.order_date = h.order_date
JOIN rim_products p ON p.id = l.product_id
JOIN rim_accounts s ON s.id = h.supplier_id
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

GRANT SELECT ON v_purchase_order_lines TO anon, authenticated, service_role;


-- ============================================================
-- Report 1 — Purchase Order Register (GROUPED)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_po_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_order_date_from DATE DEFAULT NULL,
    p_order_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_po_type     TEXT DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (
    order_no TEXT, order_date DATE, supplier_name TEXT, location_name TEXT,
    po_type TEXT, payment_terms TEXT, status TEXT, grand_total NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT order_no, order_date, MIN(supplier_name), MIN(location_name),
           MIN(po_type), MIN(payment_terms), MIN(status), MIN(grand_total), COUNT(*)
    FROM v_purchase_order_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_order_date_from IS NULL OR order_date >= p_order_date_from)
      AND (p_order_date_to   IS NULL OR order_date <= p_order_date_to)
      AND (p_supplier_id     IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_po_type         IS NULL OR po_type      = p_po_type)
      AND (p_status          IS NULL OR status       = p_status)
      AND (p_product_id      IS NULL OR product_id   = p_product_id)
    GROUP BY order_no, order_date;
$$;

GRANT EXECUTE ON FUNCTION fn_po_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_po_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_order_date_from DATE DEFAULT NULL,
    p_order_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_po_type     TEXT DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount), 0), COUNT(*)
    FROM v_purchase_order_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_order_date_from IS NULL OR order_date >= p_order_date_from)
      AND (p_order_date_to   IS NULL OR order_date <= p_order_date_to)
      AND (p_supplier_id     IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_po_type         IS NULL OR po_type      = p_po_type)
      AND (p_status          IS NULL OR status       = p_status)
      AND (p_product_id      IS NULL OR product_id   = p_product_id);
$$;

GRANT EXECUTE ON FUNCTION fn_po_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT, UUID) TO authenticated;


-- ============================================================
-- Report 2 — Pending Purchase Orders (TABULAR)
-- ============================================================
CREATE OR REPLACE VIEW v_pending_purchase_orders AS
SELECT *, (CURRENT_DATE - order_date) AS days_open, (qty_pending * rate) AS pending_value
FROM v_purchase_order_lines
WHERE qty_pending > 0 AND status IN ('APPROVED', 'PARTIALLY_RECEIVED');

GRANT SELECT ON v_pending_purchase_orders TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_pending_po_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_po_type     TEXT DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL,
    p_min_days_open INTEGER DEFAULT NULL
) RETURNS TABLE (qty_pending NUMERIC, pending_value NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty_pending), 0), COALESCE(SUM(pending_value), 0), COUNT(*)
    FROM v_pending_purchase_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_supplier_id IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id IS NULL OR location_id = p_location_id)
      AND (p_po_type     IS NULL OR po_type      = p_po_type)
      AND (p_product_id  IS NULL OR product_id   = p_product_id)
      AND (p_min_days_open IS NULL OR days_open >= p_min_days_open);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_po_totals(UUID, UUID, UUID, UUID, TEXT, UUID, INTEGER) TO authenticated;


-- ============================================================
-- Report 11 — Vendor On-Time Delivery
-- ============================================================
CREATE OR REPLACE VIEW v_purchase_order_delivery AS
WITH receipts AS (
    SELECT
        g.source_po_order_no, g.source_po_order_date, g.source_po_line_serial,
        h.grn_date, g.base_qty
    FROM rid_grn_lines g
    JOIN rih_grn_headers h ON h.client_id = g.client_id AND h.company_id = g.company_id
        AND h.grn_no = g.grn_no AND h.grn_date = g.grn_date
    WHERE g.is_deleted = false AND h.is_deleted = false AND h.status = 'APPROVED'
      AND g.source_po_order_no IS NOT NULL
),
receipt_rollup AS (
    SELECT
        source_po_order_no, source_po_order_date, source_po_line_serial,
        MIN(grn_date) AS first_receipt_date,
        SUM(base_qty) AS total_received,
        array_agg(grn_date ORDER BY grn_date) AS grn_dates,
        array_agg(base_qty ORDER BY grn_date) AS grn_qtys
    FROM receipts
    GROUP BY source_po_order_no, source_po_order_date, source_po_line_serial
),
fully_received AS (
    -- Walk each PO line's own receiving GRNs in date order and find the
    -- GRN at which the running total first reaches the ordered qty.
    SELECT
        l.order_no, l.order_date, l.serial_no,
        (SELECT rr.grn_dates[i]
         FROM receipt_rollup rr, generate_subscripts(rr.grn_dates, 1) AS i
         WHERE rr.source_po_order_no = l.order_no AND rr.source_po_order_date = l.order_date
           AND rr.source_po_line_serial = l.serial_no
           AND (SELECT SUM(q) FROM unnest(rr.grn_qtys[1:i]) q) >= l.base_qty
         ORDER BY i LIMIT 1) AS fully_received_date
    FROM rid_purchase_order_lines l
    WHERE l.is_deleted = false AND l.expected_delivery_date IS NOT NULL
)
SELECT
    h.client_id, h.company_id, h.order_no, h.order_date,
    h.supplier_id, s.account_name AS supplier_name,
    h.location_id, loc.location_name,
    l.serial_no AS line_serial, l.product_id, p.product_code, p.product_name,
    l.expected_delivery_date,
    rr.first_receipt_date,
    fr.fully_received_date,
    CASE WHEN fr.fully_received_date IS NOT NULL
         THEN (fr.fully_received_date - l.expected_delivery_date) END AS days_variance,
    CASE
        WHEN fr.fully_received_date IS NOT NULL AND fr.fully_received_date <= l.expected_delivery_date THEN 'Received On-Time'
        WHEN fr.fully_received_date IS NOT NULL AND fr.fully_received_date >  l.expected_delivery_date THEN 'Received Late'
        WHEN rr.first_receipt_date IS NOT NULL THEN 'Partially Received'
        WHEN l.expected_delivery_date < CURRENT_DATE THEN 'Pending'
        ELSE 'Not Yet Due'
    END AS delivery_status
FROM rih_purchase_orders h
JOIN rid_purchase_order_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.order_no = h.order_no AND l.order_date = h.order_date
JOIN rim_products p ON p.id = l.product_id
JOIN rim_accounts s ON s.id = h.supplier_id
LEFT JOIN ric_locations loc ON loc.id = h.location_id
LEFT JOIN receipt_rollup rr
    ON rr.source_po_order_no = l.order_no AND rr.source_po_order_date = l.order_date AND rr.source_po_line_serial = l.serial_no
LEFT JOIN fully_received fr
    ON fr.order_no = l.order_no AND fr.order_date = l.order_date AND fr.serial_no = l.serial_no
WHERE h.is_deleted = false AND l.is_deleted = false AND l.expected_delivery_date IS NOT NULL
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

GRANT SELECT ON v_purchase_order_delivery TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_purchase_order_delivery_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_expected_date_from DATE DEFAULT NULL,
    p_expected_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL,
    p_delivery_status TEXT DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_purchase_order_delivery
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_expected_date_from IS NULL OR expected_delivery_date >= p_expected_date_from)
      AND (p_expected_date_to   IS NULL OR expected_delivery_date <= p_expected_date_to)
      AND (p_supplier_id  IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id  IS NULL OR location_id = p_location_id)
      AND (p_product_id   IS NULL OR product_id  = p_product_id)
      AND (p_delivery_status IS NULL OR delivery_status = p_delivery_status);
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_order_delivery_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT) TO authenticated;


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

        -- ---------------- Report 1: Purchase Order Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PURCHASE_ORDER_REGISTER', 'Purchase Order Register',
             'TABULAR', 'VIEW', 'v_purchase_order_lines', 'PR', 'order_date', 'DESC', 200,
             'fn_po_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'order_no', 'Order No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'po_type', 'PO Type', 'TEXT', 'LEFT', true, true, 90, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'payment_terms', 'Payment Terms', 'TEXT', 'LEFT', true, true, 130, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'TEXT', 'LEFT', true, true, 110, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grand_total', 'Grand Total', 'NUMBER', 'RIGHT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_ordered', 'Qty Ordered', 'NUMBER', 'RIGHT', true, true, 110, 12, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_received', 'Qty Received', 'NUMBER', 'RIGHT', true, true, 110, 13, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_pending', 'Qty Pending', 'NUMBER', 'RIGHT', true, true, 110, 14, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 15, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'discount_percent', 'Discount %', 'NUMBER', 'RIGHT', true, true, 100, 16, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_amount', 'Tax', 'NUMBER', 'RIGHT', true, true, 100, 17, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Final Amount', 'NUMBER', 'RIGHT', true, true, 130, 18, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_amount', 'Charge Amount', 'NUMBER', 'RIGHT', true, true, 120, 19, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'landed_amount', 'Landed Amount', 'NUMBER', 'RIGHT', true, true, 130, 20, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Order Date', 'DATE_RANGE', NULL, NULL, NULL, 'order_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'po_type', 'PO Type', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"LOCAL","label":"Local"},{"value":"IMPORT","label":"Import"}]'::jsonb, 'po_type', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"PARTIALLY_RECEIVED","label":"Partially Received"},{"value":"CLOSED","label":"Closed"},{"value":"CANCELLED","label":"Cancelled"}]'::jsonb,
                'status', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 6);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'order_no', 'order_no', 'fn_po_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-POR', 'Purchase Order Register', '/reports/PURCHASE_ORDER_REGISTER', 1, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 2: Pending Purchase Orders ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PENDING_PURCHASE_ORDERS', 'Pending Purchase Orders',
             'TABULAR', 'VIEW', 'v_pending_purchase_orders', 'PR', 'order_date', 'ASC', 200,
             'fn_pending_po_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'order_no', 'PO No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_open', 'Days Open', 'NUMBER', 'RIGHT', true, true, 100, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 140, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_ordered', 'Qty Ordered', 'NUMBER', 'RIGHT', true, true, 110, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_received', 'Qty Received', 'NUMBER', 'RIGHT', true, true, 110, 9, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_pending', 'Qty Pending', 'NUMBER', 'RIGHT', true, true, 110, 10, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'pending_value', 'Pending Value', 'NUMBER', 'RIGHT', true, true, 130, 12, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'po_type', 'PO Type', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"LOCAL","label":"Local"},{"value":"IMPORT","label":"Import"}]'::jsonb, 'po_type', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'min_days_open', 'Aging Over (days)', 'TEXT', NULL, NULL, NULL, 'min_days_open', false, NULL, 5);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-PPO', 'Pending Purchase Orders', '/reports/PENDING_PURCHASE_ORDERS', 2, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 11: Vendor On-Time Delivery ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'VENDOR_ON_TIME_DELIVERY', 'Vendor On-Time Delivery',
             'TABULAR', 'VIEW', 'v_purchase_order_delivery', 'PR', 'expected_delivery_date', 'ASC', 200,
             'fn_purchase_order_delivery_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'order_no', 'PO No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'order_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'expected_delivery_date', 'Expected Delivery', 'DATE', 'LEFT', true, true, 140, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'first_receipt_date', 'First Receipt', 'DATE', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'fully_received_date', 'Fully Received', 'DATE', 'LEFT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_variance', 'Days Late/Early', 'NUMBER', 'RIGHT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'delivery_status', 'Delivery Status', 'BADGE', 'CENTER', true, true, 150, 10, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Expected Delivery Date', 'DATE_RANGE', NULL, NULL, NULL, 'expected_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'delivery_status', 'Delivery Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"Not Yet Due","label":"Not Yet Due"},{"value":"Pending","label":"Pending"},{"value":"Partially Received","label":"Partially Received"},{"value":"Received On-Time","label":"Received On-Time"},{"value":"Received Late","label":"Received Late"}]'::jsonb,
                'delivery_status', false, NULL, 5);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-OTD', 'Vendor On-Time Delivery', '/reports/VENDOR_ON_TIME_DELIVERY', 11, 'PR-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('PR-RPT-POR', 'PR-RPT-PPO', 'PR-RPT-OTD')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
