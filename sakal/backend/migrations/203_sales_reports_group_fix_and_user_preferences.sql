-- ============================================================
-- Migration 203: Sales "Reports" duplicate-folder fix + user print preferences
-- ============================================================
-- Full design: sakal/docs/screens/plan_quick_invoice_navigation.md
--
-- Part A — same drift class migration 093 already fixed once for
-- SL-TXN/"Transactions": fn_get_user_menu.sql groups by
-- (group_code, group_name, group_serial_no) together, so two rows
-- sharing group_code/group_name but disagreeing on group_serial_no
-- render as two separate sidebar folders. Confirmed live: every SL-RPT
-- row across every company sits at group_serial_no=1 except one
-- company's own SL-RPT-REG ("Sales Register"), stuck at 2 — a leftover
-- from migration 127_sales_register_report.sql's own original insert,
-- predating migration 128's full reseed, which should have normalized
-- it but evidently missed this one row for this one company.
--
-- Part B — ric_user_menu_favorites-style per-user preference table
-- (migration 202's own precedent: a personal UI preference must never
-- live on a row that also carries real permissions) for the new
-- Direct Print / On Screen choice on Quick Invoice's post-save print
-- flow.
-- ============================================================

-- ── Part A — Sales Reports group_serial_no fix ──────────────────────────
UPDATE ric_master_menus
SET    group_serial_no = 1
WHERE  group_code = 'SL-RPT'
  AND  group_serial_no <> 1;

-- ── Part B — ric_user_preferences ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS ric_user_preferences (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id     UUID        NOT NULL REFERENCES ric_clients(id),
    company_id    UUID        NOT NULL REFERENCES ric_companies(id),
    user_id       UUID        NOT NULL REFERENCES rim_users(id),
    print_mode    TEXT        NOT NULL DEFAULT 'ON_SCREEN' CHECK (print_mode IN ('DIRECT', 'ON_SCREEN')),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (client_id, company_id, user_id)
);

ALTER TABLE ric_user_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_rw_user_preferences" ON ric_user_preferences;
CREATE POLICY "auth_rw_user_preferences" ON ric_user_preferences
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND user_id    = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND user_id    = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid);

REVOKE ALL ON ric_user_preferences FROM anon;
REVOKE TRUNCATE ON ric_user_preferences FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON ric_user_preferences TO authenticated;
