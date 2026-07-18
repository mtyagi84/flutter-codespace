-- ============================================================
-- Migration 095: Seed menu rows for the remaining 9 Master screens
-- that had no ric_master_menus row -- same gap as MST-CUST/MST-SUPP
-- (migration 092), found while scoping the design-system rollout to
-- the rest of the Masters module. Same fix shape: fn_seed_client_modules.sql
-- updated for future clients, this migration backfills existing ones.
-- ============================================================
-- Excluded on purpose (both are detail/edit screens reached via extra
-- params from a list screen already in this batch, not standalone menu
-- targets -- same Menu->List->Entry convention as product-entry, which
-- also has no row of its own): /master/account-link-configure and
-- /master/product-entry.
--
-- IMPORTANT: as with migration 092, adding these rows alone does not
-- grant any existing user access -- re-run fn_grant_admin_access
-- (user_id, client_id, company_id) for whichever user(s) should see
-- these screens (idempotent, safe to re-run).
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
    ('MST-COA', 'Chart of Accounts',  '/master/accounts',            2),
    ('MST-ITC', 'Item Categories',    '/master/item-categories',     3),
    ('MST-CMN', 'Common Masters',     '/master/common-masters',      4),
    ('MST-TAX', 'Tax Master',         '/master/tax-master',          5),
    ('MST-TXG', 'Tax Groups',         '/master/tax-groups',          6),
    ('MST-CHG', 'Additional Charges', '/master/additional-charges',  7),
    ('MST-ALS', 'Account Link Setup', '/master/account-link-setup',  8),
    ('MST-IAL', 'Item Account Links', '/master/item-account-links',  9),
    ('MST-PRD', 'Product Master',     '/master/products',           10)
) AS v(feature_code, feature_name, screen_name, serial_no)
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
