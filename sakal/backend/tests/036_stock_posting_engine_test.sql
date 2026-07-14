-- ============================================================
-- 036_stock_posting_engine_test.sql — pgTAP tests for migration 036
--
-- Tables: ril_stock_ledger, ril_cost_price_history
-- Functions: fn_post_stock_movement, fn_verify_stock_integrity
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
  v_client_id   uuid := '00000000-0000-0000-0036-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0036-000000000002';
  v_user_id     uuid := '00000000-0000-0000-0036-000000000003';
  v_location_id uuid := '00000000-0000-0000-0036-000000000004';
  v_product_id  uuid := '00000000-0000-0000-0036-000000000005';
  v_fy_id       uuid := '00000000-0000-0000-0036-000000000006';
  v_lock_id     uuid := '00000000-0000-0000-0036-000000000007';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST036', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST036 CO', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test036', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, is_active, is_deleted, created_at)
  VALUES (v_location_id, v_client_id, v_company_id, 'Test Store', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'STK-00001', 'Stock Test Item', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Wide-open financial year so every test date below falls inside it.
  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST036', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- A locked window for the period-block test.
  INSERT INTO ric_period_locks (id, client_id, company_id, period_start_date, period_end_date, locked_by, is_active)
  VALUES (v_lock_id, v_client_id, v_company_id, '2026-01-01', '2026-01-31', v_user_id, true)
  ON CONFLICT (id) DO NOTHING;

  -- Opening stock: 10 units @ base 1.5000 / specific 1.8000 (qty_before=0, so
  -- weighted average collapses to the inward price itself). Named
  -- parameters throughout this file — fn_post_stock_movement's positional
  -- shape has grown (p_serial_no inserted mid-list, p_rate_to_base/
  -- p_manufacturing_date appended) since this fixture was first written,
  -- and a stale 15-arg positional call silently misaligned into type
  -- mismatches (DATE where TEXT expected, UUID where DATE expected) rather
  -- than failing obviously.
  PERFORM fn_post_stock_movement(
    p_client_id => v_client_id, p_company_id => v_company_id,
    p_location_id => v_location_id, p_product_id => v_product_id,
    p_trans_date => '2026-06-01'::date, p_trans_type => 'OPENING_STOCK', p_qty_change => 10,
    p_unit_cost_base => 1.5, p_unit_cost_specific => 1.8,
    p_source_doc_type => 'OPENING_STOCK', p_source_doc_no => 'OPEN-1',
    p_source_doc_date => '2026-06-01'::date, p_user_id => v_user_id
  );

  -- Inward: 20 units @ base 1.7000 / specific 2.0000 — this is the user's own
  -- worked example: (10*1.5 + 20*1.7)/30 = 49/30 = 1.6333(base),
  -- (10*1.8 + 20*2.0)/30 = 58/30 = 1.9333(specific).
  PERFORM fn_post_stock_movement(
    p_client_id => v_client_id, p_company_id => v_company_id,
    p_location_id => v_location_id, p_product_id => v_product_id,
    p_trans_date => '2026-06-02'::date, p_trans_type => 'GRN', p_qty_change => 20,
    p_unit_cost_base => 1.7, p_unit_cost_specific => 2.0,
    p_source_doc_type => 'GRN', p_source_doc_no => 'GRN-TEST-1',
    p_source_doc_date => '2026-06-02'::date, p_user_id => v_user_id
  );

  -- Outward: 5 units sold. Cost must NOT change; current_stock drops to 25.
  PERFORM fn_post_stock_movement(
    p_client_id => v_client_id, p_company_id => v_company_id,
    p_location_id => v_location_id, p_product_id => v_product_id,
    p_trans_date => '2026-06-03'::date, p_trans_type => 'SALES_INVOICE', p_qty_change => -5,
    p_source_doc_type => 'SALES_INVOICE', p_source_doc_no => 'INV-TEST-1',
    p_source_doc_date => '2026-06-03'::date, p_user_id => v_user_id
  );
END;
$$ LANGUAGE plpgsql;

-- ── Plan ──────────────────────────────────────────────────────────────────────
SELECT plan(9);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section A: weighted-average costing (base + item-specific currency)
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0036-000000000001' AND product_id = '00000000-0000-0000-0036-000000000005') = 25,
  'ok 1 — current_stock = 10 + 20 - 5 = 25 after all three movements'
);

SELECT ok(
  (SELECT cost_price FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0036-000000000001' AND product_id = '00000000-0000-0000-0036-000000000005') = 1.6333,
  'ok 2 — base cost_price = 49/30 = 1.6333 after the second inward (outward does not change it)'
);

SELECT ok(
  (SELECT cost_price_specific FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0036-000000000001' AND product_id = '00000000-0000-0000-0036-000000000005') = 1.9333,
  'ok 3 — item-currency cost_price_specific = 58/30 = 1.9333, independently computed'
);

SELECT ok(
  (SELECT cost_price_after FROM ril_cost_price_history
   WHERE source_doc_no = 'GRN-TEST-1') = 1.6333,
  'ok 4 — ril_cost_price_history.cost_price_after matches the same 1.6333 figure'
);

SELECT ok(
  (SELECT qty_before FROM ril_cost_price_history WHERE source_doc_no = 'GRN-TEST-1') = 10
  AND (SELECT qty_in FROM ril_cost_price_history WHERE source_doc_no = 'GRN-TEST-1') = 20
  AND (SELECT qty_after FROM ril_cost_price_history WHERE source_doc_no = 'GRN-TEST-1') = 30,
  'ok 5 — before/in/after quantities on the history row are exactly 10/20/30'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section B: outward movements never write a cost-history row
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  NOT EXISTS (SELECT 1 FROM ril_cost_price_history WHERE source_doc_no = 'INV-TEST-1'),
  'ok 6 — the outward SALES_INVOICE movement wrote no cost_price_history row'
);

SELECT ok(
  (SELECT unit_cost FROM ril_stock_ledger WHERE source_doc_no = 'INV-TEST-1') = 1.6333,
  'ok 7 — the outward ledger row snapshots the CURRENT average cost, not a caller-supplied value'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Section C: integrity + guard rails
-- ══════════════════════════════════════════════════════════════════════════════

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM fn_verify_stock_integrity('00000000-0000-0000-0036-000000000002')
    WHERE product_id = '00000000-0000-0000-0036-000000000005'
  ),
  'ok 8 — fn_verify_stock_integrity finds no drift for this product (current_stock matches ledger sum)'
);

SELECT throws_ok(
  $$ SELECT fn_post_stock_movement(
       p_client_id => '00000000-0000-0000-0036-000000000001', p_company_id => '00000000-0000-0000-0036-000000000002',
       p_location_id => '00000000-0000-0000-0036-000000000004', p_product_id => '00000000-0000-0000-0036-000000000005',
       p_trans_date => '2026-06-04'::date, p_trans_type => 'GRN', p_qty_change => 5,
       p_source_doc_type => 'GRN', p_source_doc_no => 'GRN-TEST-2',
       p_source_doc_date => '2026-06-04'::date, p_user_id => '00000000-0000-0000-0036-000000000003'
     ) $$,
  'UNIT_COST_REQUIRED',
  'ok 9 — an inward movement with no unit cost raises UNIT_COST_REQUIRED'
);

SELECT * FROM finish();
ROLLBACK;
