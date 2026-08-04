-- ============================================================
-- Migration 124: Drop a stray 2-arg overload of fn_seed_client_modules
-- that only ever existed live in Supabase (never in a committed
-- migration/function file), then re-run the group-column resync (093)
-- now that it can actually complete.
-- ============================================================
-- fn_seed_client_modules has always been a 3-param function in this
-- repo (backend/functions/fn_seed_client_modules.sql:
-- p_client_id uuid, p_company_id uuid, p_admin_user_id uuid DEFAULT NULL),
-- so `CREATE OR REPLACE FUNCTION` has always been safe to re-run — but
-- at some point a 2-arg version (p_client_id, p_company_id, no third
-- param at all) was created directly in the Supabase SQL editor, outside
-- of any migration or the committed function file — same class of "live
-- DB carries a manual patch no file on disk reflects" gotcha already
-- documented in migration 109's own postmortem (the FN-PRV feature_code
-- row). Since Postgres matches overloads by parameter TYPE LIST, calling
-- fn_seed_client_modules(uuid, uuid) became ambiguous the moment both a
-- 2-arg AND a 3-arg-with-default version existed at once — exactly the
-- trap CLAUDE.md's own migration-idempotency section warns about for
-- appended parameters.
--
-- Caught live: migration 093's resync loop (`PERFORM fn_seed_client_modules(
-- v_company.client_id, v_company.company_id)`) started failing with
-- `42725: function fn_seed_client_modules(uuid, uuid) is not unique`
-- once this stray overload existed — which is also why the SL-TXN
-- group_serial_no drift (093 was written to fix, the Sales sidebar
-- showing "Transactions" twice) was still reproducing months later: the
-- fix migration could no longer run to completion.
--
-- IMPORTANT ORDER: re-run backend/functions/fn_seed_client_modules.sql's
-- CREATE OR REPLACE FUNCTION in the Supabase SQL editor BEFORE this
-- migration, same requirement 093 already documented.
-- ============================================================

DROP FUNCTION IF EXISTS fn_seed_client_modules(uuid, uuid);

DO $$
DECLARE
    v_company RECORD;
BEGIN
    FOR v_company IN SELECT client_id, id AS company_id FROM ric_companies LOOP
        PERFORM fn_seed_client_modules(v_company.client_id, v_company.company_id);
    END LOOP;
END $$;
