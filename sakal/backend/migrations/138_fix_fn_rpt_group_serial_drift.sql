-- ============================================================
-- Migration 138: fix FN-RPT group_serial_no drift (duplicate "Reports"
-- sidebar section, Finance module)
-- ============================================================
-- Same bug class as the earlier Sales "Transactions" duplicate (see
-- 093_resync_menu_group_columns.sql / 124_fix_seed_client_modules_overload.sql)
-- — fn_get_user_menu.sql's groups subquery does
-- `SELECT DISTINCT group_code, group_name, group_serial_no`, and its
-- features subquery joins back onto a group row by group_code ALONE,
-- never group_serial_no. Any two rows sharing group_code with a
-- DIFFERENT group_serial_no therefore render as two separate sidebar
-- headers, each pulling the FULL identical feature list for that
-- group_code.
--
-- 135_trial_balance_report.sql's own ric_master_menus UPSERT set
-- FN-TRB's group_serial_no to 2 — every other FN-RPT feature (FN-PNL,
-- FN-BSH, FN-RPT-PBR, FN-RPT-PBG, FN-RPT-LDG, and 137's own FN-RPT-CAG/
-- FN-RPT-SAG) uses 1, matching fn_seed_client_modules.sql's own
-- authoritative definition — 135 should have copied that value instead
-- of introducing a new one. Fixed at the source in 135's own file (won't
-- re-apply itself, per this project's "editing a run migration does
-- nothing" rule) and here, against the live data.
-- ============================================================

UPDATE ric_master_menus
SET group_serial_no = 1
WHERE feature_code = 'FN-TRB'
  AND group_code = 'FN-RPT'
  AND group_serial_no <> 1;
