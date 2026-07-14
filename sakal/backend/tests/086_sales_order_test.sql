-- ============================================================
-- 086_sales_order_test.sql — pgTAP tests for migration 086
-- (ric_user_sales_controls, fn_convert_prospect_to_customer,
--  fn_save_sales_order, fn_approve_sales_order, fn_cancel_sales_order)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Fixture: 1 location, 1 user with NO ric_user_sales_controls row at all
-- (proves the missing-row-default is all-false, never permissive), 1
-- user WITH an explicit permissive row (override + discount up to 10%),
-- a Customer group account (posting_allowed=false, needed by
-- fn_convert_prospect_to_customer's fn_next_account_code lookup), 2
-- products (one with an active GENERIC Price Master entry, one with
-- none at all), 4 quotations covering: convertible+future (the happy
-- path, partially then fully converted), DRAFT (not convertible),
-- expired, and PROSPECT (conversion + PROSPECT_NOT_CONVERTED guard).
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client_id       uuid := '00000000-0000-0000-0086-000000000001';
  v_company_id      uuid := '00000000-0000-0000-0086-000000000002';
  v_loc_id          uuid := '00000000-0000-0000-0086-000000000003';
  v_user_no_ctrl_id uuid := '00000000-0000-0000-0086-000000000004'; -- no ric_user_sales_controls row
  v_user_priv_id    uuid := '00000000-0000-0000-0086-000000000005'; -- override+discount granted
  v_customer_id     uuid := '00000000-0000-0000-0086-000000000006';
  v_customer_group_id uuid := '00000000-0000-0000-0086-000000000007';
  v_prod_priced_id  uuid := '00000000-0000-0000-0086-000000000008';
  v_prod_unpriced_id uuid := '00000000-0000-0000-0086-000000000009';
  v_uom_id          uuid := '00000000-0000-0000-0086-00000000000a';
  v_usd_ccy_id      uuid;
  v_unit_type_id    uuid;
  v_price_entry_no  text;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST086', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST086 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test086 Loc', 'T86L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_no_ctrl_id, v_client_id, v_company_id, 'test086_a', 'Test User A (no controls)', 'x', true, false, now()),
    (v_user_priv_id,    v_client_id, v_company_id, 'test086_b', 'Test User B (privileged)',  'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- User B gets explicit permissive Sales Controls; User A gets none at
  -- all (the "missing row = all false" case under test).
  INSERT INTO ric_user_sales_controls (client_id, company_id, user_id, can_override_price, can_give_discount, max_discount_percent, can_view_cost_price)
  VALUES (v_client_id, v_company_id, v_user_priv_id, true, true, 10, true)
  ON CONFLICT (client_id, company_id, user_id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  -- Customer group (non-posting parent) — required by
  -- fn_convert_prospect_to_customer's fn_next_account_code lookup.
  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_customer_group_id, v_client_id, v_company_id, '3000', 'Sundry Debtors 086', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- account_code MUST end in exactly 3 digits — fn_next_account_code (used
  -- by fn_convert_prospect_to_customer below) scans RIGHT(account_code,3)
  -- across every sibling under the same parent to compute the next
  -- sequence number, and fails to cast a non-numeric suffix.
  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES (v_customer_id, v_client_id, v_company_id, v_customer_group_id, '3000001', 'Test086 Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece086', v_user_priv_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_prod_priced_id,   v_client_id, v_company_id, 'SO-001', 'Test086 Priced Item',   v_usd_ccy_id, 'NONE', v_user_priv_id),
    (v_prod_unpriced_id, v_client_id, v_company_id, 'SO-002', 'Test086 Unpriced Item', v_usd_ccy_id, 'NONE', v_user_priv_id)
  ON CONFLICT (id) DO NOTHING;

  -- Active GENERIC price for v_prod_priced_id, effective well in the past
  -- so it's always active regardless of when this test runs.
  v_price_entry_no := fn_save_price_master_batch(
    jsonb_build_object(
      'client_id', v_client_id, 'company_id', v_company_id, 'location_id', v_loc_id,
      'entry_no', NULL, 'entry_date', '2020-01-01',
      'price_type', 'GENERIC', 'effective_date', '2020-01-01',
      'price_currency_id', v_usd_ccy_id, 'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', v_prod_priced_id,
      'uom_id', v_uom_id, 'uom_conversion_factor', 1, 'cost_price', 30, 'selling_price', 50)),
    v_user_priv_id
  );
  PERFORM fn_approve_price_master_batch(v_client_id, v_company_id, v_price_entry_no, '2020-01-01'::date, v_user_priv_id);

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user_a', v_user_no_ctrl_id::text, false);
  PERFORM set_config('pgtap.v_user_b', v_user_priv_id::text, false);
  PERFORM set_config('pgtap.v_customer', v_customer_id::text, false);
  PERFORM set_config('pgtap.v_prod_priced', v_prod_priced_id::text, false);
  PERFORM set_config('pgtap.v_prod_unpriced', v_prod_unpriced_id::text, false);
  PERFORM set_config('pgtap.v_uom', v_uom_id::text, false);
  PERFORM set_config('pgtap.v_usd_ccy', v_usd_ccy_id::text, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(21);

-- ══════════════════════════════════════════════════════════════════════════
-- Direct mode — price resolution + governance (Part A)
-- ══════════════════════════════════════════════════════════════════════════

-- Test 1: priced product resolves and locks to PRICE_MASTER, even for
-- User A who has no ric_user_sales_controls row at all (irrelevant here
-- since the price DID resolve — no override needed).
DO $$
DECLARE v_order_no text;
BEGIN
  v_order_no := fn_save_sales_order(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'order_no', NULL, 'order_date', '2026-06-01',
      'order_mode', 'DIRECT', 'customer_id', current_setting('pgtap.v_customer'),
      'order_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_priced'),
      'uom_id', current_setting('pgtap.v_uom'), 'uom_conversion_factor', 1, 'qty_pack', 5, 'base_qty', 5)),
    '[]'::jsonb, current_setting('pgtap.v_user_a')::uuid
  );
  PERFORM set_config('pgtap.v_order1', v_order_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT rate FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order1') AND serial_no = 1) = 50
  AND (SELECT price_source FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order1') AND serial_no = 1) = 'PRICE_MASTER',
  'ok 1 — Direct order line resolves and locks to the active Price Master rate'
);

-- Test 2: unpriced product, User A (no controls row) -> hard block.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-01',
      'order_mode', 'DIRECT', 'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L, 'uom_id', %L, 'uom_conversion_factor', 1, 'qty_pack', 1, 'base_qty', 1)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_prod_unpriced'), current_setting('pgtap.v_uom'), current_setting('pgtap.v_user_a')),
  'PRICE_NOT_CONFIGURED',
  'ok 2 — unpriced product blocked for a user with no Sales Controls row (missing row = all false, not permissive)'
);

