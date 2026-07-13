-- ============================================================
-- 083_sales_price_master_test.sql — pgTAP tests for migration 083
-- (Sales Price Master: fn_save_price_master_batch,
-- fn_approve_price_master_batch, fn_get_active_price resolution cascade)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. Supabase's SQL editor only displays the LAST statement's result
--      grid, discarding each individual SELECT ok(...)'s own row along
--      the way — so every assertion result is captured into a temp table
--      (test_results) instead, and the final query at the bottom of this
--      file dumps them all in one grid. Look for any row NOT starting
--      with "ok " (i.e. starting with "not ok ") — that's your failure,
--      with pgTAP's own expected/actual diagnostic text right below it.
--
-- Fixture: 2 LOCATIONS (loc1 exercises the main flow, loc2 proves pricing
-- never falls back across locations), 3 products (P1 exercises
-- coexistence/cascade/future-date/below-cost, P2 is only ever saved as
-- DRAFT — never approved, P3 is never touched by any batch at all), 2
-- UOMs (Piece, Carton), 2 customer accounts (customer1 gets an actual
-- customer-specific price, customer2 never does — proves the
-- fallback-to-GENERIC cascade), 1 below-cost reason master value. cost
-- prices are seeded directly into rim_product_location for loc1/P1 (80
-- for Piece-equivalent base qty, 1920 for a full carton) — the line's own
-- cost_price is passed by the caller as a plain snapshot value in these
-- tests (currency conversion is a Flutter-side concern, not tested here).
-- No GL fixture needed — this module never touches the books.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client_id    uuid := '00000000-0000-0000-0083-000000000001';
  v_company_id   uuid := '00000000-0000-0000-0083-000000000002';
  v_user_id      uuid := '00000000-0000-0000-0083-000000000003';
  v_customer1_id uuid := '00000000-0000-0000-0083-000000000004';
  v_customer2_id uuid := '00000000-0000-0000-0083-000000000005';
  v_product1_id  uuid := '00000000-0000-0000-0083-000000000006';
  v_product2_id  uuid := '00000000-0000-0000-0083-000000000007';
  v_product3_id  uuid := '00000000-0000-0000-0083-000000000008';
  v_uom_piece_id  uuid := '00000000-0000-0000-0083-000000000009';
  v_uom_carton_id uuid := '00000000-0000-0000-0083-000000000010';
  v_loc1_id      uuid := '00000000-0000-0000-0083-000000000011';
  v_loc2_id      uuid := '00000000-0000-0000-0083-000000000012';
  v_reason_id    uuid := '00000000-0000-0000-0083-000000000013';
  v_usd_ccy_id   uuid;
  v_unit_type_id uuid;
  v_reason_type_id uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST083', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST083 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES
    (v_loc1_id, v_client_id, v_company_id, 'Test083 Loc One', 'T83A', true, false, now()),
    (v_loc2_id, v_client_id, v_company_id, 'Test083 Loc Two', 'T83B', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test083', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_customer1_id, v_client_id, v_company_id, '3083A', 'Test083 Customer One', 'Customer', 'OHADA', true, true, false, now()),
    (v_customer2_id, v_client_id, v_company_id, '3083B', 'Test083 Customer Two', 'Customer', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';

  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES
    (v_uom_piece_id, v_client_id, v_company_id, v_unit_type_id, 'Piece083', v_user_id),
    (v_uom_carton_id, v_client_id, v_company_id, v_unit_type_id, 'Carton083', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- New global type seeded by migration 083 itself.
  SELECT id INTO v_reason_type_id FROM rim_common_master_types WHERE type_key = 'PRICE_BELOW_COST_REASON';

  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_reason_id, v_client_id, v_company_id, v_reason_type_id, 'Clearance Sale083', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_product1_id, v_client_id, v_company_id, 'PRC-001', 'Test Item One',   v_usd_ccy_id, 'NONE', v_user_id),
    (v_product2_id, v_client_id, v_company_id, 'PRC-002', 'Test Item Two',   v_usd_ccy_id, 'NONE', v_user_id),
    (v_product3_id, v_client_id, v_company_id, 'PRC-003', 'Test Item Three', v_usd_ccy_id, 'NONE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Cost prices at location 1 only — location 2 deliberately has no
  -- rim_product_location row at all, proving cost display is a Flutter
  -- concern, not something this migration's DB functions require.
  INSERT INTO rim_product_location (client_id, company_id, location_id, product_id, current_stock, cost_price)
  VALUES (v_client_id, v_company_id, v_loc1_id, v_product1_id, 100, 80)
  ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

SELECT plan(24);

-- ══════════════════════════════════════════════════════════════════════════════
-- Batch G1: GENERIC, Location 1, P1, Piece (cost 80) @100 + Carton (cost
-- 1920) @2400, effective 2026-07-01.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_entry_no text;
BEGIN
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
      'location_id', '00000000-0000-0000-0083-000000000011',
      'entry_no', NULL, 'entry_date', '2026-07-01',
      'price_type', 'GENERIC', 'effective_date', '2026-07-01',
      'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                               AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1, 'remarks', 'G1'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
        'uom_id', '00000000-0000-0000-0083-000000000009', 'uom_conversion_factor', 1,
        'cost_price', 80, 'margin_percent', 25, 'selling_price', 100),
      jsonb_build_object('serial_no', 2, 'product_id', '00000000-0000-0000-0083-000000000006',
        'uom_id', '00000000-0000-0000-0083-000000000010', 'uom_conversion_factor', 24,
        'cost_price', 1920, 'margin_percent', 25, 'selling_price', 2400)
    ),
    '00000000-0000-0000-0083-000000000003'
  );
  PERFORM set_config('pgtap.v_g1_083', v_entry_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_g1_083') LIKE 'PRC/T83A/%',
  'ok 1 — entry_no assigned via PER-LOCATION fn_next_trans_no, embeds PRC type + T83A location code'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_price_master_headers WHERE entry_no = current_setting('pgtap.v_g1_083')) = 'DRAFT'
  AND (SELECT count(*) FROM rid_price_master_lines WHERE entry_no = current_setting('pgtap.v_g1_083')) = 2
  AND (SELECT cost_price FROM rid_price_master_lines WHERE entry_no = current_setting('pgtap.v_g1_083') AND serial_no = 1) = 80,
  'ok 2 — G1 saved as DRAFT with 2 lines, cost_price snapshot stored as supplied (80)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Batch G2: a second DRAFT, GENERIC, same Location, P1, Piece @105, SAME
