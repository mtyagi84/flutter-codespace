-- ============================================================
-- Migration 151: Stock Transfer Register + Pending Transfer to Receive
-- ============================================================
-- Fifth/sixth Inventory reports. A document-register style report (one row
-- per transfer LINE, header fields repeated) modeled on Sales Register
-- (126_sales_details_views.sql/127_sales_register_report.sql) — the
-- closest existing precedent — plus a companion "still open" view of the
-- same data.
--
-- Real schema finding: this app has NO partial-receipt concept.
-- rih_stock_receipts has UNIQUE(source_transfer_no, source_transfer_date)
-- — exactly one receipt per transfer, ever — and fn_approve_stock_receipt
-- forces the transfer to status='CLOSED' unconditionally the moment that
-- one receipt is approved, regardless of whether every line was fully
-- received. A shortfall is written off immediately, never carried forward.
-- Confirmed with the user: "Pending" = (1) dispatched, no receipt filed at
-- all yet (full qty pending) + (2) already-closed transfers that were
-- received SHORT (flagged, shortfall qty only) — both in one report,
-- distinguished by a Receipt Status column.
--
-- Full design: sakal/docs/screens/plan_stock_transfer_reports.md
-- ============================================================

-- ============================================================
-- Part A — v_stock_transfer_lines: shared base VIEW (mirrors
-- v_sales_details_base's shape)
-- ============================================================
-- One row per transfer LINE (non-serial-tracked products), or one row per
-- SERIAL (serial-tracked products, via the shared rid_transaction_line_serials
-- table) — same UNION ALL convention as migrations 148/149.
--
-- status is NOT filtered here (same reasoning as v_sales_details_base) —
-- every report built on this view applies its own status filter. A
-- computed status_group column buckets the bookkeeping-only 'CLOSED'
-- state into 'APPROVED' for filtering purposes, since a plain PostgREST
-- eq. filter on a VIEW has no way to express "IN (...)" — this lets the
-- Stock Transfer Register's 3-option Draft/Approved/All filter treat a
-- received (CLOSED) transfer as still "Approved" for filtering, matching
-- the user's own literal 3-option ask without inventing a 4th status.
--
-- Location-access scoping checks EITHER from_location_id OR to_location_id
-- against the user's own ric_user_location_access rows — a user
-- responsible for receiving at their own location needs to see a transfer
-- dispatched FROM a location they don't otherwise manage, and vice versa.
DROP VIEW IF EXISTS v_stock_transfer_lines;
CREATE VIEW v_stock_transfer_lines AS
SELECT
    h.client_id, h.company_id,
    h.transfer_no, h.transfer_date, h.status,
    CASE WHEN h.status IN ('APPROVED','CLOSED') THEN 'APPROVED' ELSE h.status END AS status_group,
    h.from_location_id, fl.location_name AS from_location_name,
    h.to_location_id, tl.location_name AS to_location_name,
    h.source_request_no, h.source_request_date,
    h.remarks AS doc_remarks,
    l.serial_no AS line_serial,
    l.barcode,
    NULL::text AS serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS transfer_qty
FROM rih_stock_transfers h
JOIN rid_stock_transfer_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.transfer_no = h.transfer_no AND l.transfer_date = h.transfer_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type != 'SERIAL'
LEFT JOIN rim_common_masters u  ON u.id  = l.uom_id
LEFT JOIN ric_locations      fl ON fl.id = h.from_location_id
LEFT JOIN ric_locations      tl ON tl.id = h.to_location_id
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
    h.transfer_no, h.transfer_date, h.status,
    CASE WHEN h.status IN ('APPROVED','CLOSED') THEN 'APPROVED' ELSE h.status END AS status_group,
    h.from_location_id, fl.location_name AS from_location_name,
    h.to_location_id, tl.location_name AS to_location_name,
    h.source_request_no, h.source_request_date,
    h.remarks AS doc_remarks,
    l.serial_no AS line_serial,
    l.barcode,
    ts.serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    1::NUMERIC AS transfer_qty
FROM rih_stock_transfers h
JOIN rid_stock_transfer_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.transfer_no = h.transfer_no AND l.transfer_date = h.transfer_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type = 'SERIAL'
JOIN rid_transaction_line_serials ts
    ON  ts.client_id = h.client_id AND ts.company_id = h.company_id
    AND ts.source_doc_type = 'STOCK_TRANSFER'
    AND ts.source_doc_no = h.transfer_no AND ts.source_doc_date = h.transfer_date
    AND ts.line_serial = l.serial_no
LEFT JOIN rim_common_masters u  ON u.id  = l.uom_id
LEFT JOIN ric_locations      fl ON fl.id = h.from_location_id
LEFT JOIN ric_locations      tl ON tl.id = h.to_location_id
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

GRANT SELECT ON v_stock_transfer_lines TO anon, authenticated, service_role;


-- ============================================================
-- Part B — fn_stock_transfer_register_totals: wraps the view with the
-- report's own filter params (fetchTotals always calls its target as a
-- FUNCTION even when the main report source is a VIEW — same reasoning
-- Sales Register's own totals wrapper exists for, 127).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_stock_transfer_register_totals(
    p_client_id        UUID,
    p_company_id       UUID,
    p_transfer_date_from DATE DEFAULT NULL,
    p_transfer_date_to   DATE DEFAULT NULL,
    p_from_location_id UUID DEFAULT NULL,
    p_to_location_id   UUID DEFAULT NULL,
    p_status_group     TEXT DEFAULT NULL
) RETURNS TABLE (
    transfer_qty NUMERIC,
    row_count      BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(transfer_qty), 0), COUNT(*)
    FROM v_stock_transfer_lines
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_transfer_date_from IS NULL OR transfer_date >= p_transfer_date_from)
      AND (p_transfer_date_to   IS NULL OR transfer_date <= p_transfer_date_to)
      AND (p_from_location_id   IS NULL OR from_location_id = p_from_location_id)
      AND (p_to_location_id     IS NULL OR to_location_id   = p_to_location_id)
      AND (p_status_group       IS NULL OR status_group     = p_status_group);
