-- ============================================================
-- Migration 188: CRITICAL -- the three ROOT tenancy tables
-- (ric_clients, ric_companies, ric_locations) were still on the
-- original "dev_allow_all" permissive RLS policy from day one
-- ============================================================
-- Found 2026-09-14, during Phase B prep for the Production-Readiness
-- Testing Roadmap (multi-tenant isolation proof). A full grep of every
-- migration for GRANT/REVOKE/POLICY statements touching ric_clients,
-- ric_companies, or ric_locations found NOTHING after 001_tenancy.sql --
-- these three tables have been sitting on
--   CREATE POLICY "dev_allow_all_*" ON <table> FOR ALL USING (true) WITH CHECK (true);
-- since the very first migration, whose own comment already flagged it:
-- "For development: allow all for anon role. Tighten before production
-- deployment." That tightening never happened for these three tables,
-- even though every OTHER table in the schema since has followed the
-- `auth_rw_<table>` convention (CLAUDE.md).
--
-- Confirmed live against the real database: logging in as the QA
-- Automation tenant and querying these three tables with NO filter
-- returned ALL 4 existing tenants' full rows (client_name, company_name,
-- location_name) -- including a tenant named "Rigvedam Innovations" and
-- two others ("Test Zambia Trading", "Test India Trading"). Same class of
-- bug as migration 185's view-security-invoker fix, except here it's the
-- root client/company/location records themselves, not a report view.
--
-- Scoping rules, since these three tables sit ABOVE client_id/company_id
-- rather than carrying them as ordinary foreign keys:
--   - ric_clients has no client_id/company_id column at all -- it IS the
--     client. Its own `id` must equal the JWT's client_id claim.
--   - ric_companies has client_id but no company_id -- it IS the company.
--     Scoped on client_id match AND its own `id` = JWT's company_id claim
--     (a client may have multiple companies, but the JWT is only ever
--     issued for one; confirmed via a full grep that no screen anywhere
--     in the app queries ric_companies for any id other than the
--     session's own company_id -- there is no company-switching UI to
--     preserve).
--   - ric_locations already carries both client_id and company_id --
--     standard auth_rw_<table> pattern applies directly (a user may
--     legitimately see every location under their own company, not just
--     their own default one, e.g. to pick a location on a document).
-- ============================================================

-- ── ric_clients ──────────────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_clients" ON ric_clients;
DROP POLICY IF EXISTS "auth_rw_ric_clients" ON ric_clients;

CREATE POLICY "auth_rw_ric_clients" ON ric_clients
    FOR ALL TO authenticated
    USING     (id = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid)
    WITH CHECK(id = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid);

REVOKE ALL ON ric_clients FROM anon;
GRANT SELECT, UPDATE ON ric_clients TO authenticated;

-- ── ric_companies ────────────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_companies" ON ric_companies;
DROP POLICY IF EXISTS "auth_rw_ric_companies" ON ric_companies;

CREATE POLICY "auth_rw_ric_companies" ON ric_companies
    FOR ALL TO authenticated
    USING     (client_id = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND id        = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND id        = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_companies FROM anon;
GRANT SELECT, UPDATE ON ric_companies TO authenticated;

-- ── ric_locations ────────────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_locations" ON ric_locations;
DROP POLICY IF EXISTS "auth_rw_ric_locations" ON ric_locations;

CREATE POLICY "auth_rw_ric_locations" ON ric_locations
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_locations FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_locations TO authenticated;

-- ============================================================
-- NOTE: fn_register_client, fn_login, and every other SECURITY DEFINER
-- function that touches these three tables during registration/login
-- (before a JWT with client_id/company_id claims even exists) is
-- unaffected by this migration -- SECURITY DEFINER functions run with
-- the DEFINING role's privileges and bypass RLS/GRANT restrictions on
-- the calling role entirely. Confirmed by reading fn_register_client's
-- own body: it INSERTs into all three tables directly with no RLS-aware
-- guard, which only works because it is `security definer`.
-- ============================================================