-- effective date as G1. Must succeed while both are DRAFT.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_entry_no text;
BEGIN
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
      'location_id', '00000000-0000-0000-0083-000000000011',
      'entry_no', NULL, 'entry_date', '2026-07-01',
      'price_type', 'GENERIC', 'effective_date', '2026-07-01',
      'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                               AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1, 'remarks', 'G2 - correction draft'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
        'uom_id', '00000000-0000-0000-0083-000000000009', 'uom_conversion_factor', 1,
        'cost_price', 80, 'margin_percent', 31.25, 'selling_price', 105)
    ),
    '00000000-0000-0000-0083-000000000003'
  );
  PERFORM set_config('pgtap.v_g2_083', v_entry_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_g2_083') IS NOT NULL AND current_setting('pgtap.v_g2_083') != current_setting('pgtap.v_g1_083'),
  'ok 3 — G2 (a second DRAFT GENERIC batch, same location/product/uom/date as G1) saves without collision'
);

-- ── Approve G1 — succeeds ──
DO $$
BEGIN
  PERFORM fn_approve_price_master_batch(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    current_setting('pgtap.v_g1_083'), '2026-07-01'::date, '00000000-0000-0000-0083-000000000003'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_price_master_headers WHERE entry_no = current_setting('pgtap.v_g1_083')) = 'APPROVED',
  'ok 4 — G1 approved successfully'
);

-- ── Approve G2 — must FAIL: same location+product+uom+date now already APPROVED by G1 ──
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_price_master_batch(
       '00000000-0000-0000-0083-000000000001'::uuid, '00000000-0000-0000-0083-000000000002'::uuid,
       %L, '2026-07-01'::date, '00000000-0000-0000-0083-000000000003'::uuid
     ) $$, current_setting('pgtap.v_g2_083')),
  'PRICE_ALREADY_EXISTS',
  'ok 5 — approving G2 after G1 raises PRICE_ALREADY_EXISTS, not a raw constraint error'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Batch C1: CUSTOMER (customer1), same Location, P1, Piece @90, SAME
