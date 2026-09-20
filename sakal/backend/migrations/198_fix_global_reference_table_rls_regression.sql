-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 198 — CRITICAL regression fix: migration 195 broke rim_voucher_types
-- and rim_payment_modes entirely (every voucher-numbering/GL-posting call in
-- the whole app), plus cleanup of 3 orphaned test drafts.
-- ═══════════════════════════════════════════════════════════════════════════
-- Found live 2026-09-20: user hit "Voucher type CNT not found or inactive"
-- (Stock Count) and "Voucher type OPST not found or inactive" (Opening
-- Stock Value Upload) immediately after running migration 195.
--
-- Root cause: migration 195 fixed rim_voucher_types' dev_allow_all_*
-- policy with the standard auth_rw_<table> shape (strict client_id =
-- jwt_client AND company_id = jwt_company). But rim_voucher_types is a
-- FULLY GLOBAL reference table — confirmed all 46 rows (OPST, CNT, CNTR,
-- JV, every other voucher_type_code in the schema) have client_id/
-- company_id = NULL, is_system = true. NULL never equals a UUID in SQL, so
-- the strict-equality policy silently returned ZERO rows for every voucher
-- type lookup, everywhere in the app — this is not scoped to Stock Count/
-- Opening Stock, it broke fn_next_trans_no (document numbering) and
-- fn_post_voucher (GL posting) for every single transaction type. A
-- broader check for the same shape (any table touched by 194/195 with a
-- NULL client_id or company_id row) found ONE more: rim_payment_modes,
-- also 100% global (7/7 rows NULL/is_system=true), same regression, not
-- yet reported live only because nothing has exercised it since 195 ran.
--
-- Fixed with the same is_system-aware policy already used correctly for
-- rim_divisions in migration 194 (global is_system rows always readable;
-- a tenant may only write its own non-system custom rows) — the general
-- lesson from that migration's own comment applies here too: before
-- writing a plain auth_rw_<table> policy for a "dev_allow_all_*" table
-- being cleaned up, check whether ANY row in it actually has a NULL
-- tenant column before assuming the standard strict-equality shape is
-- correct. This migration's own audit query (below, informational) is
-- the check that should have been run before 195 shipped.
-- ═══════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "auth_rw_rim_voucher_types" ON rim_voucher_types;
CREATE POLICY "auth_rw_rim_voucher_types" ON rim_voucher_types
    FOR ALL TO authenticated
    USING (
        client_id IS NULL
        OR (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    )
    WITH CHECK (
        is_system = false
        AND client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
    );

DROP POLICY IF EXISTS "auth_rw_rim_payment_modes" ON rim_payment_modes;
CREATE POLICY "auth_rw_rim_payment_modes" ON rim_payment_modes
    FOR ALL TO authenticated
    USING (
        client_id IS NULL
        OR (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    )
    WITH CHECK (
        is_system = false
        AND client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
    );

-- ── Informational audit query, kept for reference — re-run this any time
--    a dev_allow_all_* cleanup touches a new table, BEFORE assuming the
--    plain strict-equality policy is correct:
--
--    SELECT count(*) FILTER (WHERE client_id IS NULL OR company_id IS NULL) AS null_rows, count(*) AS total
--    FROM <table>;
--
--    A non-zero null_rows count means the table has global/system rows and
--    needs the is_system-aware shape above, not the plain one.


-- ═══════════════════════════════════════════════════════════════════════════
-- Cleanup — 3 abandoned Opening Stock DRAFT test documents
-- ═══════════════════════════════════════════════════════════════════════════
-- OPST/SL/2026/00001-00003, created 2026-09-19 evening during initial
-- testing of the Opening Stock Value Upload screen (predates this
-- migration's own regression — these were saved successfully back then,
-- before migration 195 ever existed; the approve step failed for
-- unrelated reasons already fixed since, e.g. the Opening Stock Equity
-- Account / exchange rate setup). All three are still DRAFT (never
-- approved — no stock/GL impact ever happened), confirmed test noise the
-- user did not knowingly create. Soft-deleted, matching this app's own
-- convention, rather than hard-deleted.
UPDATE rid_opening_stock_lines
SET is_deleted = true, updated_at = now()
WHERE client_id = '61f96b99-d478-4f67-8d40-90df164c7cb0'
  AND company_id = '84c7cbb5-0492-4294-ae7a-4d9f41f3596e'
  AND opening_no IN ('OPST/SL/2026/00001', 'OPST/SL/2026/00002', 'OPST/SL/2026/00003');

UPDATE rih_opening_stock_headers
SET is_deleted = true, updated_at = now()
WHERE client_id = '61f96b99-d478-4f67-8d40-90df164c7cb0'
  AND company_id = '84c7cbb5-0492-4294-ae7a-4d9f41f3596e'
  AND opening_no IN ('OPST/SL/2026/00001', 'OPST/SL/2026/00002', 'OPST/SL/2026/00003')
  AND status = 'DRAFT';
