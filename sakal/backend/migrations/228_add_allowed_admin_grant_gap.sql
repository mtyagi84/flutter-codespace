-- ============================================================
-- Migration 228: add_allowed never granted to any admin, ever
-- ============================================================
-- Real bug, found live 2026-10-16 via a user screenshot of a brand-new
-- admin's User Permissions screen: every single "Add" checkbox was
-- unticked, on every feature, despite "View"/"Edit"/"Approve"/"Copy" all
-- being correctly ticked. Root cause: migration 016 added `add_allowed` to
-- `ric_user_menus` (separating "create new" from "edit existing") and
-- rebuilt the permission-read/upsert/copy functions to carry it — but
-- `fn_grant_admin_access` (the function `fn_seed_client_modules` calls at
-- the end of every new-tenant registration to grant the admin full access)
-- was never updated. Its own INSERT/UPDATE column lists simply never
-- mentioned `add_allowed`, so it has silently defaulted to `false` for
-- EVERY admin, on EVERY tenant, since migration 016 shipped. Fixed in
-- fn_grant_admin_access.sql (re-deployed alongside this migration); this
-- file backfills every existing tenant's admin-granted rows.
--
-- Scope: any ric_user_menus row that already has the "full access grant"
-- signature (view_allowed=true AND edit_allowed=true) is exactly what
-- fn_grant_admin_access produces — a plain per-user Permissions-screen
-- edit could ALSO happen to match that signature, but granting add_allowed
-- too in that case only ever WIDENS an already-broad permission, never
-- narrows anything, so this is safe either way.
-- ============================================================

UPDATE ric_user_menus
SET add_allowed = true,
    updated_at  = now()
WHERE is_deleted    = false
  AND view_allowed   = true
  AND edit_allowed   = true
  AND add_allowed    = false;
