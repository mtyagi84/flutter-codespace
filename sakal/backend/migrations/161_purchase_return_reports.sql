-- ============================================================
-- Migration 161: Purchase Reports — Returns
--   (Purchase Return Register)
-- ============================================================
-- Fourth of five Purchase-reporting migrations. Reason is both a filter
-- AND a group-row column here — folding what would otherwise be a
-- redundant "Return Reason Analysis" report into this one via
-- grouping/filtering.
--
-- Posted Voucher(s) column reports JV/SDN/Both by checking whether the
-- return's own posted_voucher_no belongs to a JV or SDN voucher type, and
-- separately whether ANY other finance header shares this return's own
-- source_doc_type/no/date tag (since one return can post both a JV and an
-- SDN simultaneously — only one of which is the header's own primary
-- posted_voucher_no).
--
-- Full design: sakal/docs/screens/artifact_purchase_reports_plan.html
-- ============================================================

CREATE OR REPLACE VIEW v_purchase_return_lines AS
SELECT
    h.client_id, h.company_id,
    h.return_no, h.return_date, h.status, h.reason, h.return_total,
    h.location_id, loc.location_name,
    h.supplier_id, s.account_name AS supplier_name,
    (SELECT string_agg(DISTINCT fh.voucher_type_code, '+' ORDER BY fh.voucher_type_code)
       FROM rih_finance_headers fh
       WHERE fh.client_id = h.client_id AND fh.company_id = h.company_id
         AND fh.source_doc_type = 'PURCHASE_RETURN' AND fh.source_doc_no = h.return_no
         AND fh.source_doc_date = h.return_date AND fh.is_deleted = false
    ) AS posted_vouchers,
    l.serial_no AS line_serial,
    l.source_grn_no, l.source_grn_date,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS qty_returned, l.rate, l.final_amount,
    -- Whether THIS line's own source GRN was billed at the time of return —
    -- narrows independently of the return document as a whole, since one
    -- return can straddle both billed and unbilled GRN lines.
    (g.billed_invoice_no IS NOT NULL) AS source_grn_was_billed
FROM rih_purchase_return_headers h
JOIN rid_purchase_return_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.return_no = h.return_no AND l.return_date = h.return_date
JOIN rim_products p ON p.id = l.product_id
JOIN rim_accounts s ON s.id = h.supplier_id
LEFT JOIN rim_common_masters u ON u.id = l.uom_id
LEFT JOIN ric_locations loc ON loc.id = h.location_id
LEFT JOIN rih_grn_headers g
    ON  g.client_id = l.client_id AND g.company_id = l.company_id
    AND g.grn_no = l.source_grn_no AND g.grn_date = l.source_grn_date
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

GRANT SELECT ON v_purchase_return_lines TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION fn_purchase_return_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_return_date_from DATE DEFAULT NULL,
    p_return_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_reason      TEXT DEFAULT NULL,
    p_grn_billed  BOOLEAN DEFAULT NULL
) RETURNS TABLE (
    return_no TEXT, return_date DATE, supplier_name TEXT, reason TEXT, status TEXT,
    return_total NUMERIC, posted_vouchers TEXT, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT return_no, return_date, MIN(supplier_name), MIN(reason), MIN(status),
           MIN(return_total), MIN(posted_vouchers), COUNT(*)
    FROM v_purchase_return_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_return_date_from IS NULL OR return_date >= p_return_date_from)
      AND (p_return_date_to   IS NULL OR return_date <= p_return_date_to)
      AND (p_supplier_id      IS NULL OR supplier_id  = p_supplier_id)
      AND (p_location_id      IS NULL OR location_id  = p_location_id)
      AND (p_status           IS NULL OR status       = p_status)
      AND (p_reason           IS NULL OR reason       = p_reason)
      AND (p_grn_billed       IS NULL OR source_grn_was_billed = p_grn_billed)
    GROUP BY return_no, return_date;
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_return_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_purchase_return_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_return_date_from DATE DEFAULT NULL,
    p_return_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL,
    p_reason      TEXT DEFAULT NULL,
    p_grn_billed  BOOLEAN DEFAULT NULL
) RETURNS TABLE (qty_returned NUMERIC, final_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty_returned),0), COALESCE(SUM(final_amount),0), COUNT(*)
    FROM v_purchase_return_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_return_date_from IS NULL OR return_date >= p_return_date_from)
      AND (p_return_date_to   IS NULL OR return_date <= p_return_date_to)
      AND (p_supplier_id      IS NULL OR supplier_id  = p_supplier_id)
      AND (p_location_id      IS NULL OR location_id  = p_location_id)
      AND (p_status           IS NULL OR status       = p_status)
      AND (p_reason           IS NULL OR reason       = p_reason)
      AND (p_grn_billed       IS NULL OR source_grn_was_billed = p_grn_billed);
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_return_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT, BOOLEAN) TO authenticated;


-- Distinct-values lookup for the Reason filter — free TEXT, no master table.
CREATE OR REPLACE VIEW v_purchase_return_reasons AS
SELECT DISTINCT client_id, company_id, reason AS id, reason AS reason_name
FROM rih_purchase_return_headers
WHERE reason IS NOT NULL AND is_deleted = false;

GRANT SELECT ON v_purchase_return_reasons TO authenticated;


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

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PURCHASE_RETURN_REGISTER', 'Purchase Return Register',
             'TABULAR', 'VIEW', 'v_purchase_return_lines', 'PR', 'return_date', 'DESC', 200,
             'fn_purchase_return_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'return_no', 'Return No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'return_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason', 'Reason', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'TEXT', 'LEFT', true, true, 110, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'return_total', 'Return Total', 'NUMBER', 'RIGHT', true, true, 130, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_vouchers', 'Posted Voucher(s)', 'TEXT', 'LEFT', true, true, 140, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_grn_no', 'Source GRN No', 'TEXT', 'LEFT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_grn_date', 'Source GRN Date', 'DATE', 'LEFT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_returned', 'Qty Returned', 'NUMBER', 'RIGHT', true, true, 120, 13, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 14, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Amount', 'NUMBER', 'RIGHT', true, true, 120, 15, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Return Date', 'DATE_RANGE', NULL, NULL, NULL, 'return_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason', 'Reason', 'DROPDOWN_LOOKUP', 'v_purchase_return_reasons', 'reason_name', NULL, 'reason', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_billed', 'Source GRN', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"true","label":"Billed GRN Only"},{"value":"false","label":"Unbilled GRN Only"}]'::jsonb, 'grn_billed', false, NULL, 6);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'return_no', 'return_no', 'fn_purchase_return_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-PRR', 'Purchase Return Register', '/reports/PURCHASE_RETURN_REGISTER', 6, 'PR-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code = 'PR-RPT-PRR'
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
