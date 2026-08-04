-- ============================================================
-- Migration 119: Reporting Engine — permission backfill for the 3 pilots
-- ============================================================
-- Real gap caught live: fn_get_user_menu (the sidebar builder) reads
-- ric_user_menus (per-USER grants), joined against ric_master_menus (the
-- master feature catalog) — migration 118 only inserted into the latter.
-- A ric_master_menus row alone makes a feature ELIGIBLE to be granted; it
-- grants nobody anything. Every existing user was therefore left with
-- zero visibility into all 3 new reports, silently — fn_get_user_menu
-- has no error path for "feature exists but nobody can see it," it just
-- omits it from the sidebar.
--
-- Fix: grant VIEW access to the 3 new report feature_codes for every
-- user who already has view access to ANY feature in the same module
-- (FN or IN) — "if you can already use Finance, you can now see the new
-- Finance reports too," not a blanket grant to every user in the system.
-- edit_allowed is left false throughout (a report has no edit concept).
-- ============================================================

INSERT INTO ric_user_menus (
    client_id, company_id, user_id, module_id, feature_code, serial_no,
    view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT DISTINCT
    mm.client_id, mm.company_id, existing.user_id, mm.module_id, mm.feature_code, mm.serial_no,
    true, false, mm.approve_allowed, mm.copy_allowed, mm.excel_upload_allowed
FROM ric_master_menus mm
JOIN (
    SELECT DISTINCT user_id, client_id, company_id, module_id
    FROM ric_user_menus
    WHERE view_allowed = true AND is_deleted = false
) existing
    ON  existing.client_id  = mm.client_id
    AND existing.company_id = mm.company_id
    AND existing.module_id  = mm.module_id
WHERE mm.feature_code IN ('FN-RPT-PBR', 'FN-RPT-PBG', 'IN-RPT-SBM')
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
