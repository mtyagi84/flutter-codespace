-- ============================================================
-- Migration 132: Account Ledger (Account Statement) report — Finance.
-- ============================================================
-- Built entirely on the existing Reporting Engine (116-119, 126/127) — no
-- new screen, no new route. Two deliberate design choices, both per
-- explicit user direction during planning (not the Sales Register
-- precedent):
--
--   1. Currency is a PLAIN FILTER on this report (BASE/LOCAL/PARTY,
--      default PARTY), not the engine's Base/Local SegmentedButton
--      toggle mechanism (source_object_local/totals_source_object_local)
--      — that mechanism stays exactly as Sales Register left it. Every
--      report decides for itself whether it needs a currency parameter
--      at all; this one does, a future non-monetary report might not.
--      Each of the three modes reads straight from rid_finance_lines'
--      own pre-stored base_amount/local_amount/party_amount column —
--      NEVER converted/derived via fn_get_exchange_rate. When the user
--      picks an account, party_amount/party_currency on every one of
--      that account's own lines is already in that account's own
--      currency, so PARTY mode needs no per-row currency resolution
--      either.
--   2. Opening Balance is derived purely from rid_finance_lines (sum of
--      every qualifying line dated before the report's from-date) — NOT
--      from rim_opening_balances. That table is the Chart-of-Accounts
--      FY-opening master (a different, unrelated concept per CLAUDE.md's
--      own note) and is intentionally not touched by this report.
--
-- Both fn_account_ledger_lines and fn_account_ledger_totals additionally
-- take p_posting_filter ('POSTED' default | 'ALL') so a user can include
-- still-DRAFT/unapproved vouchers when just verifying a running balance,
-- not only the official posted books.
-- ============================================================

-- ------------------------------------------------------------
-- Widen the filter_type CHECK (116) to add FINANCE_ACCOUNT_PICKER — the
-- real searchable Code/Name/Parent-Group picker (finance_account_picker.
-- dart), wired into sakal_report_filter_bar.dart alongside this
-- migration. Grepped every migration touching this constraint first
-- (only 116 defines it) before widening, per this project's own
-- "CHECK constraint drift" rule.
-- ------------------------------------------------------------
ALTER TABLE ric_report_filters
    DROP CONSTRAINT IF EXISTS ric_report_filters_filter_type_check;
ALTER TABLE ric_report_filters
    ADD CONSTRAINT ric_report_filters_filter_type_check
        CHECK (filter_type IN ('DATE_RANGE', 'DATE', 'DROPDOWN_STATIC', 'DROPDOWN_LOOKUP',
                                'ACCOUNT_PICKER', 'PRODUCT_PICKER', 'FINANCE_ACCOUNT_PICKER',
                                'TEXT', 'BOOLEAN'));


-- ============================================================
-- fn_account_ledger_lines — the report's row source (source_type='FUNCTION').
-- STABLE FUNCTION, not a VIEW: Opening Balance and Running Balance both
-- depend on p_account_id/p_date_from themselves, which a plain VIEW has
-- no way to receive (PostgREST only applies post-hoc ?col=op.val
-- operators to a view, never a real parameter) — same reasoning already
-- documented for fn_sales_register_totals_* (118/127), just extended to
-- the whole report here, not only its totals.
--
-- sort_seq is a hidden (default_visible=false) tie-breaking column:
-- PostgREST's own outer ORDER BY (built from default_sort_column) only
-- ever sorts by ONE column name — ordering purely by trans_date would
-- leave same-day rows in an unspecified sub-order, silently shuffling
-- the Opening Balance row and any same-day transactions relative to the
-- exact chronological+priority order the window function below already
-- computed running_balance against. default_sort_column is set to
-- sort_seq (Part B) specifically so the displayed row order always
-- matches the order running_balance was computed in.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_account_ledger_lines(
    p_client_id      UUID,
    p_company_id     UUID,
    p_account_id     UUID DEFAULT NULL,
    p_date_from      DATE DEFAULT NULL,
    p_date_to        DATE DEFAULT NULL,
    p_currency_mode  TEXT DEFAULT 'PARTY',
    p_posting_filter TEXT DEFAULT 'POSTED'
) RETURNS TABLE (
    trans_no        TEXT,
    trans_date      DATE,
    remarks         TEXT,
    debit           NUMERIC,
    credit          NUMERIC,
    running_balance NUMERIC,
    currency_code   TEXT,
    sort_seq        BIGINT
) LANGUAGE sql STABLE AS $$
    WITH qualifying_lines AS (
        SELECT
            h.trans_no, h.trans_date, l.serial_no, l.trans_nature,
            CASE p_currency_mode
                WHEN 'BASE'  THEN l.base_amount
                WHEN 'LOCAL' THEN l.local_amount
                ELSE              l.party_amount
            END AS amt,
            COALESCE(l.line_remarks, h.remarks, '')
                || CASE WHEN l.inv_bill_no IS NOT NULL
                        THEN ' | Bill: ' || l.inv_bill_no
                             || COALESCE(' dated ' || to_char(l.inv_bill_date, 'DD Mon YYYY'), '')
                        ELSE '' END
                || CASE WHEN h.reference_no IS NOT NULL
                        THEN ' | Ref: ' || h.reference_no
                             || COALESCE(' dated ' || to_char(h.reference_date, 'DD Mon YYYY'), '')
                        ELSE '' END AS remarks
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.account_id = p_account_id
          AND l.is_deleted = false AND h.is_deleted = false
          AND (p_posting_filter <> 'POSTED' OR h.is_posted = true)
          -- ric_user_location_access (029) — zero active rows for the JWT's
          -- user_id = unrestricted; any active rows = limited to that set.
          -- Same block as v_sales_details_base (126).
          AND (
              NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                          WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                            AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                            AND ula.is_active = true AND ula.is_deleted = false)
              OR h.location_id IN (SELECT ula.location_id 
                                   FROM ric_user_location_access ula
                                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                      AND ula.client_id = h.client_id
                                      AND ula.company_id = h.company_id
                                      AND ula.is_active = true AND ula.is_deleted = false)
          )
    ),
    opening AS (
        SELECT COALESCE(SUM(CASE WHEN trans_nature = 'DR' THEN amt ELSE -amt END), 0) AS bal
        FROM qualifying_lines
        WHERE p_date_from IS NOT NULL AND trans_date < p_date_from
    ),
    combined AS (
        SELECT
            0 AS sort_priority,
            'Opening Balance'::TEXT AS trans_no,
            COALESCE(p_date_from, DATE '1900-01-01') AS trans_date,
            0 AS serial_no,
            ''::TEXT AS remarks,
            NULL::NUMERIC AS debit,
            NULL::NUMERIC AS credit,
            (SELECT bal FROM opening) AS signed_amt
        UNION ALL
        SELECT
            1 AS sort_priority,
            trans_no, trans_date, serial_no, remarks,
            CASE WHEN trans_nature = 'DR' THEN amt END AS debit,
            CASE WHEN trans_nature = 'CR' THEN amt END AS credit,
            CASE WHEN trans_nature = 'DR' THEN amt ELSE -amt END AS signed_amt
        FROM qualifying_lines
        WHERE (p_date_from IS NULL OR trans_date >= p_date_from)
          AND (p_date_to   IS NULL OR trans_date <= p_date_to)
    )
    SELECT
        c.trans_no, c.trans_date, c.remarks, c.debit, c.credit,
        SUM(c.signed_amt) OVER (
            ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.serial_no
            ROWS UNBOUNDED PRECEDING
        ) AS running_balance,
        (CASE p_currency_mode
            WHEN 'BASE'  THEN (SELECT base_currency  FROM ric_companies WHERE id = p_company_id)
            WHEN 'LOCAL' THEN (SELECT local_currency FROM ric_companies WHERE id = p_company_id)
            ELSE (SELECT rc.currency_id FROM rim_accounts a
                  JOIN rim_currencies rc ON rc.id = a.account_currency_id
                  WHERE a.id = p_account_id)
        END) AS currency_code,
        ROW_NUMBER() OVER (ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.serial_no) AS sort_seq
    FROM combined c
    ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.serial_no;
