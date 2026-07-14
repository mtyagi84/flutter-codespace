-- ============================================================
-- 077_opening_stock_test.sql — pgTAP tests for Opening Stock (migration 077).
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--
-- Covers: untracked line, batch-tracked line (2 lots), serial-tracked line
-- (2 units), the OPENING_STOCK_ALREADY_ESTABLISHED guard, cost-currency
-- derivation into unit_cost_specific when it differs from base, and an
-- explicit assertion that Approve creates NO rih_finance_headers row at
-- all — proving the "no GL posting" design holds.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client      uuid := '00000000-0000-0000-0077-000000000001';
  v_company     uuid := '00000000-0000-0000-0077-000000000002';
  v_loc         uuid := '00000000-0000-0000-0077-000000000003';
  v_user        uuid := '00000000-0000-0000-0077-000000000004';
  v_fy          uuid := '00000000-0000-0000-0077-000000000005';
  v_usd         uuid;
  v_eur         uuid;
  v_prod_plain  uuid := '00000000-0000-0000-0077-000000000006';  -- untracked, base currency cost
  v_prod_batch  uuid := '00000000-0000-0000-0077-000000000007';  -- batch-tracked, 2 lots
  v_prod_serial uuid := '00000000-0000-0000-0077-000000000008';  -- serial-tracked, 2 units
  v_prod_eur    uuid := '00000000-0000-0000-0077-000000000009';  -- untracked, cost_currency_id = EUR (differs from base USD)
  v_prod_already uuid := '00000000-0000-0000-0077-00000000000a'; -- already has stock at the location
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client, 'TEST077', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company, v_client, 'TEST077 CO', 'USD', 'USD', 'SIMPLE', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES (v_loc, v_client, v_company, 'TEST077 Loc', 'T077L', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user, v_client, v_company, 'test077', 'Test User 077', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy, v_client, v_company, 'FY TEST077', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- currency_notation is NOT NULL with no default -- and since Postgres
  -- validates NOT NULL constraints while constructing the row, BEFORE
  -- ON CONFLICT ever gets a chance to suppress anything, omitting it fails
  -- outright even when the trigger-seeded row would otherwise make this a
  -- harmless no-op.
  SELECT id INTO v_usd FROM rim_currencies WHERE client_id = v_client AND company_id = v_company AND currency_id = 'USD';
  IF v_usd IS NULL THEN
    INSERT INTO rim_currencies (id, client_id, company_id, currency_id, currency_name, currency_notation, is_active, created_by)
    VALUES (gen_random_uuid(), v_client, v_company, 'USD', 'US Dollar', '$', true, v_user)
    RETURNING id INTO v_usd;
  END IF;

  INSERT INTO rim_currencies (id, client_id, company_id, currency_id, currency_name, currency_notation, is_active, created_by)
  VALUES (gen_random_uuid(), v_client, v_company, 'EUR', 'Euro', '€', true, v_user)
  ON CONFLICT DO NOTHING;
  SELECT id INTO v_eur FROM rim_currencies WHERE client_id = v_client AND company_id = v_company AND currency_id = 'EUR';

  -- rim_exchange_rates (migration 018) keys on location_id + from_currency/
  -- to_currency as TEXT ISO codes (not from_currency_id/to_currency_id
  -- UUIDs), and stores buying_rate/selling_rate separately rather than a
  -- single "rate" column -- this insert was written against a schema shape
  -- that never actually existed. from_currency is always the company's
  -- base currency per that table's own convention (fn_get_exchange_rate
  -- resolves USD -> EUR here, needed for fn_save_opening_stock/
  -- fn_approve_opening_stock to derive unit_cost_specific on the EUR-cost
  -- product line below).
  INSERT INTO rim_exchange_rates (client_id, company_id, location_id, rate_date, from_currency, to_currency, buying_rate, selling_rate, created_by)
  VALUES (v_client, v_company, v_loc, '2026-06-01', 'USD', 'EUR', 0.9, 0.9, v_user)
  ON CONFLICT (client_id, company_id, location_id, rate_date, from_currency, to_currency) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_prod_plain,   v_client, v_company, 'OPN-PLAIN',  'Opening Test Plain',   v_usd, 'NONE',   v_user),
    (v_prod_batch,   v_client, v_company, 'OPN-BATCH',  'Opening Test Batch',   v_usd, 'BATCH',  v_user),
    (v_prod_serial,  v_client, v_company, 'OPN-SERIAL', 'Opening Test Serial',  v_usd, 'SERIAL', v_user),
    (v_prod_eur,     v_client, v_company, 'OPN-EUR',    'Opening Test EUR Cost', v_eur, 'NONE',  v_user),
    (v_prod_already, v_client, v_company, 'OPN-ALRDY',  'Opening Test Already', v_usd, 'NONE',   v_user)
  ON CONFLICT (id) DO NOTHING;

  -- Product that already has stock at this location, via a prior movement
  -- unrelated to Opening Stock — the guard must block re-entry on it.
  PERFORM fn_post_stock_movement(
    v_client, v_company, v_loc, v_prod_already,
    '2026-06-01'::date, 'ADJUSTMENT_IN', 5,
    20, 20, NULL, NULL, NULL,
    'STOCK_ADJUSTMENT', 'PRIOR-ADJ-001', '2026-06-01'::date, v_user
  );

  PERFORM set_config('pgtap.v_client', v_client::text, false);
  PERFORM set_config('pgtap.v_company', v_company::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc::text, false);
  PERFORM set_config('pgtap.v_user', v_user::text, false);
  PERFORM set_config('pgtap.v_prod_plain', v_prod_plain::text, false);
  PERFORM set_config('pgtap.v_prod_batch', v_prod_batch::text, false);
  PERFORM set_config('pgtap.v_prod_serial', v_prod_serial::text, false);
  PERFORM set_config('pgtap.v_prod_eur', v_prod_eur::text, false);
  PERFORM set_config('pgtap.v_prod_already', v_prod_already::text, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(14);

-- ══════════════════════════════════════════════════════════════════════════
-- Entry 1: plain + batch (2 lots) + serial (2 units) + EUR-cost product,
-- all in one Opening Stock document.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_opening_no text;
BEGIN
  v_opening_no := fn_save_opening_stock(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'opening_no', NULL, 'opening_date', '2026-06-15',
      'remarks', 'Test entry 1'
    ),
    jsonb_build_array(
      jsonb_build_object('line_no', 1, 'product_id', current_setting('pgtap.v_prod_plain'),
        'uom_conversion_factor', 1, 'pack_qty', 10, 'loose_qty', 0, 'base_qty', 10, 'unit_cost', 5),
      jsonb_build_object('line_no', 2, 'product_id', current_setting('pgtap.v_prod_batch'),
        'uom_conversion_factor', 1, 'pack_qty', 6, 'loose_qty', 0, 'base_qty', 6, 'batch_no', 'B001',
        'expiry_date', '2027-01-01', 'unit_cost', 8),
      jsonb_build_object('line_no', 3, 'product_id', current_setting('pgtap.v_prod_batch'),
        'uom_conversion_factor', 1, 'pack_qty', 4, 'loose_qty', 0, 'base_qty', 4, 'batch_no', 'B002',
        'expiry_date', '2027-03-01', 'unit_cost', 9),
      jsonb_build_object('line_no', 4, 'product_id', current_setting('pgtap.v_prod_serial'),
        'uom_conversion_factor', 1, 'pack_qty', 1, 'loose_qty', 0, 'base_qty', 1, 'serial_no', 'SN-001', 'unit_cost', 100),
      jsonb_build_object('line_no', 5, 'product_id', current_setting('pgtap.v_prod_serial'),
        'uom_conversion_factor', 1, 'pack_qty', 1, 'loose_qty', 0, 'base_qty', 1, 'serial_no', 'SN-002', 'unit_cost', 100),
      jsonb_build_object('line_no', 6, 'product_id', current_setting('pgtap.v_prod_eur'),
        'uom_conversion_factor', 1, 'pack_qty', 20, 'loose_qty', 0, 'base_qty', 20, 'unit_cost', 50)
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_opening_no', v_opening_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_opening_stock_headers WHERE opening_no = current_setting('pgtap.v_opening_no')) = 'DRAFT',
  'ok 1 — Opening Stock saved as DRAFT'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rid_opening_stock_lines WHERE opening_no = current_setting('pgtap.v_opening_no')) = 6,
  'ok 2 — all 6 lines saved (one line per lot/unit, not per product)'
);

