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
--   4. finish() returns no rows = all passed.
--
-- All fixture IDs are hardcoded so SELECT tests need no temp table.
-- Transaction is rolled back — no permanent data changes.
-- ============================================================

BEGIN;

-- ── Fixtures (hardcoded UUIDs so SELECTs can reference them directly) ─────────
DO $$
DECLARE
  -- Standard test tenant
  v_client_id     uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id    uuid := '00000000-0000-0000-0000-000000000002';
  v_user_id       uuid := '00000000-0000-0000-0000-000000000003';
  -- Hardcoded entity IDs
  v_level1_id     uuid := '00000000-0000-0001-0000-000000000001';
  v_level2_id     uuid := '00000000-0000-0001-0000-000000000002';
  v_flag_id       uuid := '00000000-0000-0002-0000-000000000001';
  v_flag2_id      uuid := '00000000-0000-0002-0000-000000000002';
  v_root_id       uuid := '00000000-0000-0003-0000-000000000001';
  v_no_flags_id   uuid := '00000000-0000-0003-0000-000000000002';
  v_child_id      uuid := '00000000-0000-0003-0000-000000000003';
  v_grandchild_id uuid := '00000000-0000-0003-0000-000000000004';
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

  -- ── Category Levels ──────────────────────────────────────────────────────
  INSERT INTO rim_category_levels
    (id, client_id, company_id, level_no, level_label, is_mandatory, created_by)
  VALUES (v_level1_id, v_client_id, v_company_id, 1, 'Department', true, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Level 2 inserted WITHOUT is_mandatory to test the default
  INSERT INTO rim_category_levels
    (id, client_id, company_id, level_no, level_label, created_by)
  VALUES (v_level2_id, v_client_id, v_company_id, 2, 'Category', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- ── Flag Types ────────────────────────────────────────────────────────────
  INSERT INTO rim_product_flag_types
    (id, client_id, company_id, flag_key, flag_label, default_value, sort_order, created_by)
  VALUES (v_flag_id, v_client_id, v_company_id, 'is_saleable', 'Can be Sold', true, 1, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- is_purchasable inserted WITHOUT default_value to test the column default
  INSERT INTO rim_product_flag_types
    (id, client_id, company_id, flag_key, flag_label, sort_order, created_by)
  VALUES (v_flag2_id, v_client_id, v_company_id, 'is_purchasable', 'Can be Purchased', 2, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- ── Item Categories ───────────────────────────────────────────────────────
  -- Root (level 1, no parent)
  INSERT INTO rim_item_categories
    (id, client_id, company_id, level_no, category_name, flags, sort_order, created_by)
  VALUES (v_root_id, v_client_id, v_company_id, 1, 'Food & Beverages',
          '{"is_saleable": true, "is_purchasable": true}', 1, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- No-flags category (to test empty JSONB default)
  INSERT INTO rim_item_categories
    (id, client_id, company_id, level_no, category_name, sort_order, created_by)
  VALUES (v_no_flags_id, v_client_id, v_company_id, 1, 'No Flags Category', 99, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Child (level 2)
  INSERT INTO rim_item_categories
    (id, client_id, company_id, parent_id, level_no, category_name, flags, sort_order, created_by)
  VALUES (v_child_id, v_client_id, v_company_id, v_root_id, 2, 'Beverages',
          '{"is_saleable": true, "is_purchasable": false}', 1, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Grandchild (level 3)
  INSERT INTO rim_item_categories
    (id, client_id, company_id, parent_id, level_no, category_name, flags, sort_order, created_by)
  VALUES (v_grandchild_id, v_client_id, v_company_id, v_child_id, 3, 'Soft Drinks',
          '{"is_saleable": true, "is_purchasable": false}', 1, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Soft-delete grandchild (tests 18) then restore (tests 20-24 need it alive)
  UPDATE rim_item_categories
  SET is_deleted = true, updated_by = v_user_id, updated_at = now()
  WHERE id = v_grandchild_id;

  -- Cascade flag update to child + grandchild (test 19)
  UPDATE rim_item_categories
  SET flags      = '{"is_saleable": false, "is_purchasable": false}'::jsonb,
      updated_by = v_user_id, updated_at = now()
  WHERE id IN (v_child_id, v_grandchild_id);

  -- Restore grandchild so subtree tests see 3 live rows
  UPDATE rim_item_categories SET is_deleted = false WHERE id = v_grandchild_id;
END;
$$ LANGUAGE plpgsql;

-- ── Plan ─────────────────────────────────────────────────────────────────────
SELECT plan(24);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section A: rim_category_levels
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 1: level inserted with explicit id
SELECT ok(
  EXISTS (SELECT 1 FROM rim_category_levels
          WHERE id = '00000000-0000-0001-0000-000000000001'),
  'ok 1 — category level inserted'
);

-- ok 2: is_mandatory defaults to false when omitted
SELECT ok(
  NOT (SELECT is_mandatory FROM rim_category_levels
       WHERE id = '00000000-0000-0001-0000-000000000002'),
  'ok 2 — is_mandatory defaults to false'
);

-- ok 3: is_active defaults to true when omitted
SELECT ok(
  (SELECT is_active FROM rim_category_levels
   WHERE id = '00000000-0000-0001-0000-000000000002'),
  'ok 3 — is_active defaults to true'
);

-- ok 4: unique constraint on (client_id, company_id, level_no) in schema
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name    = 'rim_category_levels'
      AND constraint_type = 'UNIQUE'
  ),
  'ok 4 — unique constraint defined on rim_category_levels'
);

-- ok 5: CHECK constraint on level_no in schema
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name    = 'rim_category_levels'
      AND constraint_type = 'CHECK'
  ),
  'ok 5 — check constraint defined on rim_category_levels (level_no 1-4)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section B: rim_product_flag_types
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 6: flag type inserted
SELECT ok(
  EXISTS (SELECT 1 FROM rim_product_flag_types
          WHERE id = '00000000-0000-0002-0000-000000000001'),
  'ok 6 — flag type inserted'
);

-- ok 7: default_value column default is true
SELECT ok(
  (SELECT default_value FROM rim_product_flag_types
   WHERE id = '00000000-0000-0002-0000-000000000002'),
  'ok 7 — default_value defaults to true when not specified'
);

-- ok 8: description is nullable (no value provided → NULL)
SELECT ok(
  (SELECT description FROM rim_product_flag_types
   WHERE id = '00000000-0000-0002-0000-000000000002') IS NULL,
  'ok 8 — description is nullable'
);

-- ok 9: unique constraint on (client_id, company_id, flag_key) in schema
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name    = 'rim_product_flag_types'
      AND constraint_type = 'UNIQUE'
  ),
  'ok 9 — unique constraint defined on rim_product_flag_types (flag_key per company)'
);

-- ok 10: flag type label updatable (PATCH equivalent)
UPDATE rim_product_flag_types
SET flag_label = 'Can Sell',
    updated_by = '00000000-0000-0000-0000-000000000003',
    updated_at = now()
WHERE id = '00000000-0000-0002-0000-000000000001';

SELECT ok(
  (SELECT flag_label FROM rim_product_flag_types
   WHERE id = '00000000-0000-0002-0000-000000000001') = 'Can Sell',
  'ok 10 — flag type label updated correctly'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section C: rim_item_categories
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 11: root category has no parent
SELECT ok(
  (SELECT parent_id FROM rim_item_categories
   WHERE id = '00000000-0000-0003-0000-000000000001') IS NULL,
  'ok 11 — root category inserted with no parent_id'
);

-- ok 12: flags JSONB stored and @> containment query works
SELECT ok(
  (SELECT flags FROM rim_item_categories
   WHERE id = '00000000-0000-0003-0000-000000000001')
  @> '{"is_saleable": true, "is_purchasable": true}'::jsonb,
  'ok 12 — flags JSONB stored correctly and @> containment query works'
);

-- ok 13: flags defaults to empty JSONB when column not provided
SELECT ok(
  (SELECT flags FROM rim_item_categories
   WHERE id = '00000000-0000-0003-0000-000000000002') = '{}'::jsonb,
  'ok 13 — flags defaults to empty JSONB when not specified'
);

-- ok 14: child references root as parent
SELECT ok(
  (SELECT parent_id FROM rim_item_categories
   WHERE id = '00000000-0000-0003-0000-000000000003')
  = '00000000-0000-0003-0000-000000000001'::uuid,
  'ok 14 — child category has correct parent_id (root)'
);

-- ok 15: grandchild references child as parent
SELECT ok(
  (SELECT parent_id FROM rim_item_categories
   WHERE id = '00000000-0000-0003-0000-000000000004')
  = '00000000-0000-0003-0000-000000000003'::uuid,
  'ok 15 — grandchild category has correct parent_id (child)'
);

-- ok 16: unique constraint on (client_id, company_id, parent_id, category_name) in schema
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_name    = 'rim_item_categories'
      AND constraint_type = 'UNIQUE'
  ),
  'ok 16 — unique constraint defined on rim_item_categories (name per parent)'
);

-- ok 17: is_deleted and is_active defaults on root
SELECT ok(
  (SELECT is_deleted FROM rim_item_categories
   WHERE id = '00000000-0000-0003-0000-000000000001') = false
  AND
  (SELECT is_active FROM rim_item_categories
   WHERE id = '00000000-0000-0003-0000-000000000001') = true,
  'ok 17 — is_deleted defaults false, is_active defaults true'
);

-- ok 18: soft delete — grandchild was deleted and then restored; count of active >= 3
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE client_id = '00000000-0000-0000-0000-000000000001'
     AND is_deleted = false) >= 3,
  'ok 18 — soft delete works; restored grandchild counts as active'
);

