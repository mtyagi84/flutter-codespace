-- ============================================================
-- Migration 227: Cash Receipt (SL-RCP) approve_allowed gap fix
-- ============================================================
-- Real bug, found live 2026-10-15 while investigating a user report that
-- new-admin User Access checkboxes weren't all ticked: SL-RCP's own menu
-- row has carried approve_allowed=false since it was first seeded as a
-- plain placeholder (migration 005), long before Cash Receipt had any real
-- Approve workflow. Migration 104 built fn_approve_cash_receipt and
-- migration 114 added real server-side enforcement
-- (fn_check_approve_permission(..., 'SL-RCP')) on top of it -- but neither
-- ever flipped this flag. Net effect: ric_user_menus.approve_allowed for
-- SL-RCP mirrors ric_master_menus and is therefore false for every user of
-- every existing company, including a full-access admin -- nobody can ever
-- approve a Cash Receipt in this app today. Confirmed against both Arova
-- Pharma (SK-32130, the real tenant) and a freshly-registered test tenant,
-- same gap on both -- this is a seeding-data bug, not a one-off.
--
-- Two-sided fix, same pattern as every other menu/permission gap this
-- project has hit before (see CLAUDE.md's "Menu Seed Two-Sided Rule"):
--   1. fn_seed_client_modules.sql fixed in place (future tenants).
--   2. ric_master_menus backfilled for every existing company (this file).
--   3. ric_user_menus re-granted for any user who already has edit access
--      to Cash Receipt -- same "backfill users who already have edit
--      access to a sibling feature in the group" convention used by every
--      prior permission-rollout migration in this project.
-- ============================================================

UPDATE ric_master_menus
SET approve_allowed = true,
    updated_at      = now()
WHERE feature_code = 'SL-RCP'
  AND is_deleted    = false
  AND approve_allowed = false;

UPDATE ric_user_menus
SET approve_allowed = true,
    updated_at      = now()
WHERE feature_code     = 'SL-RCP'
  AND is_deleted        = false
  AND edit_allowed      = true
  AND approve_allowed   = false;
