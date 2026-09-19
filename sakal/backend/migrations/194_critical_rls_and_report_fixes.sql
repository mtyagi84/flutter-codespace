-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 194 — CRITICAL: RLS was never enabled on 5 tenant-scoped tables
-- ═══════════════════════════════════════════════════════════════════════════
-- Found live 2026-09-19 while investigating why the Chart of Accounts Report
-- and Chart of Groups Report showed OTHER companies' accounts (Test India
-- Co, QA Isolation Test Co, etc.) mixed into Shanju's own report. Root
-- cause traced to rim_accounts having Row Level Security COMPLETELY
-- DISABLED — and never enabled in ANY migration since its creation in
-- migration 013. v_chart_of_accounts_tree already has security_invoker=true
-- (correctly set), which is exactly why this was invisible until now: that
-- setting delegates enforcement to the underlying table's own RLS, and
-- rim_accounts simply had none to delegate to.
--
-- A full audit of every table carrying BOTH client_id and company_id columns
-- (118 tables) found FOUR MORE tables in the identical state — RLS disabled,
-- AND the anon (unauthenticated) role holding full INSERT/SELECT/UPDATE/
-- DELETE/TRUNCATE grants on all five:
--   rim_accounts            -- Chart of Accounts (every GL feature reads/writes this)
--   rim_accounting_setup    -- per-company accounting standard + FY config
--   rim_financial_years     -- financial year records
--   rim_cities               -- always tenant-scoped in practice (0 null-client rows)
--   rim_divisions             -- MOSTLY global reference data (396/398 rows have
--                                NULL client_id, is_system=true) with a small
--                                number of real tenant-specific custom rows —
--                                needs the same is_system-aware policy shape
--                                already documented for this table's own query
--                                pattern (see CLAUDE.md's Divisions Query Pattern)
--
-- This means, until this migration runs, ANY authenticated user of ANY
-- tenant — and via the anon grants, potentially even an unauthenticated
-- caller holding only the anon API key — could read, insert, update, delete,
-- or truncate EVERY tenant's Chart of Accounts, accounting setup, and
-- financial year records. This is fixed here with the exact same
-- auth_rw_<table> policy shape used by every other table in this schema
-- (rim_cities, rim_accounting_setup, rim_financial_years, rim_accounts), and
-- a small is_system-aware variant for rim_divisions.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── rim_accounts ─────────────────────────────────────────────────────────
ALTER TABLE rim_accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_rim_accounts" ON rim_accounts;
CREATE POLICY "auth_rw_rim_accounts" ON rim_accounts
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rim_accounts FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_accounts TO authenticated;

-- ── rim_accounting_setup ─────────────────────────────────────────────────
ALTER TABLE rim_accounting_setup ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_rim_accounting_setup" ON rim_accounting_setup;
CREATE POLICY "auth_rw_rim_accounting_setup" ON rim_accounting_setup
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rim_accounting_setup FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_accounting_setup TO authenticated;

-- ── rim_financial_years ──────────────────────────────────────────────────
ALTER TABLE rim_financial_years ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_rim_financial_years" ON rim_financial_years;
CREATE POLICY "auth_rw_rim_financial_years" ON rim_financial_years
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rim_financial_years FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_financial_years TO authenticated;

-- ── rim_cities ────────────────────────────────────────────────────────────
ALTER TABLE rim_cities ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_rim_cities" ON rim_cities;
CREATE POLICY "auth_rw_rim_cities" ON rim_cities
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
REVOKE ALL ON rim_cities FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_cities TO authenticated;

-- ── rim_divisions — is_system-aware (global seeded rows + per-tenant custom) ──
-- Matches this project's own documented query pattern (CLAUDE.md's
-- "Divisions Query Pattern": rim_divisions global; is_system=true OR
-- (client+company)). Any authenticated user may READ a global is_system
-- row; only a tenant's own custom (non-system) rows can be
-- inserted/updated, and never as is_system=true.
ALTER TABLE rim_divisions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_rim_divisions" ON rim_divisions;
CREATE POLICY "auth_rw_rim_divisions" ON rim_divisions
    FOR ALL TO authenticated
    USING (
        is_system = true
        OR (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    )
    WITH CHECK (
        is_system = false
        AND client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
    );
REVOKE ALL ON rim_divisions FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_divisions TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- Fix 2 — v_product_master_report missing category_id/brand_id passthrough
-- ═══════════════════════════════════════════════════════════════════════════
-- The report's own Category/Brand filters (ric_report_filters, migration
-- 169) target param_target='category_id'/'brand_id', but the view only ever
-- exposed the resolved NAME (category_name/brand_name), never the raw id —
-- so PostgREST's `?category_id=eq.<uuid>` (fired on every PDF/Excel export,
-- which re-issues the query with the current filter values) failed with
-- "column v_product_master_report.category_id does not exist". Fixed by
-- adding both id columns to the SELECT list — additive, appended at the
-- end so no existing column position shifts.
CREATE OR REPLACE VIEW v_product_master_report AS
 SELECT p.client_id,
    p.company_id,
    p.product_code,
    p.barcode,
    p.part_number,
    p.product_name,
    p.product_nature,
    cat.category_name,
    brand.description AS brand_name,
    uom.description AS base_uom_name,
    p.tracking_type,
    stg.group_name AS sales_tax_group_name,
    ptg.group_name AS purchase_tax_group_name,
    p.hsn_sac_code,
    sup.account_code AS main_supplier_code,
    sup.account_name AS main_supplier_name,
    p.standard_cost,
    p.average_cost,
    p.last_purchase_cost,
    p.is_active,
    p.category_id,
    p.brand_id
   FROM rim_products p
     LEFT JOIN rim_item_categories cat ON cat.id = p.category_id
     LEFT JOIN rim_common_masters brand ON brand.id = p.brand_id
     LEFT JOIN rim_common_masters uom ON uom.id = p.base_uom_id
     LEFT JOIN rim_tax_groups stg ON stg.id = p.sales_tax_group_id
     LEFT JOIN rim_tax_groups ptg ON ptg.id = p.purchase_tax_group_id
     LEFT JOIN rim_accounts sup ON sup.id = p.main_supplier_id
  WHERE p.is_deleted = false;

