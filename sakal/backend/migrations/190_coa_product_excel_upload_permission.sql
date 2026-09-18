-- ============================================================
-- Migration 190: enable bulk Excel upload for Chart of Accounts and
-- Product Master (permission wiring only -- the Flutter upload UI is a
-- separate, follow-up change to chart_of_accounts_screen.dart and the
-- Product Master screens)
-- ============================================================
-- Part of onboarding the first real tenant (Shanju Investment Limited,
-- a Zambia steel/hardware trader) -- 147 new ledger accounts and 487
-- new products need creating, and today Chart of Accounts / Product
-- Master are the only 2 masters with no bulk-upload path at all
-- (confirmed via a full grep of every migration: excel_upload_allowed
-- is only ever seeded true for MST-OB, Opening Balance, and IN-OPN,
-- Opening Stock). This is a standing capability, not a one-off for this
-- tenant -- both feature rows and fn_seed_client_modules.sql itself are
-- updated so every future client gets it too.
--
-- Same recipe as migration 133's own Opening Balance rollout:
--   1. Flip the per-company master-feature flag (ric_master_menus).
--   2. Backfill the per-user grant (ric_user_menus) for anyone who
--      already has edit access to that specific feature -- these are
--      PRE-EXISTING features (unlike Opening Balance, which was brand
--      new), so a plain UPDATE on already-existing rows is correct here,
--      not the INSERT-via-join-to-a-different-feature pattern 133 used
--      for a feature nobody had a row for yet.
--   3. fn_seed_client_modules.sql updated separately (see that file) so
--      new clients get excel_upload_allowed=true on these two features
--      from day one.
-- ============================================================

UPDATE ric_master_menus
SET    excel_upload_allowed = true
WHERE  feature_code IN ('MST-COA', 'MST-PRD')
  AND  is_deleted = false;

UPDATE ric_user_menus
SET    excel_upload_allowed = true,
       updated_at = now()
WHERE  feature_code IN ('MST-COA', 'MST-PRD')
  AND  edit_allowed = true
  AND  is_deleted = false;
