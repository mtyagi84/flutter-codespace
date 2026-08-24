-- ============================================================
-- Migration 152: Stock Receipt Register report
-- ============================================================
-- Seventh Inventory report. Document-register style (one row per receipt
-- LINE, header fields repeated), same shape/conventions as the Stock
-- Transfer Register (151) but sourced from rih_stock_receipts/
-- rid_stock_receipt_lines — a receipt is its own document with its own
-- receipt_no/receipt_date and its own RECEIVED quantity (which can be
-- less than what was transferred), never the transfer's own qty.
--
-- Carries the originating Transfer No/Date (rih_stock_receipts.
-- source_transfer_no/date) and, one hop further, that transfer's own
-- source_request_no/date (rih_stock_transfers) — same "if available"
-- reference-column convention as the Transfer Register's own Request No.
--
-- Short Received = per-line shortfall (transferred qty − received qty,
-- floored at 0) shown as its own column on every row — not a separate
-- filtered report this time, since the user wants ALL receipts with the
-- shortfall visible inline, not just the short ones.
--
-- Full design: sakal/docs/screens/plan_stock_receipt_report.md
-- ============================================================

-- ============================================================
-- v_stock_receipt_lines — base VIEW, same UNION ALL (non-serial + serial-
-- expanded) convention as v_stock_transfer_lines (151). Serial expansion
-- uses the RECEIPT's own rid_transaction_line_serials rows
-- (source_doc_type='STOCK_RECEIPT') — this report is about what was
-- actually received, not what was originally transferred.
-- ============================================================
DROP VIEW IF EXISTS v_stock_receipt_lines;
CREATE VIEW v_stock_receipt_lines AS
SELECT
    h.client_id, h.company_id,
    h.receipt_no, h.receipt_date, h.status,
    h.source_transfer_no AS transfer_no, h.source_transfer_date AS transfer_date,
    h.from_location_id, loc_from.location_name AS from_location_name,
    h.to_location_id, loc_to.location_name AS to_location_name,
    th.source_request_no, th.source_request_date,
    h.remarks AS doc_remarks,
    l.serial_no AS line_serial,
    l.barcode,
    NULL::text AS serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.received_base_qty AS received_qty,
    GREATEST(COALESCE(tline.base_qty, 0) - l.received_base_qty, 0) AS short_received
FROM rih_stock_receipts h
JOIN rid_stock_receipt_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.receipt_no = h.receipt_no AND l.receipt_date = h.receipt_date
LEFT JOIN rih_stock_transfers th
    ON  th.client_id = h.client_id AND th.company_id = h.company_id
    AND th.transfer_no = h.source_transfer_no AND th.transfer_date = h.source_transfer_date
LEFT JOIN rid_stock_transfer_lines tline
    ON  tline.client_id = h.client_id AND tline.company_id = h.company_id
    AND tline.transfer_no = h.source_transfer_no AND tline.transfer_date = h.source_transfer_date
    AND tline.serial_no = l.source_transfer_line_serial
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type != 'SERIAL'
LEFT JOIN rim_common_masters u       ON u.id       = l.uom_id
LEFT JOIN ric_locations      loc_from ON loc_from.id = h.from_location_id
LEFT JOIN ric_locations      loc_to   ON loc_to.id   = h.to_location_id
WHERE h.is_deleted = false AND l.is_deleted = false
  AND (
      NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                  WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
      OR h.from_location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                      AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                      AND ula.is_active = true AND ula.is_deleted = false)
      OR h.to_location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                      AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                      AND ula.is_active = true AND ula.is_deleted = false)
  )

UNION ALL

SELECT
    h.client_id, h.company_id,
    h.receipt_no, h.receipt_date, h.status,
    h.source_transfer_no AS transfer_no, h.source_transfer_date AS transfer_date,
    h.from_location_id, loc_from.location_name AS from_location_name,
    h.to_location_id, loc_to.location_name AS to_location_name,
    th.source_request_no, th.source_request_date,
    h.remarks AS doc_remarks,
    l.serial_no AS line_serial,
    l.barcode,
    ts.serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    1::NUMERIC AS received_qty,
    0::NUMERIC AS short_received   -- a physically-scanned received serial is, by definition, not short
