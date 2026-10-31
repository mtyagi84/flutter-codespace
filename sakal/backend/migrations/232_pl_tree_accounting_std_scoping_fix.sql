-- Fix: fn_pl_tree_base / fn_pl_tree_local (migration 143) never scoped
-- their INCOME/EXPENSE root resolution by accounting_std, despite the
-- migration's own header comment explicitly documenting that INDIAN uses
-- root codes '4000'(Revenue)/'5000'(Expense) while OHADA uses
-- '7000'(Revenue)/'6000'(Expenses) -- two DIFFERENT numbering schemes
-- where the SAME codes mean different things. The actual SQL wrote
-- `account_code IN ('4000','7000')` for INCOME and `IN ('5000','6000')`
-- for EXPENSE with NO accounting_std filter at all, so on an OHADA
-- company BOTH '4000' (Class 4 "Third Parties" -- Customers/Suppliers/
-- Tax, a Balance Sheet class) and '7000' (the real Revenue root) got
-- swept into INCOME, and BOTH '5000' (Class 5 "Treasury" -- Cash/Bank,
-- also Balance Sheet) and '6000' (the real Expenses root) got swept into
-- EXPENSE. Confirmed live on fresh tenant SK-98262 (OHADA): P&L Summary
-- showed "Customers"/"State & Taxes"/"Suppliers" under INCOME and
-- "Banks" under EXPENSE, corrupting Net Profit for every OHADA tenant
-- with any real third-party/treasury balance -- which is essentially
-- every tenant from day one. ZAMBIA shares INDIAN's numbering (4000=
-- Revenue, 5000=Expense, confirmed via migration 180_zambia_coa_
-- standard.sql), so it was never affected and needs no separate branch,
-- matching Balance Sheet's own precedent (144_balance_sheet_hierarchical.sql),
-- which already correctly scopes each root by accounting_std ('INDIAN'
-- explicit, 'OHADA' explicit, no bare `account_code IN (...)` with no
-- accounting_std filter anywhere in that file).
--
-- Fix: add explicit accounting_std scoping to both functions' `roots`
-- CTE, exactly mirroring Balance Sheet's established pattern. Full
-- current bodies reproduced verbatim from migration 143 otherwise.

CREATE OR REPLACE FUNCTION fn_pl_tree_base(
    p_client_id uuid, p_company_id uuid, p_date_from date, p_date_to date,
    p_location_group_id uuid DEFAULT NULL, p_posted_only boolean DEFAULT true,
    p_leaves_included boolean DEFAULT true
) RETURNS TABLE (
    node_id      UUID,
    parent_id    UUID,
    section      TEXT,     -- 'INCOME' | 'EXPENSE'
    node_name    TEXT,
    level_depth  INTEGER,
    is_leaf      BOOLEAN,
    amount       NUMERIC,
    sort_key     TEXT
) LANGUAGE sql STABLE AS $$
    WITH RECURSIVE roots AS (
        SELECT id AS root_id, 'INCOME' AS section
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code = '4000'
        UNION ALL
        SELECT id AS root_id, 'INCOME' AS section
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '7000'
        UNION ALL
        SELECT id, 'EXPENSE'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code = '5000'
        UNION ALL
        SELECT id, 'EXPENSE'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '6000'
    ),
    subtree AS (
        SELECT a.id, a.parent_id, a.account_code, a.account_name, a.posting_allowed,
               1 AS level_depth, r.section
        FROM rim_accounts a
        JOIN roots r ON a.parent_id = r.root_id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id AND a.is_deleted = false
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
    leaf_amounts AS (
        SELECT
            l.account_id,
            SUM(CASE
                WHEN st.section = 'INCOME'  THEN (CASE WHEN l.trans_nature = 'CR' THEN l.base_amount ELSE -l.base_amount END)
                ELSE                             (CASE WHEN l.trans_nature = 'DR' THEN l.base_amount ELSE -l.base_amount END)
            END) AS signed_amount
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
            AND h.trans_date  = l.trans_date
        JOIN subtree st ON st.id = l.account_id AND st.posting_allowed = true
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
        GROUP BY l.account_id
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

CREATE OR REPLACE FUNCTION fn_pl_tree_local(
    p_client_id uuid, p_company_id uuid, p_date_from date, p_date_to date,
    p_location_group_id uuid DEFAULT NULL, p_posted_only boolean DEFAULT true,
    p_leaves_included boolean DEFAULT true
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
        SELECT id AS root_id, 'INCOME' AS section
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code = '4000'
        UNION ALL
        SELECT id AS root_id, 'INCOME' AS section
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '7000'
        UNION ALL
        SELECT id, 'EXPENSE'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'INDIAN' AND account_code = '5000'
        UNION ALL
        SELECT id, 'EXPENSE'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND accounting_std = 'OHADA' AND account_code = '6000'
    ),
    subtree AS (
        SELECT a.id, a.parent_id, a.account_code, a.account_name, a.posting_allowed,
               1 AS level_depth, r.section
        FROM rim_accounts a
        JOIN roots r ON a.parent_id = r.root_id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id AND a.is_deleted = false
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
    leaf_amounts AS (
        SELECT
            l.account_id,
            SUM(CASE
                WHEN st.section = 'INCOME'  THEN (CASE WHEN l.trans_nature = 'CR' THEN l.local_amount ELSE -l.local_amount END)
                ELSE                             (CASE WHEN l.trans_nature = 'DR' THEN l.local_amount ELSE -l.local_amount END)
            END) AS signed_amount
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
            AND h.trans_date  = l.trans_date
        JOIN subtree st ON st.id = l.account_id AND st.posting_allowed = true
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
        GROUP BY l.account_id
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
