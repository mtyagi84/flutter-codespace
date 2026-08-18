-- ============================================================
-- Migration 135: Trial Balance report — Finance.
-- ============================================================
-- Built entirely on the existing Reporting Engine (116-119, 126/127) — no
-- new screen, no new route, same as Sales Register (127) and Account
-- Ledger (132). TABULAR, not HIERARCHICAL — ric_report_group_levels
-- (116) is still unused by every report in this schema; Account Group
-- Name is a plain column here, not a collapsible tree.
--
-- Consumes the opening-balance infrastructure migration 133 built and
-- explicitly left for this: v_opening_balance_summary (one signed figure
-- per account/FY/location_group) plus rid_finance_lines movement, per
-- 133's own prescribed formula:
--   opening (as of p_date_from) = v_opening_balance_summary's signed
--   figure for the FY containing p_date_from, PLUS net signed movement of
--   rid_finance_lines from that FY's own start date up to (not including)
--   p_date_from.
--
-- Currency: the engine's Base/Local SegmentedButton toggle
-- (source_object_local / totals_source_object_local, 127) — NOT Account
-- Ledger's own plain-filter approach (132's Currency filter is
-- BASE/LOCAL/PARTY because an account ledger is one account's own party
-- currency; Trial Balance is book-wide, so Base/Local only, and every
-- account's own figures share the same two currencies).
--
-- Location Group is a genuinely new filter shape for this engine — no
-- prior report scopes by ric_location_groups. Kept ADDITIONAL to (not a
-- replacement for) the existing ric_user_location_access security
-- scoping every report function already applies (same block as
-- fn_account_ledger_lines/v_sales_details_base) — Location Group narrows
-- an already-permitted view for entity-wise P&L under INTER_ENTITY,
-- it isn't itself the access-control boundary. Left NULL (the default),
-- a company's postings from every accessible location are consolidated
-- together, which is also the only sensible behaviour for a SIMPLE
-- company (rid_opening_balance_lines.location_group_id is always NULL
-- there).
-- ============================================================


-- ============================================================
-- v_location_groups_lookup — the Location Group filter's own
-- lookup_source, same shape as v_user_accessible_locations (127).
-- ============================================================
CREATE OR REPLACE VIEW v_location_groups_lookup AS
SELECT id, client_id, company_id, group_name
FROM ric_location_groups
WHERE is_active = true AND is_deleted = false;

GRANT SELECT ON v_location_groups_lookup TO authenticated;