FROM rih_stock_receipts h
JOIN rid_stock_receipt_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.receipt_no = h.receipt_no AND l.receipt_date = h.receipt_date
LEFT JOIN rih_stock_transfers th
    ON  th.client_id = h.client_id AND th.company_id = h.company_id
    AND th.transfer_no = h.source_transfer_no AND th.transfer_date = h.source_transfer_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type = 'SERIAL'
JOIN rid_transaction_line_serials ts
    ON  ts.client_id = h.client_id AND ts.company_id = h.company_id
    AND ts.source_doc_type = 'STOCK_RECEIPT'
    AND ts.source_doc_no = h.receipt_no AND ts.source_doc_date = h.receipt_date
    AND ts.line_serial = l.serial_no
LEFT JOIN rim_common_masters u       ON u.id       = l.uom_id
LEFT JOIN ric_locations      loc_from ON loc_from.id = h.from_location_id
LEFT JOIN ric_locations      loc_to   ON loc_to.id   = h.to_location_id
WHERE h.is_deleted = false AND l.is_deleted = false
  AND (
      NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                  WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
      OR h.from_location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                      AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                      AND ula.is_active = true AND ula.is_deleted = false)
      OR h.to_location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                      AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                      AND ula.is_active = true AND ula.is_deleted = false)
  );

GRANT SELECT ON v_stock_receipt_lines TO anon, authenticated, service_role;


-- ============================================================
-- fn_stock_receipt_register_totals — wraps the view with the report's own
-- filter params (fetchTotals always calls its target as a FUNCTION even
-- when the main report source is a VIEW, same reasoning as 151).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_stock_receipt_register_totals(
    p_client_id       UUID,
    p_company_id      UUID,
    p_receipt_date_from DATE DEFAULT NULL,
    p_receipt_date_to   DATE DEFAULT NULL,
    p_from_location_id UUID DEFAULT NULL,
    p_to_location_id   UUID DEFAULT NULL,
    p_status           TEXT DEFAULT NULL
) RETURNS TABLE (
    received_qty   NUMERIC,
    short_received   NUMERIC,
    row_count          BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(received_qty), 0), COALESCE(SUM(short_received), 0), COUNT(*)
    FROM v_stock_receipt_lines
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_receipt_date_from IS NULL OR receipt_date >= p_receipt_date_from)
      AND (p_receipt_date_to   IS NULL OR receipt_date <= p_receipt_date_to)
      AND (p_from_location_id  IS NULL OR from_location_id = p_from_location_id)
      AND (p_to_location_id    IS NULL OR to_location_id   = p_to_location_id)
      AND (p_status            IS NULL OR status           = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_stock_receipt_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Registry rows, one full set per existing company
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
            (v_company.client_id, v_company.company_id, 'STOCK_RECEIPT_REGISTER', 'Stock Receipt Register',
             'TABULAR', 'VIEW', 'v_stock_receipt_lines', 'IN', 'receipt_date', 'DESC', 200,
             'fn_stock_receipt_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'receipt_no', 'Receipt No', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'receipt_date', 'Receipt Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_no', 'Transfer No', 'TEXT', 'LEFT', true, true, 120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_date', 'Transfer Date', 'DATE', 'LEFT', true, true, 110, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'from_location_name', 'From Store', 'TEXT', 'LEFT', true, true, 150, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_request_no', 'Request No', 'TEXT', 'LEFT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_request_date', 'Request Date', 'DATE', 'LEFT', true, true, 110, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'to_location_name', 'To Store', 'TEXT', 'LEFT', true, true, 150, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_remarks', 'Remarks', 'TEXT', 'LEFT', true, true, 200, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 14, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'received_qty', 'Received Qty', 'NUMBER', 'RIGHT', true, true, 110, 15, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'short_received', 'Short Received', 'NUMBER', 'RIGHT', true, true, 120, 16, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Receipt Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'receipt_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'from_location_id', 'From Store', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'from_location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'to_location_id', 'To Store', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'to_location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb,
                'status', false, 'APPROVED', 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SRR', 'Stock Receipt Register',
             '/reports/STOCK_RECEIPT_REGISTER', 6, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- ric_user_menus backfill, same shape as every prior Inventory report
-- migration this session.
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
WHERE mm.feature_code = 'IN-RPT-SRR'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
