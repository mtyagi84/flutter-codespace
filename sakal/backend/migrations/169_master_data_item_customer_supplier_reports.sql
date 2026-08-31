-- ============================================================
-- Migration 169: Master Data Reports — Item/Product, Customer, Supplier Master
-- ============================================================
-- First of five Master-Data-reporting migrations covering the 13-report
-- design in sakal/docs/screens/artifact_master_data_reports_plan.html. No
-- Master screen anywhere has a Print/Export button today — confirmed
-- greenfield. Every report registered in ric_report_definitions already
-- gets a working PDF/Excel export for free (lib/core/reporting/) — this
-- batch is purely migration/registry work, zero new Flutter code.
--
-- Master data is NOT location-scoped (rim_products/rim_accounts are
-- company-wide) — none of these views need the ric_user_location_access
-- pattern every Purchase/Sales/Finance/Inventory report view uses.
--
-- Menu placement: one new group_code 'MST-RPT' ("Master Reports") under
-- the SAME shared 'AD' (Admin/Setup) system module every other Master
-- screen already lives in (confirmed via fn_seed_client_modules.sql) —
-- not a new module_code.
-- ============================================================

-- ============================================================
-- Report 1 — Item / Product Master Report
-- ============================================================
CREATE OR REPLACE VIEW v_product_master_report AS
SELECT
    p.client_id, p.company_id,
    p.product_code, p.barcode, p.part_number, p.product_name, p.product_nature,
    cat.category_name, brand.description AS brand_name,
    uom.description AS base_uom_name,
    p.tracking_type,
    stg.group_name AS sales_tax_group_name,
    ptg.group_name AS purchase_tax_group_name,
    p.hsn_sac_code,
    sup.account_code AS main_supplier_code, sup.account_name AS main_supplier_name,
    p.standard_cost, p.average_cost, p.last_purchase_cost,
    p.is_active
FROM rim_products p
LEFT JOIN rim_item_categories cat ON cat.id = p.category_id
LEFT JOIN rim_common_masters  brand ON brand.id = p.brand_id
LEFT JOIN rim_common_masters  uom   ON uom.id = p.base_uom_id
LEFT JOIN rim_tax_groups stg ON stg.id = p.sales_tax_group_id
LEFT JOIN rim_tax_groups ptg ON ptg.id = p.purchase_tax_group_id
LEFT JOIN rim_accounts sup ON sup.id = p.main_supplier_id
WHERE p.is_deleted = false;

GRANT SELECT ON v_product_master_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_product_master_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_category_id UUID DEFAULT NULL,
    p_brand_id UUID DEFAULT NULL,
    p_tracking_type TEXT DEFAULT NULL,
    p_product_nature TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_product_master_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_category_id     IS NULL OR category_name = (SELECT category_name FROM rim_item_categories WHERE id = p_category_id))
      AND (p_brand_id        IS NULL OR brand_name = (SELECT description FROM rim_common_masters WHERE id = p_brand_id))
      AND (p_tracking_type   IS NULL OR tracking_type = p_tracking_type)
      AND (p_product_nature  IS NULL OR product_nature = p_product_nature)
      AND (p_is_active       IS NULL OR is_active = p_is_active);
$$;

GRANT EXECUTE ON FUNCTION fn_product_master_report_totals(
    UUID, UUID, UUID, UUID, TEXT, TEXT, BOOLEAN) TO authenticated;


-- ============================================================
-- Report 2/3 — Customer Master + Supplier Master Report (shared view)
-- ============================================================
CREATE OR REPLACE VIEW v_party_master_report AS
SELECT
    a.client_id, a.company_id,
    a.account_code, a.account_name, a.account_nature,
    a.party_type, a.party_category, a.contact_person, a.phone, a.email,
    a.address_line1, a.address_line2, city.city_name, country.country_name,
    cur.currency_id AS ledger_currency_code,
    a.tax_id, a.credit_limit, a.credit_days, a.is_credit_blocked, a.is_active
FROM rim_accounts a
LEFT JOIN rim_cities city ON city.id = a.city_id
LEFT JOIN rim_countries country ON country.id = a.country_id
LEFT JOIN rim_currencies cur ON cur.id = a.account_currency_id
WHERE a.is_deleted = false AND a.account_nature IN ('Customer', 'Supplier');

GRANT SELECT ON v_party_master_report TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fn_party_master_report_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_account_nature TEXT,
    p_party_category TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL,
    p_is_credit_blocked BOOLEAN DEFAULT NULL
) RETURNS TABLE (row_count BIGINT) LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)
    FROM v_party_master_report
    WHERE client_id = p_client_id AND company_id = p_company_id AND account_nature = p_account_nature
      AND (p_party_category    IS NULL OR party_category = p_party_category)
      AND (p_is_active         IS NULL OR is_active = p_is_active)
      AND (p_is_credit_blocked IS NULL OR is_credit_blocked = p_is_credit_blocked);
$$;

GRANT EXECUTE ON FUNCTION fn_party_master_report_totals(
    UUID, UUID, TEXT, TEXT, BOOLEAN, BOOLEAN) TO authenticated;


