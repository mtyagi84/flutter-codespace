-- ============================================================
-- Migration 127: Sales Register report + runtime Base/Local currency
-- toggle (engine enhancement).
-- ============================================================
-- Part A — engine enhancement (generic, not Sales-specific): a report can
-- now declare a same-shape Local-currency twin of its own source_object/
-- totals_source_object. When populated, the Flutter screen shows a
-- Currency toggle instead of the report needing a second report_key.
-- v_sales_details_base/v_sales_details_local (126) already share
-- identical column names, so the exact same ric_report_columns/
-- ric_report_filters rows below work against either object unchanged.
-- ============================================================
ALTER TABLE ric_report_definitions
    ADD COLUMN IF NOT EXISTS source_object_local        TEXT,
    ADD COLUMN IF NOT EXISTS totals_source_object_local  TEXT;

-- ============================================================
-- v_user_accessible_locations — the Location filter's own lookup_source,
-- scoped by ric_user_location_access the same way v_sales_details_base/
-- local's own WHERE clause is (029; zero active rows for the JWT's user =
-- unrestricted, any rows = limited to that set) so the picker never lists
-- an option the underlying data-scoping would silently return zero rows
-- for. sakal_report_filter_bar.dart's DROPDOWN_LOOKUP handling needs no
-- Flutter change — it already just does
-- GET /{lookup_source}?select=id,{lookup_label_column} against whatever
-- object name ric_report_filters.lookup_source names, and a view behaves
-- identically to a table there.
-- ============================================================
CREATE OR REPLACE VIEW v_user_accessible_locations AS
SELECT
    loc.id,
    loc.client_id,
    loc.company_id,
    loc.location_name,
    loc.location_short
FROM ric_locations loc
WHERE loc.is_deleted = false
  AND (
      NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                  WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = loc.client_id AND ula.company_id = loc.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
      OR loc.id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                      AND ula.client_id = loc.client_id AND ula.company_id = loc.company_id
                      AND ula.is_active = true AND ula.is_deleted = false)
  );

GRANT SELECT ON v_user_accessible_locations TO anon, authenticated, service_role;


-- ============================================================
-- Part B — Sales Register: report-level totals, one per currency object.
-- STABLE FUNCTIONs, not VIEWs (v_pending_bills-pilot reasoning, 118) — a
-- pre-aggregated VIEW has already collapsed away the very columns
-- PostgREST would need to filter on. Filter args mirror the
-- ric_report_filters rows below exactly (p_<param_target>, date-range as
-- p_<param_target>_from/_to) — see report_repository.dart's
-- _buildFilterParams for the naming convention this must match.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_sales_register_totals_base(
    p_client_id      UUID,
    p_company_id     UUID,
    p_doc_date_from  DATE DEFAULT NULL,
    p_doc_date_to    DATE DEFAULT NULL,
    p_customer_id    UUID DEFAULT NULL,
    p_product_id     UUID DEFAULT NULL,
    p_location_id    UUID DEFAULT NULL,
    p_record_type    TEXT DEFAULT NULL,
    p_status         TEXT DEFAULT NULL,
    p_doc_no         TEXT DEFAULT NULL
) RETURNS TABLE (
    gross_amount    NUMERIC,
    discount_amount NUMERIC,
    tax_amount      NUMERIC,
    final_amount    NUMERIC,
    cost_value      NUMERIC,
    gross_profit    NUMERIC,
    row_count       BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(gross_amount), 0),
        COALESCE(SUM(discount_amount), 0),
        COALESCE(SUM(tax_amount), 0),
        COALESCE(SUM(final_amount), 0),
        COALESCE(SUM(cost_value), 0),
        COALESCE(SUM(gross_profit), 0),
        COUNT(*)
    FROM v_sales_details_base
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_doc_date_from IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to   IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id   IS NULL OR customer_id = p_customer_id)
      AND (p_product_id    IS NULL OR product_id  = p_product_id)
      AND (p_location_id   IS NULL OR location_id = p_location_id)
      AND (p_record_type   IS NULL OR record_type = p_record_type)
      AND (p_status        IS NULL OR status      = p_status)
      AND (p_doc_no        IS NULL OR doc_no ILIKE '%' || p_doc_no || '%');
$$;

GRANT EXECUTE ON FUNCTION fn_sales_register_totals_base(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_sales_register_totals_local(
    p_client_id      UUID,
    p_company_id     UUID,
    p_doc_date_from  DATE DEFAULT NULL,
    p_doc_date_to    DATE DEFAULT NULL,
    p_customer_id    UUID DEFAULT NULL,
    p_product_id     UUID DEFAULT NULL,
    p_location_id    UUID DEFAULT NULL,
    p_record_type    TEXT DEFAULT NULL,
    p_status         TEXT DEFAULT NULL,
    p_doc_no         TEXT DEFAULT NULL
) RETURNS TABLE (
    gross_amount    NUMERIC,
    discount_amount NUMERIC,
    tax_amount      NUMERIC,
    final_amount    NUMERIC,
    cost_value      NUMERIC,
    gross_profit    NUMERIC,
    row_count       BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(gross_amount), 0),
        COALESCE(SUM(discount_amount), 0),
        COALESCE(SUM(tax_amount), 0),
        COALESCE(SUM(final_amount), 0),
        COALESCE(SUM(cost_value), 0),
        COALESCE(SUM(gross_profit), 0),
        COUNT(*)
    FROM v_sales_details_local
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_doc_date_from IS NULL OR doc_date >= p_doc_date_from)
      AND (p_doc_date_to   IS NULL OR doc_date <= p_doc_date_to)
      AND (p_customer_id   IS NULL OR customer_id = p_customer_id)
      AND (p_product_id    IS NULL OR product_id  = p_product_id)
      AND (p_location_id   IS NULL OR location_id = p_location_id)
      AND (p_record_type   IS NULL OR record_type = p_record_type)
      AND (p_status        IS NULL OR status      = p_status)
      AND (p_doc_no        IS NULL OR doc_no ILIKE '%' || p_doc_no || '%');