$$;

GRANT EXECUTE ON FUNCTION fn_stock_transfer_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Part C — fn_stock_transfer_pending_receipt / _totals
-- ============================================================
-- Three-branch UNION ALL, built directly from the base tables (not the
-- shared view above) since branch 3 needs LINE-level totals to diff
-- against rid_stock_receipt_lines.received_base_qty, which the view's own
-- serial-expanded rows don't carry.
--
-- Branch 1/2 (not received): status='APPROVED' is sufficient on its own —
-- a transfer can ONLY reach 'APPROVED' if no receipt has ever been filed
-- (filing one forces CLOSED unconditionally, confirmed in
-- fn_approve_stock_receipt) — no NOT EXISTS subquery needed.
--
-- Branch 3 (short received) is LINE-level, not serial-expanded — a
-- deliberate v1 scoping choice, documented in the plan: resolving a
-- shortfall down to which SPECIFIC serial(s) are missing would need
-- diffing the transfer's own serial set against the receipt's own serial
-- set (both in rid_transaction_line_serials, different source_doc_types),
-- a real but more involved piece of logic a shortfall is typically
-- investigated at the document level for anyway. Serial No is left blank
-- on these rows.
CREATE OR REPLACE FUNCTION fn_stock_transfer_pending_receipt(
    p_client_id        UUID,
    p_company_id       UUID,
    p_transfer_date_from DATE DEFAULT NULL,
    p_transfer_date_to   DATE DEFAULT NULL,
    p_from_location_id UUID DEFAULT NULL,
    p_to_location_id   UUID DEFAULT NULL
) RETURNS TABLE (
    transfer_no       TEXT,
    transfer_date     DATE,
    from_location_name TEXT,
    source_request_no TEXT,
    source_request_date DATE,
    to_location_name   TEXT,
    doc_remarks         TEXT,
    barcode               TEXT,
    serial_no               TEXT,
    product_code              TEXT,
    product_name               TEXT,
    unit_name                    TEXT,
    transfer_qty                  NUMERIC,
    receipt_status                 TEXT,
    pending_qty                      NUMERIC
) LANGUAGE sql STABLE AS $$
    WITH accessible_locations AS (
        SELECT loc.id
        FROM ric_locations loc
        WHERE loc.client_id = p_client_id AND loc.company_id = p_company_id
          AND loc.is_deleted = false
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
    transfer_base AS (
        SELECT h.*, fl.location_name AS from_location_name, tl.location_name AS to_location_name
        FROM rih_stock_transfers h
        LEFT JOIN ric_locations fl ON fl.id = h.from_location_id
        LEFT JOIN ric_locations tl ON tl.id = h.to_location_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id AND h.is_deleted = false
          AND (h.from_location_id IN (SELECT id FROM accessible_locations)
               OR h.to_location_id IN (SELECT id FROM accessible_locations))
          AND (p_transfer_date_from IS NULL OR h.transfer_date >= p_transfer_date_from)
          AND (p_transfer_date_to   IS NULL OR h.transfer_date <= p_transfer_date_to)
          AND (p_from_location_id   IS NULL OR h.from_location_id = p_from_location_id)
          AND (p_to_location_id     IS NULL OR h.to_location_id   = p_to_location_id)
    ),
    not_received_non_serial AS (
        SELECT
            h.transfer_no, h.transfer_date, h.from_location_name,
            h.source_request_no, h.source_request_date, h.to_location_name,
            h.remarks AS doc_remarks, l.barcode, NULL::text AS serial_no,
            p.product_code, p.product_name, u.description AS unit_name,
            l.base_qty AS transfer_qty, 'Not Received'::text AS receipt_status, l.base_qty AS pending_qty
        FROM transfer_base h
        JOIN rid_stock_transfer_lines l
            ON  l.client_id = h.client_id AND l.company_id = h.company_id
            AND l.transfer_no = h.transfer_no AND l.transfer_date = h.transfer_date AND l.is_deleted = false
        JOIN rim_products p ON p.id = l.product_id AND p.tracking_type != 'SERIAL'
        LEFT JOIN rim_common_masters u ON u.id = l.uom_id
        WHERE h.status = 'APPROVED'
    ),
    not_received_serial AS (
        SELECT
            h.transfer_no, h.transfer_date, h.from_location_name,
            h.source_request_no, h.source_request_date, h.to_location_name,
            h.remarks AS doc_remarks, l.barcode, ts.serial_no,
            p.product_code, p.product_name, u.description AS unit_name,
            1::NUMERIC AS transfer_qty, 'Not Received'::text AS receipt_status, 1::NUMERIC AS pending_qty
        FROM transfer_base h
        JOIN rid_stock_transfer_lines l
            ON  l.client_id = h.client_id AND l.company_id = h.company_id
            AND l.transfer_no = h.transfer_no AND l.transfer_date = h.transfer_date AND l.is_deleted = false
        JOIN rim_products p ON p.id = l.product_id AND p.tracking_type = 'SERIAL'
        JOIN rid_transaction_line_serials ts
            ON  ts.client_id = h.client_id AND ts.company_id = h.company_id
            AND ts.source_doc_type = 'STOCK_TRANSFER'
            AND ts.source_doc_no = h.transfer_no AND ts.source_doc_date = h.transfer_date
            AND ts.line_serial = l.serial_no
        LEFT JOIN rim_common_masters u ON u.id = l.uom_id
        WHERE h.status = 'APPROVED'
    ),
    short_received AS (
        SELECT
            h.transfer_no, h.transfer_date, h.from_location_name,
            h.source_request_no, h.source_request_date, h.to_location_name,
            h.remarks AS doc_remarks, l.barcode, NULL::text AS serial_no,
            p.product_code, p.product_name, u.description AS unit_name,
            l.base_qty AS transfer_qty, 'Short Received'::text AS receipt_status,
            (l.base_qty - COALESCE(rl.received_base_qty, 0)) AS pending_qty
        FROM transfer_base h
        JOIN rid_stock_transfer_lines l
            ON  l.client_id = h.client_id AND l.company_id = h.company_id
            AND l.transfer_no = h.transfer_no AND l.transfer_date = h.transfer_date AND l.is_deleted = false
        JOIN rim_products p ON p.id = l.product_id
        LEFT JOIN rim_common_masters u ON u.id = l.uom_id
        JOIN rih_stock_receipts rh
            ON  rh.client_id = h.client_id AND rh.company_id = h.company_id
            AND rh.source_transfer_no = h.transfer_no AND rh.source_transfer_date = h.transfer_date
            AND rh.is_deleted = false
        LEFT JOIN rid_stock_receipt_lines rl
            ON  rl.client_id = rh.client_id AND rl.company_id = rh.company_id
            AND rl.receipt_no = rh.receipt_no AND rl.receipt_date = rh.receipt_date
            AND rl.source_transfer_line_serial = l.serial_no AND rl.is_deleted = false
        WHERE h.status = 'CLOSED'
          AND (l.base_qty - COALESCE(rl.received_base_qty, 0)) > 0
    )
    SELECT * FROM not_received_non_serial
    UNION ALL
    SELECT * FROM not_received_serial
    UNION ALL
    SELECT * FROM short_received;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_transfer_pending_receipt(
    UUID, UUID, DATE, DATE, UUID, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_stock_transfer_pending_receipt_totals(
    p_client_id        UUID,
    p_company_id       UUID,
    p_transfer_date_from DATE DEFAULT NULL,
    p_transfer_date_to   DATE DEFAULT NULL,
    p_from_location_id UUID DEFAULT NULL,
    p_to_location_id   UUID DEFAULT NULL
) RETURNS TABLE (
    pending_qty NUMERIC,
    row_count     BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(pending_qty), 0), COUNT(*)
    FROM fn_stock_transfer_pending_receipt(p_client_id, p_company_id, p_transfer_date_from,
                                            p_transfer_date_to, p_from_location_id, p_to_location_id);
$$;

GRANT EXECUTE ON FUNCTION fn_stock_transfer_pending_receipt_totals(
    UUID, UUID, DATE, DATE, UUID, UUID) TO authenticated;


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

        -- ============================================================
        -- Report 1 — Stock Transfer Register
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_TRANSFER_REGISTER', 'Stock Transfer Register',
             'TABULAR', 'VIEW', 'v_stock_transfer_lines', 'IN', 'transfer_date', 'DESC', 200,
             'fn_stock_transfer_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_no', 'Transfer No', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_date', 'Transfer Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'from_location_name', 'From Store', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_request_no', 'Request No', 'TEXT', 'LEFT', true, true, 120, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_request_date', 'Request Date', 'DATE', 'LEFT', true, true, 110, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'to_location_name', 'To Store', 'TEXT', 'LEFT', true, true, 150, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_remarks', 'Remarks', 'TEXT', 'LEFT', true, true, 220, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 220, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_qty', 'Transfer Qty', 'NUMBER', 'RIGHT', true, true, 120, 13, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Transfer Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'transfer_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'from_location_id', 'From Store', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'from_location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'to_location_id', 'To Store', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'to_location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb,
                'status_group', false, 'APPROVED', 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-STR', 'Stock Transfer Register',
             '/reports/STOCK_TRANSFER_REGISTER', 4, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ============================================================
        -- Report 2 — Pending Transfer to Receive
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_TRANSFER_PENDING_RECEIPT', 'Pending Transfer to Receive',
             'TABULAR', 'FUNCTION', 'fn_stock_transfer_pending_receipt', 'IN', 'transfer_date', 'DESC', 200,
             'fn_stock_transfer_pending_receipt_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_no', 'Transfer No', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_date', 'Transfer Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'from_location_name', 'From Store', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_request_no', 'Request No', 'TEXT', 'LEFT', true, true, 120, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_request_date', 'Request Date', 'DATE', 'LEFT', true, true, 110, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'to_location_name', 'To Store', 'TEXT', 'LEFT', true, true, 150, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_remarks', 'Remarks', 'TEXT', 'LEFT', true, true, 200, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'transfer_qty', 'Transfer Qty', 'NUMBER', 'RIGHT', true, true, 110, 13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'receipt_status', 'Receipt Status', 'TEXT', 'LEFT', true, true, 130, 14, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'pending_qty', 'Pending Qty', 'NUMBER', 'RIGHT', true, true, 110, 15, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Transfer Date', 'DATE_RANGE',
                NULL, NULL, 'transfer_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'from_location_id', 'From Store', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', 'from_location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'to_location_id', 'To Store', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', 'to_location_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-STP', 'Pending Transfer to Receive',
             '/reports/STOCK_TRANSFER_PENDING_RECEIPT', 5, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- Part E — ric_user_menus backfill, same shape as prior Inventory
-- reports this session (119/148/149/150).
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
WHERE mm.feature_code IN ('IN-RPT-STR', 'IN-RPT-STP')
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
