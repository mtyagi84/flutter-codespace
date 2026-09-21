-- ============================================================
-- Migration 202: Module order reorder + Menu Favorites
-- ============================================================
-- Full design: sakal/docs/screens/plan_app_menu_navigation_overhaul.md
--
-- Part A — reorder ric_system_modules for every EXISTING company to
-- Sales/Purchase/Inventory/Finance/Settings (user-requested). A plain
-- targeted UPDATE on the one column that needs to change, deliberately
-- NOT a full re-run of fn_seed_client_modules (that function also
-- touches ~75 menu/report rows per company — unnecessary risk/cost for
-- a 5-row-per-company reorder, especially now that Shanju is a real,
-- live tenant). fn_seed_client_modules.sql itself is updated separately
-- (same commit) so future tenants get the new order at registration.
--
-- Part B — ric_user_menu_favorites: a brand-new, deliberately SEPARATE
-- table for a user's personal "starred" menu items, never a column on
-- ric_user_menus. ric_user_menus also carries real permission grants
-- (edit_allowed/approve_allowed/etc.) — a favorite is a pure UI
-- preference a user should be able to self-service without ever writing
-- to the same row that controls their own permissions.
-- ============================================================

-- ── Part A — module order backfill ──────────────────────────────────────
UPDATE ric_system_modules
SET    serial_no = CASE module_code
           WHEN 'SL' THEN 0
           WHEN 'PR' THEN 1
           WHEN 'IN' THEN 2
           WHEN 'FN' THEN 3
           WHEN 'AD' THEN 4
       END
WHERE  module_code IN ('SL', 'PR', 'IN', 'FN', 'AD')
  AND  is_deleted = false;

-- ── Part B — ric_user_menu_favorites ────────────────────────────────────
CREATE TABLE IF NOT EXISTS ric_user_menu_favorites (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id     UUID        NOT NULL REFERENCES ric_clients(id),
    company_id    UUID        NOT NULL REFERENCES ric_companies(id),
    user_id       UUID        NOT NULL REFERENCES rim_users(id),
    feature_code  TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (client_id, company_id, user_id, feature_code)
);

ALTER TABLE ric_user_menu_favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_rw_user_menu_favorites" ON ric_user_menu_favorites;
CREATE POLICY "auth_rw_user_menu_favorites" ON ric_user_menu_favorites
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND user_id    = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND user_id    = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid);

REVOKE ALL ON ric_user_menu_favorites FROM anon;
REVOKE TRUNCATE ON ric_user_menu_favorites FROM authenticated;
GRANT SELECT, INSERT, DELETE ON ric_user_menu_favorites TO authenticated;
