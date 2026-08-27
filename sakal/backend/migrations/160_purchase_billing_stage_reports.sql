-- ============================================================
-- Migration 160: Purchase Reports — Billing stage
--   (Purchase Invoice Register, Purchase Tax Summary)
-- ============================================================
-- Third of five Purchase-reporting migrations. A Purchase Invoice (Bill)
-- has no line-items table of its own — it IS a set of linked GRNs (the
-- linkage lives in reverse, on rih_grn_headers.billed_invoice_no). So the
-- group row here is the Bill, and its "detail rows" are whole GRN
-- documents, not items — the only report shape in this whole plan where
-- that's true, an honest reflection of how the document actually works.
--
-- rih_purchase_invoices DOES carry its own location_id (confirmed by
-- direct read before writing this migration) — no workaround needed for
-- the Location filter, unlike what the design plan initially flagged as
-- needing verification.
--
-- Full design: sakal/docs/screens/artifact_purchase_reports_plan.html
-- ============================================================

CREATE OR REPLACE VIEW v_purchase_invoice_grns AS
SELECT
    h.client_id, h.company_id,
    h.invoice_no, h.invoice_date, h.supplier_invoice_no, h.supplier_invoice_date,
    h.supplier_id, s.account_name AS supplier_name,
    h.location_id, loc.location_name,
    h.taxable_amount, h.tax_amount, h.invoice_total, h.exchange_diff_base, h.status,
    g.grn_no, g.grn_date, g.grand_total AS grn_grand_total
FROM rih_purchase_invoices h
JOIN rim_accounts s ON s.id = h.supplier_id
LEFT JOIN ric_locations loc ON loc.id = h.location_id
JOIN rih_grn_headers g
    ON  g.client_id = h.client_id AND g.company_id = h.company_id
    AND g.billed_invoice_no = h.invoice_no AND g.billed_invoice_date = h.invoice_date
    AND g.is_deleted = false
WHERE h.is_deleted = false
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

