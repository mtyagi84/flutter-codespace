-- ============================================================
-- Migration 154: Material Requisition Register + Material Issue Register
-- ============================================================
-- Tenth/eleventh Inventory reports — document-register style, same shape
-- as every register report this session. Material Requisition is pure
-- intent (no stock movement, no batch/serial); Material Issue is what
-- actually leaves stock against one or more requisitions (has batch/
-- serial via the shared tables, source_doc_type='MATERIAL_ISSUE').
--
-- Requisition Status "Approved" bucket = anything past Draft (APPROVED,
-- PARTIALLY_ISSUED, CLOSED all map to 'APPROVED') — same status_group
-- technique as the Stock Transfer Register's own 3-state status (151).
--
-- "Consumption Area based on selected Department" reuses the existing
-- cascading-lookup-filter engine capability (migration 149) verbatim —
-- first real exercise of its "no expand_fn, plain equality" branch
-- (Category→Product needed fn_category_subtree; Department→Area is a
-- flat one-hop relationship, no expansion needed).
--
-- Full design: sakal/docs/screens/plan_material_requisition_issue_reports.md
-- ============================================================

-- ============================================================
-- Lookup views
-- ============================================================
CREATE OR REPLACE VIEW v_departments AS
SELECT
    m.id,
    m.client_id,
    m.company_id,
    m.description AS department_name
FROM rim_common_masters m
JOIN rim_common_master_types t ON t.id = m.type_id
WHERE t.type_key = 'DEPARTMENT'
  AND m.is_active = true
  AND m.is_deleted = false;

GRANT SELECT ON v_departments TO authenticated;

-- Exposes department_id as a real column so the cascading filter's own
-- plain-equality branch (depends_on_expand_fn IS NULL) can filter this
-- view directly by department_id=eq.<value>.
CREATE OR REPLACE VIEW v_consumption_areas AS
SELECT
    dca.id,
    dca.client_id,
    dca.company_id,
    dca.department_id,
    m.description AS area_name
FROM rim_department_consumption_areas dca
JOIN rim_common_masters m ON m.id = dca.consumption_area_id
WHERE dca.is_active = true AND dca.is_deleted = false;

GRANT SELECT ON v_consumption_areas TO authenticated;

-- requested_by is plain free text (no FK) — this is a DISTINCT-values
-- lookup, not a master table. The filter bar's generic {id,label} lookup
-- mechanism doesn't require "id" to be a UUID, so the raw text value
-- works directly as both id and label. Reused by both reports below.
CREATE OR REPLACE VIEW v_material_requisition_requesters AS
SELECT DISTINCT
    h.client_id,
    h.company_id,
    h.requested_by AS id,
    h.requested_by AS requester_name
FROM rih_material_requisition_headers h
WHERE h.requested_by IS NOT NULL AND h.is_deleted = false;

GRANT SELECT ON v_material_requisition_requesters TO authenticated;


-- ============================================================
-- v_material_requisition_lines — base VIEW. No serial expansion needed —
-- this module has no batch/serial tracking at all (pure intent document).
-- ============================================================
CREATE OR REPLACE VIEW v_material_requisition_lines AS
SELECT
    h.client_id, h.company_id,
    h.requisition_no, h.requisition_date, h.status,
    CASE WHEN h.status = 'DRAFT' THEN 'DRAFT' ELSE 'APPROVED' END AS status_group,
    h.location_id,
    h.requested_by,
    l.department_id, dept.description AS department_name,
    l.consumption_area_id, area.description AS consumption_area_name,
    l.barcode,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS qty
FROM rih_material_requisition_headers h
JOIN rid_material_requisition_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.requisition_no = h.requisition_no AND l.requisition_date = h.requisition_date
JOIN rim_products p ON p.id = l.product_id
LEFT JOIN rim_common_masters dept ON dept.id = l.department_id
LEFT JOIN rim_common_masters area ON area.id = l.consumption_area_id
LEFT JOIN rim_common_masters u    ON u.id    = l.uom_id
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

GRANT SELECT ON v_material_requisition_lines TO anon, authenticated, service_role;


