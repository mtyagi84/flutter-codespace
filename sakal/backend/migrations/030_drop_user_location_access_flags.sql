-- ============================================================
-- 030_drop_user_location_access_flags.sql
-- can_view / can_transact were removed from 029_user_location_access.sql
-- before other code depended on them — screen permissions
-- (ric_master_menus) already govern add/edit/view/approve rights.
-- This table only scopes which locations a user is restricted to.
-- ============================================================

ALTER TABLE ric_user_location_access
    DROP COLUMN IF EXISTS can_view,
    DROP COLUMN IF EXISTS can_transact;