-- effective date as G1. Must coexist with the already-APPROVED G1.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_entry_no text;
BEGIN
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
      'location_id', '00000000-0000-0000-0083-000000000011',
      'entry_no', NULL, 'entry_date', '2026-07-01',
      'price_type', 'CUSTOMER', 'customer_id', '00000000-0000-0000-0083-000000000004',
      'effective_date', '2026-07-01',
      'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                               AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1, 'remarks', 'C1 - customer1 special price'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
        'uom_id', '00000000-0000-0000-0083-000000000009', 'uom_conversion_factor', 1,
        'cost_price', 80, 'margin_percent', 12.5, 'selling_price', 90)
    ),
    '00000000-0000-0000-0083-000000000003'
  );
  PERFORM set_config('pgtap.v_c1_083', v_entry_no, false);

  PERFORM fn_approve_price_master_batch(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    v_entry_no, '2026-07-01'::date, '00000000-0000-0000-0083-000000000003'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_price_master_headers WHERE entry_no = current_setting('pgtap.v_c1_083')) = 'APPROVED',
  'ok 6 — C1 (CUSTOMER price, same location/product/uom/date as already-APPROVED GENERIC G1) saves and approves — coexistence confirmed'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- fn_get_active_price resolution cascade (within Location 1)
-- ══════════════════════════════════════════════════════════════════════════════

INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000009',
    '00000000-0000-0000-0083-000000000004', '2026-07-01'
  )) = 90,
  'ok 7 — customer1''s Piece price at Location 1 resolves to their own CUSTOMER price (90), not GENERIC'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000009',
    NULL, '2026-07-01'
  )) = 100,
  'ok 8 — no customer supplied resolves to the GENERIC Piece price (100) at Location 1'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000009',
    '00000000-0000-0000-0083-000000000005', '2026-07-01'
  )) = 100,
  'ok 9 — customer2 (no customer-specific price) falls back to GENERIC (100) — cascade fallback confirmed'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000010',
    NULL, '2026-07-01'
  )) = 2400,
  'ok 10 — the Carton line resolves independently of the Piece line (2400), per-UOM pricing confirmed'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- LOCATION HARD FILTER: Location 2 gets its OWN GENERIC price for the same
-- product/uom/date — must coexist with Location 1's price (different key),
-- and neither location's resolution may see the other's price.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_entry_no text;
BEGIN
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
      'location_id', '00000000-0000-0000-0083-000000000012',
      'entry_no', NULL, 'entry_date', '2026-07-01',
      'price_type', 'GENERIC', 'effective_date', '2026-07-01',
      'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                               AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1, 'remarks', 'L2 - Location 2 has its own price'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
        'uom_id', '00000000-0000-0000-0083-000000000009', 'uom_conversion_factor', 1,
        'cost_price', 0, 'margin_percent', NULL, 'selling_price', 150)
    ),
    '00000000-0000-0000-0083-000000000003'
  );
  PERFORM set_config('pgtap.v_l2_083', v_entry_no, false);

  PERFORM fn_approve_price_master_batch(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    v_entry_no, '2026-07-01'::date, '00000000-0000-0000-0083-000000000003'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_l2_083') LIKE 'PRC/T83B/%'
  AND (SELECT status FROM rih_price_master_headers WHERE entry_no = current_setting('pgtap.v_l2_083')) = 'APPROVED',
  'ok 11 — Location 2''s own batch for the SAME product/uom/date as G1 saves+approves without collision — location is part of the uniqueness key'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000012',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000009',
    NULL, '2026-07-01'
  )) = 150
  AND (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000009',
    NULL, '2026-07-01'
  )) = 100,
  'ok 12 — Location 2 resolves to its own 150, Location 1 still resolves to its own 100 — no cross-location fallback or contamination'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Batch D: GENERIC, Location 1, P1, Piece @120, effective 2026-08-01
