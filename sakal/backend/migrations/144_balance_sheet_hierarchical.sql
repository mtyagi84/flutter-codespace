-- ============================================================
-- Migration 144: Balance Sheet reports — third HIERARCHICAL report,
-- the last of the three core financial statements (Trial Balance 135,
-- Profit & Loss 143, now Balance Sheet).
-- ============================================================
-- Two reports, one shared engine, same shape as P&L (143): Balance Sheet
-- Summary (sections + subtotals only) and Balance Sheet Account Detail
-- (full tree down to individual accounts). Reuses fn_pl_totals_base/
-- _local (143) UNMODIFIED for the "Current Year Earnings" line — no
-- change to that migration at all.
--
-- Hardest classification problem in this schema. INDIAN's Assets(1000)/
-- Liabilities(2000)/Equity(3000) roots classify cleanly, same as P&L's
-- own Income/Expense roots. OHADA does NOT: two of its five relevant
-- root classes mix categories directly under one root —
--   root '1000' ("Equity & Long Term Financing"): children '1100'
--     Reserves/'1200' Retained Earnings/'1300' Net Income = EQUITY, but
--     '1600' Loans & Borrowings = LIABILITY.
--   root '4000' ("Third Parties"): child '4110' Customers = ASSET
--     (receivable), but '4010' Suppliers/'4200' Personnel/'4300' Social
--     Security/'4400' State & Taxes = LIABILITY.
-- Confirmed by reading 013_chart_of_accounts.sql's actual OHADA seed —
-- not guessed. '4400' State & Taxes has no seed-level receivable/payable
-- split (unlike INDIAN's own '1140'/'2120' split) — confirmed via Q&A to
-- classify LIABILITY by default (the dominant real-world case for a
-- trading company; a net tax *receivable* position just shows negative,
-- correct in total).
--
-- Resolution: rather than a separate v_balance_sheet_accounts
-- classification view, the section boundary is expressed directly as
-- extra "virtual root" rows in this function's own `roots` CTE — same
-- shape fn_pl_tree_base's own `roots` CTE already uses, just with some
-- entries one level below the true parent_id-IS-NULL root (OHADA's
-- 1100/1200/1300/1600/4010/4110/4200/4300/4400) instead of always being
-- the literal root. subtree then walks DOWN from each virtual root
-- exactly like P&L — the ambiguous real root ('1000'/'4000' for OHADA)
-- is simply never selected as a virtual root itself, so its own mixed
-- meaning is fully absorbed by its children being separate top-level
-- (level_depth=1) tree nodes instead of being bundled under one node.
--
-- Genuine code collision, handled explicitly: OHADA's ASSET root '2000'
-- (Fixed Assets) and EQUITY-becomes-ASSET-context '3000' (Inventory)
-- collide with INDIAN's own LIABILITY root '2000' and EQUITY root
-- '3000' — and OHADA's '1100'/'1200'/'4110'/'4200' also collide with
-- unrelated INDIAN sub-group codes (Current Assets, Non-Current Assets,
-- Product Sales, Non-Operating Revenue — confirmed live via grep on the
-- actual INDIAN seed). Every branch below is explicitly scoped by
-- `accounting_std`, so no cross-standard leakage is possible even though
-- the raw account_code text overlaps — a single company only ever has
-- ONE seeded COA (its own accounting_std), so only one branch can ever
-- match for that company regardless.
--
-- Balance computation: unlike P&L (which nets period activity), Asset/
-- Liability/Equity accounts carry forward indefinitely — reuses Trial
-- Balance's (135) own "opening (from v_opening_balance_summary for the
-- FY containing the as-of date) + movement from that FY's start through
-- the as-of date" formula and its `fy` CTE, verbatim technique, just
-- computed through p_as_of_date inclusive instead of split into a
-- separate opening/period pair (a Balance Sheet is one point in time,
-- not a from/to range).
--
-- Current Year Earnings: no automated year-end closing exists yet in
-- this schema (confirmed via Q&A — a separate future mechanism will zero
-- Income/Expense at the start of every FY; this report is built assuming
-- that mechanism exists, not implementing it). Calls
-- fn_pl_totals_base/_local(..., p_date_from := fy.fy_start_date,
-- p_date_to := p_as_of_date, ...) directly, unioned in as one synthetic
-- EQUITY leaf ("Current Year Earnings", a well-known sentinel UUID, not
-- a real rim_accounts row) — zero changes to migration 143's functions.
-- Until the closing mechanism is live, this figure reflects all-time
-- Income/Expense activity, not just the current year — the report still
-- mathematically balances either way (double-entry is self-consistent
-- regardless), just with a misleadingly-labeled figure until closing
-- actually runs; flagged in the as-built doc, not fixed here.
--
-- Built-in correctness check: fn_balance_sheet_totals_base/_local's own
-- `difference` column (Total Assets − (Total Liabilities + Total
-- Equity)) should always compute to exactly 0 when classification and
-- the Current Year Earnings figure are both right — a stronger,
-- self-validating check than P&L ever had. Treat this as the primary
-- pass/fail signal once run against real data.
-- ============================================================