-- Test 3: same unpriced product, User B (can_override_price = true) but
-- no override reason supplied -> OVERRIDE_REASON_REQUIRED.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-01',
      'order_mode', 'DIRECT', 'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L, 'uom_id', %L, 'uom_conversion_factor', 1,
      'qty_pack', 1, 'base_qty', 1, 'rate', 99)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_prod_unpriced'), current_setting('pgtap.v_uom'), current_setting('pgtap.v_user_b')),
  'OVERRIDE_REASON_REQUIRED',
  'ok 3 — override permitted but a reason is still required'
);

-- Test 4: same, now WITH a reason -> succeeds, MANUAL_OVERRIDE.
DO $$
DECLARE v_order_no text;
BEGIN
  v_order_no := fn_save_sales_order(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'order_no', NULL, 'order_date', '2026-06-01',
      'order_mode', 'DIRECT', 'customer_id', current_setting('pgtap.v_customer'),
      'order_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_unpriced'),
      'uom_id', current_setting('pgtap.v_uom'), 'uom_conversion_factor', 1, 'qty_pack', 1, 'base_qty', 1,
      'rate', 99, 'price_override_reason', 'New product, price master not yet updated')),
    '[]'::jsonb, current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM set_config('pgtap.v_order2', v_order_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT rate FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order2') AND serial_no = 1) = 99
  AND (SELECT price_source FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order2') AND serial_no = 1) = 'MANUAL_OVERRIDE',
  'ok 4 — override with a reason succeeds and is tagged MANUAL_OVERRIDE'
);

-- Test 5: discount attempted by User A (no controls row) -> DISCOUNT_NOT_ALLOWED.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-01',
      'order_mode', 'DIRECT', 'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L, 'uom_id', %L, 'uom_conversion_factor', 1,
      'qty_pack', 1, 'base_qty', 1, 'discount_percent', 5)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_prod_priced'), current_setting('pgtap.v_uom'), current_setting('pgtap.v_user_a')),
  'DISCOUNT_NOT_ALLOWED',
  'ok 5 — discount blocked for a user not authorized to give one'
);