-- (future). Approve succeeds today even though effective_date is a month
-- out — Approve is never date-gated.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_entry_no text;
BEGIN
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
      'location_id', '00000000-0000-0000-0083-000000000011',
      'entry_no', NULL, 'entry_date', '2026-07-01',
      'price_type', 'GENERIC', 'effective_date', '2026-08-01',
      'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                               AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1, 'remarks', 'D - future price revision'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
        'uom_id', '00000000-0000-0000-0083-000000000009', 'uom_conversion_factor', 1,
        'cost_price', 80, 'margin_percent', 50, 'selling_price', 120)
    ),
    '00000000-0000-0000-0083-000000000003'
  );
  PERFORM set_config('pgtap.v_d_083', v_entry_no, false);

  PERFORM fn_approve_price_master_batch(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    v_entry_no, '2026-07-01'::date, '00000000-0000-0000-0083-000000000003'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_price_master_headers WHERE entry_no = current_setting('pgtap.v_d_083')) = 'APPROVED',
  'ok 13 — future-dated batch D (effective 2026-08-01) approves today without any date restriction'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000009',
    NULL, '2026-07-01'
  )) = 100,
  'ok 14 — as-of 2026-07-01, D (approved but not yet effective) is invisible — still resolves to G1''s 100'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000006', '00000000-0000-0000-0083-000000000009',
    NULL, '2026-08-01'
  )) = 120,
  'ok 15 — as-of 2026-08-01, D''s 120 wins over G1''s 100 — latest-effective-date-wins confirmed'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Batch E: GENERIC, Location 1, P2, Piece @50, effective 2026-01-01 (past).
-- Saved as DRAFT only — NEVER approved.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_entry_no text;
BEGIN
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
      'location_id', '00000000-0000-0000-0083-000000000011',
      'entry_no', NULL, 'entry_date', '2026-07-01',
      'price_type', 'GENERIC', 'effective_date', '2026-01-01',
      'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                               AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1, 'remarks', 'E - never approved'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000007',
        'uom_id', '00000000-0000-0000-0083-000000000009', 'uom_conversion_factor', 1,
        'cost_price', 0, 'margin_percent', NULL, 'selling_price', 50)
    ),
    '00000000-0000-0000-0083-000000000003'
  );
  PERFORM set_config('pgtap.v_e_083', v_entry_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  NOT EXISTS (SELECT 1 FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000007', '00000000-0000-0000-0083-000000000009',
    NULL, '2026-07-01'
  )),
  'ok 16 — an unapproved DRAFT price (E) is never returned, even with an effective date safely in the past'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- P3 was never touched by any batch at all — resolution must return no
-- rows, not zero, not an error.
-- ══════════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  NOT EXISTS (SELECT 1 FROM fn_get_active_price(
    '00000000-0000-0000-0083-000000000001', '00000000-0000-0000-0083-000000000002',
    '00000000-0000-0000-0083-000000000011',
    '00000000-0000-0000-0083-000000000008', '00000000-0000-0000-0083-000000000009',
    NULL, '2026-07-01'
  )),
  'ok 17 — a product with zero price batches ever entered returns no rows (not zero, not an error)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Below-cost reason — required at Save
-- ══════════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_save_price_master_batch(
       jsonb_build_object('client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
         'location_id', '00000000-0000-0000-0083-000000000011', 'entry_no', NULL, 'entry_date', '2026-07-01',
         'price_type', 'GENERIC', 'effective_date', '2026-07-01',
         'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                                  AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
         'rate_to_base', 1, 'rate_to_local', 1),
       jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
         'uom_id', '00000000-0000-0000-0083-000000000009', 'cost_price', 80, 'selling_price', 70)),
       '00000000-0000-0000-0083-000000000003'
     ) $$,
  'BELOW_COST_REASON_REQUIRED',
  'ok 18 — a line priced below cost (70 < 80) with no reason is rejected at Save'
);

DO $$
DECLARE v_entry_no text;
BEGIN
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
      'location_id', '00000000-0000-0000-0083-000000000011',
      'entry_no', NULL, 'entry_date', '2026-07-01',
      'price_type', 'GENERIC', 'effective_date', '2026-01-15',
      'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                               AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1, 'remarks', 'F - below cost with reason'
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
      'uom_id', '00000000-0000-0000-0083-000000000009', 'cost_price', 80, 'selling_price', 70,
      'below_cost_reason_id', '00000000-0000-0000-0083-000000000013')),
    '00000000-0000-0000-0083-000000000003'
  );
  PERFORM set_config('pgtap.v_f_083', v_entry_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT below_cost_reason_id FROM rid_price_master_lines WHERE entry_no = current_setting('pgtap.v_f_083'))::text
    = '00000000-0000-0000-0083-000000000013',
  'ok 19 — the same below-cost line saves successfully once a reason is supplied'
);