$$;

GRANT EXECUTE ON FUNCTION fn_sales_register_totals_local(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- Part C — registry rows + menu, one full set per existing company.
-- status is intentionally NOT hardcoded into the view (126) — every
-- report built on it must apply its own default, which the 'status'
-- filter below does (default_value = APPROVED).
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

        -- Skip a company that hasn't had the Sales module seeded at all
        -- (shouldn't happen for a real company, defensive only).
        CONTINUE WHEN v_sl_module_id IS NULL;

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             source_object_local, module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'SALES_REGISTER', 'Sales Register',
             'TABULAR', 'VIEW', 'v_sales_details_base', 'v_sales_details_local', 'SL',
             'doc_date', 'DESC', 50, 'fn_sales_register_totals_base', 'fn_sales_register_totals_local')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object_local = excluded.source_object_local,
                totals_source_object_local = excluded.totals_source_object_local
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_no',        'Doc No',         'TEXT',   'LEFT',   true, true,  100, 1,  NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_date',      'Date',           'DATE',   'LEFT',   true, true,  90,  2,  NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'record_type',   'Type',           'BADGE',  'CENTER', true, true,  60,  3,  NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer_name', 'Customer',       'TEXT',   'LEFT',   true, true,  160, 4,  NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name',  'Product',        'TEXT',   'LEFT',   true, true,  180, 5,  NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'base_qty',      'Qty',            'NUMBER', 'RIGHT',  true, true,  80,  6,  'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'rate',          'Rate',           'NUMBER', 'RIGHT',  true, true,  90,  7,  NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_amount',  'Gross Amt',      'NUMBER', 'RIGHT',  true, true,  100, 8,  'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_amount',    'Tax',            'NUMBER', 'RIGHT',  true, true,  90,  9,  'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'final_amount',  'Net Amount',     'NUMBER', 'RIGHT',  true, true,  110, 10, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'cost_value',    'Cost',           'NUMBER', 'RIGHT',  true, true,  100, 11, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit',  'Profit',         'NUMBER', 'RIGHT',  true, true,  100, 12, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'status',        'Status',         'BADGE',  'CENTER', true, true,  90,  13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'invoice_no',    'Ref Invoice No', 'TEXT',   'LEFT',   true, false, 130, 14, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'discount_amount','Discount',      'NUMBER', 'RIGHT',  true, false, 100, 15, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'discount_percent','Disc %',       'NUMBER', 'RIGHT',  true, false, 80,  16, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location',       'TEXT',   'LEFT',   true, false, 140, 17, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_person_name','Salesperson', 'TEXT',   'LEFT',   true, false, 140, 18, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'uom_name',      'UOM',            'TEXT',   'LEFT',   true, false, 80,  19, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'gross_profit_percent','Profit %', 'NUMBER', 'RIGHT',  true, false, 90,  20, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'currency_code', 'Currency',       'TEXT',   'LEFT',   true, false, 90,  21, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_remarks',   'Remarks',        'TEXT',   'LEFT',   true, false, 200, 22, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, static_options, param_target, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'doc_date', 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'customer', 'Customer', 'ACCOUNT_PICKER',
                NULL, NULL, NULL, 'customer_id', NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'product', 'Product', 'PRODUCT_PICKER',
                NULL, NULL, NULL, 'product_id', NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'location', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'record_type', 'Type', 'DROPDOWN_STATIC',
                NULL, NULL, '[{"value":"S","label":"Sales"},{"value":"R","label":"Returns"}]'::jsonb,
                'record_type', NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"APPROVED","label":"Approved"},{"value":"CANCELLED","label":"Cancelled"}]'::jsonb,
                'status', 'APPROVED', 6),
            (v_company.client_id, v_company.company_id, v_report_id, 'doc_search', 'Doc No', 'TEXT',
                NULL, NULL, NULL, 'doc_no', NULL, 7);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_sl_module_id, 'SL-RPT-REG', 'Sales Register',
             '/reports/SALES_REGISTER', 0, 'SL-RPT', 'Reports', 2, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$;


-- ============================================================
-- Part D — ric_user_menus backfill (same pattern as migration 119): a
-- ric_master_menus row alone makes a feature ELIGIBLE, it grants nobody
-- anything. Give VIEW access to whoever already has view access to any
-- other Sales (SL) feature.
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
WHERE mm.feature_code = 'SL-RPT-REG'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