-- ============================================================
-- fn_material_requisition_register_totals
-- ============================================================
CREATE OR REPLACE FUNCTION fn_material_requisition_register_totals(
    p_client_id           UUID,
    p_company_id          UUID,
    p_requisition_date_from DATE DEFAULT NULL,
    p_requisition_date_to   DATE DEFAULT NULL,
    p_location_id          UUID DEFAULT NULL,
    p_requested_by          TEXT DEFAULT NULL,
    p_product_id             UUID DEFAULT NULL,
    p_department_id           UUID DEFAULT NULL,
    p_consumption_area_id      UUID DEFAULT NULL,
    p_status_group              TEXT DEFAULT NULL
) RETURNS TABLE (
    qty       NUMERIC,
    row_count   BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty), 0), COUNT(*)
    FROM v_material_requisition_lines
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_requisition_date_from IS NULL OR requisition_date >= p_requisition_date_from)
      AND (p_requisition_date_to   IS NULL OR requisition_date <= p_requisition_date_to)
      AND (p_location_id           IS NULL OR location_id           = p_location_id)
      AND (p_requested_by           IS NULL OR requested_by           = p_requested_by)
      AND (p_product_id              IS NULL OR product_id              = p_product_id)
      AND (p_department_id            IS NULL OR department_id            = p_department_id)
      AND (p_consumption_area_id       IS NULL OR consumption_area_id       = p_consumption_area_id)
      AND (p_status_group                IS NULL OR status_group                = p_status_group);
$$;