ALTER VIEW v_product_master_report SET (security_invoker = true);
GRANT SELECT ON v_product_master_report TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- Fix 3 — Customer Master Report / Supplier Master Report show BOTH
-- customers AND suppliers, and Customer's own PDF/Excel export/totals call
-- hard-fails outright.
-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 169 wired BOTH report_keys to the SAME v_party_master_report
-- (which returns account_nature IN ('Customer','Supplier') with no further
-- scoping) and the SAME fn_party_master_report_totals (whose first
-- parameter, p_account_nature, has no default and was never supplied by
-- either report's filter config — no 'account_nature' filter row exists
-- for either report_key at all). Two real bugs, same root cause: nothing
-- ever scoped either report to its own party type.
-- Fixed with two DEDICATED views + DEDICATED totals functions (rather than
-- adding a visible "Account Nature" filter, which would defeat the point of
-- having two separate report screens) — each hardcodes its own nature.
CREATE OR REPLACE VIEW v_customer_master_report AS
    SELECT * FROM v_party_master_report WHERE account_nature = 'Customer';
ALTER VIEW v_customer_master_report SET (security_invoker = true);
GRANT SELECT ON v_customer_master_report TO anon, authenticated;

CREATE OR REPLACE VIEW v_supplier_master_report AS
    SELECT * FROM v_party_master_report WHERE account_nature = 'Supplier';
ALTER VIEW v_supplier_master_report SET (security_invoker = true);
GRANT SELECT ON v_supplier_master_report TO anon, authenticated;

CREATE OR REPLACE FUNCTION fn_customer_master_report_totals(
    p_client_id uuid, p_company_id uuid,
    p_party_category text DEFAULT NULL, p_is_active boolean DEFAULT NULL, p_is_credit_blocked boolean DEFAULT NULL
) RETURNS TABLE(row_count bigint)
LANGUAGE sql STABLE
AS $$
    SELECT COUNT(*)
    FROM v_customer_master_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_party_category    IS NULL OR party_category = p_party_category)
      AND (p_is_active         IS NULL OR is_active = p_is_active)
      AND (p_is_credit_blocked IS NULL OR is_credit_blocked = p_is_credit_blocked);
$$;
GRANT EXECUTE ON FUNCTION fn_customer_master_report_totals(uuid, uuid, text, boolean, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION fn_supplier_master_report_totals(
    p_client_id uuid, p_company_id uuid,
    p_party_category text DEFAULT NULL, p_is_active boolean DEFAULT NULL, p_is_credit_blocked boolean DEFAULT NULL
) RETURNS TABLE(row_count bigint)
LANGUAGE sql STABLE
AS $$
    SELECT COUNT(*)
    FROM v_supplier_master_report
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_party_category    IS NULL OR party_category = p_party_category)
      AND (p_is_active         IS NULL OR is_active = p_is_active)
      AND (p_is_credit_blocked IS NULL OR is_credit_blocked = p_is_credit_blocked);
$$;
GRANT EXECUTE ON FUNCTION fn_supplier_master_report_totals(uuid, uuid, text, boolean, boolean) TO authenticated;

-- Repoint every existing company's report registration at the new,
-- correctly-scoped objects (ric_report_definitions has one row per company,
-- seeded by migration 169's own one-off DO-loop — there is no ongoing
-- per-new-company seed for this table today, a separate, pre-existing gap
-- not addressed by this migration).
UPDATE ric_report_definitions
SET source_object = 'v_customer_master_report', totals_source_object = 'fn_customer_master_report_totals'
WHERE report_key = 'CUSTOMER_MASTER_REPORT' AND is_deleted = false;

UPDATE ric_report_definitions
SET source_object = 'v_supplier_master_report', totals_source_object = 'fn_supplier_master_report_totals'
WHERE report_key = 'SUPPLIER_MASTER_REPORT' AND is_deleted = false;
