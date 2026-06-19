-- ============================================================
-- 001_permissions_fn_test.sql — pgTAP tests for permission functions
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. Make sure pgTAP extension is enabled:
--        CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste this entire file into the SQL Editor and run.
--   3. All lines in the results should show "ok N — …"
--      Any "not ok" line is a failure — read the description.
--
-- These tests use a throwaway client/company UUID so they never
-- touch real data. The transaction is rolled back at the end.
-- ============================================================

BEGIN;

SELECT plan(18);   -- update this number if you add more tests

-- ── Fixtures ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_client_id  uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id uuid := '00000000-0000-0000-0000-000000000002';
  v_user_id    uuid := '00000000-0000-0000-0000-000000000003';
  v_module_id  uuid := '00000000-0000-0000-0000-000000000004';
BEGIN
  -- Insert minimal fixture data needed for the functions to return rows.
  -- Adjust table names / columns if your schema differs slightly.

  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name, serial_no, is_active, is_deleted, created_at, created_by)
  VALUES (v_module_id, v_client_id, v_company_id, 'TEST_MOD', 'Test Module', 1, true, false, now(), v_user_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, group_code, group_name, group_serial_no, serial_no, approve_allowed, copy_allowed, excel_upload_allowed, is_active, is_deleted, created_at, created_by)
  VALUES (v_client_id, v_company_id, v_module_id, 'TEST_FEAT', 'Test Feature', 'testScreen', 'GRP1', 'Group 1', 1, 1, true, true, true, true, false, now(), v_user_id)
  ON CONFLICT DO NOTHING;
END;
$$;

-- ── fn_upsert_user_permission ─────────────────────────────────────────────────