DO $$
BEGIN
  PERFORM fn_approve_opening_stock(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_opening_no'), '2026-06-15'::date, current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_opening_stock_headers WHERE opening_no = current_setting('pgtap.v_opening_no')) = 'APPROVED',
  'ok 3 — Opening Stock approved'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_prod_plain')::uuid) = 10
  AND (SELECT cost_price FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_prod_plain')::uuid) = 5,
  'ok 4 — untracked line: stock=10, cost_price=5 established'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_prod_batch')::uuid) = 10,
  'ok 5 — batch-tracked product: two lots (6+4) sum to 10 total stock'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(qty_change) FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_prod_batch')::uuid AND batch_no = 'B001') = 6
  AND (SELECT sum(qty_change) FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_prod_batch')::uuid AND batch_no = 'B002') = 4,
  'ok 6 — each batch lot posted as its own separate ledger entry (B001=6, B002=4)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_prod_serial')::uuid) = 2,
  'ok 7 — serial-tracked product: two units (SN-001, SN-002) sum to 2 total stock'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM v_serial_stock_status
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND product_id = current_setting('pgtap.v_prod_serial')::uuid
     AND serial_no = 'SN-001') = 'IN_STOCK'
  AND (SELECT status FROM v_serial_stock_status
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND product_id = current_setting('pgtap.v_prod_serial')::uuid
     AND serial_no = 'SN-002') = 'IN_STOCK',
  'ok 8 — both serials individually resolve IN_STOCK'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT unit_cost_specific FROM rid_opening_stock_lines
   WHERE opening_no = current_setting('pgtap.v_opening_no') AND line_no = 6) = 45,
  'ok 9 — EUR-cost product: unit_cost_specific = 50 (base USD) x 0.9 (USD->EUR rate) = 45'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT cost_price_specific FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND location_id = current_setting('pgtap.v_loc')::uuid
     AND product_id = current_setting('pgtap.v_prod_eur')::uuid) = 45,
  'ok 10 — rim_product_location.cost_price_specific also reflects the derived 45'
);

