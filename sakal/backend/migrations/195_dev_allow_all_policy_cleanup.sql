-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 195 — CRITICAL: 11 tables still running their original
-- "dev_allow_all_*" permissive policy — USING (true) WITH CHECK (true),
-- applying to EVERY role including anon. Zero tenant isolation, zero
-- access control.
-- ═══════════════════════════════════════════════════════════════════════════
-- Found live 2026-09-20 during a full audit prompted by migration 194's
-- RLS fix (rim_accounts and 4 siblings). That audit covered "RLS disabled
-- entirely" and came back clean beyond those 5 — but a second pass,
-- specifically checking for a policy naming anon/public rather than just
-- checking whether RLS was ON, found ELEVEN tables where RLS is enabled but
-- the single policy present is still the original dev-only placeholder
-- (`dev_allow_all_<table>`, `roles: {-}` meaning PUBLIC — every role,
-- authenticated or not): the exact anti-pattern CLAUDE.md's own RLS
-- convention section already warns about ("that permissive shape belongs
-- only in pgTAP test fixtures... mistakenly copied into a real migration
-- once already"), on tables that were apparently never migrated off it at
-- all:
--   rim_users                    -- the entire user table (auth/login records)
--   ric_master_menus             -- the permission SYSTEM's own menu registry
--   ric_user_menus               -- the permission SYSTEM's own per-user grants
--   ric_system_modules           -- module registry
--   rih_finance_headers          -- every GL voucher header, every module
--   rid_finance_lines            -- every GL Dr/Cr line, every module
--   rid_cheque_register
--   rid_invoice_bill_settlement
--   ril_trans_no_seq             -- document numbering sequence counters
--   rim_payment_modes
--   rim_voucher_types
--
-- Until this migration runs, ANY caller — including an unauthenticated one
-- holding only the public anon API key, since anon also holds full table
-- grants on all eleven (a separate, related finding — see the follow-up
-- migration for a broader anon-grant hygiene pass) — can read, insert,
-- update, or delete EVERY tenant's users, GL postings, and even grant
-- themselves arbitrary menu/feature permissions, since ric_user_menus
-- itself is one of the eleven. This is at least as severe as migration
-- 194's rim_accounts finding, arguably more so given rim_users and the
-- permission tables are in this list.
--
-- Fixed with the exact same auth_rw_<table> policy shape used everywhere
-- else in this schema (all eleven tables carry both client_id and
-- company_id). No DELETE/TRUNCATE grant to authenticated on any of them,
-- matching the existing convention.
-- ═══════════════════════════════════════════════════════════════════════════

-- Explicit per-table drop+create (never dynamic SQL) — keeps every policy's
-- exact name/shape visible and grep-able here, matching how every other
-- migration in this schema writes RLS policies. Each table's own original
-- dev_allow_all_* policy name is dropped by its ACTUAL name (confirmed via
-- pg_policy, not guessed/derived — they don't follow one consistent naming
-- formula, e.g. ric_system_modules's is "dev_allow_all_modules", not
-- "dev_allow_all_system_modules").

DROP POLICY IF EXISTS "dev_allow_all_users" ON rim_users;
DROP POLICY IF EXISTS "auth_rw_rim_users" ON rim_users;
CREATE POLICY "auth_rw_rim_users" ON rim_users
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rim_users FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_users TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_master_menus" ON ric_master_menus;
DROP POLICY IF EXISTS "auth_rw_ric_master_menus" ON ric_master_menus;
CREATE POLICY "auth_rw_ric_master_menus" ON ric_master_menus
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON ric_master_menus FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_master_menus TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_user_menus" ON ric_user_menus;
DROP POLICY IF EXISTS "auth_rw_ric_user_menus" ON ric_user_menus;
CREATE POLICY "auth_rw_ric_user_menus" ON ric_user_menus
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON ric_user_menus FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_user_menus TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_modules" ON ric_system_modules;
DROP POLICY IF EXISTS "auth_rw_ric_system_modules" ON ric_system_modules;
CREATE POLICY "auth_rw_ric_system_modules" ON ric_system_modules
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON ric_system_modules FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_system_modules TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_finance_headers" ON rih_finance_headers;
DROP POLICY IF EXISTS "auth_rw_rih_finance_headers" ON rih_finance_headers;
CREATE POLICY "auth_rw_rih_finance_headers" ON rih_finance_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rih_finance_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_finance_headers TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_finance_lines" ON rid_finance_lines;
DROP POLICY IF EXISTS "auth_rw_rid_finance_lines" ON rid_finance_lines;
CREATE POLICY "auth_rw_rid_finance_lines" ON rid_finance_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rid_finance_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_finance_lines TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_cheque_register" ON rid_cheque_register;
DROP POLICY IF EXISTS "auth_rw_rid_cheque_register" ON rid_cheque_register;
CREATE POLICY "auth_rw_rid_cheque_register" ON rid_cheque_register
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rid_cheque_register FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_cheque_register TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_invoice_settlement" ON rid_invoice_bill_settlement;
DROP POLICY IF EXISTS "auth_rw_rid_invoice_bill_settlement" ON rid_invoice_bill_settlement;
CREATE POLICY "auth_rw_rid_invoice_bill_settlement" ON rid_invoice_bill_settlement
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rid_invoice_bill_settlement FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_invoice_bill_settlement TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_trans_no_seq" ON ril_trans_no_seq;
DROP POLICY IF EXISTS "auth_rw_ril_trans_no_seq" ON ril_trans_no_seq;
CREATE POLICY "auth_rw_ril_trans_no_seq" ON ril_trans_no_seq
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON ril_trans_no_seq FROM anon;
GRANT SELECT, INSERT, UPDATE ON ril_trans_no_seq TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_payment_modes" ON rim_payment_modes;
DROP POLICY IF EXISTS "auth_rw_rim_payment_modes" ON rim_payment_modes;
CREATE POLICY "auth_rw_rim_payment_modes" ON rim_payment_modes
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rim_payment_modes FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_payment_modes TO authenticated;

DROP POLICY IF EXISTS "dev_allow_all_voucher_types" ON rim_voucher_types;
DROP POLICY IF EXISTS "auth_rw_rim_voucher_types" ON rim_voucher_types;
CREATE POLICY "auth_rw_rim_voucher_types" ON rim_voucher_types
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rim_voucher_types FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_voucher_types TO authenticated;
