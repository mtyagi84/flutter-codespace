-- ============================================================
-- 087_payment_terms_and_currency_aware_pricing_test.sql — pgTAP tests
-- for migration 087 (currency-aware fn_get_active_price, Payment Terms
-- master, Incoterm seed, Sales Quotation retrofit).
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Fixture: 1 location, 1 user, 1 customer account, a GENERIC-priced
-- product (USD, 100) and a CUSTOMER-priced product for that customer
-- (USD, 80), and a USD->EUR SELLING rate of 0.9 — same "clean number"
-- convention as 038/077's own exchange-rate fixtures.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client_id      uuid := '00000000-0000-0000-0087-000000000001';
  v_company_id     uuid := '00000000-0000-0000-0087-000000000002';
  v_loc_id         uuid := '00000000-0000-0000-0087-000000000003';
  v_user_id        uuid := '00000000-0000-0000-0087-000000000004';
  v_customer_id    uuid := '00000000-0000-0000-0087-000000000005';
  v_customer_group_id uuid := '00000000-0000-0000-0087-000000000006';
  v_prod_generic_id uuid := '00000000-0000-0000-0087-000000000007';
  v_prod_customer_id uuid := '00000000-0000-0000-0087-000000000008';
  v_prod_unpriced_id uuid := '00000000-0000-0000-0087-000000000009';
  v_uom_id         uuid := '00000000-0000-0000-0087-00000000000a';
  v_usd_ccy_id     uuid;
  v_eur_ccy_id     uuid;
  v_unit_type_id   uuid;
  v_entry_no       text;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST087', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST087 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test087 Loc', 'T87L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test087_a', 'Test User 087', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- ric_companies' trg_seed_company_currencies trigger (007) already
  -- auto-seeded USD/EUR/every world currency for this company — read
  -- back the ids rather than inserting our own (same fix already
  -- applied in 038/054/061's tests).
  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';
  SELECT id INTO v_eur_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'EUR';

  -- USD -> EUR SELLING at 0.9 — a clean number to assert against without
  -- floating-point rounding noise (same convention as 038/077).
  INSERT INTO rim_exchange_rates (client_id, company_id, location_id, rate_date, from_currency, to_currency, buying_rate, selling_rate, created_by)
  VALUES (v_client_id, v_company_id, v_loc_id, '2026-07-01', 'USD', 'EUR', 0.9, 0.9, v_user_id)
  ON CONFLICT (client_id, company_id, location_id, rate_date, from_currency, to_currency) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_customer_group_id, v_client_id, v_company_id, '3000', 'Sundry Debtors 087', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES (v_customer_id, v_client_id, v_company_id, v_customer_group_id, '3000001', 'Test087 Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece087', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_prod_generic_id,  v_client_id, v_company_id, 'PT-001', 'Test087 Generic Item',  v_usd_ccy_id, 'NONE', v_user_id),
    (v_prod_customer_id, v_client_id, v_company_id, 'PT-002', 'Test087 Customer Item', v_usd_ccy_id, 'NONE', v_user_id),
    (v_prod_unpriced_id, v_client_id, v_company_id, 'PT-003', 'Test087 Unpriced Item', v_usd_ccy_id, 'NONE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- GENERIC price, USD 100.
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', v_client_id, 'company_id', v_company_id, 'location_id', v_loc_id,
      'entry_no', NULL, 'entry_date', '2020-01-01',
      'price_type', 'GENERIC', 'effective_date', '2020-01-01',
      'price_currency_id', v_usd_ccy_id, 'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', v_prod_generic_id,
      'uom_id', v_uom_id, 'uom_conversion_factor', 1, 'cost_price', 60, 'selling_price', 100)),
    v_user_id
  );
  PERFORM fn_approve_price_master_batch(v_client_id, v_company_id, v_entry_no, '2020-01-01'::date, v_user_id);
  PERFORM set_config('pgtap.v_generic_entry', v_entry_no, false);

  -- CUSTOMER price for v_customer_id, USD 80.
  v_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', v_client_id, 'company_id', v_company_id, 'location_id', v_loc_id,
      'entry_no', NULL, 'entry_date', '2020-01-01',
      'price_type', 'CUSTOMER', 'customer_id', v_customer_id,
      'effective_date', '2020-01-01',
      'price_currency_id', v_usd_ccy_id, 'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', v_prod_customer_id,
      'uom_id', v_uom_id, 'uom_conversion_factor', 1, 'cost_price', 60, 'selling_price', 80)),
    v_user_id
  );
  PERFORM fn_approve_price_master_batch(v_client_id, v_company_id, v_entry_no, '2020-01-01'::date, v_user_id);

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user', v_user_id::text, false);
  PERFORM set_config('pgtap.v_customer', v_customer_id::text, false);
  PERFORM set_config('pgtap.v_prod_generic', v_prod_generic_id::text, false);
  PERFORM set_config('pgtap.v_prod_customer', v_prod_customer_id::text, false);
  PERFORM set_config('pgtap.v_prod_unpriced', v_prod_unpriced_id::text, false);
  PERFORM set_config('pgtap.v_uom', v_uom_id::text, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(12);

-- ══════════════════════════════════════════════════════════════════════════
-- fn_get_active_price — currency awareness (Part 1)
-- ══════════════════════════════════════════════════════════════════════════

-- Test 1: GENERIC price, target currency = native currency (USD) —
-- same-currency shortcut, conversion_rate = 1.
INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price = 100 AND native_selling_price = 100 AND conversion_rate = 1 AND price_currency_code = 'USD'
   FROM fn_get_active_price(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
     current_setting('pgtap.v_loc')::uuid, current_setting('pgtap.v_prod_generic')::uuid,
     current_setting('pgtap.v_uom')::uuid, NULL, '2026-07-01'::date, 'USD')),
  'ok 1 — GENERIC price, target currency = native currency: no conversion, conversion_rate = 1'
);

