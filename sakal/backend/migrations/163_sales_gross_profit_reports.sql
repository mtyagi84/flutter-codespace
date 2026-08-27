-- ============================================================
-- Migration 163: Sales Reports — Gross Profit family
--   (Item-wise, Invoice-wise, Customer-wise Gross Profit,
--    Salesperson-wise Performance, Sales Return Register)
-- ============================================================
-- First of three Sales-reporting migrations. Unlike Purchase (which
-- started from zero), Sales already has v_sales_details_base/_local
-- (migration 126) with REAL, posting-consistent cost_price/cost_value/
-- gross_profit/gross_profit_percent columns — the same cost_price
-- fn_approve_sales_invoice actually posts the Cost-of-Sales voucher with
-- (migrations 120-122). These five reports are new ways to GROUP that
-- existing data, not a new costing engine.
--
-- One new thin wrapper view (v_sales_gross_profit_lines) joins
-- rim_products onto v_sales_details_base purely to add category_id/
-- brand_id — columns the base view deliberately doesn't carry — mirroring
-- the exact same "wrapper view for one extra join" pattern already used
-- for Purchase's own Supplier Analysis report this session.
--
-- Currency-toggle (BASE/LOCAL, the feature Sales Register itself uses) is
-- deliberately NOT added to these five reports for v1 — matches the "one
-- new concept at a time" scope discipline used throughout this session;
-- easy to add later by pointing source_object_local at a _local variant
-- of the same wrapper view, same mechanism Sales Register already proves.
--
-- Full design: sakal/docs/screens/artifact_sales_reports_plan.html
-- ============================================================

CREATE OR REPLACE VIEW v_sales_gross_profit_lines AS
SELECT
    v.*,
    p.category_id, cat.category_name,
    p.brand_id, br.description AS brand_name
FROM v_sales_details_base v
JOIN rim_products p ON p.id = v.product_id
LEFT JOIN rim_item_categories cat ON cat.id = p.category_id
LEFT JOIN rim_common_masters  br  ON br.id  = p.brand_id;

GRANT SELECT ON v_sales_gross_profit_lines TO anon, authenticated, service_role;

-- Distinct-values lookup for the Reason filter (Sales Return Register) —
-- free TEXT on rih_sales_return_headers, no master table, same pattern as
-- v_purchase_return_reasons.
CREATE OR REPLACE VIEW v_sales_return_reasons AS
SELECT DISTINCT client_id, company_id, reason AS id, reason AS reason_name
FROM rih_sales_return_headers
WHERE reason IS NOT NULL AND is_deleted = false;

GRANT SELECT ON v_sales_return_reasons TO authenticated;


-- ============================================================
-- Report 1 — Item-wise Gross Profit (GROUPED by Product)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_item_gross_profit_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_brand_id    UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_record_type TEXT DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    product_id UUID, product_code TEXT, product_name TEXT,
    qty NUMERIC, avg_rate NUMERIC, revenue NUMERIC, cost_value NUMERIC,
    gross_profit NUMERIC, gross_profit_percent NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT product_id, MIN(product_code), MIN(product_name),
           COALESCE(SUM(base_qty), 0),
           CASE WHEN SUM(base_qty) = 0 THEN NULL ELSE SUM(final_amount) / SUM(base_qty) END,
           COALESCE(SUM(final_amount), 0), COALESCE(SUM(cost_value), 0),
           COALESCE(SUM(gross_profit), 0),
           CASE WHEN SUM(final_amount) = 0 THEN NULL ELSE SUM(gross_profit) / SUM(final_amount) * 100 END,
           COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_product_id      IS NULL OR product_id  = p_product_id)
      AND (p_category_id     IS NULL OR category_id = p_category_id)
      AND (p_brand_id        IS NULL OR brand_id    = p_brand_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_record_type     IS NULL OR record_type = p_record_type)
      AND (p_status          IS NULL OR status       = p_status)
    GROUP BY product_id;
$$;

GRANT EXECUTE ON FUNCTION fn_item_gross_profit_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, UUID, UUID, UUID, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_item_gross_profit_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_brand_id    UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_record_type TEXT DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, cost_value NUMERIC, gross_profit NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount),0), COALESCE(SUM(cost_value),0), COALESCE(SUM(gross_profit),0), COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_product_id      IS NULL OR product_id  = p_product_id)
      AND (p_category_id     IS NULL OR category_id = p_category_id)
      AND (p_brand_id        IS NULL OR brand_id    = p_brand_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_record_type     IS NULL OR record_type = p_record_type)
      AND (p_status          IS NULL OR status       = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_item_gross_profit_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, UUID, UUID, UUID, TEXT, TEXT) TO authenticated;


