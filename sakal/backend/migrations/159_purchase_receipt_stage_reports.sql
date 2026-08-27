-- ============================================================
-- Migration 159: Purchase Reports — Receipt stage
--   (GRN Register, GRN Pending to Bill, Purchase Charges Register)
-- ============================================================
-- Second of five Purchase-reporting migrations. Covers what's physically
-- arrived: the GRN Register (with landed cost visible end-to-end), GRN
-- Pending to Bill (the provisional accrual v_pending_bills structurally
-- cannot see, since an unbilled GRN never carries inv_bill_no), and the
-- Purchase Charges Register (documenting, not hiding, the known gap that
-- no document in this schema ever clears a GRN charge).
--
-- Full design: sakal/docs/screens/artifact_purchase_reports_plan.html
-- ============================================================

-- ============================================================
-- v_grn_lines — shared base VIEW for Report 3 (non-serial + serial-
-- expansion UNION ALL, same convention as every other Inventory/Purchase
-- register this app has built).
-- ============================================================
CREATE OR REPLACE VIEW v_grn_lines AS
SELECT
    h.client_id, h.company_id,
    h.grn_no, h.grn_date, h.receipt_mode, h.status,
    h.location_id, loc.location_name,
    h.supplier_id, s.account_code AS supplier_code, s.account_name AS supplier_name,
    (h.billed_invoice_no IS NOT NULL) AS is_billed,
    h.grand_total,
    l.serial_no AS line_serial,
    l.source_po_order_no,
    l.barcode,
    NULL::text AS serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS qty_received,
    l.rate, l.tax_amount, l.final_amount, l.charge_amount, l.landed_amount
FROM rih_grn_headers h
JOIN rid_grn_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.grn_no = h.grn_no AND l.grn_date = h.grn_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type != 'SERIAL'
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
)

UNION ALL

SELECT
    h.client_id, h.company_id,
    h.grn_no, h.grn_date, h.receipt_mode, h.status,
    h.location_id, loc.location_name,
    h.supplier_id, s.account_code, s.account_name,
    (h.billed_invoice_no IS NOT NULL),
    h.grand_total,
    l.serial_no AS line_serial,
    l.source_po_order_no,
    l.barcode,
    ts.serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    1::NUMERIC AS qty_received,
    l.rate, l.tax_amount, l.final_amount, l.charge_amount, l.landed_amount
FROM rih_grn_headers h
JOIN rid_grn_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.grn_no = h.grn_no AND l.grn_date = h.grn_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type = 'SERIAL'
JOIN rid_transaction_line_serials ts
    ON  ts.client_id = h.client_id AND ts.company_id = h.company_id
    AND ts.source_doc_type = 'GRN' AND ts.source_doc_no = h.grn_no AND ts.source_doc_date = h.grn_date
    AND ts.line_serial = l.serial_no
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

GRANT SELECT ON v_grn_lines TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION fn_grn_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_grn_date_from DATE DEFAULT NULL,
    p_grn_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_receipt_mode TEXT DEFAULT NULL,
    p_status       TEXT DEFAULT NULL,
    p_is_billed    BOOLEAN DEFAULT NULL,
    p_product_id   UUID DEFAULT NULL
) RETURNS TABLE (
    grn_no TEXT, grn_date DATE, supplier_name TEXT, location_name TEXT, receipt_mode TEXT,
    source_po_order_no TEXT, is_billed BOOLEAN, status TEXT, grand_total NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT grn_no, grn_date, MIN(supplier_name), MIN(location_name), MIN(receipt_mode),
           MIN(source_po_order_no), bool_or(is_billed), MIN(status), MIN(grand_total), COUNT(*)
    FROM v_grn_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_grn_date_from IS NULL OR grn_date >= p_grn_date_from)
      AND (p_grn_date_to   IS NULL OR grn_date <= p_grn_date_to)
      AND (p_supplier_id   IS NULL OR supplier_id  = p_supplier_id)
      AND (p_location_id   IS NULL OR location_id  = p_location_id)
      AND (p_receipt_mode  IS NULL OR receipt_mode = p_receipt_mode)
      AND (p_status        IS NULL OR status       = p_status)
      AND (p_is_billed     IS NULL OR is_billed    = p_is_billed)
      AND (p_product_id    IS NULL OR product_id   = p_product_id)
    GROUP BY grn_no, grn_date;
$$;

