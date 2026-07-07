-- ============================================================
-- Migration 066: Inventory setup for Material Requisition/Issue
-- ============================================================
-- Groundwork for the two transaction modules that follow (067/068):
--
-- 1. rim_department_consumption_areas — Department -> Consumption Area ->
--    Account linking. A Consumption Area belongs to exactly ONE Department
--    and has exactly ONE expense account (company-wide UNIQUE on
--    consumption_area_id alone, not the department+area pair) — confirmed
--    live. The admin screen's "add multiple areas under one department in
--    one go" is a bulk-entry convenience only, not a hint that areas repeat
--    across departments. department_id/consumption_area_id themselves
--    already exist as rim_common_masters rows (type_keys DEPARTMENT/
--    CONSUMPTION_AREA, seeded in 031) and already sit on rid_grn_lines/
--    rid_purchase_order_lines as per-line tags — this table is what turns
--    that per-line pair into a resolvable GL account for the new
--    consumption modules, nothing on the existing PO/GRN lines changes.
--
-- 2. ric_locations.is_issue_allowed — new location flag (default TRUE, so
--    no existing location is locked out) gating which locations can be a
--    Material Requisition's From Location, mirrors is_negative_stock_
--    allowed's shape (028).
--
-- 3. Removes the STOCK_CONSUMPTION_ACCOUNT link type (seeded 032, resolved
--    by item/category/location, never actually consumed anywhere) — same
--    dead-config cleanup as INPUT_VAT_ACCOUNT's removal in 056. The new
--    rim_department_consumption_areas table supersedes it entirely: the
--    consumption account is resolved by WHERE the material is being
--    consumed (department/area), not by WHAT item is being consumed.
--
-- 4. Seeds MREQ/MISS (document numbering only, via fn_next_trans_no, same
--    per-location scheme as GRN/Purchase Return) and MIC (the actual GL
--    posting voucher type for Material Issue's Dr Expense/Cr Stock entry —
--    deliberately separate from MISS, same "numbering code != posting code"
--    rule as Purchase Invoice's PINV/PUR split, migration 055).
--
-- 5. Menu seeding for existing companies (fn_seed_client_modules.sql
--    updated separately for future clients): IN-DCA under a new IN-SETG
--    group, IN-MRQ/IN-MIS under the existing IN-OPS group.
-- ============================================================


-- ── 1. rim_department_consumption_areas ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS rim_department_consumption_areas (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    department_id       UUID          NOT NULL REFERENCES rim_common_masters(id),
    consumption_area_id UUID          NOT NULL REFERENCES rim_common_masters(id),
    account_id          UUID          NOT NULL REFERENCES rim_accounts(id),
    is_active           BOOLEAN       NOT NULL DEFAULT true,
    is_deleted          BOOLEAN       NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          UUID          REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID          REFERENCES rim_users(id)
);

-- Partial (not plain) UNIQUE — a soft-deleted area can be re-added (to the
-- same or a different department) without a permanent uniqueness lock-out.
CREATE UNIQUE INDEX IF NOT EXISTS uq_dept_consumption_areas_area
    ON rim_department_consumption_areas (client_id, company_id, consumption_area_id)
    WHERE is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_dept_consumption_areas_department
    ON rim_department_consumption_areas (client_id, company_id, department_id)
    WHERE is_deleted = false;

DROP TRIGGER IF EXISTS trg_rim_department_consumption_areas_updated_at ON rim_department_consumption_areas;
CREATE TRIGGER trg_rim_department_consumption_areas_updated_at
    BEFORE UPDATE ON rim_department_consumption_areas
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rim_department_consumption_areas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_department_consumption_areas" ON rim_department_consumption_areas;
CREATE POLICY "auth_rw_department_consumption_areas" ON rim_department_consumption_areas
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_department_consumption_areas FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_department_consumption_areas TO authenticated;


-- ── 2. ric_locations.is_issue_allowed ────────────────────────────────────────
ALTER TABLE ric_locations ADD COLUMN IF NOT EXISTS is_issue_allowed BOOLEAN NOT NULL DEFAULT true;


-- ── 3. Remove the orphaned STOCK_CONSUMPTION_ACCOUNT link type ───────────────
DELETE FROM rim_account_links
WHERE link_type_id = (SELECT id FROM rim_account_link_types WHERE link_key = 'STOCK_CONSUMPTION_ACCOUNT');
DELETE FROM rim_account_link_defaults
WHERE link_type_id = (SELECT id FROM rim_account_link_types WHERE link_key = 'STOCK_CONSUMPTION_ACCOUNT');
DELETE FROM rim_account_link_setup
WHERE link_type_id = (SELECT id FROM rim_account_link_types WHERE link_key = 'STOCK_CONSUMPTION_ACCOUNT');
DELETE FROM rim_account_link_types WHERE link_key = 'STOCK_CONSUMPTION_ACCOUNT';


-- ── 4. Voucher types: MREQ/MISS (numbering) + MIC (GL posting) ──────────────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('MREQ', 'Material Requisition',           'STOCK', NULL, 'YEARLY', 'MREQ/{LOC}/{YYYY}/{SEQ5}', true),
    ('MISS', 'Material Issue for Consumption', 'STOCK', NULL, 'YEARLY', 'MISS/{LOC}/{YYYY}/{SEQ5}', true),
    ('MIC',  'Material Consumption Voucher',   'STOCK', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 5. Menu seeding for existing companies ───────────────────────────────────
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, v.feature_code, v.feature_name, v.screen_name,
       v.serial_no, v.group_code, v.group_name, v.group_serial_no,
       v.approve_allowed, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'IN'
CROSS JOIN (VALUES
    ('IN-DCA', 'Consumption Area Setup', '/inventory/department-consumption-areas', 0, 'IN-SETG', 'Setup',       1, false),
    ('IN-MRQ', 'Material Requisition',   '/inventory/requisitions',                  3, 'IN-OPS',  'Operations',  0, true),
    ('IN-MIS', 'Material Issue',         '/inventory/material-issue',                4, 'IN-OPS',  'Operations',  0, true)
) AS v(feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed)
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