-- Test 2: GENERIC price, target currency = EUR — converts at the seeded
-- USD->EUR SELLING rate (0.9): 100 * 0.9 = 90.
INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price = 90 AND native_selling_price = 100 AND conversion_rate = 0.9 AND price_currency_code = 'USD'
   FROM fn_get_active_price(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
     current_setting('pgtap.v_loc')::uuid, current_setting('pgtap.v_prod_generic')::uuid,
     current_setting('pgtap.v_uom')::uuid, NULL, '2026-07-01'::date, 'EUR')),
  'ok 2 — GENERIC price converts to the caller''s own document currency (EUR) at the active SELLING rate'
);

-- Test 3: CUSTOMER price, target currency = native currency (USD).
INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price = 80 AND conversion_rate = 1
   FROM fn_get_active_price(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
     current_setting('pgtap.v_loc')::uuid, current_setting('pgtap.v_prod_customer')::uuid,
     current_setting('pgtap.v_uom')::uuid, current_setting('pgtap.v_customer')::uuid, '2026-07-01'::date, 'USD')),
  'ok 3 — CUSTOMER price, target currency = native currency: no conversion'
);

-- Test 4: CUSTOMER price, target currency = EUR: 80 * 0.9 = 72.
INSERT INTO test_results (result) SELECT ok(
  (SELECT selling_price = 72 AND conversion_rate = 0.9
   FROM fn_get_active_price(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
     current_setting('pgtap.v_loc')::uuid, current_setting('pgtap.v_prod_customer')::uuid,
     current_setting('pgtap.v_uom')::uuid, current_setting('pgtap.v_customer')::uuid, '2026-07-01'::date, 'EUR')),
  'ok 4 — CUSTOMER price converts to the caller''s own document currency (EUR) at the active SELLING rate'
);

-- Test 5: unpriced product — no row returned, regardless of currency.
INSERT INTO test_results (result) SELECT ok(
  NOT EXISTS (SELECT 1 FROM fn_get_active_price(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
     current_setting('pgtap.v_loc')::uuid, current_setting('pgtap.v_prod_unpriced')::uuid,
     current_setting('pgtap.v_uom')::uuid, NULL, '2026-07-01'::date, 'EUR')),
  'ok 5 — an unpriced product returns no row (never a silent zero default), currency-aware call included'
);

-- ══════════════════════════════════════════════════════════════════════════
-- fn_save_payment_term — installment lines (Part 2)
-- ══════════════════════════════════════════════════════════════════════════

