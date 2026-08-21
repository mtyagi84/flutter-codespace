-- ============================================================
-- Migration 150: Stock Ledger report (per-product transaction statement,
--   running balance) + fn_resolve_transaction_remarks
-- ============================================================
-- Fourth Inventory report, modeled explicitly on the Finance Account
-- Ledger report (132_account_ledger_report.sql) — Opening Qty as its own
-- first row, every real transaction in the date range with a running
-- balance, Closing Qty as its own last row. Unlike the other three
-- Inventory reports (148/149) this is a per-transaction DETAIL report for
-- ONE product, not a summary across the catalog.
--
-- Remarks is resolved via a SEPARATE, dedicated function
-- (fn_resolve_transaction_remarks) rather than inlined into the ledger
-- query or a write-time denormalized column — user-specified design, so
-- that adding/changing what Remarks shows for one document type in the
-- future only ever touches that one function, never this report. Safe
-- performance-wise specifically because Product is a required filter, so
-- one product's ledger over a date range is inherently small.
--
-- Full design: sakal/docs/screens/plan_stock_ledger_report.md
-- ============================================================

-- ============================================================
-- Part A — fn_resolve_transaction_remarks
-- ============================================================
-- One branch per real source_doc_type value ever passed to
-- fn_post_stock_movement (confirmed exhaustive list via research across
-- every migration). Never repeats the document's own no/date (that's
-- already the caller's Transaction No/Date columns) — only genuinely new
-- information: party name, a DIFFERENT document's own reference number,
-- a reason, or (for transfers) a location.
CREATE OR REPLACE FUNCTION fn_resolve_transaction_remarks(
    p_client_id       UUID,
    p_company_id      UUID,
    p_source_doc_type TEXT,
    p_source_doc_no   TEXT,
    p_source_doc_date DATE
) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_remarks TEXT;
BEGIN
    CASE p_source_doc_type
    WHEN 'GRN' THEN
        SELECT 'Supplier: ' || a.account_name INTO v_remarks
        FROM rih_grn_headers h
        JOIN rim_accounts a ON a.id = h.supplier_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.grn_no = p_source_doc_no AND h.grn_date = p_source_doc_date;

    WHEN 'PURCHASE_RETURN' THEN
        SELECT 'Supplier: ' || a.account_name || COALESCE(' | Reason: ' || h.reason, '') INTO v_remarks
        FROM rih_purchase_return_headers h
        JOIN rim_accounts a ON a.id = h.supplier_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.return_no = p_source_doc_no AND h.return_date = p_source_doc_date;

    WHEN 'SALES_INVOICE' THEN
        SELECT 'Customer: ' || COALESCE(a.account_name, h.party_name, '-')
               || COALESCE(' | Order: ' || h.order_no, '') INTO v_remarks
        FROM rih_sales_invoices h
        LEFT JOIN rim_accounts a ON a.id = h.customer_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.invoice_no = p_source_doc_no AND h.invoice_date = p_source_doc_date;

    WHEN 'SALES_DELIVERY' THEN
        SELECT 'Customer: ' || a.account_name || COALESCE(' | Invoice: ' || h.invoice_no, '') INTO v_remarks
        FROM rih_sales_delivery_headers h
        JOIN rim_accounts a ON a.id = h.customer_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.delivery_no = p_source_doc_no AND h.delivery_date = p_source_doc_date;

    WHEN 'SALES_RETURN' THEN
        SELECT 'Customer: ' || a.account_name || COALESCE(' | Reason: ' || h.reason, '') INTO v_remarks
        FROM rih_sales_return_headers h
        JOIN rim_accounts a ON a.id = h.customer_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.return_no = p_source_doc_no AND h.return_date = p_source_doc_date;

    WHEN 'STOCK_TRANSFER' THEN
        SELECT 'To: ' || l.location_name INTO v_remarks
        FROM rih_stock_transfers h
        JOIN ric_locations l ON l.id = h.to_location_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.transfer_no = p_source_doc_no AND h.transfer_date = p_source_doc_date;

    WHEN 'STOCK_RECEIPT' THEN
        SELECT 'From: ' || l.location_name INTO v_remarks
        FROM rih_stock_receipts h
        JOIN ric_locations l ON l.id = h.from_location_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.receipt_no = p_source_doc_no AND h.receipt_date = p_source_doc_date;

    WHEN 'STOCK_ADJUSTMENT' THEN
        SELECT 'Reason: ' || COALESCE(m.description, '-') INTO v_remarks
        FROM rih_stock_adjustment_headers h
        LEFT JOIN rim_common_masters m ON m.id = h.reason_id
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.adjustment_no = p_source_doc_no AND h.adjustment_date = p_source_doc_date;

    WHEN 'MATERIAL_ISSUE' THEN
        SELECT 'Dept: ' || COALESCE(m.description, '-') INTO v_remarks
        FROM rid_material_issue_lines l
        LEFT JOIN rim_common_masters m ON m.id = l.department_id
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.issue_no = p_source_doc_no AND l.issue_date = p_source_doc_date
        ORDER BY l.serial_no
        LIMIT 1;

    WHEN 'OPENING_STOCK' THEN
        v_remarks := 'Opening Stock';

    ELSE
        v_remarks := NULL;
    END CASE;

    RETURN v_remarks;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_resolve_transaction_remarks(UUID, UUID, TEXT, TEXT, DATE) TO authenticated;