-- ============================================================
-- fn_trial_balance_lines_base / _local — the report's row source
-- (source_type='FUNCTION'). One row per postable (posting_allowed=true)
-- rim_accounts row. Both are STABLE SQL functions, identical shape,
-- differing only in which rid_finance_lines/rid_opening_balance_lines
-- amount column they read (base_amount vs local_amount) — same twin-
-- function pattern as fn_sales_register_totals_base/_local (127).
--
-- sort_key is a hidden (default_visible=false) single-column sort key —
-- same reasoning as fn_account_ledger_lines' sort_seq (132):
-- PostgREST's default_sort_column can only ever be ONE column, but the
-- user wants a two-level sort (account group's own code, then the
-- account's own code within that group) so the report reads
-- Assets -> Liabilities -> Income -> Expense following the Chart of
-- Accounts' own numbering, not an arbitrary alpha sort on the group's
-- display name. Zero-padded to a fixed width so text-sort matches
-- numeric-sort for typical numeric account codes; a non-numeric code
-- just sorts alphabetically within its own comparison, which is a
-- reasonable fallback, not a bug.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_trial_balance_lines_base(
    p_client_id         UUID,
    p_company_id        UUID,
    p_date_from         DATE,
    p_date_to           DATE,
    p_include_zero      BOOLEAN DEFAULT false,
    p_location_group_id UUID    DEFAULT NULL
) RETURNS TABLE (
    account_group_name   TEXT,
    account_name         TEXT,
    opening_balance      NUMERIC,
    opening_balance_type TEXT,
    debit                NUMERIC,
    credit               NUMERIC,
    closing_balance      NUMERIC,
    closing_balance_type TEXT,
    sort_key             TEXT
) LANGUAGE sql STABLE AS $$
    WITH fy AS (
        SELECT id, fy_start_date
        FROM   rim_financial_years
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND fy_start_date <= p_date_from AND fy_end_date >= p_date_from
        LIMIT 1
    ),
    opening_master AS (
        SELECT ob.account_id, ob.base_signed AS signed
        FROM v_opening_balance_summary ob, fy
        WHERE ob.client_id = p_client_id AND ob.company_id = p_company_id
          AND ob.fy_id = fy.id
          AND (p_location_group_id IS NULL OR ob.location_group_id = p_location_group_id)
    ),
    opening_movement AS (
        SELECT l.account_id,
               SUM(CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END) AS signed
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        JOIN fy ON true
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
          AND h.trans_date >= fy.fy_start_date AND h.trans_date < p_date_from
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
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
        GROUP BY l.account_id
    ),
    period_movement AS (
        SELECT l.account_id,
               COALESCE(SUM(l.base_amount) FILTER (WHERE l.trans_nature = 'DR'), 0) AS period_debit,
               COALESCE(SUM(l.base_amount) FILTER (WHERE l.trans_nature = 'CR'), 0) AS period_credit
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
          AND h.trans_date >= p_date_from AND h.trans_date <= p_date_to
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
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
        GROUP BY l.account_id
    ),
    accounts AS (
        SELECT a.id, a.account_code, a.account_name,
               COALESCE(p.account_code, a.account_code) AS group_code,
               p.account_name AS group_name
        FROM rim_accounts a
        LEFT JOIN rim_accounts p
            ON p.id = a.parent_id AND p.client_id = a.client_id AND p.company_id = a.company_id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id
          AND a.posting_allowed = true AND a.is_deleted = false
    ),
    combined AS (
        SELECT
            a.id AS account_id,
            a.group_name AS account_group_name,
            '[' || a.account_code || '] ' || a.account_name AS account_name,
            COALESCE(om.signed, 0) + COALESCE(mv.signed, 0) AS opening_signed,
            COALESCE(pm.period_debit, 0) AS period_debit,
            COALESCE(pm.period_credit, 0) AS period_credit,
            LPAD(a.group_code, 12, '0') || '~' || LPAD(a.account_code, 12, '0') AS sort_key
        FROM accounts a
        LEFT JOIN opening_master   om ON om.account_id = a.id
        LEFT JOIN opening_movement mv ON mv.account_id = a.id
        LEFT JOIN period_movement  pm ON pm.account_id = a.id
    )
    SELECT
        c.account_group_name,
        c.account_name,
        ABS(c.opening_signed) AS opening_balance,
        CASE WHEN c.opening_signed < 0 THEN 'Cr' ELSE 'Dr' END AS opening_balance_type,
        c.period_debit  AS debit,
        c.period_credit AS credit,
        ABS(c.opening_signed + c.period_debit - c.period_credit) AS closing_balance,
        CASE WHEN (c.opening_signed + c.period_debit - c.period_credit) < 0 THEN 'Cr' ELSE 'Dr' END AS closing_balance_type,
        c.sort_key
    FROM combined c
    WHERE p_include_zero
       OR c.opening_signed <> 0 OR c.period_debit <> 0 OR c.period_credit <> 0
       OR (c.opening_signed + c.period_debit - c.period_credit) <> 0
    ORDER BY c.sort_key;
$$;

GRANT EXECUTE ON FUNCTION fn_trial_balance_lines_base(
    UUID, UUID, DATE, DATE, BOOLEAN, UUID) TO authenticated;


CREATE OR REPLACE FUNCTION fn_trial_balance_lines_local(
    p_client_id         UUID,
    p_company_id        UUID,
    p_date_from         DATE,
    p_date_to           DATE,
    p_include_zero      BOOLEAN DEFAULT false,
    p_location_group_id UUID    DEFAULT NULL
) RETURNS TABLE (
    account_group_name   TEXT,
    account_name         TEXT,
    opening_balance      NUMERIC,
    opening_balance_type TEXT,
    debit                NUMERIC,
    credit               NUMERIC,
    closing_balance      NUMERIC,
    closing_balance_type TEXT,
    sort_key             TEXT
) LANGUAGE sql STABLE AS $$
    WITH fy AS (
        SELECT id, fy_start_date
        FROM rim_financial_years
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND fy_start_date <= p_date_from AND fy_end_date >= p_date_from
        LIMIT 1
    ),
    opening_master AS (
        SELECT ob.account_id, ob.local_signed AS signed
        FROM v_opening_balance_summary ob, fy
        WHERE ob.client_id = p_client_id AND ob.company_id = p_company_id
          AND ob.fy_id = fy.id
          AND (p_location_group_id IS NULL OR ob.location_group_id = p_location_group_id)
    ),
    opening_movement AS (
        SELECT l.account_id,
               SUM(CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END) AS signed
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        JOIN fy ON true
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
          AND h.trans_date >= fy.fy_start_date AND h.trans_date < p_date_from
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
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
        GROUP BY l.account_id
    ),
    period_movement AS (
        SELECT l.account_id,
               COALESCE(SUM(l.local_amount) FILTER (WHERE l.trans_nature = 'DR'), 0) AS period_debit,
               COALESCE(SUM(l.local_amount) FILTER (WHERE l.trans_nature = 'CR'), 0) AS period_credit
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
          AND h.trans_date >= p_date_from AND h.trans_date <= p_date_to
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
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
        GROUP BY l.account_id
    ),
    accounts AS (
        SELECT a.id, a.account_code, a.account_name,
               COALESCE(p.account_code, a.account_code) AS group_code,
               p.account_name AS group_name
        FROM rim_accounts a
        LEFT JOIN rim_accounts p
            ON p.id = a.parent_id AND p.client_id = a.client_id AND p.company_id = a.company_id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id
          AND a.posting_allowed = true AND a.is_deleted = false
    ),
    combined AS (
        SELECT
            a.id AS account_id,
            a.group_name AS account_group_name,
            '[' || a.account_code || '] ' || a.account_name AS account_name,
            COALESCE(om.signed, 0) + COALESCE(mv.signed, 0) AS opening_signed,
            COALESCE(pm.period_debit, 0) AS period_debit,
            COALESCE(pm.period_credit, 0) AS period_credit,
            LPAD(a.group_code, 12, '0') || '~' || LPAD(a.account_code, 12, '0') AS sort_key
        FROM accounts a
        LEFT JOIN opening_master   om ON om.account_id = a.id
        LEFT JOIN opening_movement mv ON mv.account_id = a.id
        LEFT JOIN period_movement  pm ON pm.account_id = a.id
    )
    SELECT
        c.account_group_name,
        c.account_name,
        ABS(c.opening_signed) AS opening_balance,
        CASE WHEN c.opening_signed < 0 THEN 'Cr' ELSE 'Dr' END AS opening_balance_type,
        c.period_debit  AS debit,
        c.period_credit AS credit,
        ABS(c.opening_signed + c.period_debit - c.period_credit) AS closing_balance,
        CASE WHEN (c.opening_signed + c.period_debit - c.period_credit) < 0 THEN 'Cr' ELSE 'Dr' END AS closing_balance_type,
        c.sort_key
    FROM combined c
    WHERE p_include_zero
       OR c.opening_signed <> 0 OR c.period_debit <> 0 OR c.period_credit <> 0
       OR (c.opening_signed + c.period_debit - c.period_credit) <> 0
    ORDER BY c.sort_key;
$$;

GRANT EXECUTE ON FUNCTION fn_trial_balance_lines_local(
    UUID, UUID, DATE, DATE, BOOLEAN, UUID) TO authenticated;


-- ============================================================
-- fn_trial_balance_totals_base / _local — the totals-footer row. Only
-- Debit/Credit are summed (matching the visible aggregate_fn='SUM'
-- columns below) — Opening/Closing Balance are deliberately NOT summed
-- here: they're stored as an ABS amount + a separate Dr/Cr type column,
-- so a blind SUM of the raw amounts would mix Dr and Cr figures into a
-- meaningless total. Total Debit vs Total Credit reconciling is the
-- natural double-entry sanity check a Trial Balance is FOR — if the
-- books genuinely balance, this footer row proves it for free.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_trial_balance_totals_base(
    p_client_id         UUID,
    p_company_id        UUID,
    p_date_from         DATE,
    p_date_to           DATE,
    p_include_zero      BOOLEAN DEFAULT false,
    p_location_group_id UUID    DEFAULT NULL
) RETURNS TABLE (
    debit  NUMERIC,
    credit NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
    FROM fn_trial_balance_lines_base(p_client_id, p_company_id, p_date_from, p_date_to, p_include_zero, p_location_group_id);
$$;

GRANT EXECUTE ON FUNCTION fn_trial_balance_totals_base(
    UUID, UUID, DATE, DATE, BOOLEAN, UUID) TO authenticated;


CREATE OR REPLACE FUNCTION fn_trial_balance_totals_local(
    p_client_id         UUID,
    p_company_id        UUID,
    p_date_from         DATE,
    p_date_to           DATE,
    p_include_zero      BOOLEAN DEFAULT false,
    p_location_group_id UUID    DEFAULT NULL
) RETURNS TABLE (
    debit  NUMERIC,
    credit NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
    FROM fn_trial_balance_lines_local(p_client_id, p_company_id, p_date_from, p_date_to, p_include_zero, p_location_group_id);
$$;

GRANT EXECUTE ON FUNCTION fn_trial_balance_totals_local(
    UUID, UUID, DATE, DATE, BOOLEAN, UUID) TO authenticated;


-- ============================================================
-- Registry rows + menu, one full set per existing company — same
-- per-company DO loop / ON CONFLICT upsert shape as 127/132.
--
-- Menu: FN-TRB already exists as a placeholder row (pre-dates the
-- Reporting Engine, resolves to a bare _Placeholder widget at
-- /finance/trial-balance) — per this project's own "check ric_master_
-- menus for an existing placeholder before assuming a new menu-seed is
-- needed" rule, repoint its screen_name at the real report instead of
-- adding a second feature_code. The old /finance/trial-balance route
-- is left harmlessly unreferenced (no menu row points at it anymore).
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
             source_object_local, module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'TRIAL_BALANCE', 'Trial Balance',
             'TABULAR', 'FUNCTION', 'fn_trial_balance_lines_base', 'fn_trial_balance_lines_local', 'FN',
             'sort_key', 'ASC', 500, 'fn_trial_balance_totals_base', 'fn_trial_balance_totals_local')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object = excluded.source_object,
                source_object_local = excluded.source_object_local,
                default_sort_column = excluded.default_sort_column,
                default_sort_dir = excluded.default_sort_dir,
                default_page_size = excluded.default_page_size,
                totals_source_object = excluded.totals_source_object,
                totals_source_object_local = excluded.totals_source_object_local
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            -- sortable=false everywhere: row order IS the group/account-code
            -- order sort_key computed — letting a user click a header to
            -- re-sort would break the Assets->Liabilities->Income->Expense
            -- grouping. default_width sums to 830 (>700) so the existing
            -- report_pdf_export.dart width heuristic auto-selects landscape.
            (v_company.client_id, v_company.company_id, v_report_id, 'account_group_name',   'Account Group',        'TEXT',   'LEFT',  false, true,  140, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name',         'Account Name',         'TEXT',   'LEFT',  false, true,  180, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'opening_balance',      'Opening Balance',      'NUMBER', 'RIGHT', false, true,  110, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'opening_balance_type', 'Opening Bal. Type',    'TEXT',   'CENTER',false, true,  70,  4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'debit',                'Debit',                'NUMBER', 'RIGHT', false, true,  110, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'credit',               'Credit',               'NUMBER', 'RIGHT', false, true,  110, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'closing_balance',      'Closing Balance',      'NUMBER', 'RIGHT', false, true,  110, 7, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'closing_balance_type', 'Closing Bal. Type',    'TEXT',   'CENTER',false, true,  70,  8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'sort_key',             'Sort',                 'TEXT',   'LEFT',  false, false, 0,   9, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Period', 'DATE_RANGE',
                NULL, NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'include_zero', 'Include Zero Balances', 'BOOLEAN',
                NULL, NULL, NULL, 'include_zero', false, 'false', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_group', 'Location Group', 'DROPDOWN_LOOKUP',
                'v_location_groups_lookup', 'group_name', NULL, 'location_group_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-TRB', 'Trial Balance',
             '/reports/TRIAL_BALANCE', 6, 'FN-RPT', 'Reports', 2, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill (same pattern as 127/132 Part D): a
-- ric_master_menus row alone makes a feature ELIGIBLE, it grants nobody
-- anything. Give VIEW access to whoever already has view access to any
-- other Finance (FN) feature. FN-TRB may already have grants from
-- whenever the placeholder route was first seeded — ON CONFLICT DO
-- UPDATE just reconfirms view_allowed=true rather than duplicating.
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
WHERE mm.feature_code = 'FN-TRB'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