SELECT ok(
  (SELECT COUNT(*) = 0 FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'),
  '01 — no permission row exists before upsert'
);

SELECT fn_upsert_user_permission(
  '00000000-0000-0000-0000-000000000001'::uuid,
  '00000000-0000-0000-0000-000000000002'::uuid,
  '00000000-0000-0000-0000-000000000003'::uuid,
  '00000000-0000-0000-0000-000000000004'::uuid,
  'TEST_FEAT',
  true,   -- view
  true,   -- add
  false,  -- edit
  false,  -- approve
  false,  -- copy
  false   -- excel
);

SELECT ok(
  (SELECT COUNT(*) = 1 FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'),
  '02 — permission row created after first upsert'
);

SELECT ok(
  (SELECT view_allowed FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'),
  '03 — view_allowed stored as true'
);

SELECT ok(
  (SELECT add_allowed FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'),
  '04 — add_allowed stored as true'
);

SELECT ok(
  NOT (SELECT edit_allowed FROM ric_user_menus
       WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
         AND feature_code = 'TEST_FEAT'),
  '05 — edit_allowed stored as false'
);

-- Upsert again — should UPDATE, not INSERT a duplicate
SELECT fn_upsert_user_permission(
  '00000000-0000-0000-0000-000000000001'::uuid,
  '00000000-0000-0000-0000-000000000002'::uuid,
  '00000000-0000-0000-0000-000000000003'::uuid,
  '00000000-0000-0000-0000-000000000004'::uuid,
  'TEST_FEAT',
  true, false, true, false, false, false  -- flip: add OFF, edit ON
);

SELECT ok(
  (SELECT COUNT(*) = 1 FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'),
  '06 — upsert does not create a duplicate row'
);

SELECT ok(
  NOT (SELECT add_allowed FROM ric_user_menus
       WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
         AND feature_code = 'TEST_FEAT'),
  '07 — add_allowed updated to false on second upsert'
);

SELECT ok(
  (SELECT edit_allowed FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'),
  '08 — edit_allowed updated to true on second upsert'
);

-- ── fn_get_user_permissions ───────────────────────────────────────────────────

SELECT ok(
  (SELECT COUNT(*) >= 1
   FROM fn_get_user_permissions(
     '00000000-0000-0000-0000-000000000003'::uuid,
     '00000000-0000-0000-0000-000000000001'::uuid,
     '00000000-0000-0000-0000-000000000002'::uuid
   )),
  '09 — fn_get_user_permissions returns at least one row'
);

SELECT ok(
  (SELECT feature_code = 'TEST_FEAT'
   FROM fn_get_user_permissions(
     '00000000-0000-0000-0000-000000000003'::uuid,
     '00000000-0000-0000-0000-000000000001'::uuid,
     '00000000-0000-0000-0000-000000000002'::uuid
   ) LIMIT 1),
  '10 — returned row has correct feature_code'
);

SELECT ok(
  (SELECT view_allowed
   FROM fn_get_user_permissions(
     '00000000-0000-0000-0000-000000000003'::uuid,
     '00000000-0000-0000-0000-000000000001'::uuid,
     '00000000-0000-0000-0000-000000000002'::uuid
   ) WHERE feature_code = 'TEST_FEAT'),
  '11 — fn_get_user_permissions reflects view_allowed = true'
);

SELECT ok(
  NOT (SELECT add_allowed
       FROM fn_get_user_permissions(
         '00000000-0000-0000-0000-000000000003'::uuid,
         '00000000-0000-0000-0000-000000000001'::uuid,
         '00000000-0000-0000-0000-000000000002'::uuid
       ) WHERE feature_code = 'TEST_FEAT'),
  '12 — fn_get_user_permissions reflects add_allowed = false'
);

SELECT ok(
  (SELECT edit_allowed
   FROM fn_get_user_permissions(
     '00000000-0000-0000-0000-000000000003'::uuid,
     '00000000-0000-0000-0000-000000000001'::uuid,
     '00000000-0000-0000-0000-000000000002'::uuid
   ) WHERE feature_code = 'TEST_FEAT'),
  '13 — fn_get_user_permissions reflects edit_allowed = true'
);

-- A user with no rows at all should return COALESCE defaults (false)
SELECT ok(
  NOT (SELECT add_allowed
       FROM fn_get_user_permissions(
         '00000000-0000-0000-ffff-000000000000'::uuid,  -- unknown user
         '00000000-0000-0000-0000-000000000001'::uuid,
         '00000000-0000-0000-0000-000000000002'::uuid
       ) WHERE feature_code = 'TEST_FEAT'),
  '14 — unknown user gets add_allowed = false (COALESCE default)'
);

-- ── fn_copy_user_permissions ──────────────────────────────────────────────────

-- Give source user full permissions first
SELECT fn_upsert_user_permission(
  '00000000-0000-0000-0000-000000000001'::uuid,
  '00000000-0000-0000-0000-000000000002'::uuid,
  '00000000-0000-0000-ffff-000000000001'::uuid,   -- source user
  '00000000-0000-0000-0000-000000000004'::uuid,
  'TEST_FEAT', true, true, true, false, false, false
);

SELECT fn_copy_user_permissions(
  '00000000-0000-0000-ffff-000000000001'::uuid,   -- from (source)
  '00000000-0000-0000-0000-000000000003'::uuid,   -- to (our test user)
  '00000000-0000-0000-0000-000000000001'::uuid,
  '00000000-0000-0000-0000-000000000002'::uuid
);

SELECT ok(
  (SELECT add_allowed
   FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'
     AND is_deleted = false),
  '15 — copy_user_permissions copies add_allowed = true from source'
);

SELECT ok(
  (SELECT edit_allowed
   FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'
     AND is_deleted = false),
  '16 — copy_user_permissions copies edit_allowed = true from source'
);

SELECT ok(
  (SELECT COUNT(*) = 1
   FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'
     AND is_deleted = false),
  '17 — copy produces exactly one active row (no duplicates)'
);

SELECT ok(
  (SELECT COUNT(*) >= 1
   FROM ric_user_menus
   WHERE user_id = '00000000-0000-0000-0000-000000000003'::uuid
     AND feature_code = 'TEST_FEAT'
     AND is_deleted = true),
  '18 — copy soft-deletes previous rows before inserting new ones'
);

-- ── Finish ────────────────────────────────────────────────────────────────────

SELECT * FROM finish();

ROLLBACK;   -- all fixture data discarded — production tables untouched
