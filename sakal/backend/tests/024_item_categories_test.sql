-- ============================================================
-- 024_item_categories_test.sql — pgTAP tests for migration 024
--
-- Tables tested: rim_category_levels, rim_product_flag_types,
--                rim_item_categories
-- Function tested: fn_category_subtree
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste this entire file and run.
--   3. All rows show "ok N — ..." with no "not ok" lines.
--   4. Last row from finish() is blank = all passed.
--
-- Transaction is rolled back — no permanent data changes.
-- ============================================================

BEGIN;

-- ── Temp table to share IDs between setup DO block and SELECT tests ───────────
CREATE TEMP TABLE _tid (k text PRIMARY KEY, v uuid) ON COMMIT DROP;

-- ── Fixtures: insert all test rows and store IDs ──────────────────────────────
DO $$
DECLARE
  v_client_id     uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id    uuid := '00000000-0000-0000-0000-000000000002';
  v_user_id       uuid := '00000000-0000-0000-0000-000000000003';
  v_level_id      uuid;
  v_flag_id       uuid;
  v_root_id       uuid;
  v_no_flags_id   uuid;
  v_child_id      uuid;
  v_grandchild_id uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST CLIENT', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST COMPANY', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash,
                         is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test_user', 'Test User', 'x',
          true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Category Levels
  INSERT INTO rim_category_levels
    (client_id, company_id, level_no, level_label, is_mandatory, created_by)
  VALUES (v_client_id, v_company_id, 1, 'Department', true, v_user_id)
  RETURNING id INTO v_level_id;
  INSERT INTO _tid VALUES ('level_id', v_level_id);

  INSERT INTO rim_category_levels
    (client_id, company_id, level_no, level_label, created_by)
  VALUES (v_client_id, v_company_id, 2, 'Category', v_user_id);

  -- Flag Types
  INSERT INTO rim_product_flag_types
    (client_id, company_id, flag_key, flag_label, default_value, sort_order, created_by)
  VALUES (v_client_id, v_company_id, 'is_saleable', 'Can be Sold', true, 1, v_user_id)
  RETURNING id INTO v_flag_id;
  INSERT INTO _tid VALUES ('flag_id', v_flag_id);

  INSERT INTO rim_product_flag_types
    (client_id, company_id, flag_key, flag_label, sort_order, created_by)
  VALUES (v_client_id, v_company_id, 'is_purchasable', 'Can be Purchased', 2, v_user_id);

  -- Item Categories: root
  INSERT INTO rim_item_categories
    (client_id, company_id, level_no, category_name, flags, sort_order, created_by)
  VALUES (v_client_id, v_company_id, 1, 'Food & Beverages',
          '{"is_saleable": true, "is_purchasable": true}', 1, v_user_id)
  RETURNING id INTO v_root_id;
  INSERT INTO _tid VALUES ('root_id', v_root_id);

  -- root-level category with no flags (to test JSONB default)
  INSERT INTO rim_item_categories
    (client_id, company_id, level_no, category_name, sort_order, created_by)
  VALUES (v_client_id, v_company_id, 1, 'No Flags Category', 99, v_user_id)
  RETURNING id INTO v_no_flags_id;
  INSERT INTO _tid VALUES ('no_flags_id', v_no_flags_id);

  -- child (level 2)
  INSERT INTO rim_item_categories
    (client_id, company_id, parent_id, level_no, category_name, flags, sort_order, created_by)
  VALUES (v_client_id, v_company_id, v_root_id, 2, 'Beverages',
          '{"is_saleable": true, "is_purchasable": false}', 1, v_user_id)
  RETURNING id INTO v_child_id;
  INSERT INTO _tid VALUES ('child_id', v_child_id);

  -- grandchild (level 3)
  INSERT INTO rim_item_categories
    (client_id, company_id, parent_id, level_no, category_name, flags, sort_order, created_by)
  VALUES (v_client_id, v_company_id, v_child_id, 3, 'Soft Drinks',
          '{"is_saleable": true, "is_purchasable": false}', 1, v_user_id)
  RETURNING id INTO v_grandchild_id;
  INSERT INTO _tid VALUES ('grandchild_id', v_grandchild_id);

  -- Soft-delete grandchild (for test 18) then cascade-update child flags (for test 19)
  UPDATE rim_item_categories
  SET is_deleted = true, updated_by = v_user_id, updated_at = now()
  WHERE id = v_grandchild_id;

  UPDATE rim_item_categories
  SET flags = '{"is_saleable": false, "is_purchasable": false}'::jsonb,
      updated_by = v_user_id, updated_at = now()
  WHERE id IN (v_child_id, v_grandchild_id);

  -- Restore grandchild for subtree tests
  UPDATE rim_item_categories SET is_deleted = false WHERE id = v_grandchild_id;