-- ------------------------------------------------------------
-- fn_balance_sheet_tree_base / _local — the core engine, same recursive
-- shape as fn_pl_tree_base/_local (143): roots -> subtree -> ancestry ->
-- leaf-level signed balance -> node_totals fan-out rollup.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_balance_sheet_tree_base(
    p_client_id  UUID,
    p_company_id UUID,
    p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL,
    p_posted_only        BOOLEAN DEFAULT true,
    p_leaves_included     BOOLEAN DEFAULT true   -- false = Summary report (groups only)
) RETURNS TABLE (
    node_id      UUID,
    parent_id    UUID,
    section      TEXT,     -- 'ASSET' | 'LIABILITY' | 'EQUITY'
    node_name    TEXT,
    level_depth  INTEGER,
    is_leaf      BOOLEAN,
    amount       NUMERIC,
    sort_key     TEXT
) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE roots AS (
        -- INDIAN — clean root-level classification, same shape as P&L's own roots CTE.
        SELECT id AS root_id, 'ASSET' AS section
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'INDIAN' AND account_code = '1000'
        UNION ALL
        SELECT id, 'LIABILITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'INDIAN' AND account_code = '2000'
        UNION ALL
        SELECT id, 'EQUITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'INDIAN' AND account_code = '3000'
        -- OHADA — unambiguous roots (Fixed Assets, Inventory, Treasury).
        UNION ALL
        SELECT id, 'ASSET'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'OHADA' AND account_code IN ('2000', '3000', '5000')
        -- OHADA — root '1000' ("Equity & Long Term Financing") splits at its own children.
        UNION ALL
        SELECT id, 'EQUITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code IN ('1100', '1200', '1300')
        UNION ALL
        SELECT id, 'LIABILITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '1600'
        -- OHADA — root '4000' ("Third Parties") splits at its own children.
        -- '4400' State & Taxes -> LIABILITY by default (confirmed via Q&A).
        UNION ALL
        SELECT id, 'ASSET'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '4110'
        UNION ALL
        SELECT id, 'LIABILITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code IN ('4010', '4200', '4300', '4400')
    ),
    subtree AS (
        -- Each virtual root becomes its own level_depth=1 tree node (parent_id
        -- forced NULL — its true rim_accounts parent, when one exists and is
        -- ambiguous, e.g. OHADA's '1000'/'4000', is deliberately never part of
        -- this displayed tree).
        SELECT r.root_id AS id, NULL::uuid AS parent_id, a.account_code, a.account_name, a.posting_allowed,
               1 AS level_depth, r.section
        FROM roots r
        JOIN rim_accounts a ON a.id = r.root_id
        UNION ALL
        SELECT a.id, a.parent_id, a.account_code, a.account_name, a.posting_allowed,
               s.level_depth + 1, s.section
        FROM rim_accounts a
        JOIN subtree s ON a.parent_id = s.id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id AND a.is_deleted = false
    ),
    ancestry AS (
        SELECT id AS descendant_id, id AS ancestor_id, parent_id
        FROM subtree
        WHERE posting_allowed = true
        UNION ALL
        SELECT anc.descendant_id, s.id AS ancestor_id, s.parent_id
        FROM subtree s
        JOIN ancestry anc ON s.id = anc.parent_id
    ),
    fy AS (
        SELECT id, fy_start_date
        FROM rim_financial_years
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND fy_start_date <= p_as_of_date AND fy_end_date >= p_as_of_date
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
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
            AND h.trans_date  = l.trans_date
        JOIN fy ON true
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.is_deleted = false AND h.is_deleted = false
          AND (NOT p_posted_only OR h.is_posted = true)
          AND h.trans_date >= fy.fy_start_date AND h.trans_date <= p_as_of_date
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
          AND (
              NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                          WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                            AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                            AND ula.is_active = true AND ula.is_deleted = false)
              OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                      AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                      AND ula.is_active = true AND ula.is_deleted = false)
          )
        GROUP BY l.account_id
    ),
    leaf_balance AS (
        -- Dr-positive raw balance (opening + movement to date), then sign-
        -- flipped per section: ASSET stays Dr-positive, LIABILITY/EQUITY
        -- shown Cr-positive — mirrors exactly how P&L signs Income
        -- (Cr-positive) vs Expense (Dr-positive). LEFT JOINs (not a plain
        -- movement-only source like P&L's own leaf_amounts) so an account
        -- with a carried-forward balance but zero current-year movement
        -- still appears.
        SELECT
            st.id AS account_id,
            CASE WHEN st.section = 'ASSET'
                 THEN COALESCE(om.signed, 0) + COALESCE(mv.signed, 0)
                 ELSE -(COALESCE(om.signed, 0) + COALESCE(mv.signed, 0))
            END AS signed_amount
        FROM subtree st
        LEFT JOIN opening_master   om ON om.account_id = st.id
        LEFT JOIN opening_movement mv ON mv.account_id = st.id
        WHERE st.posting_allowed = true
    ),
    node_totals AS (
        SELECT anc.ancestor_id AS node_id, SUM(lb.signed_amount) AS amount
        FROM ancestry anc
        JOIN leaf_balance lb ON lb.account_id = anc.descendant_id
        GROUP BY anc.ancestor_id
    )
    SELECT
        s.id, s.parent_id, s.section, s.account_name, s.level_depth, s.posting_allowed,
        nt.amount,
        s.section || '~' || LPAD(s.level_depth::text, 3, '0') || '~' || s.account_code AS sort_key
    FROM subtree s
    JOIN node_totals nt ON nt.node_id = s.id
    WHERE nt.amount <> 0
      AND (p_leaves_included OR NOT s.posting_allowed)
    UNION ALL
    -- Current Year Earnings — synthetic EQUITY leaf, always shown
    -- (Summary and Detail both), sourced from fn_pl_totals_base (143)
    -- unchanged. Sentinel UUID, not a real rim_accounts row.
    SELECT
        '00000000-0000-0000-0000-000000000001'::uuid, NULL::uuid, 'EQUITY', 'Current Year Earnings',
        1, true, pl.net_profit, 'EQUITY~001~ZZZZ'
    FROM fy, LATERAL fn_pl_totals_base(p_client_id, p_company_id, fy.fy_start_date, p_as_of_date, p_location_group_id, p_posted_only) pl
    WHERE pl.net_profit <> 0;
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_tree_base(UUID, UUID, DATE, UUID, BOOLEAN, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_balance_sheet_tree_local(
    p_client_id  UUID,
    p_company_id UUID,
    p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL,
    p_posted_only        BOOLEAN DEFAULT true,
    p_leaves_included     BOOLEAN DEFAULT true
) RETURNS TABLE (
    node_id      UUID,
    parent_id    UUID,
    section      TEXT,
    node_name    TEXT,
    level_depth  INTEGER,
    is_leaf      BOOLEAN,
    amount       NUMERIC,
    sort_key     TEXT
) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE roots AS (
        SELECT id AS root_id, 'ASSET' AS section
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'INDIAN' AND account_code = '1000'
        UNION ALL
        SELECT id, 'LIABILITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'INDIAN' AND account_code = '2000'
        UNION ALL
        SELECT id, 'EQUITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'INDIAN' AND account_code = '3000'
        UNION ALL
        SELECT id, 'ASSET'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND parent_id IS NULL AND accounting_std = 'OHADA' AND account_code IN ('2000', '3000', '5000')
        UNION ALL
        SELECT id, 'EQUITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code IN ('1100', '1200', '1300')
        UNION ALL
        SELECT id, 'LIABILITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '1600'
        UNION ALL
        SELECT id, 'ASSET'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '4110'
        UNION ALL
        SELECT id, 'LIABILITY'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code IN ('4010', '4200', '4300', '4400')
    ),
    subtree AS (
        SELECT r.root_id AS id, NULL::uuid AS parent_id, a.account_code, a.account_name, a.posting_allowed,
               1 AS level_depth, r.section
        FROM roots r
        JOIN rim_accounts a ON a.id = r.root_id
        UNION ALL
        SELECT a.id, a.parent_id, a.account_code, a.account_name, a.posting_allowed,
               s.level_depth + 1, s.section
        FROM rim_accounts a
        JOIN subtree s ON a.parent_id = s.id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id AND a.is_deleted = false
    ),
    ancestry AS (
        SELECT id AS descendant_id, id AS ancestor_id, parent_id
        FROM subtree
        WHERE posting_allowed = true
        UNION ALL
        SELECT anc.descendant_id, s.id AS ancestor_id, s.parent_id
        FROM subtree s
        JOIN ancestry anc ON s.id = anc.parent_id
    ),
    fy AS (
        SELECT id, fy_start_date
        FROM rim_financial_years
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND fy_start_date <= p_as_of_date AND fy_end_date >= p_as_of_date
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
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
            AND h.trans_date  = l.trans_date
        JOIN fy ON true
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.is_deleted = false AND h.is_deleted = false
          AND (NOT p_posted_only OR h.is_posted = true)
          AND h.trans_date >= fy.fy_start_date AND h.trans_date <= p_as_of_date
          AND (p_location_group_id IS NULL
               OR EXISTS (SELECT 1 FROM ric_locations rl WHERE rl.id = h.location_id AND rl.group_id = p_location_group_id))
          AND (
              NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                          WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                            AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                            AND ula.is_active = true AND ula.is_deleted = false)
              OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                      AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                      AND ula.is_active = true AND ula.is_deleted = false)
          )
        GROUP BY l.account_id
    ),
    leaf_balance AS (
        SELECT
            st.id AS account_id,
            CASE WHEN st.section = 'ASSET'
                 THEN COALESCE(om.signed, 0) + COALESCE(mv.signed, 0)
                 ELSE -(COALESCE(om.signed, 0) + COALESCE(mv.signed, 0))
            END AS signed_amount
        FROM subtree st
        LEFT JOIN opening_master   om ON om.account_id = st.id
        LEFT JOIN opening_movement mv ON mv.account_id = st.id
        WHERE st.posting_allowed = true
    ),
    node_totals AS (
        SELECT anc.ancestor_id AS node_id, SUM(lb.signed_amount) AS amount
        FROM ancestry anc
        JOIN leaf_balance lb ON lb.account_id = anc.descendant_id
        GROUP BY anc.ancestor_id
    )
    SELECT
        s.id, s.parent_id, s.section, s.account_name, s.level_depth, s.posting_allowed,
        nt.amount,
        s.section || '~' || LPAD(s.level_depth::text, 3, '0') || '~' || s.account_code AS sort_key
    FROM subtree s
    JOIN node_totals nt ON nt.node_id = s.id
    WHERE nt.amount <> 0
      AND (p_leaves_included OR NOT s.posting_allowed)
    UNION ALL
    SELECT
        '00000000-0000-0000-0000-000000000001'::uuid, NULL::uuid, 'EQUITY', 'Current Year Earnings',
        1, true, pl.net_profit, 'EQUITY~001~ZZZZ'
    FROM fy, LATERAL fn_pl_totals_local(p_client_id, p_company_id, fy.fy_start_date, p_as_of_date, p_location_group_id, p_posted_only) pl
    WHERE pl.net_profit <> 0;
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_tree_local(UUID, UUID, DATE, UUID, BOOLEAN, BOOLEAN) TO authenticated;