-- Test 6: two PERCENT lines summing to 100 -> succeeds.
DO $$
DECLARE v_term_id uuid;
BEGIN
  v_term_id := fn_save_payment_term(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'term_id', NULL, 'term_code', 'PT087A', 'term_name', '30/70', 'description', '30% Advance, 70% in 30 Days'),
    jsonb_build_array(
      jsonb_build_object('sequence', 1, 'value_type', 'PERCENT', 'value_amount', 30, 'due_days', 0, 'is_end_of_month', false),
      jsonb_build_object('sequence', 2, 'value_type', 'PERCENT', 'value_amount', 70, 'due_days', 30, 'is_end_of_month', false)
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_term_a', v_term_id::text, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rim_payment_term_lines WHERE term_id = current_setting('pgtap.v_term_a')::uuid) = 2,
  'ok 6 — two PERCENT lines summing to 100 save successfully'
);

-- Test 7: PERCENT lines summing to 90 (not 100) -> rejected.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_payment_term(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'term_id', NULL, 'term_code', 'PT087B', 'term_name', 'Bad Split'),
    jsonb_build_array(jsonb_build_object('sequence', 1, 'value_type', 'PERCENT', 'value_amount', 90, 'due_days', 0, 'is_end_of_month', false)),
    %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_user')),
  'PERCENT_LINES_MUST_SUM_TO_100',
  'ok 7 — PERCENT-only lines not summing to 100% are rejected'
);

-- Test 8: mixed FIXED + PERCENT lines -> percent-sum validation is
-- deliberately skipped (documented v1 simplification).
DO $$
DECLARE v_term_id uuid;
BEGIN
  v_term_id := fn_save_payment_term(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'term_id', NULL, 'term_code', 'PT087C', 'term_name', 'Deposit + Balance'),
    jsonb_build_array(
      jsonb_build_object('sequence', 1, 'value_type', 'FIXED', 'value_amount', 500, 'due_days', 0, 'is_end_of_month', false),
      jsonb_build_object('sequence', 2, 'value_type', 'PERCENT', 'value_amount', 50, 'due_days', 30, 'is_end_of_month', false)
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_term_c', v_term_id::text, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rim_payment_term_lines WHERE term_id = current_setting('pgtap.v_term_c')::uuid) = 2,
  'ok 8 — a mixed FIXED+PERCENT batch saves without the percent-sum check (documented v1 simplification)'
);

-- Test 9: updating an existing term (term_id supplied) replaces its lines.
DO $$
BEGIN
  PERFORM fn_save_payment_term(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'term_id', current_setting('pgtap.v_term_a'), 'term_code', 'PT087A', 'term_name', '30/70 Revised', 'description', 'Updated'),
    jsonb_build_array(
      jsonb_build_object('sequence', 1, 'value_type', 'PERCENT', 'value_amount', 100, 'due_days', 15, 'is_end_of_month', false)
    ),
    current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rim_payment_term_lines WHERE term_id = current_setting('pgtap.v_term_a')::uuid) = 1
  AND (SELECT term_name FROM rim_payment_terms WHERE id = current_setting('pgtap.v_term_a')::uuid) = '30/70 Revised',
  'ok 9 — re-saving an existing term (term_id supplied) replaces its old lines with the new set'
);

-- ══════════════════════════════════════════════════════════════════════════
-- RLS + Incoterm seed + Sales Quotation retrofit (Part 3/4)
-- ══════════════════════════════════════════════════════════════════════════

-- Test 10: RLS is in place on the new tables (not a permissive dev policy).
INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM pg_policies WHERE tablename = 'rim_payment_terms' AND qual LIKE '%request.jwt.claims%') = 1
  AND (SELECT count(*) FROM pg_policies WHERE tablename = 'rim_payment_term_lines' AND qual LIKE '%request.jwt.claims%') = 1,
  'ok 10 — rim_payment_terms and rim_payment_term_lines use the auth_rw_<table> JWT-claims RLS pattern, not a permissive dev policy'
);

-- Test 11: INCOTERM common-master type was seeded globally.
INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rim_common_master_types WHERE type_key = 'INCOTERM'),
  'ok 11 — the INCOTERM common-master type was seeded'
);

-- Test 12: rih_sales_quotations was retrofitted with the two new
-- reference columns (additive-only — the old TEXT columns still exist).
INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'rih_sales_quotations' AND column_name = 'payment_term_id')
  AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'rih_sales_quotations' AND column_name = 'incoterm_id')
  AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'rih_sales_quotations' AND column_name = 'payment_terms'),
  'ok 12 — rih_sales_quotations gained payment_term_id/incoterm_id while keeping the old payment_terms TEXT column (additive retrofit)'
);

-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