-- Test 6: discount above User B's 10% cap -> DISCOUNT_EXCEEDS_LIMIT.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-01',
      'order_mode', 'DIRECT', 'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L, 'uom_id', %L, 'uom_conversion_factor', 1,
      'qty_pack', 1, 'base_qty', 1, 'discount_percent', 15)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_prod_priced'), current_setting('pgtap.v_uom'), current_setting('pgtap.v_user_b')),
  'DISCOUNT_EXCEEDS_LIMIT',
  'ok 6 — discount above the authorized 10% cap is rejected'
);

-- Test 7: discount within User B's cap -> succeeds.
DO $$
DECLARE v_order_no text;
BEGIN
  v_order_no := fn_save_sales_order(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'order_no', NULL, 'order_date', '2026-06-01',
      'order_mode', 'DIRECT', 'customer_id', current_setting('pgtap.v_customer'),
      'order_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_priced'),
      'uom_id', current_setting('pgtap.v_uom'), 'uom_conversion_factor', 1, 'qty_pack', 1, 'base_qty', 1, 'discount_percent', 8)),
    '[]'::jsonb, current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM set_config('pgtap.v_order3', v_order_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT discount_percent FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order3') AND serial_no = 1) = 8,
  'ok 7 — discount within the authorized cap is accepted'
);

-- ══════════════════════════════════════════════════════════════════════════
-- Prospect -> Customer conversion (Part B) + Against-Quotation validity (Part C)
-- ══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_q_ok      text; -- convertible, future valid_until — the happy path
  v_q_draft   text; -- never approved
  v_q_expired text;
  v_q_prospect text;