-- ------------------------------------------------------------
-- Thin wrappers — what ric_report_definitions.source_object actually
-- names for each of the two reports. Same pattern as fn_pl_tree_
-- summary/detail_base/_local (143).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_balance_sheet_tree_summary_base(
    p_client_id UUID, p_company_id UUID, p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_balance_sheet_tree_base(p_client_id, p_company_id, p_as_of_date, p_location_group_id, p_posted_only, false);
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_tree_summary_base(UUID, UUID, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_balance_sheet_tree_summary_local(
    p_client_id UUID, p_company_id UUID, p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_balance_sheet_tree_local(p_client_id, p_company_id, p_as_of_date, p_location_group_id, p_posted_only, false);
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_tree_summary_local(UUID, UUID, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_balance_sheet_tree_detail_base(
    p_client_id UUID, p_company_id UUID, p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_balance_sheet_tree_base(p_client_id, p_company_id, p_as_of_date, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_tree_detail_base(UUID, UUID, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_balance_sheet_tree_detail_local(
    p_client_id UUID, p_company_id UUID, p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_balance_sheet_tree_local(p_client_id, p_company_id, p_as_of_date, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_tree_detail_local(UUID, UUID, DATE, UUID, BOOLEAN) TO authenticated;


-- ------------------------------------------------------------
-- fn_balance_sheet_totals_base / _local — Total Assets / Total
-- Liabilities / Total Equity / Total Liabilities & Equity / Difference
-- footer. Reuses fn_balance_sheet_tree_base/_local directly (summing
-- each section's own level_depth=1 group totals, already fully rolled
-- up, including the synthetic Current Year Earnings row) rather than
-- re-deriving the rollup a third time — same guarantee-by-construction
-- fn_pl_totals_base/_local (143) already established. `difference` is
-- the report's own built-in correctness check — always 0 when
-- classification and the Current Year Earnings figure are both right.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_balance_sheet_totals_base(
    p_client_id UUID, p_company_id UUID, p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (
    total_assets NUMERIC, total_liabilities NUMERIC, total_equity NUMERIC,
    total_liabilities_equity NUMERIC, difference NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(amount) FILTER (WHERE section = 'ASSET'     AND level_depth = 1), 0) AS total_assets,
        COALESCE(SUM(amount) FILTER (WHERE section = 'LIABILITY' AND level_depth = 1), 0) AS total_liabilities,
        COALESCE(SUM(amount) FILTER (WHERE section = 'EQUITY'    AND level_depth = 1), 0) AS total_equity,
        COALESCE(SUM(amount) FILTER (WHERE section = 'LIABILITY' AND level_depth = 1), 0)
          + COALESCE(SUM(amount) FILTER (WHERE section = 'EQUITY' AND level_depth = 1), 0) AS total_liabilities_equity,
        COALESCE(SUM(amount) FILTER (WHERE section = 'ASSET' AND level_depth = 1), 0)
          - (COALESCE(SUM(amount) FILTER (WHERE section = 'LIABILITY' AND level_depth = 1), 0)
             + COALESCE(SUM(amount) FILTER (WHERE section = 'EQUITY' AND level_depth = 1), 0)) AS difference
    FROM fn_balance_sheet_tree_base(p_client_id, p_company_id, p_as_of_date, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_totals_base(UUID, UUID, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_balance_sheet_totals_local(
    p_client_id UUID, p_company_id UUID, p_as_of_date DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (
    total_assets NUMERIC, total_liabilities NUMERIC, total_equity NUMERIC,
    total_liabilities_equity NUMERIC, difference NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(amount) FILTER (WHERE section = 'ASSET'     AND level_depth = 1), 0) AS total_assets,
        COALESCE(SUM(amount) FILTER (WHERE section = 'LIABILITY' AND level_depth = 1), 0) AS total_liabilities,
        COALESCE(SUM(amount) FILTER (WHERE section = 'EQUITY'    AND level_depth = 1), 0) AS total_equity,
        COALESCE(SUM(amount) FILTER (WHERE section = 'LIABILITY' AND level_depth = 1), 0)
          + COALESCE(SUM(amount) FILTER (WHERE section = 'EQUITY' AND level_depth = 1), 0) AS total_liabilities_equity,
        COALESCE(SUM(amount) FILTER (WHERE section = 'ASSET' AND level_depth = 1), 0)
          - (COALESCE(SUM(amount) FILTER (WHERE section = 'LIABILITY' AND level_depth = 1), 0)
             + COALESCE(SUM(amount) FILTER (WHERE section = 'EQUITY' AND level_depth = 1), 0)) AS difference
    FROM fn_balance_sheet_tree_local(p_client_id, p_company_id, p_as_of_date, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_balance_sheet_totals_local(UUID, UUID, DATE, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Registry — per company: repoint the existing FN-BSH placeholder for
-- Summary, add a genuinely new feature code for Detail. Same shape as
-- 143's own P&L registry block.
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

        -- ---------------- Balance Sheet Summary ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             source_object_local, totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'BALANCE_SHEET_SUMMARY', 'Balance Sheet Summary',
             'HIERARCHICAL', 'FUNCTION', 'fn_balance_sheet_tree_summary_base', 'FN', 'sort_key', 'ASC', 2000,
             'fn_balance_sheet_tree_summary_local', 'fn_balance_sheet_totals_base', 'fn_balance_sheet_totals_local')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object = excluded.source_object,
                source_object_local = excluded.source_object_local,
                totals_source_object = excluded.totals_source_object,
                totals_source_object_local = excluded.totals_source_object_local
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'node_name', 'Group Name', 'TEXT',   'LEFT',  false, true, 260, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'amount',    'Amount',     'NUMBER', 'RIGHT', false, true, 150, 2);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'as_of_date', 'As Of Date', 'DATE',
                NULL, NULL, 'as_of_date', true, 'TODAY', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_only', 'Posted Only', 'BOOLEAN',
                NULL, NULL, 'posted_only', false, 'true', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_group_id', 'Location Group', 'DROPDOWN_LOOKUP',
                'v_location_groups_lookup', 'group_name', 'location_group_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-BSH', 'Balance Sheet',
             '/reports/BALANCE_SHEET_SUMMARY', 2, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

        -- ---------------- Balance Sheet Account Detail (new) ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             source_object_local, totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'BALANCE_SHEET_DETAIL', 'Balance Sheet Account Detail',
             'HIERARCHICAL', 'FUNCTION', 'fn_balance_sheet_tree_detail_base', 'FN', 'sort_key', 'ASC', 5000,
             'fn_balance_sheet_tree_detail_local', 'fn_balance_sheet_totals_base', 'fn_balance_sheet_totals_local')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object = excluded.source_object,
                source_object_local = excluded.source_object_local,
                totals_source_object = excluded.totals_source_object,
                totals_source_object_local = excluded.totals_source_object_local
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'node_name', 'Account / Group Name', 'TEXT',   'LEFT',  false, true, 300, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'amount',    'Amount',               'NUMBER', 'RIGHT', false, true, 150, 2);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'as_of_date', 'As Of Date', 'DATE',
                NULL, NULL, 'as_of_date', true, 'TODAY', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_only', 'Posted Only', 'BOOLEAN',
                NULL, NULL, 'posted_only', false, 'true', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_group_id', 'Location Group', 'DROPDOWN_LOOKUP',
                'v_location_groups_lookup', 'group_name', 'location_group_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-BSD', 'Balance Sheet Account Detail',
             '/reports/BALANCE_SHEET_DETAIL', 12, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill — same pattern as every prior report
-- migration. FN-BSH already has whatever grants it had before (this
-- migration only repoints its screen_name); FN-RPT-BSD is genuinely new
-- and needs the same backfill every new feature code gets.
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
WHERE mm.feature_code = 'FN-RPT-BSD'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
