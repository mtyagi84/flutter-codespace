-- ============================================================
-- Migration 155: Stock Adjustment Register regroup (document-level
--   grouping) + Stock Count Worksheet Register + Stock Count Variance
--   Report (two variants: with/without Value)
-- ============================================================
-- Treats migration 153 as ALREADY RUN (user confirmed) — this is a
-- follow-up migration, not an in-place edit of 153's own file. No changes
-- to v_stock_adjustment_lines, fn_stock_adjustment_register_totals, or any
-- existing function signature — everything here is either brand-new
-- objects or idempotent DELETE+INSERT registry rows targeting existing
-- report_ids by report_key (safe to re-run regardless of 153's run-state).
--
-- ---- Grouping design (user-reviewed via an artifact mockup) ----
-- Stock Adjustment Register (both variants) becomes a GROUPED report: one
-- collapsible row per document (Adjustment No / Date / Location / Reason —
-- the HEADER's own reason only, never a per-line override), expanding to
-- its own line items. "Grouped" in this reporting engine is NOT a
-- report_type value (report_type stays 'TABULAR' — CHECK constraint only
-- allows TABULAR/MATRIX/HIERARCHICAL) — it's TABULAR + a non-empty
-- ric_report_group_levels row, exactly the mechanism already proven by
-- Pending Bills by Customer/Supplier (migration 140). No changes to
-- ric_report_columns are needed: the existing declared columns
-- (adjustment_no/date/location_name/reason_name) already render inside the
-- group row via the summary function below; line-only columns (item,
-- qty, cost...) simply come back NULL from the summary function and
-- render as "—" on the group row, real values in the detail rows — same
-- behavior already proven by Pending Bills' own identity-vs-value column
-- split.
--
-- The group's own identity is resolved DIRECTLY from
-- rih_stock_adjustment_headers (not via v_stock_adjustment_lines) so the
-- Reason shown is unambiguously the HEADER's reason_id, never a line's
-- own override — a line-level override still displays correctly in its
-- own detail row via the view's existing COALESCE(line,header) reason_name
-- column, untouched.
--
-- ---- Stock Count Variance Report ----
-- Same grouping shape, reusing the identical group-summary pattern.
-- Thin wrapper view v_stock_count_variance_lines filters
-- v_stock_adjustment_lines to only the lines of adjustments auto-posted
-- from a Stock Count Review (rih_stock_adjustment_headers.source_doc_type
-- = 'STOCK_COUNT_REVIEW', set by fn_approve_stock_count_review since
-- migration 079) — built as an EXISTS filter over v_stock_adjustment_lines
-- rather than adding columns to that view, so 153's own view definition
-- is untouched. Review No/Date (source_doc_no/source_doc_date — 1:1 with
-- one adjustment, since one Review posts exactly one Adjustment) are
-- exposed only via the group summary function, same "identity field lives
-- at group level only" convention as the Adjustment Register's own regroup
-- above.
--
-- Same with/without-Value permission split as 153's own Report A/B
-- (STOCK_COUNT_VARIANCE_REPORT gets the normal backfill; its -V variant
-- deliberately gets none — an admin grants cost visibility per user).
--
-- ---- Stock Count Worksheet Register ----
-- Unrelated to the grouping work above — a flat, per-counted-line report
-- over Screen 1's own blind-count data (no system_qty anywhere in this
-- module's data path by design — see 078's own header comment). Lets a
-- manager/admin see what a specific counter actually recorded, filterable
-- by who counted it (submitted_by), location, category/nature scope, and
-- status.
--
-- Full design: sakal/docs/screens/plan_stock_count_reports.md
-- ============================================================


-- ============================================================
-- PIECE 1 — Stock Adjustment Register: add document-level grouping
-- ============================================================

-- Group summary — one row per document, resolved directly off the header
-- table (never via v_stock_adjustment_lines) so Reason is unambiguously
-- the HEADER's own reason_id. Same filter param names/shapes as
-- fn_stock_adjustment_register_totals (153) so the SAME declared
-- ric_report_filters continue to work unchanged for both the flat totals
-- call and this new group-summary call.
CREATE OR REPLACE FUNCTION fn_stock_adjustment_register_group_summary(
    p_client_id            UUID,
    p_company_id           UUID,
    p_adjustment_date_from DATE DEFAULT NULL,
    p_adjustment_date_to   DATE DEFAULT NULL,
    p_location_id          UUID DEFAULT NULL,
    p_effective_reason_id  UUID DEFAULT NULL,
    p_adjustment_type      TEXT DEFAULT NULL,
    p_status               TEXT DEFAULT NULL
) RETURNS TABLE (
    adjustment_no   TEXT,
    adjustment_date DATE,
    location_name   TEXT,
    reason_name     TEXT,
    doc_remarks     TEXT,
    row_count       BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT h.adjustment_no, h.adjustment_date, loc.location_name, r.description, h.remarks, COUNT(*)
    FROM rih_stock_adjustment_headers h
    JOIN rid_stock_adjustment_lines l
        ON  l.client_id = h.client_id AND l.company_id = h.company_id
        AND l.adjustment_no = h.adjustment_no AND l.adjustment_date = h.adjustment_date
    LEFT JOIN ric_locations      loc ON loc.id = h.location_id
    LEFT JOIN rim_common_masters r   ON r.id   = h.reason_id
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.is_deleted = false AND l.is_deleted = false
      AND (p_adjustment_date_from IS NULL OR h.adjustment_date >= p_adjustment_date_from)
      AND (p_adjustment_date_to   IS NULL OR h.adjustment_date <= p_adjustment_date_to)
      AND (p_location_id          IS NULL OR h.location_id     = p_location_id)
      AND (p_effective_reason_id  IS NULL OR COALESCE(l.reason_id, h.reason_id) = p_effective_reason_id)
      AND (p_adjustment_type      IS NULL OR (CASE WHEN l.adjust_flag = '+' THEN 'Increase' ELSE 'Decrease' END) = p_adjustment_type)
      AND (p_status                IS NULL OR h.status                = p_status)
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
    GROUP BY h.adjustment_no, h.adjustment_date, loc.location_name, r.description, h.remarks;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_adjustment_register_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, TEXT) TO authenticated;


-- Attach ONE group level to each of the two existing report definitions.
-- report_type stays 'TABULAR' (see header comment) — grouping comes
-- entirely from this table's own presence. Idempotent DELETE+INSERT,
-- targets rows by report_key so it's safe whether or not 153 already ran.
DO $$
DECLARE
    v_report_id UUID;
BEGIN
    FOR v_report_id IN
        SELECT id FROM ric_report_definitions
        WHERE report_key IN ('STOCK_ADJUSTMENT_REGISTER', 'STOCK_ADJUSTMENT_REGISTER_VALUE')
    LOOP
        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        SELECT rd.client_id, rd.company_id, rd.id, 1, 'adjustment_no', 'adjustment_no',
               'fn_stock_adjustment_register_group_summary'
        FROM ric_report_definitions rd WHERE rd.id = v_report_id;
    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- PIECE 3 (built ahead of Piece 2 since it shares the pattern above) —
-- Stock Count Variance Report — thin wrapper view + group summary +
-- totals + registry (two variants).
-- ============================================================

-- Thin wrapper — same row shape as v_stock_adjustment_lines (location
-- access, unit_cost/value already baked in there), narrowed to only the
-- lines of an adjustment auto-posted from a Stock Count Review. An EXISTS
-- filter against the header table rather than adding source_doc_type to
-- v_stock_adjustment_lines itself, so 153's own view is left untouched.
CREATE OR REPLACE VIEW v_stock_count_variance_lines AS
SELECT vsa.*
FROM v_stock_adjustment_lines vsa
WHERE EXISTS (
    SELECT 1 FROM rih_stock_adjustment_headers h
    WHERE h.client_id = vsa.client_id AND h.company_id = vsa.company_id
      AND h.adjustment_no = vsa.adjustment_no AND h.adjustment_date = vsa.adjustment_date
      AND h.source_doc_type = 'STOCK_COUNT_REVIEW'
);

GRANT SELECT ON v_stock_count_variance_lines TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION fn_stock_count_variance_totals(
    p_client_id            UUID,
    p_company_id           UUID,
    p_adjustment_date_from DATE DEFAULT NULL,
    p_adjustment_date_to   DATE DEFAULT NULL,
    p_location_id          UUID DEFAULT NULL,
    p_effective_reason_id  UUID DEFAULT NULL,
    p_adjustment_type      TEXT DEFAULT NULL,
    p_product_id           UUID DEFAULT NULL
) RETURNS TABLE (
    adjusted_qty NUMERIC,
    value        NUMERIC,
    row_count    BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(adjusted_qty), 0), COALESCE(SUM(value), 0), COUNT(*)
    FROM v_stock_count_variance_lines
    WHERE client_id  = p_client_id
    AND company_id = p_company_id
    AND (p_adjustment_date_from IS NULL OR adjustment_date >= p_adjustment_date_from)
    AND (p_adjustment_date_to   IS NULL OR adjustment_date <= p_adjustment_date_to)
    AND (p_location_id          IS NULL OR location_id          = p_location_id)
    AND (p_effective_reason_id  IS NULL OR effective_reason_id  = p_effective_reason_id)
    AND (p_adjustment_type      IS NULL OR adjustment_type      = p_adjustment_type)
    AND (p_product_id            IS NULL OR product_id            = p_product_id);
$$;

GRANT EXECUTE ON FUNCTION fn_stock_count_variance_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, UUID) TO authenticated;