BEGIN
  v_q_ok := fn_save_sales_quotation(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'quotation_no', NULL, 'quotation_date', '2026-06-01',
      'valid_until_date', (CURRENT_DATE + 365)::text, 'customer_type', 'CUSTOMER', 'customer_id', current_setting('pgtap.v_customer'), 'party_name', 'Test086 Customer',
      'quotation_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_priced'),
      'uom_id', current_setting('pgtap.v_uom'), 'uom_conversion_factor', 1, 'base_qty', 100, 'rate', 50, 'final_amount', 5000)),
    '[]'::jsonb, current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM fn_approve_sales_quotation(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_q_ok, '2026-06-01'::date, current_setting('pgtap.v_user_b')::uuid);
  PERFORM set_config('pgtap.v_q_ok', v_q_ok, false);

  v_q_draft := fn_save_sales_quotation(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'quotation_no', NULL, 'quotation_date', '2026-06-02',
      'valid_until_date', (CURRENT_DATE + 365)::text, 'customer_type', 'CUSTOMER', 'customer_id', current_setting('pgtap.v_customer'), 'party_name', 'Test086 Customer',
      'quotation_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_priced'),
      'uom_id', current_setting('pgtap.v_uom'), 'uom_conversion_factor', 1, 'base_qty', 10, 'rate', 50, 'final_amount', 500)),
    '[]'::jsonb, current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM set_config('pgtap.v_q_draft', v_q_draft, false);

  v_q_expired := fn_save_sales_quotation(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'quotation_no', NULL, 'quotation_date', '2020-01-01',
      'valid_until_date', '2020-01-15', 'customer_type', 'CUSTOMER', 'customer_id', current_setting('pgtap.v_customer'), 'party_name', 'Test086 Customer',
      'quotation_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_priced'),
      'uom_id', current_setting('pgtap.v_uom'), 'uom_conversion_factor', 1, 'base_qty', 10, 'rate', 50, 'final_amount', 500)),
    '[]'::jsonb, current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM fn_approve_sales_quotation(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_q_expired, '2020-01-01'::date, current_setting('pgtap.v_user_b')::uuid);
  PERFORM set_config('pgtap.v_q_expired', v_q_expired, false);

  v_q_prospect := fn_save_sales_quotation(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'quotation_no', NULL, 'quotation_date', '2026-06-03',
      'valid_until_date', (CURRENT_DATE + 365)::text, 'customer_type', 'PROSPECT', 'party_name', 'Test086 Prospect Co',
      'party_phone', '0800000086', 'quotation_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_priced'),
      'uom_id', current_setting('pgtap.v_uom'), 'uom_conversion_factor', 1, 'base_qty', 20, 'rate', 50, 'final_amount', 1000)),
    '[]'::jsonb, current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM fn_approve_sales_quotation(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_q_prospect, '2026-06-03'::date, current_setting('pgtap.v_user_b')::uuid);
  PERFORM set_config('pgtap.v_q_prospect', v_q_prospect, false);
END;
$$ LANGUAGE plpgsql;

-- Test 8: DRAFT quotation cannot be converted.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-05',
      'order_mode', 'AGAINST_QUOTATION', 'source_quotation_no', %L, 'source_quotation_date', '2026-06-02',
      'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_quotation_line_serial', 1, 'base_qty', 5)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_q_draft'), current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_user_b')),
  'QUOTATION_NOT_CONVERTIBLE',
  'ok 8 — a DRAFT quotation cannot be converted to an order'
);

-- Test 9: expired quotation cannot be converted.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-05',
      'order_mode', 'AGAINST_QUOTATION', 'source_quotation_no', %L, 'source_quotation_date', '2020-01-01',
      'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_quotation_line_serial', 1, 'base_qty', 5)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_q_expired'), current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_user_b')),
  'QUOTATION_EXPIRED',
  'ok 9 — an expired quotation cannot be converted to an order'
);

-- Test 10: PROSPECT quotation cannot be converted until the prospect is converted.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-05',
      'order_mode', 'AGAINST_QUOTATION', 'source_quotation_no', %L, 'source_quotation_date', '2026-06-03',
      'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_quotation_line_serial', 1, 'base_qty', 5)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_q_prospect'), current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_user_b')),
  'PROSPECT_NOT_CONVERTED',
  'ok 10 — a still-PROSPECT quotation cannot be converted to an order'
);