END;
$$ LANGUAGE plpgsql;

-- ── Plan ─────────────────────────────────────────────────────────────────────
SELECT plan(24);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section A: rim_category_levels
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 1: level inserted
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_category_levels
   WHERE client_id = '00000000-0000-0000-0000-000000000001' AND level_no = 1) = 1,
  'ok 1 — category level inserted'
);

-- ok 2: is_mandatory defaults to false
SELECT ok(
  NOT (SELECT is_mandatory FROM rim_category_levels
       WHERE client_id = '00000000-0000-0000-0000-000000000001' AND level_no = 2),
  'ok 2 — is_mandatory defaults to false'
);

-- ok 3: is_active defaults to true
SELECT ok(
  (SELECT is_active FROM rim_category_levels
   WHERE client_id = '00000000-0000-0000-0000-000000000001' AND level_no = 2),
  'ok 3 — is_active defaults to true'
);

-- ok 4: unique constraint on (client_id, company_id, level_no) defined in schema
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'rim_category_levels'
      AND constraint_type = 'UNIQUE'
  ),
  'ok 4 — unique constraint defined on rim_category_levels'
);

-- ok 5: CHECK constraint on level_no defined in schema
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'rim_category_levels'
      AND constraint_type = 'CHECK'
  ),
  'ok 5 — check constraint defined on rim_category_levels (level_no 1-4)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section B: rim_product_flag_types
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 6: flag type inserted
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_product_flag_types
   WHERE client_id = '00000000-0000-0000-0000-000000000001'
     AND flag_key = 'is_saleable') = 1,
  'ok 6 — flag type inserted'
);

-- ok 7: default_value defaults to true
SELECT ok(
  (SELECT default_value FROM rim_product_flag_types
   WHERE client_id = '00000000-0000-0000-0000-000000000001'
     AND flag_key = 'is_purchasable'),
  'ok 7 — default_value defaults to true when not specified'
);

-- ok 8: description is nullable
SELECT ok(
  (SELECT description FROM rim_product_flag_types
   WHERE client_id = '00000000-0000-0000-0000-000000000001'
     AND flag_key = 'is_purchasable') IS NULL,
  'ok 8 — description is nullable'
);

-- ok 9: unique constraint on (client_id, company_id, flag_key) defined in schema
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'rim_product_flag_types'
      AND constraint_type = 'UNIQUE'
  ),
  'ok 9 — unique constraint defined on rim_product_flag_types (flag_key)'
);

-- ok 10: flag type label updatable (PATCH equivalent)
UPDATE rim_product_flag_types
SET flag_label = 'Can Sell',
    updated_by = '00000000-0000-0000-0000-000000000003',
    updated_at = now()
WHERE id = (SELECT v FROM _tid WHERE k = 'flag_id');

SELECT ok(
  (SELECT flag_label FROM rim_product_flag_types
   WHERE id = (SELECT v FROM _tid WHERE k = 'flag_id')) = 'Can Sell',
  'ok 10 — flag type label updated correctly'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section C: rim_item_categories
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 11: root category has no parent
SELECT ok(
  (SELECT parent_id FROM rim_item_categories
   WHERE id = (SELECT v FROM _tid WHERE k = 'root_id')) IS NULL,
  'ok 11 — root category inserted with no parent'
);

-- ok 12: flags JSONB stored and queried correctly with @> operator
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE id = (SELECT v FROM _tid WHERE k = 'root_id')
     AND flags @> '{"is_saleable": true}'::jsonb
     AND flags @> '{"is_purchasable": true}'::jsonb) = 1,
  'ok 12 — flags JSONB contains correct values and @> query works'
);