-- ============================================================
-- Report 2 — Invoice-wise Gross Profit (GROUPED by the ORIGINAL invoice —
-- invoice_no/invoice_date, not doc_no, so a Return automatically nets
-- against the invoice it came from and this shows the TRUE, post-return
-- profitability of that sale).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_invoice_gross_profit_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    invoice_no TEXT, invoice_date DATE, customer_name TEXT, sales_person_name TEXT,
    revenue NUMERIC, cost_value NUMERIC, gross_profit NUMERIC, gross_profit_percent NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT invoice_no, invoice_date, MIN(customer_name), MIN(sales_person_name),
           COALESCE(SUM(final_amount), 0), COALESCE(SUM(cost_value), 0), COALESCE(SUM(gross_profit), 0),
           CASE WHEN SUM(final_amount) = 0 THEN NULL ELSE SUM(gross_profit) / SUM(final_amount) * 100 END,
           COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_status          IS NULL OR status       = p_status)
    GROUP BY invoice_no, invoice_date;
$$;

GRANT EXECUTE ON FUNCTION fn_invoice_gross_profit_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_invoice_gross_profit_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, cost_value NUMERIC, gross_profit NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount),0), COALESCE(SUM(cost_value),0), COALESCE(SUM(gross_profit),0), COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_status          IS NULL OR status       = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_invoice_gross_profit_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Report 3 — Customer-wise Gross Profit (GROUPED by Customer)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_customer_gross_profit_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    customer_id UUID, customer_name TEXT, invoice_count BIGINT, qty NUMERIC,
    revenue NUMERIC, cost_value NUMERIC, gross_profit NUMERIC, gross_profit_percent NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT customer_id, MIN(customer_name), COUNT(DISTINCT invoice_no), COALESCE(SUM(base_qty), 0),
           COALESCE(SUM(final_amount), 0), COALESCE(SUM(cost_value), 0), COALESCE(SUM(gross_profit), 0),
           CASE WHEN SUM(final_amount) = 0 THEN NULL ELSE SUM(gross_profit) / SUM(final_amount) * 100 END,
           COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_category_id     IS NULL OR category_id = p_category_id)
      AND (p_status          IS NULL OR status       = p_status)
    GROUP BY customer_id;
$$;

GRANT EXECUTE ON FUNCTION fn_customer_gross_profit_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_customer_gross_profit_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, cost_value NUMERIC, gross_profit NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount),0), COALESCE(SUM(cost_value),0), COALESCE(SUM(gross_profit),0), COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_category_id     IS NULL OR category_id = p_category_id)
      AND (p_status          IS NULL OR status       = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_customer_gross_profit_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Report 4 — Salesperson-wise Performance (GROUPED by Sales Person)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_salesperson_performance_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    sales_person_id UUID, sales_person_name TEXT, invoice_count BIGINT, customer_count BIGINT,
    qty NUMERIC, revenue NUMERIC, cost_value NUMERIC, gross_profit NUMERIC, gross_profit_percent NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT sales_person_id, MIN(sales_person_name), COUNT(DISTINCT invoice_no), COUNT(DISTINCT customer_id),
           COALESCE(SUM(base_qty), 0), COALESCE(SUM(final_amount), 0), COALESCE(SUM(cost_value), 0),
           COALESCE(SUM(gross_profit), 0),
           CASE WHEN SUM(final_amount) = 0 THEN NULL ELSE SUM(gross_profit) / SUM(final_amount) * 100 END,
           COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_status          IS NULL OR status       = p_status)
    GROUP BY sales_person_id;
$$;

GRANT EXECUTE ON FUNCTION fn_salesperson_performance_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_salesperson_performance_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, cost_value NUMERIC, gross_profit NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount),0), COALESCE(SUM(cost_value),0), COALESCE(SUM(gross_profit),0), COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_status          IS NULL OR status       = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_salesperson_performance_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Report 5 — Sales Return Register (GROUPED by the RETURN's own doc_no —
-- distinct from Report 2's grouping by the ORIGINAL invoice — filtered
-- record_type='R' by default).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_sales_return_register_group_summary(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_reason      TEXT DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (
    doc_no TEXT, doc_date DATE, customer_name TEXT, invoice_no TEXT, invoice_date DATE,
    reason TEXT, return_total NUMERIC, reversed_gross_profit NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT doc_no, doc_date, MIN(customer_name), MIN(invoice_no), MIN(invoice_date),
           MIN(reason), COALESCE(SUM(final_amount), 0), COALESCE(SUM(gross_profit), 0), COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND record_type = 'R'
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_reason          IS NULL OR reason      = p_reason)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_status          IS NULL OR status       = p_status)
    GROUP BY doc_no, doc_date;