GRANT EXECUTE ON FUNCTION fn_grn_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT, BOOLEAN, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_grn_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_grn_date_from DATE DEFAULT NULL,
    p_grn_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_receipt_mode TEXT DEFAULT NULL,
    p_status       TEXT DEFAULT NULL,
    p_is_billed    BOOLEAN DEFAULT NULL,
    p_product_id   UUID DEFAULT NULL
) RETURNS TABLE (qty_received NUMERIC, final_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty_received),0), COALESCE(SUM(final_amount),0), COUNT(*)
    FROM v_grn_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_grn_date_from IS NULL OR grn_date >= p_grn_date_from)
      AND (p_grn_date_to   IS NULL OR grn_date <= p_grn_date_to)
      AND (p_supplier_id   IS NULL OR supplier_id  = p_supplier_id)
      AND (p_location_id   IS NULL OR location_id  = p_location_id)
      AND (p_receipt_mode  IS NULL OR receipt_mode = p_receipt_mode)
      AND (p_status        IS NULL OR status       = p_status)
      AND (p_is_billed     IS NULL OR is_billed    = p_is_billed)
      AND (p_product_id    IS NULL OR product_id   = p_product_id);
$$;

GRANT EXECUTE ON FUNCTION fn_grn_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT, BOOLEAN, UUID) TO authenticated;


-- ============================================================
-- Report 4 — GRN Pending to Bill
-- ============================================================
CREATE OR REPLACE VIEW v_grn_pending_to_bill AS
SELECT
    h.client_id, h.company_id, h.grn_no, h.grn_date,
    (CURRENT_DATE - h.grn_date) AS days_since_grn,
    h.supplier_id, s.account_name AS supplier_name,
    h.location_id, loc.location_name,
    (SELECT l.source_po_order_no FROM rid_grn_lines l
       WHERE l.client_id = h.client_id AND l.company_id = h.company_id
         AND l.grn_no = h.grn_no AND l.grn_date = h.grn_date AND l.is_deleted = false
       LIMIT 1) AS source_po_order_no,
    (SELECT COALESCE(SUM(fl.base_amount), 0)
       FROM rid_finance_lines fl
       JOIN rih_finance_headers fh ON fh.client_id = fl.client_id AND fh.company_id = fl.company_id AND fh.trans_no = fl.trans_no
       WHERE fl.client_id = h.client_id AND fl.company_id = h.company_id
         AND fh.source_doc_type = 'GRN' AND fh.source_doc_no = h.grn_no AND fh.source_doc_date = h.grn_date
         AND fl.source_line_type = 'ACCRUAL' AND fl.is_deleted = false
    ) AS accrual_amount,
    h.grn_currency_id
FROM rih_grn_headers h
JOIN rim_accounts s ON s.id = h.supplier_id
LEFT JOIN ric_locations loc ON loc.id = h.location_id
WHERE h.is_deleted = false AND h.status = 'APPROVED' AND h.billed_invoice_no IS NULL
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

GRANT SELECT ON v_grn_pending_to_bill TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_grn_pending_to_bill_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_min_days_since_grn INTEGER DEFAULT NULL
) RETURNS TABLE (accrual_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(accrual_amount), 0), COUNT(*)
    FROM v_grn_pending_to_bill
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_supplier_id IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id IS NULL OR location_id = p_location_id)
      AND (p_min_days_since_grn IS NULL OR days_since_grn >= p_min_days_since_grn);
$$;

GRANT EXECUTE ON FUNCTION fn_grn_pending_to_bill_totals(UUID, UUID, UUID, UUID, INTEGER) TO authenticated;


-- ============================================================
-- Report 7 — Purchase Charges Register
-- ============================================================
CREATE OR REPLACE VIEW v_purchase_charges_lines AS
SELECT
    h.client_id, h.company_id, h.grn_no, h.grn_date,
    h.supplier_id, s.account_name AS supplier_name,
    h.location_id, loc.location_name,
    c.charge_name, c.nature, c.amount, c.tax_amount,
    c.gl_account_id, ga.account_name AS gl_account_name
FROM rih_grn_headers h
JOIN rid_grn_charge_lines c
    ON  c.client_id = h.client_id AND c.company_id = h.company_id
    AND c.grn_no = h.grn_no AND c.grn_date = h.grn_date
JOIN rim_accounts s ON s.id = h.supplier_id
LEFT JOIN rim_accounts ga ON ga.id = c.gl_account_id
LEFT JOIN ric_locations loc ON loc.id = h.location_id
WHERE h.is_deleted = false AND c.is_deleted = false
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

