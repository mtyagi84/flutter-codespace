-- ============================================================
-- Migration 133: Opening Balance lines (Chart of Accounts) — Finance Masters.
-- ============================================================
-- rim_opening_balances (013_chart_of_accounts.sql) was fully defined but
-- had zero UI, zero backend RPC, and zero app-side consumer anywhere in
-- this codebase — confirmed via full-repo search before this migration was
-- written. It also modeled the wrong grain: a single ob_amount per
-- (account_id, fy_id), no currency split, no bill-level detail.
--
-- Real requirement (Trial Balance design discussion): one account can have
-- MULTIPLE opening-balance rows, each optionally tied to a historical
-- Invoice/Bill No + Date — the same inv_bill_no/inv_bill_date convention
-- rid_finance_lines already uses everywhere else in this schema. A
-- customer's opening balance isn't one lump Dr figure, it's however many
-- of their old invoices were still outstanding at go-live. All three
-- currencies (Base/Local/Party) are entered directly by the user — never
-- derived via fn_get_exchange_rate, since that function requires a
-- location_id and opening balances have no location relationship (this is
-- one-time historical data transcribed from the client's prior books, not
-- a live conversion).
--
-- Table is confirmed empty and unused — dropped and recreated rather than
-- ALTER'd in place. Renamed rim_opening_balances -> rid_opening_balance_
-- lines because the grain changed from "one master value per account"
-- (rim_ prefix) to bill-level transactional detail (rid_ prefix, matching
-- rid_finance_lines' own convention).
-- ============================================================

DROP TABLE IF EXISTS rim_opening_balances;

CREATE TABLE rid_opening_balance_lines (
    id                 UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id          UUID          NOT NULL REFERENCES ric_clients(id),
    company_id         UUID          NOT NULL REFERENCES ric_companies(id),
    account_id         UUID          NOT NULL REFERENCES rim_accounts(id),
                       -- posting_allowed=true only, enforced client-side same
                       -- as every other account picker in this app
    fy_id              UUID          NOT NULL REFERENCES rim_financial_years(id),
    location_group_id  UUID          REFERENCES ric_location_groups(id),
                       -- NULL under SIMPLE accounting; required (client-side)
                       -- under INTER_ENTITY — same conditional pattern already
                       -- built for the Finance voucher Location field
    base_amount        NUMERIC(18,4) NOT NULL DEFAULT 0,
    local_amount       NUMERIC(18,4) NOT NULL DEFAULT 0,
    party_amount       NUMERIC(18,4) NOT NULL DEFAULT 0,
    party_currency     TEXT          NOT NULL,
                       -- defaults from the picked account's own
                       -- account_currency_id in the UI, editable
    ob_type            TEXT          NOT NULL CHECK (ob_type IN ('Dr', 'Cr')),
    inv_bill_no        TEXT,
    inv_bill_date      DATE,
                       -- both optional — mainly meaningful for Customer/
                       -- Supplier accounts; a Cash/Bank/General account's
                       -- opening balance has no bill to reference
    is_deleted         BOOLEAN       NOT NULL DEFAULT false,
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by         UUID          REFERENCES rim_users(id),
    updated_at         TIMESTAMPTZ,
    updated_by         UUID          REFERENCES rim_users(id)
    -- No uniqueness constraint on (account_id, fy_id) — multiple legitimate
    -- rows per account are the whole point of this design.
);

CREATE INDEX idx_opening_balance_lines_lookup
    ON rid_opening_balance_lines (client_id, company_id, account_id, fy_id);
CREATE INDEX idx_opening_balance_lines_group
    ON rid_opening_balance_lines (client_id, company_id, fy_id, location_group_id);

CREATE TRIGGER trg_rid_opening_balance_lines_updated_at
    BEFORE UPDATE ON rid_opening_balance_lines
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rid_opening_balance_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_rw_rid_opening_balance_lines" ON rid_opening_balance_lines;
CREATE POLICY "auth_rw_rid_opening_balance_lines" ON rid_opening_balance_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_opening_balance_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_opening_balance_lines TO authenticated;


-- ============================================================
-- v_opening_balance_summary — nets multiple bill-level rows per account
-- into one signed figure per currency. Not consumed by anything yet (no
-- report reads it in this migration) — built now so the schema is ready
-- for Trial Balance / a corrected Account Ledger opening-balance formula
-- in a future session: opening (as of date_from) = this view's signed
-- figure for the FY containing date_from, PLUS net movement of
-- rid_finance_lines from that FY's start date up to date_from.
-- ============================================================
CREATE OR REPLACE VIEW v_opening_balance_summary AS
SELECT
    client_id, company_id, account_id, fy_id, location_group_id,
    SUM(CASE WHEN ob_type = 'Dr' THEN base_amount  ELSE -base_amount  END) AS base_signed,
    SUM(CASE WHEN ob_type = 'Dr' THEN local_amount ELSE -local_amount END) AS local_signed,
    SUM(CASE WHEN ob_type = 'Dr' THEN party_amount ELSE -party_amount END) AS party_signed,
    MAX(party_currency) AS party_currency
    -- party_currency is expected uniform per account (it's the account's
    -- own currency) — MAX is a defensive single-value pick, not a real
    -- aggregation across genuinely differing values.
FROM rid_opening_balance_lines
WHERE is_deleted = false
GROUP BY client_id, company_id, account_id, fy_id, location_group_id;

GRANT SELECT ON v_opening_balance_summary TO authenticated;


-- ============================================================
-- Menu — reuses the existing Finance Masters group (FN-MST), same group
-- Chart of Accounts / Account Link Setup / Exchange Rates already live in.
-- New feature_code, not a placeholder-reuse situation like Trial Balance's
-- FN-TRB (confirmed no existing "Opening Balance" row anywhere in
-- ric_master_menus before this migration).
-- ============================================================
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
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-OB', 'Opening Balance',
             '/master/opening-balances', 7, 'FN-MST', 'Finance Masters', 5, false, false, true)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, excel_upload_allowed = excluded.excel_upload_allowed;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill (same pattern as every prior new-feature
-- migration): a ric_master_menus row alone makes a feature ELIGIBLE, it
-- grants nobody anything. Give VIEW+EDIT access to whoever already has
-- edit access to any other Admin/Setup (AD) feature — this is a master-
-- data entry screen, not a report, so edit (not just view) is the useful
-- default.
-- ============================================================
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
WHERE mm.feature_code = 'MST-OB'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, edit_allowed = true, updated_at = now();