-- ══════════════════════════════════════════════════════════════════════════
-- No GL posting at all — the core design guarantee.
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM rih_finance_headers
    WHERE source_doc_type = 'OPENING_STOCK' AND source_doc_no = current_setting('pgtap.v_opening_no')
  ),
  'ok 11 — Approve creates NO rih_finance_headers row — Opening Stock never posts to GL'
);

INSERT INTO test_results (result) SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'rih_opening_stock_headers' AND column_name = 'posted_voucher_no'
  ),
  'ok 12 — rih_opening_stock_headers has no posted_voucher_no column at all, by design (no voucher ever exists to link)'
);

-- ══════════════════════════════════════════════════════════════════════════
-- OPENING_STOCK_ALREADY_ESTABLISHED guard.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_opening_no2 text;
BEGIN
  v_opening_no2 := fn_save_opening_stock(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'opening_no', NULL, 'opening_date', '2026-06-16',
      'remarks', 'Test entry 2 - should fail at approve'
    ),
    jsonb_build_array(
      jsonb_build_object('line_no', 1, 'product_id', current_setting('pgtap.v_prod_already'),
        'uom_conversion_factor', 1, 'pack_qty', 3, 'loose_qty', 0, 'base_qty', 3, 'unit_cost', 7)
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_opening_no2', v_opening_no2, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_opening_stock(%L::uuid, %L::uuid, %L, '2026-06-16'::date, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_opening_no2'), current_setting('pgtap.v_user')
  ),
  'OPENING_STOCK_ALREADY_ESTABLISHED',
  'ok 13 — Approve is blocked on a product that already has stock/cost at this location'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_opening_stock_headers WHERE opening_no = current_setting('pgtap.v_opening_no2')) = 'DRAFT',
  'ok 14 — the blocked entry stays DRAFT, not partially approved'
);

-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