-- Test 11: fn_convert_prospect_to_customer creates a real account, updates
-- the quotation, and logs the conversion.
DO $$
DECLARE v_new_customer_id uuid;
BEGIN
  v_new_customer_id := fn_convert_prospect_to_customer(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_q_prospect'), '2026-06-03'::date,
    jsonb_build_object('account_name', 'Test086 Prospect Co', 'account_currency_id', current_setting('pgtap.v_usd_ccy')),
    'Converted for pgTAP test', current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM set_config('pgtap.v_new_customer', v_new_customer_id::text, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT customer_type FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_prospect')) = 'CUSTOMER'
  AND (SELECT customer_id FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_prospect')) = current_setting('pgtap.v_new_customer')::uuid
  AND (SELECT account_nature FROM rim_accounts WHERE id = current_setting('pgtap.v_new_customer')::uuid) = 'Customer'
  AND EXISTS (SELECT 1 FROM rih_prospect_conversions WHERE new_customer_id = current_setting('pgtap.v_new_customer')::uuid
     AND source_quotation_no = current_setting('pgtap.v_q_prospect')),
  'ok 11 — converting a prospect creates a real Customer account, updates the quotation, and logs the conversion'
);

-- Test 12: re-converting an already-converted quotation is rejected.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_convert_prospect_to_customer(%L::uuid, %L::uuid, %L, '2026-06-03'::date,
    jsonb_build_object('account_name', 'x', 'account_currency_id', %L), NULL, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_q_prospect'),
    current_setting('pgtap.v_usd_ccy'), current_setting('pgtap.v_user_b')),
  'ALREADY_A_CUSTOMER',
  'ok 12 — a quotation already linked to a real customer cannot be converted again'
);

-- ══════════════════════════════════════════════════════════════════════════
-- Against-Quotation: frozen fields, partial conversion, tampering, cancel
-- ══════════════════════════════════════════════════════════════════════════

-- Test 13: payload tampering (different rate/discount) is ignored — the
-- saved line always takes the source quotation line's own frozen values.
DO $$
DECLARE v_order_no text;
BEGIN
  v_order_no := fn_save_sales_order(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'order_no', NULL, 'order_date', '2026-06-05',
      'order_mode', 'AGAINST_QUOTATION', 'source_quotation_no', current_setting('pgtap.v_q_ok'), 'source_quotation_date', '2026-06-01',
      'customer_id', current_setting('pgtap.v_customer'), 'order_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_quotation_line_serial', 1, 'base_qty', 40,
      'rate', 999, 'discount_percent', 50)), -- tampered — server must ignore both
    '[]'::jsonb, current_setting('pgtap.v_user_a')::uuid -- User A has no controls row — irrelevant for this mode
  );
  PERFORM set_config('pgtap.v_order_aq1', v_order_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT rate FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order_aq1') AND serial_no = 1) = 50
  AND (SELECT discount_percent FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order_aq1') AND serial_no = 1) = 0
  AND (SELECT price_source FROM rid_sales_order_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order_aq1') AND serial_no = 1) = 'QUOTATION',
  'ok 13 — Against-Quotation line ignores tampered rate/discount, always uses the quotation''s own frozen values'
);

-- Test 14: converting more than the remaining quantity is rejected.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', NULL, 'order_date', '2026-06-05',
      'order_mode', 'AGAINST_QUOTATION', 'source_quotation_no', %L, 'source_quotation_date', '2026-06-01',
      'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_quotation_line_serial', 1, 'base_qty', 999)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_q_ok'), current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'),
       current_setting('pgtap.v_user_b')),
  'QUOTATION_QTY_EXCEEDED',
  'ok 14 — converting more than the remaining unconverted quantity is rejected at save time'
);

-- Test 15: approving order_aq1 (converting 40 of 100) rolls converted_qty
-- forward and marks the quotation PARTIALLY_CONVERTED.
DO $$
BEGIN
  PERFORM fn_approve_sales_order(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_order_aq1'), '2026-06-05'::date, current_setting('pgtap.v_user_b')::uuid);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT converted_qty FROM rid_sales_quotation_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_ok') AND serial_no = 1) = 40
  AND (SELECT status FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_ok')) = 'PARTIALLY_CONVERTED',
  'ok 15 — approving a partial Against-Quotation order rolls converted_qty forward and marks the quotation PARTIALLY_CONVERTED'
);