$$;

GRANT EXECUTE ON FUNCTION fn_account_ledger_lines(
    UUID, UUID, UUID, DATE, DATE, TEXT, TEXT) TO authenticated;


-- ============================================================
-- fn_account_ledger_totals — the footer row (Total Debit / Total Credit /
-- Closing Balance). Single scan over the same date/account/location/
-- posting scope as fn_account_ledger_lines, split via FILTER clauses
-- instead of two separate queries. running_balance here IS the Closing
-- Balance figure (Opening Balance + net movement in range) — it lands in
-- the report's totals-footer row under the Running Balance column
-- (sakal_report_table.dart only renders a footer cell when that column's
-- aggregate_fn is non-null; the value itself always comes straight from
-- this function, never a client-side re-sum, so aggregate_fn='SUM' here
-- is just the render-gate, not a literal SUM of running_balance values).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_account_ledger_totals(
    p_client_id      UUID,
    p_company_id     UUID,
    p_account_id     UUID DEFAULT NULL,
    p_date_from      DATE DEFAULT NULL,
    p_date_to        DATE DEFAULT NULL,
    p_currency_mode  TEXT DEFAULT 'PARTY',
    p_posting_filter TEXT DEFAULT 'POSTED'
) RETURNS TABLE (
    debit           NUMERIC,
    credit          NUMERIC,
    running_balance NUMERIC
) LANGUAGE sql STABLE AS $$
    WITH scoped AS (
        SELECT
            h.trans_date, l.trans_nature,
            CASE p_currency_mode
                WHEN 'BASE'  THEN l.base_amount
                WHEN 'LOCAL' THEN l.local_amount
                ELSE              l.party_amount
            END AS amt
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.account_id = p_account_id
          AND l.is_deleted = false AND h.is_deleted = false
          AND (p_posting_filter <> 'POSTED' OR h.is_posted = true)
          AND (p_date_to IS NULL OR h.trans_date <= p_date_to)
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
    )
    SELECT
        COALESCE(SUM(amt) FILTER (
            WHERE trans_nature = 'DR' AND (p_date_from IS NULL OR trans_date >= p_date_from)), 0) AS debit,
        COALESCE(SUM(amt) FILTER (
            WHERE trans_nature = 'CR' AND (p_date_from IS NULL OR trans_date >= p_date_from)), 0) AS credit,
        COALESCE(SUM(CASE WHEN trans_nature = 'DR' THEN amt ELSE -amt END), 0) AS running_balance
    FROM scoped;
