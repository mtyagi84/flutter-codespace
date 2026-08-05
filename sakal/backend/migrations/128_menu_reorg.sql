-- ============================================================
-- Migration 128: Menu reorganization — Masters consolidated under
-- Settings, Transactions/Reports kept in their own module.
-- ============================================================
-- Companion to the fn_seed_client_modules.sql rewrite (same session) —
-- that file must be re-run (CREATE OR REPLACE FUNCTION) in the Supabase
-- SQL editor BEFORE this migration, same requirement every prior
-- function-change migration in this project has documented.
--
-- Mechanism: a clean wipe + reseed, NOT a careful re-home. Safe only
-- because the app is still pre-production — one client, one company,
-- one user, nothing to preserve. A live export of ric_master_menus
-- (Current_master.csv, read this session) showed ~15 duplicate/stray
-- rows had accumulated from iterative menu rebuilding (same screen
-- reachable under 2+ different feature_codes) plus one real routing
-- bug (PR-PO pointing at a route that no longer exists) — none of that
-- is worth trying to carry forward; fn_seed_client_modules.sql alone is
-- now the single source of truth, reseeded fresh.
--
-- fn_seed_client_modules already re-grants the admin user's full access
-- via its own internal fn_grant_admin_access call when a user id is
-- passed — reseeding master menus and regranting user menus happens in
-- the same step, nothing to hand-preserve.
-- ============================================================

DO $$
DECLARE
    v_company RECORD;
    v_admin_user_id UUID;
BEGIN
    DELETE FROM ric_user_menus;
    DELETE FROM ric_master_menus;

    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP
        SELECT id INTO v_admin_user_id FROM rim_users
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id
            ORDER BY created_at ASC
            LIMIT 1;

        PERFORM fn_seed_client_modules(v_company.client_id, v_company.company_id, v_admin_user_id);
    END LOOP;
END $$;
