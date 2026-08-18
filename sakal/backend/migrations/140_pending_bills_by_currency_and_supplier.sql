-- ============================================================
-- Migration 140: Pending Bills by Customer — regroup to Currency then
-- Party, add a Customer Name search filter, and add the mirrored
-- Pending Bills by Supplier report.
-- ============================================================
-- User-requested changes to 118_reporting_engine_pilots.sql's "Pending
-- Bills by Customer" pilot report:
--   1. Add a Customer Name search filter (FINANCE_ACCOUNT_PICKER, same
--      nature-scoping mechanism migration 139 just built for the Ageing
--      reports — repurposing ric_report_filters.lookup_source to hold
--      'Customer'/'Supplier').
--   2. Swap the grouping order from Customer -> Currency to
--      Currency -> Customer, with a real subtotal row at BOTH levels
--      (currency-wise total AND customer-wise total).
--   3. Build an equivalent "Pending Bills by Supplier" report.
--
-- Same shared-core-plus-thin-wrappers shape as 137's
-- fn_party_ageing_lines_core (one engine, discriminated by
-- account_nature, exposed as Customer/Supplier wrapper pairs) — chosen
-- over duplicating every function twice, and because it's the
-- established precedent in this codebase for "technically the same
-- report" pairs.
--
-- v_pending_bills (117) itself has no account_nature column and needed
-- none added — every new function here joins rim_accounts directly for
-- that filter, the same join fn_party_ageing_lines_core already uses.
--
-- Real, pre-existing gap noted but NOT silently fixed here: the original
-- 118 functions (fn_pending_bills_totals, fn_pending_bills_summary_by_
-- customer, fn_pending_bills_summary_by_customer_currency) have no
-- ric_user_location_access check at all, unlike every report built since
-- (132/135/137). The new functions below DO include it, matching the
-- now-established convention for anything newly written — but the
-- original three are left untouched (fn_pending_bills_totals is still
-- used by the separate, unrelated "Pending Bills Register" flat report;
-- the other two become orphaned by this migration's group_levels swap,
-- not dropped, in case anything external still calls them directly).
-- ============================================================