$$;

GRANT EXECUTE ON FUNCTION fn_account_ledger_totals(
    UUID, UUID, UUID, DATE, DATE, TEXT, TEXT) TO authenticated;


-- ============================================================
-- Registry rows + menu, one full set per existing company — same
-- per-company DO loop / ON CONFLICT upsert shape as 127's Part C.
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

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, 'ACCOUNT_LEDGER', 'Account Ledger',
             'TABULAR', 'FUNCTION', 'fn_account_ledger_lines', 'FN',
             'sort_seq', 'ASC', 200, 'fn_account_ledger_totals')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object = excluded.source_object,
                default_sort_column = excluded.default_sort_column,
                default_sort_dir = excluded.default_sort_dir,
                totals_source_object = excluded.totals_source_object
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            -- sortable=false on every column: the row order IS the running-
            -- balance's own chronological order (sort_seq) — letting a user
            -- click a column header to re-sort would silently misalign the
            -- Running Balance figures against the rows shown.
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_no',        'Voucher No',      'TEXT',   'LEFT',  false, true,  120, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'trans_date',      'Voucher Date',    'DATE',   'LEFT',  false, true,  100, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'remarks',         'Remarks',         'TEXT',   'LEFT',  false, true,  280, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'debit',           'Debit',           'NUMBER', 'RIGHT', false, true,  110, 4, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'credit',          'Credit',          'NUMBER', 'RIGHT', false, true,  110, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'running_balance', 'Running Balance', 'NUMBER', 'RIGHT', false, true,  120, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'currency_code',   'Currency',        'TEXT',   'LEFT',  false, true,  80,  7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sort_seq',        'Seq',             'NUMBER', 'RIGHT', false, false, 0,   8, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Voucher Date', 'DATE_RANGE',
                NULL, NULL, NULL, 'date', false, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'account', 'Account', 'FINANCE_ACCOUNT_PICKER',
                NULL, NULL, NULL, 'account_id', true, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'currency_mode', 'Currency', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"BASE","label":"Base Currency"},{"value":"LOCAL","label":"Local Currency"},{"value":"PARTY","label":"Party Currency"}]'::jsonb,
                'currency_mode', false, 'PARTY', 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'posting_filter', 'Entries', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"POSTED","label":"Posted Only"},{"value":"ALL","label":"All Entries (incl. unposted)"}]'::jsonb,
                'posting_filter', false, 'POSTED', 4);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-LDG', 'Account Ledger',
             '/reports/ACCOUNT_LEDGER', 5, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill (same pattern as 119/127 Part D): a
-- ric_master_menus row alone makes a feature ELIGIBLE, it grants nobody
-- anything. Give VIEW access to whoever already has view access to any
-- other Finance (FN) feature.
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
WHERE mm.feature_code = 'FN-RPT-LDG'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