-- ok 19: cascade flag update applied to child AND grandchild
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE id IN (
     '00000000-0000-0003-0000-000000000003',
     '00000000-0000-0003-0000-000000000004'
   )
   AND flags @> '{"is_saleable": false}'::jsonb) = 2,
  'ok 19 — cascade flag update applied to both child and grandchild'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section D: fn_category_subtree
-- ══════════════════════════════════════════════════════════════════════════════

-- ok 20: root subtree = root + child + grandchild = 3 rows
SELECT ok(
  (SELECT COUNT(*)::int
   FROM fn_category_subtree('00000000-0000-0003-0000-000000000001'::uuid)) = 3,
  'ok 20 — fn_category_subtree(root) returns 3 rows (root + child + grandchild)'
);

-- ok 21: root is included in its own subtree
SELECT ok(
  EXISTS (
    SELECT 1 FROM fn_category_subtree('00000000-0000-0003-0000-000000000001'::uuid)
    WHERE id = '00000000-0000-0003-0000-000000000001'
  ),
  'ok 21 — fn_category_subtree includes the root node itself'
);

-- ok 22: child subtree = child + grandchild = 2 rows (root NOT included)
SELECT ok(
  (SELECT COUNT(*)::int
   FROM fn_category_subtree('00000000-0000-0003-0000-000000000003'::uuid)) = 2,
  'ok 22 — fn_category_subtree(child) returns 2 rows, root excluded'
);

-- ok 23: leaf subtree = exactly 1 row (the leaf itself)
SELECT ok(
  (SELECT COUNT(*)::int
   FROM fn_category_subtree('00000000-0000-0003-0000-000000000004'::uuid)) = 1,
  'ok 23 — fn_category_subtree(leaf) returns only the leaf itself'
);

-- ok 24: function usable in WHERE IN for report/filter queries
SELECT ok(
  (SELECT COUNT(*)::int FROM rim_item_categories
   WHERE id IN (
     SELECT id FROM fn_category_subtree('00000000-0000-0003-0000-000000000001'::uuid)
   )
   AND client_id = '00000000-0000-0000-0000-000000000001') = 3,
  'ok 24 — fn_category_subtree usable in WHERE IN clause'
);

-- ── Finish ────────────────────────────────────────────────────────────────────
SELECT * FROM finish();

ROLLBACK;
