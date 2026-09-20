-- ============================================================
-- Migration 200: Chart of Accounts Import — reconciliation wizard
-- ============================================================
-- Full design: sakal/docs/screens/plan_chart_of_accounts_import.md
--
-- Replaces the plain "insert new leaf under a known parent" bulk upload
-- on the Chart of Accounts screen (migration 190/the screen's own
-- _uploadAccountsExcel) with a proper reconciliation flow:
-- SAKAL_COA ∪ (Client_COA − SAKAL_COA). A client's own COA is matched
-- against SAKAL's existing accounts (via pg_trgm name similarity, scoped
-- to the same account_nature) — a match is recorded via a new
-- external_code traceability column, a non-match becomes a new leaf
-- under an EXISTING (protected) group, never a new group.
--
-- Also closes a real, unrelated safety gap found while researching this:
-- is_system_fixed currently has ZERO backend enforcement (only the
-- screen's own Delete button checks it client-side), and the three
-- auto-created infrastructure accounts (Stock Account, Cost of Sales,
-- Purchase Accrual — fn_seed_default_leaf_accounts_and_links, migration
-- 181) aren't even flagged is_system_fixed, so they can be deleted today
-- with zero warning despite being load-bearing for GRN/GL posting.
-- ============================================================

-- ── 1. external_code — the client's own original code ─────────────────
ALTER TABLE rim_accounts ADD COLUMN IF NOT EXISTS external_code TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_rim_accounts_external_code
    ON rim_accounts (client_id, company_id, external_code)
    WHERE external_code IS NOT NULL;

-- ── 2. pg_trgm — trigram name-similarity matching ──────────────────────
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ── 3. fn_suggest_coa_import_matches ────────────────────────────────────
-- One batched call for the whole uploaded file — never per-row. Each
-- input row is {row_index, client_name, nature}; returns the best-scoring
-- EXISTING posting account of the SAME account_nature per row (a Customer
-- row never suggests an Expense account), or no row at all if nothing
-- scores above a sane floor (0.3 — same convention as a typical
-- pg_trgm fuzzy-match threshold; below this a suggestion is more likely
-- to mislead than help, and the screen defaults such rows to Create New).
CREATE OR REPLACE FUNCTION fn_suggest_coa_import_matches(
    p_client_id  UUID,
    p_company_id UUID,
    p_rows       JSONB
) RETURNS TABLE (
    row_index    INTEGER,
    account_id   UUID,
    account_code TEXT,
    account_name TEXT,
    score        REAL
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        (r->>'row_index')::INTEGER,
        best.id,
        best.account_code,
        best.account_name,
        best.score
    FROM jsonb_array_elements(p_rows) AS r
    LEFT JOIN LATERAL (
        SELECT a.id, a.account_code, a.account_name,
               similarity(a.account_name, r->>'client_name') AS score
        FROM   rim_accounts a
        WHERE  a.client_id       = p_client_id
          AND  a.company_id      = p_company_id
          AND  a.is_deleted      = false
          AND  a.posting_allowed = true
          AND  a.account_nature  = coalesce(r->>'nature', 'General')
        ORDER BY similarity(a.account_name, r->>'client_name') DESC
        LIMIT 1
    ) best ON best.score >= 0.3;
END;
$$;

-- ── 4. fn_apply_coa_import ──────────────────────────────────────────────
-- One transaction (PL/pgSQL function body is implicitly transactional):
-- every Map row updates only external_code on an existing account (name/
-- details of an existing account are never touched by a client import);
-- every Create row inserts a brand-new leaf, same payload shape as the
-- screen's own single-row Add. Returns counts for the confirmation
-- summary.
CREATE OR REPLACE FUNCTION fn_apply_coa_import(
    p_client_id   UUID,
    p_company_id  UUID,
    p_map_rows    JSONB,   -- [{account_id, external_code}]
    p_create_rows JSONB,   -- [{parent_id, account_code, account_name, account_nature,
                            --   account_currency_id, external_code, party_type, contact_person,
                            --   phone, email, address_line1, address_line2, tax_id,
                            --   credit_days, credit_limit}]
    p_user_id     UUID
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_row          JSONB;
    v_mapped_count INTEGER := 0;
    v_created_count INTEGER := 0;
    v_is_party     BOOLEAN;
BEGIN
    FOR v_row IN SELECT * FROM jsonb_array_elements(coalesce(p_map_rows, '[]'::jsonb)) LOOP
        UPDATE rim_accounts
        SET    external_code = v_row->>'external_code',
               updated_by    = p_user_id,
               updated_at    = now()
        WHERE  id = (v_row->>'account_id')::UUID
          AND  client_id  = p_client_id
          AND  company_id = p_company_id;
        v_mapped_count := v_mapped_count + 1;
    END LOOP;

    FOR v_row IN SELECT * FROM jsonb_array_elements(coalesce(p_create_rows, '[]'::jsonb)) LOOP
        v_is_party := (v_row->>'account_nature') IN ('Customer', 'Supplier');

        INSERT INTO rim_accounts (
            client_id, company_id, parent_id, account_code, account_name,
            account_nature, account_currency_id, posting_allowed,
            accounting_std, external_code, is_active, is_system_fixed,
            party_type, contact_person, phone, email, address_line1, address_line2,
            tax_id, credit_days, credit_limit,
            created_by, updated_by
        ) VALUES (
            p_client_id, p_company_id, (v_row->>'parent_id')::UUID,
            v_row->>'account_code', v_row->>'account_name',
            v_row->>'account_nature', (v_row->>'account_currency_id')::UUID, true,
            (SELECT accounting_std FROM rim_accounts WHERE id = (v_row->>'parent_id')::UUID),
            v_row->>'external_code', true, false,
            CASE WHEN v_is_party THEN v_row->>'party_type' END,
            CASE WHEN v_is_party THEN v_row->>'contact_person' END,
            CASE WHEN v_is_party THEN v_row->>'phone' END,
            CASE WHEN v_is_party THEN v_row->>'email' END,
            CASE WHEN v_is_party THEN v_row->>'address_line1' END,
            CASE WHEN v_is_party THEN v_row->>'address_line2' END,
            CASE WHEN v_is_party THEN v_row->>'tax_id' END,
            CASE WHEN v_is_party THEN coalesce((v_row->>'credit_days')::INTEGER, 30) END,
            CASE WHEN v_is_party THEN (v_row->>'credit_limit')::NUMERIC END,
            p_user_id, p_user_id
        );
        v_created_count := v_created_count + 1;
    END LOOP;

    RETURN jsonb_build_object('mapped', v_mapped_count, 'created', v_created_count);
END;
$$;

-- ── 5. fn_can_delete_account ─────────────────────────────────────────────
-- Same NULL-is-safe/TEXT-reason shape as migration 130's fn_can_delete_*
-- guards. Checks (in order): is_system_fixed (a protected seeded/auto-
-- created account — this is the first real backend enforcement of that
-- flag), rid_finance_lines (ever posted to), rim_account_link_defaults
-- (referenced as a GL account-determination default — e.g. Stock
-- Account, Cost of Sales, Purchase Accrual).
CREATE OR REPLACE FUNCTION fn_can_delete_account(
    p_client_id  UUID,
    p_company_id UUID,
    p_account_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_account_code TEXT;
    v_account_name TEXT;
    v_is_fixed     BOOLEAN;
BEGIN
    SELECT account_code, account_name, is_system_fixed
    INTO   v_account_code, v_account_name, v_is_fixed
    FROM   rim_accounts
    WHERE  id = p_account_id AND client_id = p_client_id AND company_id = p_company_id;

    IF v_is_fixed THEN
        RETURN format('Account [%s] %s is a protected system account and cannot be deleted.', v_account_code, v_account_name);
    END IF;

    IF EXISTS (
        SELECT 1 FROM rid_finance_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND account_id = p_account_id AND is_deleted = false
    ) THEN
        RETURN format('Account [%s] %s has posted transactions and cannot be deleted.', v_account_code, v_account_name);
    END IF;

    IF EXISTS (
        SELECT 1 FROM rim_account_link_defaults
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND account_id = p_account_id AND is_deleted = false
    ) THEN
        RETURN format('Account [%s] %s is configured as a GL account-determination default and cannot be deleted.', v_account_code, v_account_name);
    END IF;

    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION fn_suggest_coa_import_matches(UUID, UUID, JSONB) FROM anon;
REVOKE ALL ON FUNCTION fn_apply_coa_import(UUID, UUID, JSONB, JSONB, UUID) FROM anon;
REVOKE ALL ON FUNCTION fn_can_delete_account(UUID, UUID, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION fn_suggest_coa_import_matches(UUID, UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_apply_coa_import(UUID, UUID, JSONB, JSONB, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_can_delete_account(UUID, UUID, UUID) TO authenticated;

-- ── 6. One-time data fix — protect every currently-unprotected,
-- load-bearing linked account (Stock Account, Cost of Sales, Purchase
-- Accrual, and any admin-configured link) across ALL companies, not just
-- one tenant. ────────────────────────────────────────────────────────────
UPDATE rim_accounts
SET    is_system_fixed = true
WHERE  is_deleted = false
  AND  is_system_fixed = false
  AND  id IN (
    SELECT account_id FROM rim_account_link_defaults WHERE is_deleted = false
  );

-- ── 7. Menu: new "Chart of Accounts Import" feature ─────────────────────
-- Same FN-MST group as MST-COA. MST-COA's own excel_upload_allowed is
-- reverted to false (same precedent as migration 191's MST-PRD
-- reversion) since its upload button is being removed in this same pass.
DO $$
DECLARE
    v_company RECORD;
    v_ad_module_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_ad_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'AD';

        CONTINUE WHEN v_ad_module_id IS NULL;

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-COAI', 'Chart of Accounts Import',
             '/master/coa-import', 8, 'FN-MST', 'Finance Masters', 5, false, false, true)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, excel_upload_allowed = excluded.excel_upload_allowed;

    END LOOP;
END $$;

-- ric_user_menus backfill — give view+edit+excel_upload to whoever already
-- has edit access to any other AD-module feature (same pattern as 191).
INSERT INTO ric_user_menus (
    client_id, company_id, user_id, module_id, feature_code, serial_no,
    view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT DISTINCT
    mm.client_id, mm.company_id, existing.user_id, mm.module_id, mm.feature_code, mm.serial_no,
    true, true, mm.approve_allowed, mm.copy_allowed, mm.excel_upload_allowed
FROM ric_master_menus mm
JOIN (
    SELECT DISTINCT user_id, client_id, company_id, module_id
    FROM ric_user_menus
    WHERE edit_allowed = true AND is_deleted = false
) existing
    ON  existing.client_id  = mm.client_id
    AND existing.company_id = mm.company_id
    AND existing.module_id  = mm.module_id
WHERE mm.feature_code = 'MST-COAI'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, edit_allowed = true, excel_upload_allowed = true, updated_at = now();

-- Revert MST-COA's excel_upload_allowed (set true by migration 190) --
-- the old upload button/methods are removed from chart_of_accounts_screen.dart
-- in this same pass.
UPDATE ric_master_menus
SET    excel_upload_allowed = false
WHERE  feature_code = 'MST-COA'
  AND  is_deleted = false;

UPDATE ric_user_menus
SET    excel_upload_allowed = false,
       updated_at = now()
WHERE  feature_code = 'MST-COA'
  AND  is_deleted = false;