-- ------------------------------------------------------------
-- Level 1 — group by Currency only, scoped to one account_nature.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_currency_core(
    p_client_id       UUID,
    p_company_id      UUID,
    p_account_nature  TEXT,               -- 'Customer' or 'Supplier', set only by the two wrappers below
    p_account_id      UUID DEFAULT NULL,  -- the Customer/Supplier Name filter, when set
    p_trans_date_from DATE DEFAULT NULL,
    p_trans_date_to   DATE DEFAULT NULL,
    p_inv_bill_no     TEXT DEFAULT NULL
) RETURNS TABLE (
    party_currency     TEXT,
    bill_amount_base   NUMERIC,
    bill_amount_local  NUMERIC,
    row_count          BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT
        b.party_currency,
        COALESCE(SUM(b.bill_amount_base), 0),
        COALESCE(SUM(b.bill_amount_local), 0),
        COUNT(*)
    FROM v_pending_bills b
    JOIN rim_accounts a ON a.id = b.account_id
    WHERE b.client_id  = p_client_id AND b.company_id = p_company_id
      AND a.account_nature = p_account_nature
      AND (p_account_id      IS NULL OR b.account_id = p_account_id)
      AND (p_trans_date_from IS NULL OR b.trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR b.trans_date <= p_trans_date_to)
      AND (p_inv_bill_no     IS NULL OR b.inv_bill_no ILIKE '%' || p_inv_bill_no || '%')
      AND (
          NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                      WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                        AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                        AND ula.is_active = true AND ula.is_deleted = false)
          OR b.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                  AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                  AND ula.is_active = true AND ula.is_deleted = false)
      )
    GROUP BY b.party_currency;
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_currency_core(UUID, UUID, TEXT, UUID, DATE, DATE, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_currency_customer(
    p_client_id UUID, p_company_id UUID, p_account_id UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL, p_trans_date_to DATE DEFAULT NULL, p_inv_bill_no TEXT DEFAULT NULL
) RETURNS TABLE (party_currency TEXT, bill_amount_base NUMERIC, bill_amount_local NUMERIC, row_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pending_bills_summary_by_currency_core(
        p_client_id, p_company_id, 'Customer', p_account_id, p_trans_date_from, p_trans_date_to, p_inv_bill_no);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_currency_customer(UUID, UUID, UUID, DATE, DATE, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_currency_supplier(
    p_client_id UUID, p_company_id UUID, p_account_id UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL, p_trans_date_to DATE DEFAULT NULL, p_inv_bill_no TEXT DEFAULT NULL
) RETURNS TABLE (party_currency TEXT, bill_amount_base NUMERIC, bill_amount_local NUMERIC, row_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pending_bills_summary_by_currency_core(
        p_client_id, p_company_id, 'Supplier', p_account_id, p_trans_date_from, p_trans_date_to, p_inv_bill_no);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_currency_supplier(UUID, UUID, UUID, DATE, DATE, TEXT) TO authenticated;


-- ------------------------------------------------------------
-- Level 2 — group by Party within one Currency (the ancestor key from
-- level 1) — p_party_currency's name matches level 1's own
-- group_by_column ('party_currency'), the naming convention
-- ReportRepository.fetchGroupSummary relies on.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_currency_account_core(
    p_client_id       UUID,
    p_company_id      UUID,
    p_account_nature  TEXT,
    p_party_currency  TEXT,
    p_account_id      UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL,
    p_trans_date_to   DATE DEFAULT NULL,
    p_inv_bill_no     TEXT DEFAULT NULL
) RETURNS TABLE (
    account_id         UUID,
    account_label      TEXT,
    party_currency     TEXT,
    bill_amount_base   NUMERIC,
    bill_amount_local  NUMERIC,
    row_count          BIGINT
) LANGUAGE sql STABLE AS $$
    -- MIN(text), not MIN(uuid) — see CLAUDE.md's Postgres aggregate
    -- gotcha; account_code/account_name are TEXT and unique per
    -- account_id in practice, MIN() here is only "pick the one value".
    SELECT
        b.account_id,
        MIN(a.account_code || ' - ' || a.account_name),
        b.party_currency,
        COALESCE(SUM(b.bill_amount_base), 0),
        COALESCE(SUM(b.bill_amount_local), 0),
        COUNT(*)
    FROM v_pending_bills b
    JOIN rim_accounts a ON a.id = b.account_id
    WHERE b.client_id  = p_client_id AND b.company_id = p_company_id
      AND a.account_nature  = p_account_nature
      AND b.party_currency  = p_party_currency
      AND (p_account_id      IS NULL OR b.account_id = p_account_id)
      AND (p_trans_date_from IS NULL OR b.trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR b.trans_date <= p_trans_date_to)
      AND (p_inv_bill_no     IS NULL OR b.inv_bill_no ILIKE '%' || p_inv_bill_no || '%')
      AND (
          NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                      WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                        AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                        AND ula.is_active = true AND ula.is_deleted = false)
          OR b.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                  AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                  AND ula.is_active = true AND ula.is_deleted = false)
      )
    GROUP BY b.account_id, b.party_currency;
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_currency_account_core(UUID, UUID, TEXT, TEXT, UUID, DATE, DATE, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_currency_account_customer(
    p_client_id UUID, p_company_id UUID, p_party_currency TEXT, p_account_id UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL, p_trans_date_to DATE DEFAULT NULL, p_inv_bill_no TEXT DEFAULT NULL
) RETURNS TABLE (account_id UUID, account_label TEXT, party_currency TEXT, bill_amount_base NUMERIC, bill_amount_local NUMERIC, row_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pending_bills_summary_by_currency_account_core(
        p_client_id, p_company_id, 'Customer', p_party_currency, p_account_id, p_trans_date_from, p_trans_date_to, p_inv_bill_no);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_currency_account_customer(UUID, UUID, TEXT, UUID, DATE, DATE, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pending_bills_summary_by_currency_account_supplier(
    p_client_id UUID, p_company_id UUID, p_party_currency TEXT, p_account_id UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL, p_trans_date_to DATE DEFAULT NULL, p_inv_bill_no TEXT DEFAULT NULL
) RETURNS TABLE (account_id UUID, account_label TEXT, party_currency TEXT, bill_amount_base NUMERIC, bill_amount_local NUMERIC, row_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pending_bills_summary_by_currency_account_core(
        p_client_id, p_company_id, 'Supplier', p_party_currency, p_account_id, p_trans_date_from, p_trans_date_to, p_inv_bill_no);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_summary_by_currency_account_supplier(UUID, UUID, TEXT, UUID, DATE, DATE, TEXT) TO authenticated;


-- ------------------------------------------------------------
-- Report-level totals — same nature/account_id scoping.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pending_bills_totals_by_nature_core(
    p_client_id       UUID,
    p_company_id      UUID,
    p_account_nature  TEXT,
    p_account_id      UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL,
    p_trans_date_to   DATE DEFAULT NULL,
    p_inv_bill_no     TEXT DEFAULT NULL
) RETURNS TABLE (bill_amount_base NUMERIC, bill_amount_local NUMERIC, row_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(b.bill_amount_base), 0),
        COALESCE(SUM(b.bill_amount_local), 0),
        COUNT(*)
    FROM v_pending_bills b
    JOIN rim_accounts a ON a.id = b.account_id
    WHERE b.client_id  = p_client_id AND b.company_id = p_company_id
      AND a.account_nature = p_account_nature
      AND (p_account_id      IS NULL OR b.account_id = p_account_id)
      AND (p_trans_date_from IS NULL OR b.trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR b.trans_date <= p_trans_date_to)
      AND (p_inv_bill_no     IS NULL OR b.inv_bill_no ILIKE '%' || p_inv_bill_no || '%')
      AND (
          NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                      WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                        AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                        AND ula.is_active = true AND ula.is_deleted = false)
          OR b.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                  AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                  AND ula.is_active = true AND ula.is_deleted = false)
      );
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_totals_by_nature_core(UUID, UUID, TEXT, UUID, DATE, DATE, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pending_bills_totals_customer(
    p_client_id UUID, p_company_id UUID, p_account_id UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL, p_trans_date_to DATE DEFAULT NULL, p_inv_bill_no TEXT DEFAULT NULL
) RETURNS TABLE (bill_amount_base NUMERIC, bill_amount_local NUMERIC, row_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pending_bills_totals_by_nature_core(
        p_client_id, p_company_id, 'Customer', p_account_id, p_trans_date_from, p_trans_date_to, p_inv_bill_no);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_totals_customer(UUID, UUID, UUID, DATE, DATE, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pending_bills_totals_supplier(
    p_client_id UUID, p_company_id UUID, p_account_id UUID DEFAULT NULL,
    p_trans_date_from DATE DEFAULT NULL, p_trans_date_to DATE DEFAULT NULL, p_inv_bill_no TEXT DEFAULT NULL
) RETURNS TABLE (bill_amount_base NUMERIC, bill_amount_local NUMERIC, row_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pending_bills_totals_by_nature_core(
        p_client_id, p_company_id, 'Supplier', p_account_id, p_trans_date_from, p_trans_date_to, p_inv_bill_no);
$$;

GRANT EXECUTE ON FUNCTION fn_pending_bills_totals_supplier(UUID, UUID, UUID, DATE, DATE, TEXT) TO authenticated;


-- ============================================================
-- Registry — per company: redesign PENDING_BILLS_BY_CUSTOMER in place,
-- add PENDING_BILLS_BY_SUPPLIER as a genuinely new report.
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_fn_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_fn_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'FN';

        CONTINUE WHEN v_fn_module_id IS NULL;

        -- ---------------- Pending Bills by Customer (redesign) ----------------
        SELECT id INTO v_report_id FROM ric_report_definitions
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id
              AND report_key = 'PENDING_BILLS_BY_CUSTOMER';

        CONTINUE WHEN v_report_id IS NULL; -- company never had 118's pilots seeded; skip rather than half-create

        UPDATE ric_report_definitions
            SET totals_source_object = 'fn_pending_bills_totals_customer'
            WHERE id = v_report_id;

        -- party_currency wasn't previously a declared column at all (it
        -- only ever appeared as a summary-row key) — added, hidden, same
        -- convention as 137's Ageing reports: shown via the currency
        -- group header, not as its own detail-row column.
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'party_currency', 'Currency', 'TEXT', 'LEFT', false, false, 80, 11, NULL)
        ON CONFLICT (report_id, column_key) DO NOTHING;

        DELETE FROM ric_report_filters WHERE report_id = v_report_id AND filter_key = 'account_id';
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, param_target, required, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'account_id', 'Customer Name', 'FINANCE_ACCOUNT_PICKER',
                'Customer', 'account_id', false, 3);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'party_currency', 'party_currency', 'fn_pending_bills_summary_by_currency_customer'),
            (v_company.client_id, v_company.company_id, v_report_id, 2, 'account_id', 'account_label', 'fn_pending_bills_summary_by_currency_account_customer');

        -- ---------------- Pending Bills by Supplier (new) ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, 'PENDING_BILLS_BY_SUPPLIER', 'Pending Bills by Supplier',
             'TABULAR', 'VIEW', 'v_pending_bills', 'FN', 'trans_date', 'DESC', 50, 'fn_pending_bills_totals_supplier')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn, currency_code_column)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_no', 'Trans No', 'TEXT', 'LEFT', true, true, 120, 1, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_date', 'Trans Date', 'DATE', 'LEFT', true, true, 110, 2, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name', 'Supplier', 'TEXT', 'LEFT', true, true, 200, 3, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_no', 'Bill No', 'TEXT', 'LEFT', true, true, 130, 4, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'inv_bill_date', 'Bill Date', 'DATE', 'LEFT', true, true, 110, 5, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount', 'Bill Amount (Original)', 'NUMBER', 'RIGHT', false, true, 160, 6, NULL, 'party_currency'),
            (v_company.client_id, v_company.company_id, v_report_id, 'balance_amount', 'Balance (Original)', 'NUMBER', 'RIGHT', false, true, 160, 7, NULL, 'party_currency'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount_base', 'Bill Amount (Base)', 'NUMBER', 'RIGHT', true, true, 150, 8, 'SUM', NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_amount_local', 'Bill Amount (Local)', 'NUMBER', 'RIGHT', true, false, 150, 9, 'SUM', NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_label', 'Supplier (Group)', 'TEXT', 'LEFT', false, false, 220, 10, NULL, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'party_currency', 'Currency', 'TEXT', 'LEFT', false, false, 80, 11, NULL, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source, param_target, required, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Trans Date', 'DATE_RANGE', NULL, 'trans_date', false, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'bill_search', 'Bill No', 'TEXT', NULL, 'inv_bill_no', false, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_id', 'Supplier Name', 'FINANCE_ACCOUNT_PICKER', 'Supplier', 'account_id', false, 3);

        -- date_range needs its own default_value ('THIS_MONTH') set the
        -- same way 118's own filters do — the column list above omits
        -- default_value since FINANCE_ACCOUNT_PICKER's own row doesn't use
        -- it and a single shared INSERT column list is simpler; set here.
        UPDATE ric_report_filters SET default_value = 'THIS_MONTH'
            WHERE report_id = v_report_id AND filter_key = 'date_range';

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'party_currency', 'party_currency', 'fn_pending_bills_summary_by_currency_supplier'),
            (v_company.client_id, v_company.company_id, v_report_id, 2, 'account_id', 'account_label', 'fn_pending_bills_summary_by_currency_account_supplier');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-PBS', 'Pending Bills by Supplier',
             '/reports/PENDING_BILLS_BY_SUPPLIER', 9, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill for the new Supplier report — same pattern as
-- every prior report migration's own Part D.
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
WHERE mm.feature_code = 'FN-RPT-PBS'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
