-- ============================================================
-- Migration 062: Seed 'PR-RET' (Purchase Return) menu item for every
-- already-existing company
-- ============================================================
-- fn_seed_client_modules (backend/functions/fn_seed_client_modules.sql) has
-- been updated to include PR-RET for FUTURE new clients, but that function
-- only runs once, at fn_register_client time — existing companies need
-- this new row inserted directly, same pattern migration 035 used for
-- AD-PDC/AD-BDC.
-- ============================================================

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'PR-RET', 'Purchase Return', '/purchase/returns',
    3, 'PR-TXN', 'Transactions', 0,
    true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'PR'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