GRANT SELECT ON v_purchase_invoice_grns TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION fn_purchase_invoice_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_invoice_date_from DATE DEFAULT NULL,
    p_invoice_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    invoice_no TEXT, invoice_date DATE, supplier_invoice_no TEXT, supplier_invoice_date DATE,
    supplier_name TEXT, taxable_amount NUMERIC, tax_amount NUMERIC, invoice_total NUMERIC,
    exchange_diff_base NUMERIC, status TEXT, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT invoice_no, invoice_date, MIN(supplier_invoice_no), MIN(supplier_invoice_date),
           MIN(supplier_name), MIN(taxable_amount), MIN(tax_amount), MIN(invoice_total),
           MIN(exchange_diff_base), MIN(status), COUNT(*)
    FROM v_purchase_invoice_grns
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_invoice_date_from IS NULL OR invoice_date >= p_invoice_date_from)
      AND (p_invoice_date_to   IS NULL OR invoice_date <= p_invoice_date_to)
      AND (p_supplier_id       IS NULL OR supplier_id = p_supplier_id)
      AND (p_status            IS NULL OR status      = p_status)
    GROUP BY invoice_no, invoice_date;
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_invoice_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_purchase_invoice_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_invoice_date_from DATE DEFAULT NULL,
    p_invoice_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (invoice_total NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    -- Sums per DISTINCT invoice (not per GRN row) so a bill linking multiple
    -- GRNs isn't double-counted in the totals bar.
    SELECT COALESCE(SUM(invoice_total), 0), COUNT(*) FROM (
        SELECT DISTINCT invoice_no, invoice_date, invoice_total
        FROM v_purchase_invoice_grns
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND (p_invoice_date_from IS NULL OR invoice_date >= p_invoice_date_from)
          AND (p_invoice_date_to   IS NULL OR invoice_date <= p_invoice_date_to)
          AND (p_supplier_id       IS NULL OR supplier_id = p_supplier_id)
          AND (p_status            IS NULL OR status      = p_status)
    ) d;
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_invoice_register_totals(
    UUID, UUID, DATE, DATE, UUID, TEXT) TO authenticated;


-- ============================================================
-- Report 13 — Purchase Tax Summary (GROUPED by Supplier)
-- ============================================================
CREATE OR REPLACE VIEW v_purchase_tax_lines AS
SELECT
    h.client_id, h.company_id,
    h.supplier_id, s.account_name AS supplier_name,
    h.invoice_no, h.invoice_date, h.supplier_invoice_no, h.supplier_invoice_date,
    h.taxable_amount, h.tax_amount, h.invoice_total, h.status
FROM rih_purchase_invoices h
JOIN rim_accounts s ON s.id = h.supplier_id
WHERE h.is_deleted = false
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

GRANT SELECT ON v_purchase_tax_lines TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_purchase_tax_summary_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_invoice_date_from DATE DEFAULT NULL,
    p_invoice_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    supplier_id UUID, supplier_name TEXT, taxable_amount NUMERIC, tax_amount NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT supplier_id, MIN(supplier_name), COALESCE(SUM(taxable_amount),0), COALESCE(SUM(tax_amount),0), COUNT(*)
    FROM v_purchase_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_invoice_date_from IS NULL OR invoice_date >= p_invoice_date_from)
      AND (p_invoice_date_to   IS NULL OR invoice_date <= p_invoice_date_to)
      AND (p_supplier_id       IS NULL OR supplier_id = p_supplier_id)
      AND (p_status            IS NULL OR status      = p_status)
    GROUP BY supplier_id;
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_tax_summary_group_summary(
    UUID, UUID, DATE, DATE, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_purchase_tax_summary_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_invoice_date_from DATE DEFAULT NULL,
    p_invoice_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (taxable_amount NUMERIC, tax_amount NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(taxable_amount),0), COALESCE(SUM(tax_amount),0), COUNT(*)
    FROM v_purchase_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_invoice_date_from IS NULL OR invoice_date >= p_invoice_date_from)
      AND (p_invoice_date_to   IS NULL OR invoice_date <= p_invoice_date_to)
      AND (p_supplier_id       IS NULL OR supplier_id = p_supplier_id)
      AND (p_status            IS NULL OR status      = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_purchase_tax_summary_totals(UUID, UUID, DATE, DATE, UUID, TEXT) TO authenticated;


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

        -- ---------------- Report 5: Purchase Invoice (Bill) Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PURCHASE_INVOICE_REGISTER', 'Purchase Invoice Register',
             'TABULAR', 'VIEW', 'v_purchase_invoice_grns', 'PR', 'invoice_date', 'DESC', 200,
             'fn_purchase_invoice_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no', 'Invoice No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_invoice_no', 'Supplier Invoice No', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_invoice_date', 'Supplier Invoice Date', 'DATE', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'taxable_amount', 'Taxable Amount', 'NUMBER', 'RIGHT', true, true, 130, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_amount', 'Tax Amount', 'NUMBER', 'RIGHT', true, true, 120, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_total', 'Invoice Total', 'NUMBER', 'RIGHT', true, true, 130, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'exchange_diff_base', 'Exchange Diff', 'NUMBER', 'RIGHT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'TEXT', 'LEFT', true, true, 110, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_no', 'GRN No', 'TEXT', 'LEFT', true, true, 130, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_date', 'GRN Date', 'DATE', 'LEFT', true, true, 120, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'grn_grand_total', 'GRN Grand Total', 'NUMBER', 'RIGHT', true, true, 140, 13, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Invoice Date', 'DATE_RANGE', NULL, NULL, NULL, 'invoice_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, NULL, 4);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'invoice_no', 'invoice_no', 'fn_purchase_invoice_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-PIR', 'Purchase Invoice Register', '/reports/PURCHASE_INVOICE_REGISTER', 5, 'PR-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 13: Purchase Tax Summary ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PURCHASE_TAX_SUMMARY', 'Purchase Tax Summary',
             'TABULAR', 'VIEW', 'v_purchase_tax_lines', 'PR', 'invoice_date', 'DESC', 200,
             'fn_purchase_tax_summary_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_name', 'Supplier', 'TEXT', 'LEFT', true, true, 180, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no', 'Invoice No', 'TEXT', 'LEFT', true, true, 130, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_date', 'Date', 'DATE', 'LEFT', true, true, 110, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_invoice_no', 'Supplier Invoice No', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_invoice_date', 'Supplier Invoice Date', 'DATE', 'LEFT', true, true, 150, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'taxable_amount', 'Taxable Amount', 'NUMBER', 'RIGHT', true, true, 130, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_amount', 'Tax Amount', 'NUMBER', 'RIGHT', true, true, 120, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_total', 'Invoice Total', 'NUMBER', 'RIGHT', true, true, 130, 8, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Invoice Date', 'DATE_RANGE', NULL, NULL, NULL, 'invoice_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'supplier_id', 'Supplier', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'supplier_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, 'APPROVED', 3);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'supplier_id', 'supplier_name', 'fn_purchase_tax_summary_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_pr_module_id, 'PR-RPT-TAX', 'Purchase Tax Summary', '/reports/PURCHASE_TAX_SUMMARY', 13, 'PR-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('PR-RPT-PIR', 'PR-RPT-TAX')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
