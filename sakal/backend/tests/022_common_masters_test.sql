-- ============================================================
-- 022_common_masters_test.sql — pgTAP tests for rim_common_masters
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste this entire file and run.
--   3. All tests pass → "Success. No rows returned"
--      Any failure   → "not ok N — ..." detail line
--
-- Transaction is rolled back — no permanent data changes.
-- ============================================================

BEGIN;

-- ── Fixtures ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0000-000000000002';
  v_user_id     uuid := '00000000-0000-0000-0000-000000000003';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST CLIENT', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST COMPANY', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test_user', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ── Tests ─────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_client_id  uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id uuid := '00000000-0000-0000-0000-000000000002';
  v_user_id    uuid := '00000000-0000-0000-0000-000000000003';
  v_brand_type_id uuid;
  v_master_id  uuid;
  v_count      int;
BEGIN

  -- ── Test 1: rim_common_master_types seeded correctly ─────────────────────
  SELECT COUNT(*) INTO v_count FROM rim_common_master_types WHERE type_key = 'BRAND';
  PERFORM ok(v_count = 1, 'ok 1 — BRAND type seeded');

  SELECT COUNT(*) INTO v_count FROM rim_common_master_types WHERE type_key = 'UNIT';
  PERFORM ok(v_count = 1, 'ok 2 — UNIT type seeded');

  SELECT COUNT(*) INTO v_count FROM rim_common_master_types WHERE type_key IN ('BRAND','UNIT','ITEM_SIZE','ITEM_TYPE','COLOR');
  PERFORM ok(v_count = 5, 'ok 3 — all 5 types seeded');

  -- ── Test 2: Insert a common master (Brand = Coca-Cola) ────────────────────
  SELECT id INTO v_brand_type_id FROM rim_common_master_types WHERE type_key = 'BRAND';

  INSERT INTO rim_common_masters
    (client_id, company_id, type_id, description, short_name, sort_order, created_by)
  VALUES
    (v_client_id, v_company_id, v_brand_type_id, 'Coca-Cola', 'CC', 1, v_user_id)
  RETURNING id INTO v_master_id;

  SELECT COUNT(*) INTO v_count
  FROM rim_common_masters
  WHERE client_id = v_client_id AND company_id = v_company_id
    AND type_id = v_brand_type_id AND description = 'Coca-Cola' AND is_deleted = false;
  PERFORM ok(v_count = 1, 'ok 4 — brand inserted successfully');

  -- ── Test 3: Upsert idempotency — same description → single row ────────────
  INSERT INTO rim_common_masters
    (client_id, company_id, type_id, description, short_name, sort_order, created_by)
  VALUES
    (v_client_id, v_company_id, v_brand_type_id, 'Coca-Cola', 'CC', 1, v_user_id)
  ON CONFLICT (client_id, company_id, type_id, description)
  DO UPDATE SET short_name = EXCLUDED.short_name, updated_at = now();

  SELECT COUNT(*) INTO v_count
  FROM rim_common_masters
  WHERE client_id = v_client_id AND company_id = v_company_id
    AND type_id = v_brand_type_id AND description = 'Coca-Cola';
  PERFORM ok(v_count = 1, 'ok 5 — upsert idempotent, no duplicate row');

  -- ── Test 4: short_name optional (NULL allowed) ────────────────────────────
  INSERT INTO rim_common_masters
    (client_id, company_id, type_id, description, created_by)
  VALUES
    (v_client_id, v_company_id, v_brand_type_id, 'Pepsi', v_user_id);

  SELECT COUNT(*) INTO v_count
  FROM rim_common_masters
  WHERE description = 'Pepsi' AND short_name IS NULL;
  PERFORM ok(v_count = 1, 'ok 6 — short_name nullable');

  -- ── Test 5: Soft delete — is_deleted=true excluded from active queries ────
  UPDATE rim_common_masters
  SET is_deleted = true, is_active = false, updated_by = v_user_id, updated_at = now()
  WHERE id = v_master_id;

  SELECT COUNT(*) INTO v_count
  FROM rim_common_masters
  WHERE client_id = v_client_id AND company_id = v_company_id
    AND type_id = v_brand_type_id AND is_deleted = false;
  PERFORM ok(v_count = 1, 'ok 7 — soft-deleted row excluded, Pepsi still active');

  -- ── Test 6: sort_order defaults to 0 ─────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM rim_common_masters
  WHERE description = 'Pepsi' AND sort_order = 0;
  PERFORM ok(v_count = 1, 'ok 8 — sort_order defaults to 0');

  -- ── Test 7: Unique constraint prevents duplicate description per type ──────
  BEGIN
    INSERT INTO rim_common_masters (client_id, company_id, type_id, description, created_by)
    VALUES (v_client_id, v_company_id, v_brand_type_id, 'Pepsi', v_user_id);
    PERFORM ok(false, 'ok 9 — unique constraint should have fired');
  EXCEPTION WHEN unique_violation THEN
    PERFORM ok(true, 'ok 9 — unique constraint prevents duplicate description per type');
  END;

END;
$$ LANGUAGE plpgsql;

ROLLBACK;
