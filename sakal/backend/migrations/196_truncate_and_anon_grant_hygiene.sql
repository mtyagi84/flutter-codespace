-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 196 — CRITICAL: `authenticated` (every real logged-in user, every
-- tenant) holds TRUNCATE on 201 tables; `anon` holds full DML+TRUNCATE on 86+
-- tables. Also: Inventory sidebar menu duplication (group_name drift).
-- ═══════════════════════════════════════════════════════════════════════════
-- Found 2026-09-20, prompted directly by the user asking "are we sure we've
-- found everything?" after migrations 194/195.
--
-- FINDING A (the more severe one): this Supabase project's own schema-wide
-- ALTER DEFAULT PRIVILEGES template grants `anon`, `authenticated`, and
-- `service_role` full `arwdDxtm` (ALL) on every table, at creation time,
-- unless a migration explicitly revokes it. Every migration in this schema
-- that follows the documented RLS convention does
-- `GRANT SELECT, INSERT, UPDATE ON <table> TO authenticated` after creating
-- a table's policy — but GRANT is additive, never subtractive. None of
-- them ever REVOKE the broader default grant sitting underneath first, so
-- that narrower-looking GRANT statement has never actually narrowed
-- anything: `authenticated` still holds DELETE and TRUNCATE via the
-- original default, on effectively every table in the schema (confirmed:
-- 201 tables, including ones "fixed" in migrations 194/195 yesterday and
-- today).
--
-- TRUNCATE is the critical one: **Postgres does not apply Row Level
-- Security to TRUNCATE at all** — it is a bulk, non-row-scoped operation.
-- This means, until this migration runs, ANY authenticated user of ANY
-- tenant — not a hypothetical unauthenticated attacker, a real logged-in
-- user of the app — holds the SQL-level privilege to `TRUNCATE rim_accounts`
-- (or almost any other table) and wipe EVERY tenant's rows in it, RLS
-- notwithstanding. DELETE is left alone here deliberately: unlike
-- TRUNCATE, DELETE IS filtered by each table's own RLS USING clause, so a
-- real DELETE already can't cross tenant boundaries — revoking it broadly
-- risks breaking some legitimate current delete flow without a full
-- per-table audit, which TRUNCATE (zero legitimate application use case,
-- anywhere) does not need.
--
-- FINDING B: `anon` (unauthenticated) additionally holds full
-- INSERT/SELECT/UPDATE/DELETE/TRUNCATE on 86+ tables — safe today only
-- because RLS on those tables has no policy naming anon (so anon gets zero
-- rows for SELECT/UPDATE/DELETE), but TRUNCATE's RLS-blindness applies
-- here too, and any grant this broad is bad hygiene regardless. The one
-- confirmed legitimate exception is `ric_website_enquiries`, which has its
-- own "Allow public insert" policy for a pre-auth website contact form —
-- re-granted explicitly below, nothing else.
--
-- Both are fixed schema-wide (every existing table) AND at the
-- ALTER DEFAULT PRIVILEGES level (every FUTURE table), so this class of
-- gap can't silently reopen the next time a migration creates a table and
-- simply follows the existing (still-safe) `GRANT SELECT, INSERT, UPDATE
-- TO authenticated` convention without an explicit TRUNCATE revoke.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Every EXISTING table: strip TRUNCATE from authenticated, strip
--    everything from anon except the one confirmed exception ─────────────
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
GRANT INSERT ON ric_website_enquiries TO anon;

-- ── Every FUTURE table created in public schema: same restrictions apply
--    from creation, so this class of gap can't reopen silently ──────────
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE TRUNCATE ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;


-- ═══════════════════════════════════════════════════════════════════════════
-- Fix C — Inventory sidebar showing "Operations" and "Transactions" as two
-- separate group headers, each with the full identical Stock/Material
-- feature list underneath.
-- ═══════════════════════════════════════════════════════════════════════════
-- Same root cause as the already-documented Sales sidebar duplicate
-- (group_serial_no/group_name drift across migrations for one group_code —
-- fn_get_user_menu.sql's grouping query does `SELECT DISTINCT group_code,
-- group_name, group_serial_no`, then joins every feature back onto EVERY
-- distinct group row by group_code alone, so two rows sharing a group_code
-- but differing in group_name both get the FULL feature list attached).
--
-- This time self-inflicted: migration 193 (Opening Stock Value Upload,
-- yesterday) added the new IN-OSV feature's one-off retrofit INSERT with
-- group_name='Operations', copied from migration 077's OLD retrofit
-- wording — instead of checking fn_seed_client_modules.sql's actual
-- CURRENT source-of-truth for the IN-OPS group_code, which has always been
-- group_name='Transactions' for every other IN-OPS feature (IN-STK, IN-TRF,
-- IN-ADJ, ... IN-CNR). fn_seed_client_modules.sql's own IN-OSV row was
-- already correctly written as 'Transactions' — only the migration's
-- direct INSERT (for companies that already existed before it ran, i.e.
-- Shanju) had the wrong value.
UPDATE ric_master_menus
SET group_name = 'Transactions'
WHERE feature_code = 'IN-OSV' AND group_name <> 'Transactions';