-- Group summary — same shape as Piece 1's, plus Review No/Date
-- (source_doc_no/source_doc_date) since one Review maps 1:1 to one
-- Adjustment — added as identity columns on the SAME group row, never
-- duplicated per detail line.
CREATE OR REPLACE FUNCTION fn_stock_count_variance_group_summary(
    p_client_id            UUID,
    p_company_id           UUID,
    p_adjustment_date_from DATE DEFAULT NULL,
    p_adjustment_date_to   DATE DEFAULT NULL,
    p_location_id          UUID DEFAULT NULL,
    p_effective_reason_id  UUID DEFAULT NULL,
    p_adjustment_type      TEXT DEFAULT NULL,
    p_product_id           UUID DEFAULT NULL
) RETURNS TABLE (
    adjustment_no   TEXT,
    adjustment_date DATE,
    location_name   TEXT,
    reason_name     TEXT,
    review_no       TEXT,
    review_date     DATE,
    row_count       BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT h.adjustment_no, h.adjustment_date, loc.location_name, r.description,
           h.source_doc_no, h.source_doc_date, COUNT(*)
    FROM rih_stock_adjustment_headers h
    JOIN rid_stock_adjustment_lines l
        ON  l.client_id = h.client_id AND l.company_id = h.company_id
        AND l.adjustment_no = h.adjustment_no AND l.adjustment_date = h.adjustment_date
    LEFT JOIN ric_locations      loc ON loc.id = h.location_id
    LEFT JOIN rim_common_masters r   ON r.id   = h.reason_id
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.source_doc_type = 'STOCK_COUNT_REVIEW'
      AND h.is_deleted = false AND l.is_deleted = false
      AND (p_adjustment_date_from IS NULL OR h.adjustment_date >= p_adjustment_date_from)
      AND (p_adjustment_date_to   IS NULL OR h.adjustment_date <= p_adjustment_date_to)
      AND (p_location_id          IS NULL OR h.location_id     = p_location_id)
      AND (p_effective_reason_id  IS NULL OR COALESCE(l.reason_id, h.reason_id) = p_effective_reason_id)
      AND (p_adjustment_type      IS NULL OR (CASE WHEN l.adjust_flag = '+' THEN 'Increase' ELSE 'Decrease' END) = p_adjustment_type)
      AND (p_product_id            IS NULL OR l.product_id            = p_product_id)
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
    GROUP BY h.adjustment_no, h.adjustment_date, loc.location_name, r.description, h.source_doc_no, h.source_doc_date;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_count_variance_group_summary(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, UUID) TO authenticated;


-- ============================================================
-- PIECE 2 — Stock Count Worksheet Register (flat, per-counted-line)
-- ============================================================

-- Distinct-values lookup for the "Counted By" filter — submitted_by is a
-- real UUID FK to rim_users (unlike Material Requisition's free-text
-- requested_by), so this joins rim_users rather than SELECT DISTINCT text.
CREATE OR REPLACE VIEW v_stock_count_counters AS
SELECT DISTINCT
    h.client_id,
    h.company_id,
    u.id,
    u.full_name AS counter_name
FROM rih_stock_count_headers h
JOIN rim_users u ON u.id = h.submitted_by
WHERE h.submitted_by IS NOT NULL AND h.is_deleted = false;

GRANT SELECT ON v_stock_count_counters TO authenticated;


-- Base VIEW — no UNION ALL/serial expansion: a blind-count worksheet is
-- naturally per-line, and batch/serial (pure free-text new-lot entry, no
-- system reconciliation at this stage) isn't a reportable dimension here —
-- deliberate simplification, matching the module's own "counting is
-- blind, reconciliation happens at Review" split.
CREATE OR REPLACE VIEW v_stock_count_lines AS
SELECT
    h.client_id, h.company_id,
    h.count_no, h.count_date, h.status,
    h.location_id, loc.location_name,
    h.category_filter_id, cat.category_name,
    h.nature_filter,
    h.submitted_by, subu.full_name AS submitted_by_name,
    h.created_by, creu.full_name AS created_by_name,
    l.serial_no AS line_serial,
    l.barcode,
    l.is_counted,
    l.product_id, p.product_code, p.product_name,
    l.uom_id, u.description AS unit_name,
    l.counted_base_qty AS counted_qty
FROM rih_stock_count_headers h
JOIN rid_stock_count_lines l
    ON  l.client_id = h.client_id AND l.company_id = h.company_id
    AND l.count_no = h.count_no AND l.count_date = h.count_date
JOIN rim_products p ON p.id = l.product_id
LEFT JOIN rim_common_masters u    ON u.id    = l.uom_id
LEFT JOIN ric_locations      loc  ON loc.id  = h.location_id
LEFT JOIN rim_item_categories cat ON cat.id  = h.category_filter_id
LEFT JOIN rim_users subu ON subu.id = h.submitted_by
LEFT JOIN rim_users creu ON creu.id = h.created_by
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

GRANT SELECT ON v_stock_count_lines TO anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION fn_stock_count_worksheet_register_totals(
    p_client_id       UUID,
    p_company_id      UUID,
    p_count_date_from DATE DEFAULT NULL,
    p_count_date_to   DATE DEFAULT NULL,
    p_location_id     UUID DEFAULT NULL,
    p_category_filter_id UUID DEFAULT NULL,
    p_nature_filter   TEXT DEFAULT NULL,
    p_submitted_by    UUID DEFAULT NULL,
    p_product_id      UUID DEFAULT NULL,
    p_status          TEXT DEFAULT NULL
) RETURNS TABLE (
    counted_qty NUMERIC,
    row_count   BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(counted_qty), 0), COUNT(*)
    FROM v_stock_count_lines
    WHERE client_id  = p_client_id
    AND company_id = p_company_id
    AND (p_count_date_from    IS NULL OR count_date          >= p_count_date_from)
    AND (p_count_date_to      IS NULL OR count_date          <= p_count_date_to)
    AND (p_location_id        IS NULL OR location_id         = p_location_id)
    AND (p_category_filter_id IS NULL OR category_filter_id  = p_category_filter_id)
    AND (p_nature_filter      IS NULL OR nature_filter        = p_nature_filter)
    AND (p_submitted_by       IS NULL OR submitted_by         = p_submitted_by)
    AND (p_product_id          IS NULL OR product_id           = p_product_id)
    AND (p_status               IS NULL OR status               = p_status);
$$;

GRANT EXECUTE ON FUNCTION fn_stock_count_worksheet_register_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, TEXT, UUID, UUID, TEXT) TO authenticated;


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
        -- Report — Stock Count Worksheet Register
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_COUNT_WORKSHEET_REGISTER', 'Stock Count Worksheet Register',
             'TABULAR', 'VIEW', 'v_stock_count_lines', 'IN', 'count_date', 'DESC', 200,
             'fn_stock_count_worksheet_register_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'count_no', 'Count No', 'TEXT', 'LEFT', true, true, 120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'count_date', 'Date', 'DATE', 'LEFT', true, true, 110, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_name', 'Category', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'nature_filter', 'Nature', 'TEXT', 'LEFT', true, true, 110, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'submitted_by_name', 'Counted By', 'TEXT', 'LEFT', true, true, 150, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'is_counted', 'Counted?', 'BOOLEAN', 'CENTER', true, true, 100, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'counted_qty', 'Counted Qty', 'NUMBER', 'RIGHT', true, true, 120, 12, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Count Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'count_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_filter_id', 'Category', 'DROPDOWN_LOOKUP',
                'rim_item_categories', 'category_name', NULL, 'category_filter_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'nature_filter', 'Nature', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"TRADING","label":"Trading"},{"value":"FINISHED_GOOD","label":"Finished Good"},{"value":"RAW_MATERIAL","label":"Raw Material"},{"value":"PACKAGING","label":"Packaging"},{"value":"CONSUMABLE","label":"Consumable"},{"value":"SERVICE","label":"Service"}]'::jsonb,
                'nature_filter', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'submitted_by', 'Counted By', 'DROPDOWN_LOOKUP',
                'v_stock_count_counters', 'counter_name', NULL, 'submitted_by', false, NULL, 5),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', NULL, 'product_id', false, NULL, 6),
            (v_company.client_id, v_company.company_id, v_report_id, 'status', 'Status', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"DRAFT","label":"Draft"},{"value":"SUBMITTED","label":"Submitted"},{"value":"CONSOLIDATED","label":"Consolidated"}]'::jsonb,
                'status', false, NULL, 7);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SCW', 'Stock Count Worksheet Register',
             '/reports/STOCK_COUNT_WORKSHEET_REGISTER', 11, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ============================================================
        -- Report — Stock Count Variance Report (Qty only), GROUPED
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_COUNT_VARIANCE_REPORT', 'Stock Count Variance Report',
             'TABULAR', 'VIEW', 'v_stock_count_variance_lines', 'IN', 'adjustment_date', 'DESC', 200,
             'fn_stock_count_variance_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_no', 'Adjustment No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_date', 'Adjustment Date', 'DATE', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_name', 'Reason', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'review_no', 'Review No', 'TEXT', 'LEFT', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'review_date', 'Review Date', 'DATE', 'LEFT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'BADGE', 'CENTER', true, true, 130, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'system_qty', 'System Qty', 'NUMBER', 'RIGHT', true, true, 110, 13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjusted_qty', 'Adjusted Qty', 'NUMBER', 'RIGHT', true, true, 120, 14, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Adjustment Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'adjustment_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_id', 'Reason', 'DROPDOWN_LOOKUP',
                'v_stock_adjustment_reasons', 'reason_name', NULL, 'effective_reason_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', NULL, 'product_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"Increase","label":"Increase"},{"value":"Decrease","label":"Decrease"}]'::jsonb,
                'adjustment_type', false, NULL, 5);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'adjustment_no', 'adjustment_no',
             'fn_stock_count_variance_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SCV', 'Stock Count Variance Report',
             '/reports/STOCK_COUNT_VARIANCE_REPORT', 12, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

        -- ============================================================
        -- Report — Stock Count Variance Report (with Value), GROUPED.
        -- Deliberately gets NO automatic ric_user_menus backfill below —
        -- same convention as STOCK_ADJUSTMENT_REGISTER_VALUE (153).
        -- ============================================================
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'STOCK_COUNT_VARIANCE_REPORT_VALUE', 'Stock Count Variance Report (with Value)',
             'TABULAR', 'VIEW', 'v_stock_count_variance_lines', 'IN', 'adjustment_date', 'DESC', 200,
             'fn_stock_count_variance_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_no', 'Adjustment No', 'TEXT', 'LEFT', true, true, 130, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_date', 'Adjustment Date', 'DATE', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 150, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_name', 'Reason', 'TEXT', 'LEFT', true, true, 150, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'review_no', 'Review No', 'TEXT', 'LEFT', true, true, 130, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'review_date', 'Review Date', 'DATE', 'LEFT', true, true, 120, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'barcode', 'Barcode', 'TEXT', 'LEFT', true, true, 130, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'serial_no', 'Serial No', 'TEXT', 'LEFT', true, true, 130, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'BADGE', 'CENTER', true, true, 130, 12, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'system_qty', 'System Qty', 'NUMBER', 'RIGHT', true, true, 110, 13, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjusted_qty', 'Adjusted Qty', 'NUMBER', 'RIGHT', true, true, 120, 14, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_cost', 'Unit Cost', 'NUMBER', 'RIGHT', true, true, 110, 15, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'value', 'Value', 'NUMBER', 'RIGHT', true, true, 130, 16, 'SUM');

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Adjustment Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'adjustment_date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'reason_id', 'Reason', 'DROPDOWN_LOOKUP',
                'v_stock_adjustment_reasons', 'reason_name', NULL, 'effective_reason_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', NULL, 'product_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'adjustment_type', 'Adjustment Type', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"Increase","label":"Increase"},{"value":"Decrease","label":"Decrease"}]'::jsonb,
                'adjustment_type', false, NULL, 5);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'adjustment_no', 'adjustment_no',
             'fn_stock_count_variance_group_summary');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SCV-V', 'Stock Count Variance Report (with Value)',
             '/reports/STOCK_COUNT_VARIANCE_REPORT_VALUE', 13, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- ric_user_menus backfill — Worksheet Register and Variance Report (Qty
-- only) get the standard backfill. Variance Report (with Value) gets NONE
-- — same deliberate carve-out as STOCK_ADJUSTMENT_REGISTER_VALUE (153):
-- cost/value data isn't retroactively exposed to every existing user, an
-- admin grants IN-RPT-SCV-V per-user afterward.
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
WHERE mm.feature_code IN ('IN-RPT-SCW', 'IN-RPT-SCV')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
