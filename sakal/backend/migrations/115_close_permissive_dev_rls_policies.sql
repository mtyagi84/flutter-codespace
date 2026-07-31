-- ============================================================
-- 115_close_permissive_dev_rls_policies.sql
--
-- Closes a real, live security gap found during a 2026-08-01 QA-checklist
-- audit (see CLAUDE.md's "OPEN: Exchange Rates RLS Gap" note, which
-- flagged only rim_exchange_rates -- the actual scope, confirmed by
-- grepping every migration for `USING (true)`/`WITH CHECK (true)`, is
-- five tables, not one):
--   rim_currencies, rim_countries, rim_exchange_rates,
--   ric_location_groups, ric_user_location_access
--
-- Each of these still carries its ORIGINAL "dev_allow_all_*" policy from
-- when the table was first created (FOR ALL USING (true) WITH CHECK
-- (true), no TO clause -> applies to PUBLIC, i.e. including the
-- unauthenticated `anon` role) -- meaning any client holding only the
-- public anon API key can currently SELECT/INSERT/UPDATE/DELETE every
-- row of these tables across EVERY tenant, no client_id/company_id
-- isolation at all. None of these five were ever revisited the way
-- rim_common_masters was in migration 023 (which explicitly DROPs its
-- own interim policies and replaces them with a real JWT-scoped one --
-- see that migration's own "Fix rim_common_masters" section for the
-- template this migration follows).
--
-- rim_tax_types' own "read_tax_types" policy (migration 025) is a
-- different, lesser case -- SELECT-only, and deliberately re-created
-- with the identical `TO authenticated, anon` shape in that same
-- migration (not a forgotten leftover) -- but granting anon read access
-- to ANY table by default is inconsistent with every other reference
-- table in this schema (rim_common_master_types, migration 023, is
-- `TO authenticated` only) and has no known legitimate use case (no
-- pre-login screen reads tax types). Tightened here too for consistency,
-- same fix shape, SELECT-only.
--
-- All five tables already have both client_id and company_id columns
-- (confirmed directly from their own CREATE TABLE statements), so the
-- standard auth_rw_<table> convention (see CLAUDE.md's "RLS policy
-- convention" section) applies cleanly to all of them.
-- ============================================================

-- ── rim_currencies ──────────────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_currencies" ON rim_currencies;
DROP POLICY IF EXISTS "auth_rw_rim_currencies"    ON rim_currencies;
CREATE POLICY "auth_rw_rim_currencies" ON rim_currencies
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_currencies FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_currencies TO authenticated;


-- ── rim_countries ────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_countries" ON rim_countries;
DROP POLICY IF EXISTS "auth_rw_rim_countries"    ON rim_countries;
CREATE POLICY "auth_rw_rim_countries" ON rim_countries
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_countries FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_countries TO authenticated;


-- ── rim_exchange_rates ───────────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_exchange_rates" ON rim_exchange_rates;
DROP POLICY IF EXISTS "auth_rw_rim_exchange_rates"    ON rim_exchange_rates;
CREATE POLICY "auth_rw_rim_exchange_rates" ON rim_exchange_rates
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_exchange_rates FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_exchange_rates TO authenticated;


-- ── ric_location_groups ──────────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_location_groups" ON ric_location_groups;
DROP POLICY IF EXISTS "auth_rw_ric_location_groups"    ON ric_location_groups;
CREATE POLICY "auth_rw_ric_location_groups" ON ric_location_groups
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_location_groups FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_location_groups TO authenticated;


-- ── ric_user_location_access ─────────────────────────────────────────────
DROP POLICY IF EXISTS "dev_allow_all_user_location_access" ON ric_user_location_access;
DROP POLICY IF EXISTS "auth_rw_ric_user_location_access"    ON ric_user_location_access;
CREATE POLICY "auth_rw_ric_user_location_access" ON ric_user_location_access
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_user_location_access FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_user_location_access TO authenticated;


-- ── rim_tax_types: tighten SELECT to authenticated-only ──────────────────
-- Was `TO authenticated, anon` since migration 025 -- inconsistent with
-- every other reference-table policy in this schema (see
-- rim_common_master_types, migration 023), no legitimate pre-login
-- consumer. SELECT-only table, no INSERT/UPDATE/DELETE policy existed
-- before and none is added here.
DROP POLICY IF EXISTS "read_tax_types" ON rim_tax_types;
CREATE POLICY "read_tax_types" ON rim_tax_types
    FOR SELECT TO authenticated USING (true);

REVOKE ALL ON rim_tax_types FROM anon;
GRANT SELECT ON rim_tax_types TO authenticated;