-- Test 16: converting the remaining 60 and approving completes the
-- quotation to CONVERTED.
DO $$
DECLARE v_order_no text;
BEGIN
  v_order_no := fn_save_sales_order(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'order_no', NULL, 'order_date', '2026-06-06',
      'order_mode', 'AGAINST_QUOTATION', 'source_quotation_no', current_setting('pgtap.v_q_ok'), 'source_quotation_date', '2026-06-01',
      'customer_id', current_setting('pgtap.v_customer'), 'order_currency_id', current_setting('pgtap.v_usd_ccy')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_quotation_line_serial', 1, 'base_qty', 60)),
    '[]'::jsonb, current_setting('pgtap.v_user_b')::uuid
  );
  PERFORM fn_approve_sales_order(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_order_no, '2026-06-06'::date, current_setting('pgtap.v_user_b')::uuid);
  PERFORM set_config('pgtap.v_order_aq2', v_order_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT converted_qty FROM rid_sales_quotation_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_ok') AND serial_no = 1) = 100
  AND (SELECT status FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_ok')) = 'CONVERTED',
  'ok 16 — converting the remaining quantity completes the quotation to CONVERTED'
);

-- Test 17: cancelling order_aq2 (APPROVED) rolls converted_qty back and
-- reverts the quotation to APPROVED (no other line/order still converted).
DO $$
BEGIN
  PERFORM fn_cancel_sales_order(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_order_aq2'), '2026-06-06'::date, 'Customer changed requirements', current_setting('pgtap.v_user_b')::uuid);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_orders WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order_aq2')) = 'CANCELLED'
  AND (SELECT cancellation_reason FROM rih_sales_orders WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND order_no = current_setting('pgtap.v_order_aq2')) = 'Customer changed requirements'
  AND (SELECT converted_qty FROM rid_sales_quotation_lines WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_ok') AND serial_no = 1) = 40
  AND (SELECT status FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client')::uuid
     AND quotation_no = current_setting('pgtap.v_q_ok')) = 'PARTIALLY_CONVERTED',
  'ok 17 — cancelling an APPROVED Against-Quotation order rolls converted_qty back, reverts the quotation status, and stores the cancellation reason'
);

-- Test 18: cancelling without a reason is rejected.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_cancel_sales_order(%L::uuid, %L::uuid, %L, '2026-06-01'::date, NULL, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_order1'), current_setting('pgtap.v_user_b')),
  'Enter a reason for cancelling this order.',
  'ok 18a — cancelling without a reason is rejected'
);

-- Test 18b: cancelling an already-CANCELLED order is rejected.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_cancel_sales_order(%L::uuid, %L::uuid, %L, '2026-06-06'::date, 'duplicate cancel attempt', %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_order_aq2'), current_setting('pgtap.v_user_b')),
  'P0001', NULL,
  'ok 18b — cancelling an already-cancelled order is rejected'
);

-- Test 19: order_aq1 is APPROVED (from test 15) — re-saving it (e.g. to
-- add a charge) must still be blocked by the same DRAFT-only guard
-- fn_save_sales_order applies in Direct mode; Against-Quotation mode
-- gets no special exemption from it.
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_order(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'order_no', %L, 'order_date', '2026-06-05',
      'order_mode', 'AGAINST_QUOTATION', 'source_quotation_no', %L, 'source_quotation_date', '2026-06-01',
      'customer_id', %L, 'order_currency_id', %L),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'source_quotation_line_serial', 1, 'base_qty', 40)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_order_aq1'), current_setting('pgtap.v_q_ok'),
       current_setting('pgtap.v_customer'), current_setting('pgtap.v_usd_ccy'), current_setting('pgtap.v_user_a')),
  'P0001', NULL,
  'ok 19 — re-saving an APPROVED order is blocked (status guard on fn_save_sales_order still holds for Against-Quotation mode)'
);

-- Test 20: RLS is in place (not a permissive dev-style policy) on the new tables.
INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM pg_policies WHERE tablename = 'ric_user_sales_controls' AND qual LIKE '%request.jwt.claims%') = 1
  AND (SELECT count(*) FROM pg_policies WHERE tablename = 'rih_sales_orders' AND qual LIKE '%request.jwt.claims%') = 1,
  'ok 20 — ric_user_sales_controls and rih_sales_orders use the auth_rw_<table> JWT-claims RLS pattern, not a permissive dev policy'
);

-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