GRANT SELECT ON v_purchase_charges_lines TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_purchase_charges_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_grn_date_from DATE DEFAULT NULL,
    p_grn_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_charge_name TEXT DEFAULT NULL
) RETURNS TABLE (amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(amount), 0), COUNT(*)
    FROM v_purchase_charges_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_grn_date_from IS NULL OR grn_date >= p_grn_date_from)
      AND (p_grn_date_to   IS NULL OR grn_date <= p_grn_date_to)
      AND (p_supplier_id   IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id   IS NULL OR location_id = p_location_id)
      AND (p_charge_name   IS NULL OR charge_name = p_charge_name);
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_charges_totals(UUID, UUID, DATE, DATE, UUID, UUID, TEXT) TO authenticated;


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

        -- ---------------- Report 3: GRN Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'GRN_REGISTER', 'GRN Register',
             'TABULAR', 'VIEW', 'v_grn_lines', 'PR', 'grn_date', 'DESC', 200, 'fn_grn_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_no', 'GRN No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'receipt_mode', 'Receipt Mode', 'TEXT', 'LEFT', true, true, 120, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_po_order_no', 'Source PO No', 'TEXT', 'LEFT', true, true, 130, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_billed', 'Billed?', 'BOOLEAN', 'CENTER', true, true, 90, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'TEXT', 'LEFT', true, true, 110, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grand_total', 'Grand Total', 'NUMBER', 'RIGHT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 120, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 120, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 14, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_received', 'Qty Received', 'NUMBER', 'RIGHT', true, true, 110, 15, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 16, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_amount', 'Tax', 'NUMBER', 'RIGHT', true, true, 100, 17, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Final Amount', 'NUMBER', 'RIGHT', true, true, 130, 18, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_amount', 'Charge Amount', 'NUMBER', 'RIGHT', true, true, 120, 19, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'landed_amount', 'Landed Amount', 'NUMBER', 'RIGHT', true, true, 130, 20, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'GRN Date', 'DATE_RANGE', NULL, NULL, NULL, 'grn_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'receipt_mode', 'Receipt Mode', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"AGAINST_PO","label":"Against PO"},{"value":"DIRECT","label":"Direct"}]'::jsonb, 'receipt_mode', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, 'APPROVED', 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_billed', 'Billed?', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"true","label":"Yes"},{"value":"false","label":"No"}]'::jsonb, 'is_billed', false, NULL, 6),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 7);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'grn_no', 'grn_no', 'fn_grn_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-GRN', 'GRN Register', '/reports/GRN_REGISTER', 3, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 4: GRN Pending to Bill ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'GRN_PENDING_TO_BILL', 'GRN Pending to Bill',
             'TABULAR', 'VIEW', 'v_grn_pending_to_bill', 'PR', 'grn_date', 'ASC', 200, 'fn_grn_pending_to_bill_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_no', 'GRN No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_since_grn', 'Days Since GRN', 'NUMBER', 'RIGHT', true, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 140, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_po_order_no', 'Source PO No', 'TEXT', 'LEFT', true, true, 130, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'accrual_amount', 'Accrual Amount', 'NUMBER', 'RIGHT', true, true, 140, 7, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'min_days_since_grn', 'Aging Over (days)', 'TEXT', NULL, NULL, NULL, 'min_days_since_grn', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-GPB', 'GRN Pending to Bill', '/reports/GRN_PENDING_TO_BILL', 4, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 7: Purchase Charges Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PURCHASE_CHARGES_REGISTER', 'Purchase Charges Register',
             'TABULAR', 'VIEW', 'v_purchase_charges_lines', 'PR', 'grn_date', 'DESC', 200, 'fn_purchase_charges_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_no', 'GRN No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_name', 'Charge Type', 'TEXT', 'LEFT', true, true, 150, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'nature', 'Nature', 'TEXT', 'LEFT', true, true, 100, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'amount', 'Amount', 'NUMBER', 'RIGHT', true, true, 120, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gl_account_name', 'GL Account', 'TEXT', 'LEFT', true, true, 180, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_amount', 'Tax', 'NUMBER', 'RIGHT', true, true, 100, 9, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'GRN Date', 'DATE_RANGE', NULL, NULL, NULL, 'grn_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'charge_name', 'Charge Type', 'DROPDOWN_LOOKUP', 'rim_additional_charges', 'charge_name', NULL, 'charge_name', false, NULL, 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-CHG', 'Purchase Charges Register', '/reports/PURCHASE_CHARGES_REGISTER', 7, 'PR-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('PR-RPT-GRN', 'PR-RPT-GPB', 'PR-RPT-CHG')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