-- ============================================================
-- Part B — fn_stock_ledger_lines / fn_stock_ledger_totals
-- ============================================================
-- p_trans_date_from/p_trans_date_to have no SQL default — always
-- populated before any fetch anyway, since the DATE_RANGE filter's own
-- default_value='THIS_MONTH' resolves client-side before refresh() is
-- ever called (same as Stock Details, 149).
--
-- p_product_id DOES need `DEFAULT NULL` despite the filter itself being
-- marked required=true in the registry below — `required` is a display-
-- only flag never actually enforced by the reporting engine (confirmed by
-- reading report_data_controller.dart/report_repository.dart/
-- sakal_report_filter_bar.dart) — report_repository.dart's own
-- _buildFilterParams SKIPS any filter whose value is still null rather
-- than sending it, so a fetch attempted before a product is picked would
-- omit p_product_id from the RPC call entirely; without a SQL default
-- that's a hard "missing argument" PostgREST error, not an empty report.
-- `sl.product_id = p_product_id` naturally matches zero rows when
-- p_product_id IS NULL, so this default is what keeps an unset-product
-- fetch harmless instead of erroring (auto_load=false below is the real
-- guard that stops that fetch from firing in the first place).
CREATE OR REPLACE FUNCTION fn_stock_ledger_lines(
    p_client_id       UUID,
    p_company_id      UUID,
    p_trans_date_from DATE,
    p_trans_date_to   DATE,
    p_product_id      UUID DEFAULT NULL,
    p_location_id     UUID DEFAULT NULL
) RETURNS TABLE (
    trans_no        TEXT,
    trans_date      DATE,
    trans_type      TEXT,
    remarks         TEXT,
    qty_in          NUMERIC,
    qty_out         NUMERIC,
    running_balance NUMERIC,
    sort_seq        BIGINT
) LANGUAGE sql STABLE AS $$
    WITH accessible_locations AS (
        SELECT loc.id
        FROM ric_locations loc
        WHERE loc.client_id = p_client_id AND loc.company_id = p_company_id
          AND loc.is_deleted = false
          AND (p_location_id IS NULL OR loc.id = p_location_id)
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
    -- Raw, unenriched rows — used for the opening-balance scalar (needs
    -- only qty_change, over ALL history before the From Date) and as the
    -- base for the detail rows below. Deliberately does NOT join
    -- ric_locations or call fn_resolve_transaction_remarks here — that
    -- enrichment is real per-row work and must only ever run for rows
    -- actually displayed (the date-range-filtered subset), never for a
    -- product's full history just to compute Opening Balance.
    all_lines AS (
        SELECT sl.id, sl.location_id, sl.source_doc_type, sl.source_doc_no, sl.source_doc_date,
               sl.trans_date, sl.qty_change, sl.created_at
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.product_id = p_product_id
          AND sl.location_id IN (SELECT id FROM accessible_locations)
    ),
    opening AS (
        SELECT COALESCE(SUM(qty_change), 0) AS bal
        FROM all_lines
        WHERE trans_date < p_trans_date_from
    ),
    -- Enrichment (location join + remarks resolver) scoped to ONLY the
    -- rows that will actually be displayed.
    detail_lines AS (
        SELECT
            al.source_doc_no, al.trans_date, al.qty_change, al.created_at,
            CASE al.source_doc_type
                WHEN 'GRN' THEN 'GRN'
                WHEN 'PURCHASE_RETURN' THEN 'Purchase Return'
                WHEN 'SALES_INVOICE' THEN 'Sales Invoice'
                WHEN 'SALES_DELIVERY' THEN 'Sales Delivery'
                WHEN 'SALES_RETURN' THEN 'Sales Return'
                WHEN 'STOCK_TRANSFER' THEN 'Stock Transfer'
                WHEN 'STOCK_RECEIPT' THEN 'Stock Receipt'
                WHEN 'STOCK_ADJUSTMENT' THEN 'Stock Adjustment'
                WHEN 'MATERIAL_ISSUE' THEN 'Material Issue'
                WHEN 'OPENING_STOCK' THEN 'Opening Stock'
                ELSE al.source_doc_type
            END AS trans_type_label,
            COALESCE(fn_resolve_transaction_remarks(
                p_client_id, p_company_id, al.source_doc_type, al.source_doc_no, al.source_doc_date), '')
                || ' | Location: ' || l.location_name AS row_remarks
        FROM all_lines al
        JOIN ric_locations l ON l.id = al.location_id
        WHERE al.trans_date BETWEEN p_trans_date_from AND p_trans_date_to
    ),
    combined AS (
        SELECT
            0 AS sort_priority,
            'Opening Balance'::TEXT AS trans_no,
            p_trans_date_from AS trans_date,
            NULL::TEXT AS trans_type,
            ''::TEXT AS remarks,
            NULL::TIMESTAMPTZ AS created_at,
            NULL::NUMERIC AS qty_in,
            NULL::NUMERIC AS qty_out,
            (SELECT bal FROM opening) AS signed_qty
        UNION ALL
        SELECT
            1 AS sort_priority,
            source_doc_no, trans_date, trans_type_label, row_remarks, created_at,
            CASE WHEN qty_change > 0 THEN qty_change END,
            CASE WHEN qty_change < 0 THEN ABS(qty_change) END,
            qty_change
        FROM detail_lines
    )
    SELECT
        c.trans_no, c.trans_date, c.trans_type, c.remarks, c.qty_in, c.qty_out,
        SUM(c.signed_qty) OVER (
            ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.created_at
            ROWS UNBOUNDED PRECEDING
        ) AS running_balance,
        ROW_NUMBER() OVER (ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.created_at) AS sort_seq
    FROM combined c
    ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.created_at;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_ledger_lines(UUID, UUID, DATE, DATE, UUID, UUID) TO authenticated;

-- Independent single-scan totals — never derived from the window
-- function's own output, same shape as fn_account_ledger_totals (132).
-- running_balance here IS the Closing Qty (opening + net movement in range).
CREATE OR REPLACE FUNCTION fn_stock_ledger_totals(
    p_client_id       UUID,
    p_company_id      UUID,
    p_trans_date_from DATE,
    p_trans_date_to   DATE,
    p_product_id      UUID DEFAULT NULL,
    p_location_id     UUID DEFAULT NULL
) RETURNS TABLE (
    qty_in          NUMERIC,
    qty_out         NUMERIC,
    running_balance NUMERIC
) LANGUAGE sql STABLE AS $$
    WITH accessible_locations AS (
        SELECT loc.id
        FROM ric_locations loc
        WHERE loc.client_id = p_client_id AND loc.company_id = p_company_id
          AND loc.is_deleted = false
          AND (p_location_id IS NULL OR loc.id = p_location_id)
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
    scoped AS (
        SELECT sl.trans_date, sl.qty_change
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.product_id = p_product_id
          AND sl.location_id IN (SELECT id FROM accessible_locations)
          AND sl.trans_date <= p_trans_date_to
    )
    SELECT
        COALESCE(SUM(qty_change) FILTER (WHERE qty_change > 0 AND trans_date >= p_trans_date_from), 0),
        COALESCE(ABS(SUM(qty_change) FILTER (WHERE qty_change < 0 AND trans_date >= p_trans_date_from)), 0),
        COALESCE(SUM(qty_change), 0)
    FROM scoped;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_ledger_totals(UUID, UUID, DATE, DATE, UUID, UUID) TO authenticated;


-- ============================================================
-- Part C — registry rows, one full set per existing company
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
            (v_company.client_id, v_company.company_id, 'STOCK_LEDGER', 'Stock Ledger',
             'TABULAR', 'FUNCTION', 'fn_stock_ledger_lines', 'IN', 'sort_seq', 'ASC', 200,
             'fn_stock_ledger_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            -- sortable=false on every column: row order IS the running-
            -- balance's own chronological order (sort_seq) — same
            -- convention as Account Ledger (132), same reasoning.
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_no',        'Trans No',        'TEXT',   'LEFT',  false, true,  120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_date',      'Trans Date',      'DATE',   'LEFT',  false, true,  100, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_type',      'Trans Type',      'TEXT',   'LEFT',  false, true,  130, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'remarks',         'Remarks',         'TEXT',   'LEFT',  false, true,  280, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_in',          'Inward',          'NUMBER', 'RIGHT', false, true,  100, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_out',         'Outward',         'NUMBER', 'RIGHT', false, true,  100, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'running_balance', 'Running Balance', 'NUMBER', 'RIGHT', false, true,  130, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'sort_seq',        'Seq',             'NUMBER', 'RIGHT', false, false, 0,   8, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', 'product_id', true, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Trans Date', 'DATE_RANGE',
                NULL, NULL, 'trans_date', true, 'THIS_MONTH', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', 'location_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-SDL', 'Stock Ledger',
             '/reports/STOCK_LEDGER', 3, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


-- ============================================================
-- Part D — ric_user_menus backfill, same shape as migrations 148/149.
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
WHERE mm.feature_code = 'IN-RPT-SDL'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
