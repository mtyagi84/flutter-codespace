-- ============================================================
-- Migration 143: Profit & Loss reports — first true HIERARCHICAL report
-- ============================================================
-- Two reports, one shared engine: P&L Group Summary (groups + subtotals
-- only) and P&L Account Detail (full account-level breakdown under its
-- real group hierarchy). report_type='HIERARCHICAL' exists in the
-- Reporting Engine's schema since migration 116 (ric_report_columns even
-- reserves parent_key_column/level_column for it) but has NEVER been
-- rendered — grep confirmed ReportDefinition.isHierarchical is checked
-- nowhere in sakal_report_screen.dart. This migration is the backend
-- half of that first real build; the Flutter half (a new
-- SakalReportHierarchicalTable widget + ReportDataController wiring)
-- ships alongside it in the same commit.
--
-- User explicitly ruled out a fixed-depth approximation (the same
-- ric_report_group_levels mechanism Ageing/Pending Bills use) — the
-- Chart of Accounts hierarchy genuinely varies in depth per account
-- (confirmed by reading both COA seeds in 013_chart_of_accounts.sql:
-- some accounts sit directly under the root, others are 2-3 levels
-- deep), so this returns a real arbitrary-depth tree.
--
-- Root account resolution — same pattern as 141's v_expense_accounts:
--   INDIAN Income root code '4000' ('Revenue'), OHADA '7000' ('Class 7 - Revenue')
--   INDIAN Expense root code '5000' ('Expense'), OHADA '6000' ('Class 6 - Expenses')
-- accounting_std lives on every rim_accounts row including the roots, so
-- no join to rim_accounting_setup is needed.
--
-- Fetch shape: whole-tree-at-once (like MATRIX's own single full fetch),
-- not per-node lazy expansion like the grouped-TABULAR mechanism — a
-- P&L's account tree is small (hundreds of nodes at most), so the
-- Flutter side loads it once and does all expand/collapse client-side,
-- instant, no per-node round trip.
-- ============================================================

-- ------------------------------------------------------------
-- fn_pl_tree_base / _local — the core engine. Returns EVERY node (group
-- AND leaf) under both the Income and Expense roots that has non-zero
-- net activity in the period, each carrying its own real parent_id link
-- so the frontend can build a genuine arbitrary-depth tree.
--
-- Technique: subtree walks DOWN from both roots (arbitrary depth,
-- carrying section + level_depth). ancestry then walks UP from every
-- POSTING-ALLOWED leaf back through subtree, collecting every ancestor
-- id along the way (including itself) — the same upward-walk technique
-- v_expense_accounts already uses, generalized to keep every
-- intermediate ancestor, not just the root. leaf_amounts nets each
-- leaf's own financial activity for the period. node_totals then fans
-- each leaf's amount out to every one of its ancestors via ancestry and
-- sums per ancestor — this is what gives a GROUP node its own correct
-- rolled-up subtotal (its own postings, if it's directly postable, plus
-- every descendant's) in ONE pass, not N+1 per-node queries.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pl_tree_base(
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
          AND account_code IN ('4000', '7000')
        UNION ALL
        SELECT id, 'EXPENSE'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND account_code IN ('5000', '6000')
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

GRANT EXECUTE ON FUNCTION fn_pl_tree_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pl_tree_local(
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
        SELECT id AS root_id, 'INCOME' AS section
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND account_code IN ('4000', '7000')
        UNION ALL
        SELECT id, 'EXPENSE'
        FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND is_deleted = false
          AND account_code IN ('5000', '6000')
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

GRANT EXECUTE ON FUNCTION fn_pl_tree_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN, BOOLEAN) TO authenticated;


-- ------------------------------------------------------------
-- Thin wrappers — what ric_report_definitions.source_object actually
-- names for each of the two reports.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pl_tree_summary_base(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pl_tree_base(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, false);
$$;

GRANT EXECUTE ON FUNCTION fn_pl_tree_summary_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pl_tree_summary_local(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pl_tree_local(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, false);
$$;

GRANT EXECUTE ON FUNCTION fn_pl_tree_summary_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pl_tree_detail_base(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pl_tree_base(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_pl_tree_detail_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pl_tree_detail_local(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (node_id UUID, parent_id UUID, section TEXT, node_name TEXT, level_depth INTEGER, is_leaf BOOLEAN, amount NUMERIC, sort_key TEXT)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_pl_tree_local(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_pl_tree_detail_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;


-- ------------------------------------------------------------
-- fn_pl_totals_base / _local — Income total / Expense total / Net
-- Profit footer. Reuses fn_pl_tree_base/_local directly (summing each
-- section's own level_depth=1 group totals, which already include their
-- whole subtree) rather than re-deriving the rollup a third time — this
-- guarantees the footer can never disagree with the tree's own numbers.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pl_totals_base(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (income_total NUMERIC, expense_total NUMERIC, net_profit NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(amount) FILTER (WHERE section = 'INCOME'  AND level_depth = 1), 0) AS income_total,
        COALESCE(SUM(amount) FILTER (WHERE section = 'EXPENSE' AND level_depth = 1), 0) AS expense_total,
        COALESCE(SUM(amount) FILTER (WHERE section = 'INCOME'  AND level_depth = 1), 0)
          - COALESCE(SUM(amount) FILTER (WHERE section = 'EXPENSE' AND level_depth = 1), 0) AS net_profit
    FROM fn_pl_tree_base(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_pl_totals_base(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_pl_totals_local(
    p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
    p_location_group_id UUID DEFAULT NULL, p_posted_only BOOLEAN DEFAULT true
) RETURNS TABLE (income_total NUMERIC, expense_total NUMERIC, net_profit NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT
        COALESCE(SUM(amount) FILTER (WHERE section = 'INCOME'  AND level_depth = 1), 0) AS income_total,
        COALESCE(SUM(amount) FILTER (WHERE section = 'EXPENSE' AND level_depth = 1), 0) AS expense_total,
        COALESCE(SUM(amount) FILTER (WHERE section = 'INCOME'  AND level_depth = 1), 0)
          - COALESCE(SUM(amount) FILTER (WHERE section = 'EXPENSE' AND level_depth = 1), 0) AS net_profit
    FROM fn_pl_tree_local(p_client_id, p_company_id, p_date_from, p_date_to, p_location_group_id, p_posted_only, true);
$$;

GRANT EXECUTE ON FUNCTION fn_pl_totals_local(UUID, UUID, DATE, DATE, UUID, BOOLEAN) TO authenticated;


-- ============================================================
-- Registry — per company: repoint the existing FN-PNL placeholder for
-- Summary, add a genuinely new feature code for Detail.
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

        -- ---------------- P&L Group Summary ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             source_object_local, totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'PROFIT_LOSS_SUMMARY', 'Profit & Loss Summary',
             'HIERARCHICAL', 'FUNCTION', 'fn_pl_tree_summary_base', 'FN', 'sort_key', 'ASC', 2000,
             'fn_pl_tree_summary_local', 'fn_pl_totals_base', 'fn_pl_totals_local')
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
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-PNL', 'Profit & Loss',
             '/reports/PROFIT_LOSS_SUMMARY', 1, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

        -- ---------------- P&L Account Detail (new) ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             source_object_local, totals_source_object, totals_source_object_local)
        VALUES
            (v_company.client_id, v_company.company_id, 'PROFIT_LOSS_DETAIL', 'Profit & Loss Account Detail',
             'HIERARCHICAL', 'FUNCTION', 'fn_pl_tree_detail_base', 'FN', 'sort_key', 'ASC', 5000,
             'fn_pl_tree_detail_local', 'fn_pl_totals_base', 'fn_pl_totals_local')
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
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-PNL', 'Profit & Loss Account Detail',
             '/reports/PROFIT_LOSS_DETAIL', 11, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill — same pattern as every prior report
-- migration. FN-PNL already has whatever grants it had before (this
-- migration only repoints its screen_name); FN-RPT-PNL is genuinely new
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
WHERE mm.feature_code = 'FN-RPT-PNL'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
