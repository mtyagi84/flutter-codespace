-- ============================================================
-- Migration 145: Cash Flow Statement — fourth and final core financial
-- statement (Trial Balance 135, Profit & Loss 143, Balance Sheet 144,
-- now Cash Flow).
-- ============================================================
-- Two reports, same shape as P&L/BS: Cash Flow Summary (sections +
-- category subtotals) and Cash Flow Account Detail (full tree down to
-- individual GL accounts). Built on the DIRECT method (traces actual
-- Cash/Bank ledger movements, classifies by contra account) — the
-- INDIRECT method (start from Net Profit, add back Depreciation, adjust
-- working capital) was explicitly rejected: this schema has no Fixed
-- Asset Register / automated depreciation engine (only plain CoA labels
-- '2800'/'6800' and a dormant ASSET_DEPRECIATION_ACCOUNT link-config
-- from migration 032, never consumed), so a reliable Depreciation
-- add-back isn't available. Direct method sidesteps that dependency
-- entirely and is also the more intuitive presentation for non-
-- accountant store managers (DRC/Zambia retail context).
--
-- Categories within each section use the company's REAL Chart of
-- Accounts hierarchy (self-maintaining, same philosophy as P&L/BS) —
-- not a hand-curated fixed category list.
--
-- ------------------------------------------------------------
-- Core technique: same recursive shape as fn_pl_tree_base (143) and
-- fn_balance_sheet_tree_base (144) — roots -> subtree -> ancestry ->
-- leaf amount -> node_totals fan-out. The leaf amount computation is
-- genuinely new: an APPORTIONED CASH CONTRIBUTION, not a direct account
-- balance/movement.
--   1. cash_lines: every rid_finance_lines row on a Cash/Bank-nature
--      account within the period, netted PER VOUCHER (Dr-positive =
--      inflow) — a voucher can have multiple cash/bank lines (e.g. a
--      split cash+bank payment) and must net to one figure.
--   2. contra_lines: every NON-cash-nature line in those same vouchers,
--      carrying its own base_amount as an apportionment weight — NOT
--      trans_amount, per this schema's own established rule (058: "any
--      DR=CR balance check across a voucher's lines must sum
--      base_amount, never trans_amount, since a voucher can legitimately
--      mix trans_currencies across lines" — e.g. Purchase Bill's own
--      Exchange Gain/Loss line). base_amount is used identically in both
--      the _base and _local functions below, so the apportionment
--      FRACTIONS never change with the Base/Local toggle — only the
--      final displayed cash figure (via cash_signed) does.
--   3. Cash<->Bank internal transfers (a Contra Voucher moving money
--      between two cash-equivalent accounts) are excluded FOR FREE: a
--      voucher whose only non-cash-nature lines are themselves ALSO
--      cash/bank nature has an EMPTY contra_lines set, so it never
--      appears downstream. No special-case code — standard accounting
--      treatment (movements between cash and cash-equivalents are not
--      part of the cash flow statement) falls out of the JOIN shape.
--   4. leaf_amounts: apportion each voucher's net cash movement across
--      its contra lines by each line's own share of the voucher's total
--      contra base_amount — same "apportion by amount share within one
--      document" technique already used for GRN/Sales Invoice charge
--      apportionment elsewhere in this app.
--   5. Classify + roll up: each contra account is classified into
--      OPERATING/INVESTING/FINANCING via an extended virtual-root
--      technique (below), then ancestor-fanout rollup (identical to
--      143/144) gives every group node its own correctly rolled-up
--      subtotal in one pass.
--
-- ------------------------------------------------------------
-- Classification (virtual roots) — unlike Balance Sheet's 3-way split
-- (which explicitly covers the WHOLE COA symmetrically), Cash Flow's
-- OPERATING bucket is the "everything else" catch-all, so INVESTING and
-- FINANCING get small explicit lists and OPERATING gets an explicit
-- list of every remaining real account-code group — same carve-out
-- technique 144 used for OHADA's '1000'/'4000' (never use an ambiguous
-- shared parent as a virtual root, only its disambiguating children),
-- applied here one level deeper for INDIAN's Current Liabilities too.
-- Every branch scoped by accounting_std (one company = one seeded COA,
-- so no cross-standard leakage despite code-text overlap).
--
-- INVESTING: INDIAN '1200' (Non-Current Assets, covers 1210-1290
--   including Investments 1290). OHADA '2000' (Fixed Assets, covers
--   2100-2800 including Investments 2700).
-- FINANCING: INDIAN '2160' (Short Term Borrowings), '2210' (Term
--   Loans), '2220' (Lease Liabilities), '3100' (Capital), '3200'
--   (Reserves & Surplus — a dividend payment, no dedicated account
--   seeded, would post here or against Capital, both already
--   Financing). OHADA '1600' (Loans & Borrowings), '1100'/'1200'/'1300'
--   (Reserves/Retained Earnings/Net Income — same codes 144 classified
--   EQUITY; here Financing for the identical reason: equity movements
--   funded/returned in cash are financing activities).
-- OPERATING (explicit catch-all): INDIAN '1100' (Current Assets, all —
--   Cash&Bank/Receivables/Inventory/Tax/Advances/Prepaid/Other),
--   '2110'/'2120'/'2130'/'2140'/'2150'/'2170' (Current Liabilities
--   MINUS '2160' Borrowings, carved out above), '2230' (Deferred Tax
--   Liability — judgment call: grouped with Tax Liabilities '2120', not
--   the Term Loan/Lease codes, since IFRS treats income-tax cash flows
--   as Operating unless specifically tied to a financing/investing
--   transaction), '4000' (Revenue, all), '5000' (Expense, all). OHADA
--   '3000' (Inventory, all — a current-asset/operating item, not a
--   fixed asset), '4010'/'4110'/'4200'/'4300'/'4400' (Third Parties
--   minus '1600', already the same Supplier/Customer/Personnel/Social
--   Security/State&Taxes codes 144 resolved), '5800' (Internal
--   Transfers — Treasury's own posting-allowed non-cash-nature child),
--   '6000'/'7000' (Expense/Revenue, all). '9000' (internal Cost
--   Accounting) is excluded entirely — never a real cash contra.
--
-- ------------------------------------------------------------
-- Opening/Closing Cash + reconciliation — the strongest correctness
-- check of any report built this session. Opening Cash (as of
-- p_date_from) and Closing Cash reuse Trial Balance's (135) own
-- opening+movement-to-date formula, restricted to account_nature IN
-- ('Cash','Bank'), computed INDEPENDENTLY of the 3-section apportionment
-- logic above. Because this is double-entry, Operating+Investing+
-- Financing MUST exactly equal Closing-Opening Cash if the SQL is
-- correct — any gap is a real bug in this report's classification/
-- apportionment logic, not a genuine accounting discrepancy. Exposed as
-- `reconciliation_diff` on the totals function — treat as the PRIMARY
-- pass/fail signal once run against real data.
-- ============================================================

-- ------------------------------------------------------------
-- fn_cash_flow_tree_base / _local — the core engine.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cash_flow_tree_base(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from  DATE,
    p_date_to    DATE,
    p_location_group_id UUID DEFAULT NULL,
    p_posted_only        BOOLEAN DEFAULT true,
    p_leaves_included     BOOLEAN DEFAULT true   -- false = Summary report (groups only)
) RETURNS TABLE (
    node_id      UUID,
    parent_id    UUID,
    section      TEXT,     -- 'OPERATING' | 'INVESTING' | 'FINANCING'
    node_name    TEXT,
    level_depth  INTEGER,
    is_leaf      BOOLEAN,
    amount       NUMERIC,
    sort_key     TEXT
) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE roots AS (
        -- INDIAN
        SELECT id AS root_id, 'FINANCING' AS section FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code IN ('2160', '2210', '2220', '3100', '3200')
        UNION ALL
        SELECT id, 'INVESTING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code = '1200'
        UNION ALL
        SELECT id, 'OPERATING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'INDIAN'
          AND account_code IN ('1100', '2110', '2120', '2130', '2140', '2150', '2170', '2230', '4000', '5000')
        -- OHADA
        UNION ALL
        SELECT id, 'FINANCING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code IN ('1600', '1100', '1200', '1300')
        UNION ALL
        SELECT id, 'INVESTING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '2000'
        UNION ALL
        SELECT id, 'OPERATING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA'
          AND account_code IN ('3000', '4010', '4110', '4200', '4300', '4400', '5800', '6000', '7000')
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
    cash_lines AS (
        SELECT
            l.client_id, l.company_id, l.location_id, l.trans_no, l.trans_date,
            SUM(CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END) AS cash_signed
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
            AND h.trans_date  = l.trans_date
        JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature IN ('Cash', 'Bank')
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND h.trans_date BETWEEN p_date_from AND p_date_to
          AND (NOT p_posted_only OR h.is_posted = true)
          AND h.is_deleted = false AND l.is_deleted = false
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
        GROUP BY l.client_id, l.company_id, l.location_id, l.trans_no, l.trans_date
    ),
    contra_lines AS (
        SELECT
            l.client_id, l.company_id, l.location_id, l.trans_no, l.trans_date,
            l.account_id, l.base_amount
        FROM rid_finance_lines l
        JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature NOT IN ('Cash', 'Bank')
        JOIN cash_lines cl
            ON  cl.client_id = l.client_id AND cl.company_id = l.company_id
            AND cl.location_id = l.location_id AND cl.trans_no = l.trans_no AND cl.trans_date = l.trans_date
        WHERE l.is_deleted = false
    ),
    contra_totals AS (
        SELECT client_id, company_id, location_id, trans_no, trans_date, SUM(base_amount) AS total_contra_amount
        FROM contra_lines
        GROUP BY client_id, company_id, location_id, trans_no, trans_date
    ),
    leaf_amounts AS (
        SELECT
            c.account_id,
            SUM(cl.cash_signed * (c.base_amount / ct.total_contra_amount)) AS signed_amount
        FROM contra_lines c
        JOIN contra_totals ct
            ON  ct.client_id = c.client_id AND ct.company_id = c.company_id AND ct.location_id = c.location_id
            AND ct.trans_no = c.trans_no AND ct.trans_date = c.trans_date
        JOIN cash_lines cl
            ON  cl.client_id = c.client_id AND cl.company_id = c.company_id AND cl.location_id = c.location_id
            AND cl.trans_no = c.trans_no AND cl.trans_date = c.trans_date
        WHERE ct.total_contra_amount <> 0
        GROUP BY c.account_id
    ),
    node_totals AS (
        SELECT anc.ancestor_id AS node_id, SUM(la.signed_amount) AS amount
        FROM ancestry anc
        JOIN leaf_amounts la ON la.account_id = anc.descendant_id
        GROUP BY anc.ancestor_id
    )
    SELECT
        s.id, s.parent_id, s.section, s.account_name, s.level_depth, s.posting_allowed,
        nt.amount,
        s.section || '~' || LPAD(s.level_depth::text, 3, '0') || '~' || s.account_code AS sort_key
    FROM subtree s
    JOIN node_totals nt ON nt.node_id = s.id
    WHERE nt.amount <> 0
      AND (p_leaves_included OR NOT s.posting_allowed);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_tree_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_cash_flow_tree_local(
    p_client_id  UUID,
    p_company_id UUID,
    p_date_from  DATE,
    p_date_to    DATE,
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
        SELECT id AS root_id, 'FINANCING' AS section FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code IN ('2160', '2210', '2220', '3100', '3200')
        UNION ALL
        SELECT id, 'INVESTING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code = '1200'
        UNION ALL
        SELECT id, 'OPERATING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'INDIAN'
          AND account_code IN ('1100', '2110', '2120', '2130', '2140', '2150', '2170', '2230', '4000', '5000')
        UNION ALL
        SELECT id, 'FINANCING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code IN ('1600', '1100', '1200', '1300')
        UNION ALL
        SELECT id, 'INVESTING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '2000'
        UNION ALL
        SELECT id, 'OPERATING' FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_deleted = false
          AND accounting_std = 'OHADA'
          AND account_code IN ('3000', '4010', '4110', '4200', '4300', '4400', '5800', '6000', '7000')
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
    cash_lines AS (
        SELECT
            l.client_id, l.company_id, l.location_id, l.trans_no, l.trans_date,
            SUM(CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END) AS cash_signed
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
            AND h.trans_date  = l.trans_date
        JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature IN ('Cash', 'Bank')
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND h.trans_date BETWEEN p_date_from AND p_date_to
          AND (NOT p_posted_only OR h.is_posted = true)
          AND h.is_deleted = false AND l.is_deleted = false
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
        GROUP BY l.client_id, l.company_id, l.location_id, l.trans_no, l.trans_date
    ),
    contra_lines AS (
        SELECT
            l.client_id, l.company_id, l.location_id, l.trans_no, l.trans_date,
            l.account_id, l.base_amount
        FROM rid_finance_lines l
        JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature NOT IN ('Cash', 'Bank')
        JOIN cash_lines cl
            ON  cl.client_id = l.client_id AND cl.company_id = l.company_id
            AND cl.location_id = l.location_id AND cl.trans_no = l.trans_no AND cl.trans_date = l.trans_date
        WHERE l.is_deleted = false
    ),
    contra_totals AS (
        SELECT client_id, company_id, location_id, trans_no, trans_date, SUM(base_amount) AS total_contra_amount
        FROM contra_lines
        GROUP BY client_id, company_id, location_id, trans_no, trans_date
    ),
    leaf_amounts AS (
        SELECT
            c.account_id,
            SUM(cl.cash_signed * (c.base_amount / ct.total_contra_amount)) AS signed_amount
        FROM contra_lines c
        JOIN contra_totals ct
            ON  ct.client_id = c.client_id AND ct.company_id = c.company_id AND ct.location_id = c.location_id
            AND ct.trans_no = c.trans_no AND ct.trans_date = c.trans_date
        JOIN cash_lines cl
            ON  cl.client_id = c.client_id AND cl.company_id = c.company_id AND cl.location_id = c.location_id
            AND cl.trans_no = c.trans_no AND cl.trans_date = c.trans_date
        WHERE ct.total_contra_amount <> 0
        GROUP BY c.account_id
    ),
    node_totals AS (
        SELECT anc.ancestor_id AS node_id, SUM(la.signed_amount) AS amount
        FROM ancestry anc
        JOIN leaf_amounts la ON la.account_id = anc.descendant_id
        GROUP BY anc.ancestor_id
    )
    SELECT
        s.id, s.parent_id, s.section, s.account_name, s.level_depth, s.posting_allowed,
        nt.amount,
        s.section || '~' || LPAD(s.level_depth::text, 3, '0') || '~' || s.account_code AS sort_key
    FROM subtree s
    JOIN node_totals nt ON nt.node_id = s.id
    WHERE nt.amount <> 0
      AND (p_leaves_included OR NOT s.posting_allowed);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_tree_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN, BOOLEAN) TO authenticated;


-- ------------------------------------------------------------
-- Thin wrappers — what ric_report_definitions.source_object actually
-- names for each of the two reports. Same pattern as 143/144.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cash_flow_tree_summary_base(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_cash_flow_tree_base(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, false);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_tree_summary_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_cash_flow_tree_summary_local(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_cash_flow_tree_local(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, false);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_tree_summary_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_cash_flow_tree_detail_base(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_cash_flow_tree_base(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_tree_detail_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_cash_flow_tree_detail_local(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_cash_flow_tree_local(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_tree_detail_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;


-- ------------------------------------------------------------
-- fn_cash_flow_totals_base / _local — Operating/Investing/Financing
-- totals + Opening/Closing Cash + the reconciliation_diff correctness
-- check. Opening/Closing Cash are computed INDEPENDENTLY of the tree
-- function above (same opening+movement-to-date formula Trial Balance
-- (135) uses, restricted to Cash/Bank-nature accounts) — deliberately
-- NOT derived from fn_cash_flow_tree_base, so the two numbers can act as
-- a genuine cross-check on each other rather than trivially agreeing by
-- construction.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cash_flow_totals_base(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (
    operating_total NUMERIC, investing_total NUMERIC, financing_total NUMERIC,
    net_cash_flow NUMERIC, opening_cash NUMERIC, closing_cash NUMERIC, reconciliation_diff NUMERIC
) LANGUAGE sql STABLE AS $$
    WITH tree_totals AS (
        SELECT
            COALESCE(SUM(amount) FILTER (WHERE section = 'OPERATING' AND level_depth = 1), 0) AS operating_total,
            COALESCE(SUM(amount) FILTER (WHERE section = 'INVESTING' AND level_depth = 1), 0) AS investing_total,
            COALESCE(SUM(amount) FILTER (WHERE section = 'FINANCING' AND level_depth = 1), 0) AS financing_total
        FROM fn_cash_flow_tree_base(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true)
    ),
    cash_recon AS (
        SELECT
            (WITH fy AS (
                SELECT id, fy_start_date FROM rim_financial_years
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND fy_start_date <= p_date_from AND fy_end_date >= p_date_from
                LIMIT 1
            )
            SELECT
                COALESCE((SELECT SUM(ob.base_signed) FROM v_opening_balance_summary ob
                          JOIN rim_accounts a ON a.id = ob.account_id AND a.account_nature IN ('Cash', 'Bank')
                          WHERE ob.client_id = p_client_id AND ob.company_id = p_company_id AND ob.fy_id = fy.id
                            AND (p_location_group_id IS NULL OR ob.location_group_id = p_location_group_id)), 0)
                +
                COALESCE((SELECT SUM(CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END)
                          FROM rid_finance_lines l
                          JOIN rih_finance_headers h
                              ON  h.client_id = l.client_id AND h.company_id = l.company_id
                              AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
                          JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature IN ('Cash', 'Bank')
                          WHERE l.client_id = p_client_id AND l.company_id = p_company_id
                            AND l.is_deleted = false AND h.is_deleted = false
                            AND (NOT p_posted_only OR h.is_posted = true)
                            AND h.trans_date >= fy.fy_start_date AND h.trans_date < p_date_from
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
                                                        AND ula.is_active = true AND ula.is_deleted = false))
                         ), 0)
            FROM fy) AS opening_cash,
            COALESCE((SELECT SUM(CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END)
                      FROM rid_finance_lines l
                      JOIN rih_finance_headers h
                          ON  h.client_id = l.client_id AND h.company_id = l.company_id
                          AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
                      JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature IN ('Cash', 'Bank')
                      WHERE l.client_id = p_client_id AND l.company_id = p_company_id
                        AND l.is_deleted = false AND h.is_deleted = false
                        AND (NOT p_posted_only OR h.is_posted = true)
                        AND h.trans_date >= p_date_from AND h.trans_date <= p_date_to
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
                                                    AND ula.is_active = true AND ula.is_deleted = false))
                     ), 0) AS period_movement
    )
    SELECT
        tt.operating_total, tt.investing_total, tt.financing_total,
        tt.operating_total + tt.investing_total + tt.financing_total AS net_cash_flow,
        cr.opening_cash,
        cr.opening_cash + cr.period_movement AS closing_cash,
        cr.period_movement - (tt.operating_total + tt.investing_total + tt.financing_total) AS reconciliation_diff
    FROM tree_totals tt, cash_recon cr;
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_totals_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_cash_flow_totals_local(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (
    operating_total NUMERIC, investing_total NUMERIC, financing_total NUMERIC,
    net_cash_flow NUMERIC, opening_cash NUMERIC, closing_cash NUMERIC, reconciliation_diff NUMERIC
) LANGUAGE sql STABLE AS $$
    WITH tree_totals AS (
        SELECT
            COALESCE(SUM(amount) FILTER (WHERE section = 'OPERATING' AND level_depth = 1), 0) AS operating_total,
            COALESCE(SUM(amount) FILTER (WHERE section = 'INVESTING' AND level_depth = 1), 0) AS investing_total,
            COALESCE(SUM(amount) FILTER (WHERE section = 'FINANCING' AND level_depth = 1), 0) AS financing_total
        FROM fn_cash_flow_tree_local(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true)
    ),
    cash_recon AS (
        SELECT
            (WITH fy AS (
                SELECT id, fy_start_date FROM rim_financial_years
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND fy_start_date <= p_date_from AND fy_end_date >= p_date_from
                LIMIT 1
            )
            SELECT
                COALESCE((SELECT SUM(ob.local_signed) FROM v_opening_balance_summary ob
                          JOIN rim_accounts a ON a.id = ob.account_id AND a.account_nature IN ('Cash', 'Bank')
                          WHERE ob.client_id = p_client_id AND ob.company_id = p_company_id AND ob.fy_id = fy.id
                            AND (p_location_group_id IS NULL OR ob.location_group_id = p_location_group_id)), 0)
                +
                COALESCE((SELECT SUM(CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END)
                          FROM rid_finance_lines l
                          JOIN rih_finance_headers h
                              ON  h.client_id = l.client_id AND h.company_id = l.company_id
                              AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
                          JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature IN ('Cash', 'Bank')
                          WHERE l.client_id = p_client_id AND l.company_id = p_company_id
                            AND l.is_deleted = false AND h.is_deleted = false
                            AND (NOT p_posted_only OR h.is_posted = true)
                            AND h.trans_date >= fy.fy_start_date AND h.trans_date < p_date_from
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
                                                        AND ula.is_active = true AND ula.is_deleted = false))
                         ), 0)
            FROM fy) AS opening_cash,
            COALESCE((SELECT SUM(CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END)
                      FROM rid_finance_lines l
                      JOIN rih_finance_headers h
                          ON  h.client_id = l.client_id AND h.company_id = l.company_id
                          AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
                      JOIN rim_accounts a ON a.id = l.account_id AND a.account_nature IN ('Cash', 'Bank')
                      WHERE l.client_id = p_client_id AND l.company_id = p_company_id
                        AND l.is_deleted = false AND h.is_deleted = false
                        AND (NOT p_posted_only OR h.is_posted = true)
                        AND h.trans_date >= p_date_from AND h.trans_date <= p_date_to
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
                                                    AND ula.is_active = true AND ula.is_deleted = false))
                     ), 0) AS period_movement
    )
    SELECT
        tt.operating_total, tt.investing_total, tt.financing_total,
        tt.operating_total + tt.investing_total + tt.financing_total AS net_cash_flow,
        cr.opening_cash,
        cr.opening_cash + cr.period_movement AS closing_cash,
        cr.period_movement - (tt.operating_total + tt.investing_total + tt.financing_total) AS reconciliation_diff
    FROM tree_totals tt, cash_recon cr;
$$;

GRANT EXECUTE ON FUNCTION fn_cash_flow_totals_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Registry — per company: two genuinely new feature codes (no existing
-- FN-CF* placeholder, confirmed via grep — unlike FN-TRB/FN-PNL/FN-BSH,
-- which all pre-dated their real reports).
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

        -- ---------------- Cash Flow Summary ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             source_object_local, totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'CASH_FLOW_SUMMARY', 'Cash Flow Summary',
             'HIERARCHICAL', 'FUNCTION', 'fn_cash_flow_tree_summary_base', 'FN', 'sort_key', 'ASC', 2000,
             'fn_cash_flow_tree_summary_local', 'fn_cash_flow_totals_base', 'fn_cash_flow_totals_local')
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
            (v_company.client_id, v_company.company_id, v_report_id, 'node_name', 'Category', 'TEXT',   'LEFT',  false, true, 260, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'amount',    'Amount',   'NUMBER', 'RIGHT', false, true, 150, 2);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Period', 'DATE_RANGE',
                NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_only', 'Posted Only', 'BOOLEAN',
                NULL, NULL, 'posted_only', false, 'true', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_group_id', 'Location Group', 'DROPDOWN_LOOKUP',
                'v_location_groups_lookup', 'group_name', 'location_group_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-CFS', 'Cash Flow Summary',
             '/reports/CASH_FLOW_SUMMARY', 13, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

        -- ---------------- Cash Flow Account Detail (new) ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             source_object_local, totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'CASH_FLOW_DETAIL', 'Cash Flow Account Detail',
             'HIERARCHICAL', 'FUNCTION', 'fn_cash_flow_tree_detail_base', 'FN', 'sort_key', 'ASC', 5000,
             'fn_cash_flow_tree_detail_local', 'fn_cash_flow_totals_base', 'fn_cash_flow_totals_local')
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
            (v_company.client_id, v_company.company_id, v_report_id, 'node_name', 'Account / Category', 'TEXT',   'LEFT',  false, true, 300, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'amount',    'Amount',             'NUMBER', 'RIGHT', false, true, 150, 2);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'date_range', 'Period', 'DATE_RANGE',
                NULL, NULL, 'date', true, 'THIS_MONTH', 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'posted_only', 'Posted Only', 'BOOLEAN',
                NULL, NULL, 'posted_only', false, 'true', 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'location_group_id', 'Location Group', 'DROPDOWN_LOOKUP',
                'v_location_groups_lookup', 'group_name', 'location_group_id', false, NULL, 3);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-CFD', 'Cash Flow Account Detail',
             '/reports/CASH_FLOW_DETAIL', 14, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill — same pattern as every prior report
-- migration. Both feature codes are genuinely new, so both need this.
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
WHERE mm.feature_code IN ('FN-RPT-CFS', 'FN-RPT-CFD')
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
