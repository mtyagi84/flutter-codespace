-- ============================================================
-- 026_product_master_test.sql — pgTAP tests for migration 026
--
-- Tables tested: rim_products, rim_product_uom, rim_product_location
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. All rows show "ok N — ..." with no "not ok" lines.
--   4. finish() returns no rows = all passed.
--
-- Hardcoded fixture UUIDs — no temp tables (Supabase auto-commits DO blocks).
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  -- Tenant (reuse standard test fixtures)
  v_client_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_company_id uuid := '00000000-0000-0000-0001-000000000002';
  v_user_id    uuid := '00000000-0000-0000-0001-000000000003';
  v_location_id uuid := '00000000-0000-0000-0001-000000000010';

  -- Products
  v_prod1  uuid := '00000000-0000-0026-0000-000000000001';  -- TRADING product
  v_prod2  uuid := '00000000-0000-0026-0000-000000000002';  -- SERVICE product
  v_prod3  uuid := '00000000-0000-0026-0000-000000000003';  -- BATCH_WITH_EXPIRY tracking
  v_prod4  uuid := '00000000-0000-0026-0000-000000000004';  -- for uniqueness test
  v_prod5  uuid := '00000000-0000-0026-0000-000000000005';  -- for update test

  -- UOM rows (rim_product_uom's own id)
  v_uom1   uuid := '00000000-0000-0026-0001-000000000001';
  v_uom2   uuid := '00000000-0000-0026-0001-000000000002';

  -- Actual UOM master rows (rim_common_masters, type_key='UNIT') that
  -- v_uom1/v_uom2 point at via uom_id — previously this fixture mistakenly
  -- pointed uom_id at v_prod1 (the product's own id) and never created a
  -- real UOM row at all, which only surfaced once the FK was enforced.
  v_uom_piece_id  uuid := '00000000-0000-0026-0003-000000000001';
  v_uom_carton_id uuid := '00000000-0000-0026-0003-000000000002';
  v_unit_type_id  uuid;

  -- Location stock row
  v_loc1   uuid := '00000000-0000-0026-0002-000000000001';
BEGIN
  -- Tenant base rows (ON CONFLICT DO NOTHING — may exist from other test files)
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST CO', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name,
                         password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test', 'Test User',
          'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name,
                              is_active, is_deleted, created_at)
  VALUES (v_location_id, v_client_id, v_company_id, 'Main Store',
          true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Product 1 — minimal TRADING product
  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, created_by)
  VALUES (v_prod1, v_client_id, v_company_id, 'PRD-00001', 'Widget A', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Product 2 — SERVICE nature
  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name,
                             product_nature, created_by)
  VALUES (v_prod2, v_client_id, v_company_id, 'SRV-00001', 'Consulting Service',
          'SERVICE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Product 3 — batch + expiry tracking, custom costs
  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name,
                             product_nature, tracking_type,
                             standard_cost, average_cost, last_purchase_cost,
                             is_scalable, sort_order, created_by)
  VALUES (v_prod3, v_client_id, v_company_id, 'FMG-00001', 'Milk 1L',
          'TRADING', 'BATCH_WITH_EXPIRY',
          2.5000, 2.4800, 2.3000,
          true, 10, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Product 5 — for update test
  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, created_by)
  VALUES (v_prod5, v_client_id, v_company_id, 'PRD-00005', 'Update Me', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Real UOM master rows — uom_id on rim_product_uom is a real FK to
  -- rim_common_masters (type_key='UNIT'), not to rim_products.
  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';

  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES
    (v_uom_piece_id,  v_client_id, v_company_id, v_unit_type_id, 'Piece026',  v_user_id),
    (v_uom_carton_id, v_client_id, v_company_id, v_unit_type_id, 'Carton026', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- UOM levels for product 1
  INSERT INTO rim_product_uom (id, client_id, company_id, product_id,
                                uom_id, conversion_factor, is_base_uom,
                                is_purchase_uom, is_sales_uom, sort_order, created_by)
  VALUES (v_uom1, v_client_id, v_company_id, v_prod1,
          v_uom_piece_id, 1.0, true, true, true, 1, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_product_uom (id, client_id, company_id, product_id,
                                uom_id, conversion_factor, is_base_uom,
                                is_purchase_uom, is_sales_uom, sort_order, created_by)
  VALUES (v_uom2, v_client_id, v_company_id, v_prod1,
          v_uom_carton_id, 12.0, false, true, false, 2, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Location stock for product 1
  INSERT INTO rim_product_location (id, client_id, company_id, location_id, product_id,
                                     current_stock, cost_price, created_by)
  VALUES (v_loc1, v_client_id, v_company_id, v_location_id, v_prod1,
          100.000, 2.5000, v_user_id)
  ON CONFLICT (id) DO NOTHING;
END $$ LANGUAGE plpgsql;

-- ── Tests ─────────────────────────────────────────────────────────────────────
SELECT plan(14);

-- 1. Product 1 exists
SELECT ok(
  EXISTS(SELECT 1 FROM rim_products WHERE id = '00000000-0000-0026-0000-000000000001'),
  'ok 1 — PRD-00001 Widget A inserted'
);

-- 2. Default values: is_active=true, is_deleted=false, tracking_type=NONE, product_nature=TRADING
SELECT ok(
  EXISTS(
    SELECT 1 FROM rim_products
    WHERE id = '00000000-0000-0026-0000-000000000001'
      AND is_active      = true
      AND is_deleted     = false
      AND tracking_type  = 'NONE'
      AND product_nature = 'TRADING'
      AND standard_cost  = 0
      AND sort_order     = 0
      AND flags          = '{}'::jsonb
  ),
  'ok 2 — default values correct (is_active, is_deleted, tracking_type, standard_cost, flags)'
);

-- 3. SERVICE product inserted
SELECT ok(
  EXISTS(SELECT 1 FROM rim_products
         WHERE id = '00000000-0000-0026-0000-000000000002'
           AND product_nature = 'SERVICE'),
  'ok 3 — SERVICE nature product inserted'
);

-- 4. BATCH_WITH_EXPIRY tracking + custom costs
SELECT ok(
  EXISTS(
    SELECT 1 FROM rim_products
    WHERE id             = '00000000-0000-0026-0000-000000000003'
      AND tracking_type  = 'BATCH_WITH_EXPIRY'
      AND standard_cost  = 2.5000
      AND average_cost   = 2.4800
      AND last_purchase_cost = 2.3000
      AND is_scalable    = true
      AND sort_order     = 10
  ),
  'ok 4 — BATCH_WITH_EXPIRY product with custom costs'
);

-- 5. Uniqueness constraint: duplicate (client, company, product_code) is rejected
SELECT throws_ok(
  $$INSERT INTO rim_products (id, client_id, company_id, product_code, product_name)
    VALUES ('00000000-0000-0026-0000-000000000004',
            '00000000-0000-0000-0001-000000000001',
            '00000000-0000-0000-0001-000000000002',
            'PRD-00001',
            'Duplicate Code')$$,
  '23505',
  NULL,
  'ok 5 — duplicate (client_id, company_id, product_code) raises unique violation'
);

-- 6. product_nature CHECK — invalid value rejected
SELECT throws_ok(
  $$INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, product_nature)
    VALUES ('00000000-0000-0026-0000-000000000099',
            '00000000-0000-0000-0001-000000000001',
            '00000000-0000-0000-0001-000000000002',
            'BAD-001', 'Bad Product', 'INVALID_NATURE')$$,
  '23514',
  NULL,
  'ok 6 — invalid product_nature rejected by CHECK constraint'
);

-- 7. tracking_type CHECK — invalid value rejected
SELECT throws_ok(
  $$INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, tracking_type)
    VALUES ('00000000-0000-0026-0000-000000000098',
            '00000000-0000-0000-0001-000000000001',
            '00000000-0000-0000-0001-000000000002',
            'BAD-002', 'Bad Track', 'RFID')$$,
  '23514',
  NULL,
  'ok 7 — invalid tracking_type rejected by CHECK constraint'
);

-- 8. UPDATE (PATCH equivalent) product works
DO $$
BEGIN
  UPDATE rim_products
  SET product_name = 'Updated Name',
      standard_cost = 9.9900,
      updated_at   = now()
  WHERE id = '00000000-0000-0026-0000-000000000005';
END $$ LANGUAGE plpgsql;

SELECT ok(
  EXISTS(SELECT 1 FROM rim_products
         WHERE id = '00000000-0000-0026-0000-000000000005'
           AND product_name  = 'Updated Name'
           AND standard_cost = 9.9900),
  'ok 8 — product name and cost updated successfully'
);

-- 9. JSONB flags update works
DO $$
BEGIN
  UPDATE rim_products
  SET flags = '{"is_saleable": true, "is_purchasable": true}'::jsonb
  WHERE id = '00000000-0000-0026-0000-000000000001';
END $$ LANGUAGE plpgsql;

SELECT ok(
  EXISTS(SELECT 1 FROM rim_products
         WHERE id    = '00000000-0000-0026-0000-000000000001'
           AND flags = '{"is_saleable": true, "is_purchasable": true}'::jsonb),
  'ok 9 — flags JSONB column updated correctly'
);

-- 10. rim_product_uom base UOM exists for product 1
SELECT ok(
  EXISTS(SELECT 1 FROM rim_product_uom
         WHERE product_id  = '00000000-0000-0026-0000-000000000001'
           AND is_base_uom = true
           AND conversion_factor = 1.0),
  'ok 10 — base UOM row inserted for product 1'
);

-- 11. rim_product_uom second UOM (case UOM) has correct conversion factor
SELECT ok(
  EXISTS(SELECT 1 FROM rim_product_uom
         WHERE product_id       = '00000000-0000-0026-0000-000000000001'
           AND is_base_uom      = false
           AND conversion_factor = 12.0),
  'ok 11 — case UOM with conversion_factor=12 inserted'
);

-- 12. rim_product_uom count for product 1
SELECT is(
  (SELECT count(*)::int FROM rim_product_uom
   WHERE product_id = '00000000-0000-0026-0000-000000000001'),
  2,
  'ok 12 — exactly 2 UOM rows for product 1'
);

-- 13. rim_product_location stock row inserted
SELECT ok(
  EXISTS(SELECT 1 FROM rim_product_location
         WHERE product_id    = '00000000-0000-0026-0000-000000000001'
           AND location_id   = '00000000-0000-0000-0001-000000000010'
           AND current_stock = 100.000
           AND cost_price    = 2.5000),
  'ok 13 — location stock row inserted with correct quantities'
);

-- 14. is_deleted soft-delete works and is filterable
DO $$
BEGIN
  UPDATE rim_products
  SET is_deleted = true, updated_at = now()
  WHERE id = '00000000-0000-0026-0000-000000000002';
END $$ LANGUAGE plpgsql;

SELECT ok(
  NOT EXISTS(SELECT 1 FROM rim_products
             WHERE id = '00000000-0000-0026-0000-000000000002'
               AND is_deleted = false),
  'ok 14 — soft-deleted product excluded by is_deleted=false filter'
);

SELECT * FROM finish();
ROLLBACK;