-- ============================================================
-- Registry rows, one per existing company
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_ad_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_ad_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'AD';

        CONTINUE WHEN v_ad_module_id IS NULL;

        -- ---------------- Report 1: Item / Product Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PRODUCT_MASTER_REPORT', 'Item / Product Master Report',
             'TABULAR', 'VIEW', 'v_product_master_report', 'AD', 'product_code', 'ASC', 500,
             'fn_product_master_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Product Code', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Product Name', 'TEXT', 'LEFT', true, true, 220, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_name', 'Category', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'brand_name', 'Brand', 'TEXT', 'LEFT', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'base_uom_name', 'UOM', 'TEXT', 'LEFT', true, true, 90, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tracking_type', 'Tracking Type', 'BADGE', 'CENTER', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sales_tax_group_name', 'Sales Tax Group', 'TEXT', 'LEFT', true, true, 150, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'purchase_tax_group_name', 'Purchase Tax Group', 'TEXT', 'LEFT', true, true, 150, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'hsn_sac_code', 'HSN/SAC Code', 'TEXT', 'LEFT', true, true, 120, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'main_supplier_name', 'Main Supplier', 'TEXT', 'LEFT', true, true, 180, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'standard_cost', 'Standard Cost', 'NUMBER', 'RIGHT', true, true, 120, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 13, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP', 'rim_item_categories', 'category_name', NULL, 'category_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'brand_id', 'Brand', 'DROPDOWN_LOOKUP', 'v_product_brands', 'brand_name', NULL, 'brand_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'tracking_type', 'Tracking Type', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"NONE","label":"None"},{"value":"BATCH","label":"Batch"},{"value":"SERIAL","label":"Serial"},{"value":"BATCH_WITH_EXPIRY","label":"Batch with Expiry"}]'::jsonb, 'tracking_type', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_nature', 'Product Nature', 'DROPDOWN_STATIC', NULL, NULL,
                '[{"value":"TRADING","label":"Trading"},{"value":"FINISHED_GOOD","label":"Finished Good"},{"value":"RAW_MATERIAL","label":"Raw Material"},{"value":"PACKAGING","label":"Packaging"},{"value":"CONSUMABLE","label":"Consumable"},{"value":"SERVICE","label":"Service"}]'::jsonb, 'product_nature', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 5);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-PRD', 'Item / Product Master Report', '/reports/PRODUCT_MASTER_REPORT', 1, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 2: Customer Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'CUSTOMER_MASTER_REPORT', 'Customer Master Report',
             'TABULAR', 'VIEW', 'v_party_master_report', 'AD', 'account_name', 'ASC', 500,
             'fn_party_master_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_code', 'Code', 'TEXT', 'LEFT', true, true, 100, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Customer Name', 'TEXT', 'LEFT', true, true, 200, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'contact_person', 'Contact Person', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'phone', 'Phone', 'TEXT', 'LEFT', true, true, 130, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'email', 'Email', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'address_line1', 'Address', 'TEXT', 'LEFT', true, true, 220, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'city_name', 'City', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'ledger_currency_code', 'Ledger Currency', 'TEXT', 'LEFT', true, true, 120, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'credit_limit', 'Credit Limit', 'NUMBER', 'RIGHT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'credit_days', 'Credit Days', 'NUMBER', 'RIGHT', true, true, 110, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_id', 'Tax ID', 'TEXT', 'LEFT', true, true, 130, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_credit_blocked', 'Credit Blocked', 'BOOLEAN', 'CENTER', true, true, 110, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 13, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'party_category', 'Party Category', 'TEXT', NULL, NULL, NULL, 'party_category', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_credit_blocked', 'Credit Blocked', 'BOOLEAN', NULL, NULL, NULL, 'is_credit_blocked', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-CUS', 'Customer Master Report', '/reports/CUSTOMER_MASTER_REPORT', 2, 'MST-RPT', 'Master Reports', 6, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ---------------- Report 3: Supplier Master Report ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'SUPPLIER_MASTER_REPORT', 'Supplier Master Report',
             'TABULAR', 'VIEW', 'v_party_master_report', 'AD', 'account_name', 'ASC', 500,
             'fn_party_master_report_totals', true)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object, auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible, default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_code', 'Code', 'TEXT', 'LEFT', true, true, 100, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Supplier Name', 'TEXT', 'LEFT', true, true, 200, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'contact_person', 'Contact Person', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'phone', 'Phone', 'TEXT', 'LEFT', true, true, 130, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'email', 'Email', 'TEXT', 'LEFT', true, true, 180, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'address_line1', 'Address', 'TEXT', 'LEFT', true, true, 220, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'city_name', 'City', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'ledger_currency_code', 'Ledger Currency', 'TEXT', 'LEFT', true, true, 120, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'tax_id', 'Tax ID', 'TEXT', 'LEFT', true, true, 130, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active', 'BOOLEAN', 'CENTER', true, true, 90, 10, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'party_category', 'Party Category', 'TEXT', NULL, NULL, NULL, 'party_category', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_active', 'Active Only', 'BOOLEAN', NULL, NULL, NULL, 'is_active', false, 'true', 2);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-RPT-SUP', 'Supplier Master Report', '/reports/SUPPLIER_MASTER_REPORT', 3, 'MST-RPT', 'Master Reports', 6, false, false, false)
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
WHERE mm.feature_code IN ('MST-RPT-PRD', 'MST-RPT-CUS', 'MST-RPT-SUP')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