-- ── Below-cost reason re-checked at Approve (defense-in-depth): force the
-- stored reason to NULL via direct UPDATE (simulating a row written via
-- direct API access, bypassing the UI/Save-time check), then Approve must
-- still catch it. ──
DO $$
BEGIN
  UPDATE rid_price_master_lines SET below_cost_reason_id = NULL
  WHERE entry_no = current_setting('pgtap.v_f_083') AND serial_no = 1;
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_price_master_batch(
       '00000000-0000-0000-0083-000000000001'::uuid, '00000000-0000-0000-0083-000000000002'::uuid,
       %L, '2026-07-01'::date, '00000000-0000-0000-0083-000000000003'::uuid
     ) $$, current_setting('pgtap.v_f_083')),
  'BELOW_COST_REASON_REQUIRED',
  'ok 20 — Approve independently re-checks the below-cost-reason rule, catching a row with the reason stripped out directly'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Duplicate barcode within a batch — rejected at Save
-- ══════════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_save_price_master_batch(
       jsonb_build_object('client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
         'location_id', '00000000-0000-0000-0083-000000000011', 'entry_no', NULL, 'entry_date', '2026-07-01',
         'price_type', 'GENERIC', 'effective_date', '2026-02-01',
         'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                                  AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
         'rate_to_base', 1, 'rate_to_local', 1),
       jsonb_build_array(
         jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
           'uom_id', '00000000-0000-0000-0083-000000000009', 'cost_price', 80, 'selling_price', 100, 'barcode', 'DUPBAR083'),
         jsonb_build_object('serial_no', 2, 'product_id', '00000000-0000-0000-0083-000000000006',
           'uom_id', '00000000-0000-0000-0083-000000000010', 'cost_price', 1920, 'selling_price', 2400, 'barcode', 'DUPBAR083')
       ),
       '00000000-0000-0000-0083-000000000003'
     ) $$,
  'DUPLICATE_BARCODE',
  'ok 21 — two lines sharing the same scanned barcode within one batch are rejected at Save'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Re-approve / re-save guards
-- ══════════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_price_master_batch(
       '00000000-0000-0000-0083-000000000001'::uuid, '00000000-0000-0000-0083-000000000002'::uuid,
       %L, '2026-07-01'::date, '00000000-0000-0000-0083-000000000003'::uuid
     ) $$, current_setting('pgtap.v_g1_083')),
  NULL,
  'ok 22 — re-approving an already-APPROVED batch (G1) raises an exception'
);

DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM fn_save_price_master_batch(
      jsonb_build_object('client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
        'location_id', '00000000-0000-0000-0083-000000000011', 'entry_no', current_setting('pgtap.v_g1_083'), 'entry_date', '2026-07-01',
        'price_type', 'GENERIC', 'effective_date', '2026-07-01',
        'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                                 AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
        'rate_to_base', 1, 'rate_to_local', 1),
      jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000006',
        'uom_id', '00000000-0000-0000-0083-000000000009', 'cost_price', 80, 'selling_price', 999)),
      '00000000-0000-0000-0083-000000000003'
    );
  EXCEPTION WHEN OTHERS THEN
    v_caught := true;
  END;
  PERFORM set_config('pgtap.v_editapproved_caught_083', v_caught::text, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_editapproved_caught_083')::boolean = true,
  'ok 23 — editing an APPROVED batch (no longer DRAFT) raises an exception'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- XOR validation guard on fn_save_price_master_batch
-- ══════════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_save_price_master_batch(
       jsonb_build_object('client_id', '00000000-0000-0000-0083-000000000001', 'company_id', '00000000-0000-0000-0083-000000000002',
         'location_id', '00000000-0000-0000-0083-000000000011', 'entry_no', NULL, 'entry_date', '2026-07-01',
         'price_type', 'CUSTOMER', 'effective_date', '2026-07-01',
         'price_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0083-000000000001'
                                  AND company_id = '00000000-0000-0000-0083-000000000002' AND currency_id = 'USD'),
         'rate_to_base', 1, 'rate_to_local', 1),
       jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0083-000000000008',
         'uom_id', '00000000-0000-0000-0083-000000000009', 'cost_price', 0, 'selling_price', 10)),
       '00000000-0000-0000-0083-000000000003'
     ) $$,
  NULL,
  'ok 24 — price_type=CUSTOMER with no customer_id is rejected before hitting the DB constraint'
);

-- Final result: every one of the 24 assertions, in order. Look for any row
-- NOT starting with "ok " — that's the failing one, with pgTAP's own
-- expected-vs-actual diagnostic text right below it in the same column.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