$$;

GRANT EXECUTE ON FUNCTION fn_sales_return_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, TEXT, UUID, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_sales_return_register_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_doc_date_from DATE DEFAULT NULL,
    p_doc_date_to   DATE DEFAULT NULL,
    p_customer_id UUID DEFAULT NULL,
    p_reason      TEXT DEFAULT NULL,
    p_sales_person_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_status      TEXT DEFAULT NULL
) RETURNS TABLE (final_amount NUMERIC, gross_profit NUMERIC, row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(final_amount),0), COALESCE(SUM(gross_profit),0), COUNT(*)
    FROM v_sales_gross_profit_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND record_type = 'R'
      AND (p_doc_date_from   IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to     IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id     IS NULL OR customer_id = p_customer_id)
      AND (p_reason          IS NULL OR reason      = p_reason)
      AND (p_sales_person_id IS NULL OR sales_person_id = p_sales_person_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
      AND (p_status          IS NULL OR status       = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_sales_return_register_totals(
    UUID, UUID, DATE, DATE, UUID, TEXT, UUID, UUID, TEXT) TO authenticated;


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

        -- ---------------- Report 1: Item-wise Gross Profit ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'ITEM_GROSS_PROFIT', 'Item-wise Gross Profit',
             'TABULAR', 'VIEW', 'v_sales_gross_profit_lines', 'SL', 'doc_date', 'DESC', 200,
             'fn_item_gross_profit_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty', 'Qty', 'NUMBER', 'RIGHT', true, true, 100, 3, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'avg_rate', 'Avg Rate', 'NUMBER', 'RIGHT', true, true, 110, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'revenue', 'Revenue', 'NUMBER', 'RIGHT', true, true, 130, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'cost_value', 'Cost Value', 'NUMBER', 'RIGHT', true, true, 120, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit', 'Gross Profit', 'NUMBER', 'RIGHT', true, true, 130, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit_percent', 'GP %', 'NUMBER', 'RIGHT', true, true, 100, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_no', 'Doc No', 'TEXT', 'LEFT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_date', 'Doc Date', 'DATE', 'LEFT', true, true, 110, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 180, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Final Amount', 'NUMBER', 'RIGHT', true, true, 130, 13, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'doc_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'PRODUCT_PICKER', NULL, NULL, NULL, 'product_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP', 'rim_item_categories', 'category_name', NULL, 'category_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'brand_id', 'Brand', 'DROPDOWN_LOOKUP', 'v_product_brands', 'brand_name', NULL, 'brand_id', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 6),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 7),
            (v_company.client_id, v_company.company_id, v_report_id, 'record_type', 'Record Type', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"S","label":"Sale"},{"value":"R","label":"Return"}]'::jsonb, 'record_type', false, NULL, 8),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"CANCELLED","label":"Cancelled"}]'::jsonb, 'status', false, 'APPROVED', 9);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'product_id', 'product_code', 'fn_item_gross_profit_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-IGP', 'Item-wise Gross Profit', '/reports/ITEM_GROSS_PROFIT', 2, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 2: Invoice-wise Gross Profit ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'INVOICE_GROSS_PROFIT', 'Invoice-wise Gross Profit',
             'TABULAR', 'VIEW', 'v_sales_gross_profit_lines', 'SL', 'doc_date', 'DESC', 200,
             'fn_invoice_gross_profit_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no', 'Invoice No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 180, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_name', 'Sales Person', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'revenue', 'Revenue', 'NUMBER', 'RIGHT', true, true, 130, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'cost_value', 'Cost Value', 'NUMBER', 'RIGHT', true, true, 120, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit', 'Gross Profit', 'NUMBER', 'RIGHT', true, true, 130, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit_percent', 'GP %', 'NUMBER', 'RIGHT', true, true, 100, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty', 'Qty', 'NUMBER', 'RIGHT', true, true, 100, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Final Amount', 'NUMBER', 'RIGHT', true, true, 130, 13, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'doc_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"CANCELLED","label":"Cancelled"}]'::jsonb, 'status', false, 'APPROVED', 5);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'invoice_no', 'invoice_no', 'fn_invoice_gross_profit_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-VGP', 'Invoice-wise Gross Profit', '/reports/INVOICE_GROSS_PROFIT', 3, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 3: Customer-wise Gross Profit ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'CUSTOMER_GROSS_PROFIT', 'Customer-wise Gross Profit',
             'TABULAR', 'VIEW', 'v_sales_gross_profit_lines', 'SL', 'doc_date', 'DESC', 200,
             'fn_customer_gross_profit_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 180, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_count', 'Invoice Count', 'NUMBER', 'RIGHT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty', 'Qty', 'NUMBER', 'RIGHT', true, true, 100, 3, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'revenue', 'Revenue', 'NUMBER', 'RIGHT', true, true, 130, 4, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'cost_value', 'Cost Value', 'NUMBER', 'RIGHT', true, true, 120, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit', 'Gross Profit', 'NUMBER', 'RIGHT', true, true, 130, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit_percent', 'GP %', 'NUMBER', 'RIGHT', true, true, 100, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Line Amount', 'NUMBER', 'RIGHT', true, true, 130, 10, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'doc_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP', 'rim_item_categories', 'category_name', NULL, 'category_id', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"CANCELLED","label":"Cancelled"}]'::jsonb, 'status', false, 'APPROVED', 6);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'customer_id', 'customer_name', 'fn_customer_gross_profit_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-CGP', 'Customer-wise Gross Profit', '/reports/CUSTOMER_GROSS_PROFIT', 4, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 4: Salesperson-wise Performance ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SALESPERSON_PERFORMANCE', 'Salesperson-wise Performance',
             'TABULAR', 'VIEW', 'v_sales_gross_profit_lines', 'SL', 'doc_date', 'DESC', 200,
             'fn_salesperson_performance_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_name', 'Sales Person', 'TEXT', 'LEFT', true, true, 160, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_count', 'Invoice Count', 'NUMBER', 'RIGHT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_count', 'Customer Count', 'NUMBER', 'RIGHT', true, true, 120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty', 'Qty', 'NUMBER', 'RIGHT', true, true, 100, 4, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'revenue', 'Revenue', 'NUMBER', 'RIGHT', true, true, 130, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'cost_value', 'Cost Value', 'NUMBER', 'RIGHT', true, true, 120, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit', 'Gross Profit', 'NUMBER', 'RIGHT', true, true, 130, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit_percent', 'GP %', 'NUMBER', 'RIGHT', true, true, 100, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no', 'Invoice No', 'TEXT', 'LEFT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 180, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Line Amount', 'NUMBER', 'RIGHT', true, true, 130, 11, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'doc_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"CANCELLED","label":"Cancelled"}]'::jsonb, 'status', false, 'APPROVED', 5);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'sales_person_id', 'sales_person_name', 'fn_salesperson_performance_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-SPP', 'Salesperson-wise Performance', '/reports/SALESPERSON_PERFORMANCE', 5, 'SL-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 5: Sales Return Register ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SALES_RETURN_REGISTER', 'Sales Return Register',
             'TABULAR', 'VIEW', 'v_sales_gross_profit_lines', 'SL', 'doc_date', 'DESC', 200,
             'fn_sales_return_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_no', 'Return No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer', 'TEXT', 'LEFT', true, true, 180, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no', 'Original Invoice No', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_date', 'Original Invoice Date', 'DATE', 'LEFT', true, true, 150, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason', 'Reason', 'TEXT', 'LEFT', true, true, 150, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount', 'Return Total', 'NUMBER', 'RIGHT', true, true, 130, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit', 'Reversed Gross Profit', 'NUMBER', 'RIGHT', true, true, 150, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty', 'Qty Returned', 'NUMBER', 'RIGHT', true, true, 120, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate', 'Rate', 'NUMBER', 'RIGHT', true, true, 100, 12, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE', NULL, NULL, NULL, 'doc_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_id', 'Customer', 'ACCOUNT_PICKER', NULL, NULL, NULL, 'customer_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason', 'Reason', 'DROPDOWN_LOOKUP', 'v_sales_return_reasons', 'reason_name', NULL, 'reason', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_id', 'Sales Person', 'DROPDOWN_LOOKUP', 'rim_sales_executives', 'full_name', NULL, 'sales_person_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP', 'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"}]'::jsonb, 'status', false, 'APPROVED', 6);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'doc_no', 'doc_no', 'fn_sales_return_register_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-RET', 'Sales Return Register', '/reports/SALES_RETURN_REGISTER', 6, 'SL-RPT', 'Reports', 1, false, false, false)
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
WHERE mm.feature_code IN ('SL-RPT-IGP', 'SL-RPT-VGP', 'SL-RPT-CGP', 'SL-RPT-SPP', 'SL-RPT-RET')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