GRANT EXECUTE ON FUNCTION fn_material_requisition_register_totals(
    UUID, UUID, DATE, DATE, UUID, TEXT, UUID, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- v_material_issue_lines — base VIEW, non-serial + serial-expansion
-- UNION ALL (this module DOES have batch/serial, source_doc_type=
-- 'MATERIAL_ISSUE'). Joins back to the ORIGINATING requisition header
-- purely to resolve requested_by.
-- ============================================================
CREATE OR REPLACE VIEW v_material_issue_lines AS
SELECT
    h.client_id, h.company_id,
    h.issue_no, h.issue_date, h.status,
    h.location_id,
    l.source_requisition_no, l.source_requisition_date,
    reqh.requested_by,
    l.department_id, dept.description AS department_name,
    l.consumption_area_id, area.description AS consumption_area_name,
    l.barcode,
    NULL::text AS serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.base_qty AS issue_qty
FROM rih_material_issue_headers h
JOIN rid_material_issue_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.issue_no = h.issue_no AND l.issue_date = h.issue_date
LEFT JOIN rih_material_requisition_headers reqh
    ON  reqh.client_id = h.client_id AND reqh.company_id = h.company_id
    AND reqh.requisition_no = l.source_requisition_no AND reqh.requisition_date = l.source_requisition_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type != 'SERIAL'
LEFT JOIN rim_common_masters dept ON dept.id = l.department_id
LEFT JOIN rim_common_masters area ON area.id = l.consumption_area_id
LEFT JOIN rim_common_masters u    ON u.id    = l.uom_id
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
    h.issue_no, h.issue_date, h.status,
    h.location_id,
    l.source_requisition_no, l.source_requisition_date,
    reqh.requested_by,
    l.department_id, dept.description AS department_name,
    l.consumption_area_id, area.description AS consumption_area_name,
    l.barcode,
    ts.serial_no,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    1::NUMERIC AS issue_qty
FROM rih_material_issue_headers h
JOIN rid_material_issue_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.issue_no = h.issue_no AND l.issue_date = h.issue_date
LEFT JOIN rih_material_requisition_headers reqh
    ON  reqh.client_id = h.client_id AND reqh.company_id = h.company_id
    AND reqh.requisition_no = l.source_requisition_no AND reqh.requisition_date = l.source_requisition_date
JOIN rim_products p ON p.id = l.product_id AND p.tracking_type = 'SERIAL'
JOIN rid_transaction_line_serials ts
    ON  ts.client_id = h.client_id AND ts.company_id = h.company_id
    AND ts.source_doc_type = 'MATERIAL_ISSUE'
    AND ts.source_doc_no = h.issue_no AND ts.source_doc_date = h.issue_date
    AND ts.line_serial = l.serial_no
LEFT JOIN rim_common_masters dept ON dept.id = l.department_id
LEFT JOIN rim_common_masters area ON area.id = l.consumption_area_id
LEFT JOIN rim_common_masters u    ON u.id    = l.uom_id
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

GRANT SELECT ON v_material_issue_lines TO anon, authenticated, service_role;


-- ============================================================
-- fn_material_issue_register_totals
-- ============================================================
CREATE OR REPLACE FUNCTION fn_material_issue_register_totals(
    p_client_id     UUID,
    p_company_id    UUID,
    p_issue_date_from DATE DEFAULT NULL,
    p_issue_date_to   DATE DEFAULT NULL,
    p_location_id    UUID DEFAULT NULL,
    p_requested_by    TEXT DEFAULT NULL,
    p_product_id       UUID DEFAULT NULL,
    p_department_id     UUID DEFAULT NULL,
    p_consumption_area_id UUID DEFAULT NULL,
    p_status               TEXT DEFAULT NULL
) RETURNS TABLE (
    issue_qty NUMERIC,
    row_count   BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(issue_qty), 0), COUNT(*)
    FROM v_material_issue_lines
    WHERE client_id  = p_client_id
      AND company_id = p_company_id
      AND (p_issue_date_from IS NULL OR issue_date >= p_issue_date_from)
      AND (p_issue_date_to   IS NULL OR issue_date <= p_issue_date_to)
      AND (p_location_id      IS NULL OR location_id      = p_location_id)
      AND (p_requested_by      IS NULL OR requested_by      = p_requested_by)
      AND (p_product_id          IS NULL OR product_id          = p_product_id)
      AND (p_department_id        IS NULL OR department_id        = p_department_id)
      AND (p_consumption_area_id    IS NULL OR consumption_area_id    = p_consumption_area_id)
      AND (p_status                    IS NULL OR status                    = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_material_issue_register_totals(
    UUID, UUID, DATE, DATE, UUID, TEXT, UUID, UUID, UUID, TEXT) TO authenticated;


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

        -- ============================================================
        -- Report 1 — Material Requisition Register
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'MATERIAL_REQUISITION_REGISTER', 'Material Requisition Register',
             'TABULAR', 'VIEW', 'v_material_requisition_lines', 'IN', 'requisition_date', 'DESC', 200,
             'fn_material_requisition_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'requisition_no', 'Requisition No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'requisition_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'department_name', 'Department', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'consumption_area_name', 'Area', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty', 'Qty', 'NUMBER', 'RIGHT', true, true, 100, 9, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order,
             depends_on_filter_key, depends_on_column, depends_on_expand_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Requisition Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'requisition_date', true, 'THIS_MONTH', 1, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'requested_by', 'Requested By', 'DROPDOWN_LOOKUP',
                'v_material_requisition_requesters', 'requester_name', NULL, 'requested_by', false, NULL, 3, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', NULL, 'product_id', false, NULL, 4, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'department_id', 'Department', 'DROPDOWN_LOOKUP',
                'v_departments', 'department_name', NULL, 'department_id', false, NULL, 5, NULL, NULL, NULL),
            -- Cascading: scoped to whatever department_id is currently
            -- selected above, via a plain equality filter (no expand_fn) —
            -- reuses the generic cascading mechanism built for Stock
            -- Details' Category→Product filter (149), first exercise of
            -- its non-hierarchical branch.
            (v_company.client_id, v_company.company_id, v_report_id, 'consumption_area_id', 'Area', 'DROPDOWN_LOOKUP',
                'v_consumption_areas', 'area_name', NULL, 'consumption_area_id', false, NULL, 6,
                'department_id', 'department_id', NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Pending"},{"value":"APPROVED","label":"Approved"}]'::jsonb,
                'status_group', false, 'APPROVED', 7, NULL, NULL, NULL);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-MRQ', 'Material Requisition Register',
             '/reports/MATERIAL_REQUISITION_REGISTER', 9, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ============================================================
        -- Report 2 — Material Issue Register
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'MATERIAL_ISSUE_REGISTER', 'Material Issue Register',
             'TABULAR', 'VIEW', 'v_material_issue_lines', 'IN', 'issue_date', 'DESC', 200,
             'fn_material_issue_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'issue_no', 'Issue No', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'issue_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_requisition_no', 'Requisition No', 'TEXT', 'LEFT', true, true, 130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'source_requisition_date', 'Requisition Date', 'DATE', 'LEFT', true, true, 130, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'department_name', 'Department', 'TEXT', 'LEFT', true, true, 150, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'consumption_area_name', 'Area', 'TEXT', 'LEFT', true, true, 150, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'issue_qty', 'Issue Qty', 'NUMBER', 'RIGHT', true, true, 110, 12, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order,
             depends_on_filter_key, depends_on_column, depends_on_expand_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Issue Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'issue_date', true, 'THIS_MONTH', 1, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'requested_by', 'Requested By', 'DROPDOWN_LOOKUP',
                'v_material_requisition_requesters', 'requester_name', NULL, 'requested_by', false, NULL, 3, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', NULL, 'product_id', false, NULL, 4, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'department_id', 'Department', 'DROPDOWN_LOOKUP',
                'v_departments', 'department_name', NULL, 'department_id', false, NULL, 5, NULL, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'consumption_area_id', 'Area', 'DROPDOWN_LOOKUP',
                'v_consumption_areas', 'area_name', NULL, 'consumption_area_id', false, NULL, 6,
                'department_id', 'department_id', NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Pending"},{"value":"APPROVED","label":"Approved"}]'::jsonb,
                'status', false, 'APPROVED', 7, NULL, NULL, NULL);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-MIS', 'Material Issue Register',
             '/reports/MATERIAL_ISSUE_REGISTER', 10, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- ric_user_menus backfill — both reports get the standard backfill (no
-- cost/value data here, so no Stock-Adjustment-style split needed).
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
WHERE mm.feature_code IN ('IN-RPT-MRQ', 'IN-RPT-MIS')
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
