-- ============================================================
-- Migration 185: CRITICAL -- every reporting-engine VIEW was silently
-- bypassing Row Level Security for every tenant
-- ============================================================
-- Found live 2026-09-13 (user report: Purchase Order Register showed
-- another tenant's own orders — "Cash Purchase Supplier" rows belonging
-- to a different, real production tenant, visible from the QA Automation
-- Co tenant).
--
-- Root cause, confirmed directly against this database:
--   - PostgreSQL views execute Row Level Security using the VIEW OWNER'S
--     security context by default, NOT the querying user's -- this is
--     documented Postgres behavior, not a bug in Postgres itself. A view
--     only uses the INVOKING user's RLS context if explicitly created
--     `WITH (security_invoker = true)` (Postgres 15+).
--   - Every view in this schema was created via a direct superuser
--     connection during development (this session's own `run_sql.js`
--     tool, and presumably the Supabase SQL Editor before it) -- so
--     every one of them is owned by the `postgres` role.
--   - `postgres` has `rolbypassrls = true` (confirmed via
--     `pg_roles.rolbypassrls`).
--   - None of the 73 application views had `security_invoker` set
--     (confirmed via `pg_class.reloptions` -- every single one defaulted
--     to `false`).
--   - Net effect: querying ANY of these 73 views via PostgREST -- i.e.
--     every VIEW-backed report screen in Sales, Purchase, Inventory,
--     Finance, and Master Data -- silently ran with the `postgres`
--     role's RLS-bypassing context regardless of the actual JWT's
--     client_id/company_id, returning EVERY tenant's rows to whichever
--     tenant happened to query the report. The `client_id`/`company_id`
--     WHERE clauses/filters written into several of these views (visible
--     when reading their own SQL) were never the actual security
--     boundary -- RLS on the underlying base tables was supposed to be
--     that boundary, and it was being silently skipped entirely for
--     every view-based report the whole time.
--
-- Functions (source_type='FUNCTION' reports, e.g. Account Ledger,
-- Trial Balance) are NOT affected by this specific mechanism -- a
-- function's security context depends on SECURITY DEFINER/INVOKER on the
-- FUNCTION itself, a separate, already-correct concern for those.
--
-- Fix: `ALTER VIEW ... SET (security_invoker = true)` on every one of
-- them -- a metadata-only change, no view needs to be recreated, and it
-- takes effect immediately. This is now a MANDATORY requirement for
-- every future `CREATE VIEW`/`CREATE OR REPLACE VIEW` in this schema --
-- see the updated CLAUDE.md convention.
-- ============================================================

DO $$
DECLARE
    v_view RECORD;
BEGIN
    FOR v_view IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'v' AND n.nspname = 'public' AND c.relname LIKE 'v\_%'
    LOOP
        EXECUTE format('ALTER VIEW %I SET (security_invoker = true)', v_view.relname);
    END LOOP;
END $$;

-- Verification the migration itself can run standalone: confirm zero
-- application views remain without security_invoker after this runs.
DO $$
DECLARE
    v_remaining INTEGER;
BEGIN
    SELECT count(*) INTO v_remaining
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'v' AND n.nspname = 'public' AND c.relname LIKE 'v\_%'
      AND COALESCE(
            (SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'security_invoker'),
            'false'
          ) <> 'true';
    IF v_remaining > 0 THEN
        RAISE EXCEPTION 'SECURITY_INVOKER_FIX_INCOMPLETE'
            USING DETAIL = format('%s view(s) still missing security_invoker = true after this migration ran.', v_remaining);
    END IF;
    RAISE NOTICE 'All application views now have security_invoker = true.';
END $$;