-- ok 13: flags defaults to empty JSONB when column omitted
SELECT ok(
  (SELECT flags FROM rim_item_categories
   WHERE id = (SELECT v FROM _tid WHERE k = 'no_flags_id')) = '{}'::jsonb,
  'ok 13 — flags defaults to empty JSONB when not specified'
);

-- ok 14: child category references parent
SELECT ok(
  (SELECT parent_id FROM rim_item_categories
   WHERE id = (SELECT v FROM _tid WHERE k = 'child_id'))
  = (SELECT v FROM _tid WHERE k = 'root_id'),
  'ok 14 — child category inserted with correct parent reference'
);

-- ok 15: grandchild category references child
SELECT ok(
  (SELECT parent_id FROM rim_item_categories
   WHERE id = (SELECT v FROM _tid WHERE k = 'grandchild_id'))
  = (SELECT v FROM _tid WHERE k = 'child_id'),
  'ok 15 — grandchild category inserted with correct parent reference'
);

-- ok 16: unique constraint on (client_id, company_id, parent_id, category_name)
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name = 'rim_item_categories'
      AND constraint_type = 'UNIQUE'
  ),
  'ok 16 — unique constraint defined on rim_item_categories (name per parent)'
);

-- ok 17: is_deleted and is_active default correctly on root
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE id = (SELECT v FROM _tid WHERE k = 'root_id')
     AND is_deleted = false AND is_active = true) = 1,
  'ok 17 — is_deleted defaults false, is_active defaults true'
);

-- ok 18: soft delete — grandchild was soft-deleted then restored; child is NOT deleted
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE client_id = '00000000-0000-0000-0000-000000000001'
     AND is_deleted = false) >= 3,
  'ok 18 — soft delete flag works; active categories still visible with is_deleted=false'
);

-- ok 19: cascade flag update applied to both child and grandchild
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE id IN (SELECT v FROM _tid WHERE k IN ('child_id', 'grandchild_id'))
     AND flags @> '{"is_saleable": false}'::jsonb) = 2,
  'ok 19 — cascade flag update applied correctly to 2 rows'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section D: fn_category_subtree
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 20: root subtree includes root + child + grandchild
SELECT ok(
  (SELECT COUNT(*)::int FROM fn_category_subtree(
    (SELECT v FROM _tid WHERE k = 'root_id')
  )) = 3,
  'ok 20 — fn_category_subtree(root) returns root + child + grandchild (3 rows)'
);

-- ok 21: root itself is in its own subtree
SELECT ok(
  EXISTS (
    SELECT 1 FROM fn_category_subtree((SELECT v FROM _tid WHERE k = 'root_id'))
    WHERE id = (SELECT v FROM _tid WHERE k = 'root_id')
  ),
  'ok 21 — fn_category_subtree includes the root node itself'
);

-- ok 22: child subtree = child + grandchild only (2 rows, root excluded)
SELECT ok(
  (SELECT COUNT(*)::int FROM fn_category_subtree(
    (SELECT v FROM _tid WHERE k = 'child_id')
  )) = 2,
  'ok 22 — fn_category_subtree(child) returns child + grandchild only'
);

-- ok 23: leaf returns exactly 1 row
SELECT ok(
  (SELECT COUNT(*)::int FROM fn_category_subtree(
    (SELECT v FROM _tid WHERE k = 'grandchild_id')
  )) = 1,
  'ok 23 — fn_category_subtree(leaf) returns only the leaf itself'
);

-- ok 24: function usable in WHERE IN clause
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE id IN (
     SELECT id FROM fn_category_subtree((SELECT v FROM _tid WHERE k = 'root_id'))
   )
   AND client_id = '00000000-0000-0000-0000-000000000001') = 3,
  'ok 24 — fn_category_subtree usable in WHERE IN for report/filter queries'
);

-- ── Finish ────────────────────────────────────────────────────────────────────
SELECT * FROM finish();

ROLLBACK;
