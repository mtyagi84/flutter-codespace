-- ============================================================
-- Migration 044: seed "Print Templates" menu feature
-- ============================================================
-- Same pattern as 035's Period Close / Backdated Entry Control seed —
-- registers the designer screen (Phase 2 of the print engine) under
-- System Setup. copy_allowed is set at master level here (enabling it to
-- be granted) because "Duplicate Template" is the literal Copy action for
-- this screen.
--
-- Master-level registration alone does NOT grant any user access — as
-- with every other screen, an admin still needs to grant
-- view/add/edit/copy for 'AD-PDT' to specific users via the Users &
-- Permissions screen (fn_upsert_user_permission), same onboarding step
-- Period Close/Backdated Entry Control required when they were added.
-- ============================================================

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    c.id, co.id, sm.id, 'AD-PDT', 'Print Templates', '/setup/print-templates',
    5, 'AD-SETG', 'System Setup', 0,
    false, true, false
FROM ric_companies co
JOIN ric_clients c ON c.id = co.client_id
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'AD'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no,
        copy_allowed    = excluded.copy_allowed;
