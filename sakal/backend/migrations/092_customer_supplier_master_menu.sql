-- ============================================================
-- Migration 092: Seed 'MST-CUST' (Customer Master) and 'MST-SUPP'
-- (Supplier Master) menu items for every already-existing company
-- ============================================================
-- Both screens (lib/features/master/presentation/screens/customer_
-- master_screen.dart, supplier_master_screen.dart) and their routes
-- (/master/customers, /master/suppliers) have existed since early in
-- the build, but were never wired into ric_master_menus -- with no
-- menu row, fn_get_user_menu never returns them, so no user could
-- ever reach either screen from the sidebar (only a typed-in URL
-- worked). fn_seed_client_modules has been updated to include both
-- for FUTURE new clients (new 'Master Data' group under Administration,
-- group_serial_no=2, after 'System Setup'=0 and 'User Management'=1),
-- but that function only runs once, at fn_register_client time --
-- existing companies need these rows inserted directly, same pattern
-- migration 062 used for PR-RET.
--
-- IMPORTANT: adding these rows to ric_master_menus alone does not
-- grant any existing user access -- fn_get_user_menu requires a
-- matching ric_user_menus row with view_allowed=true, and existing
-- users have none for these brand-new feature codes. After running
-- this migration, re-run fn_grant_admin_access(user_id, client_id,
-- company_id) for whichever user(s) should see these screens (it is
-- idempotent -- safe to re-run), or grant access manually via the
-- User Permissions screen.
-- ============================================================

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, v.feature_code, v.feature_name, v.screen_name,
    v.serial_no, 'AD-MSTG', 'Master Data', 2,
    false, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'AD'
CROSS JOIN (VALUES
    ('MST-CUST', 'Customer Master', '/master/customers', 0),
    ('MST-SUPP', 'Supplier Master', '/master/suppliers', 1)
) AS v(feature_code, feature_name, screen_name, serial_no)
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
