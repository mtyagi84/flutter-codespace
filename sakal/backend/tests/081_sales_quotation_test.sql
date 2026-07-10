-- ============================================================
-- 081_sales_quotation_test.sql — pgTAP tests for migration 081
-- (Sales Quotation: fn_save_sales_quotation, fn_approve_sales_quotation,
-- fn_update_sales_quotation_status, customer/prospect toggle, item-wise
-- charge apportionment plumbing)
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
-- Fixture: one Customer account, one Prospect (no account — typed
-- directly), one product (untracked, no tax group — this module never
-- computes tax/GL itself, it's a pure store of whatever the caller
-- already computed), one SALES-applicable additional charge ("Delivery").
-- No stock/GL fixture needed at all — Sales Quotation never touches
-- either.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client_id    uuid := '00000000-0000-0000-0081-000000000001';
  v_company_id   uuid := '00000000-0000-0000-0081-000000000002';
  v_loc_id       uuid := '00000000-0000-0000-0081-000000000003';
  v_user_id      uuid := '00000000-0000-0000-0081-000000000004';
  v_customer_id  uuid := '00000000-0000-0000-0081-000000000005';
  v_product_id   uuid := '00000000-0000-0000-0081-000000000006';
  v_charge_id    uuid := '00000000-0000-0000-0081-000000000007';
  v_uom_id       uuid := '00000000-0000-0000-0081-000000000008';
  v_usd_ccy_id   uuid;
  v_unit_type_id uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST081', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST081 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test081 Loc', 'T81', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test081', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_customer_id, v_client_id, v_company_id, '3081', 'Test081 Customer', 'Customer', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';

  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'SQ-001', 'Test Item', v_usd_ccy_id, 'NONE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_additional_charges (id, client_id, company_id, charge_code, charge_name, applicable_on, is_taxable, nature, amount_or_percent)
  VALUES (v_charge_id, v_client_id, v_company_id, 'DEL081', 'Delivery', 'SALES', false, 'ADD', 'AMOUNT')
  ON CONFLICT (id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

SELECT plan(20);

-- ══════════════════════════════════════════════════════════════════════════════
-- Quotation A: full lifecycle. CUSTOMER type, 1 line (qty 10 @ 30 = 300),
-- 1 charge (Delivery, AMOUNT 20, fully apportioned onto the single line
-- since there's only one line: allocation_factor = 20/300).
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_quo_no text;
BEGIN
  v_quo_no := fn_save_sales_quotation(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
      'location_id', '00000000-0000-0000-0081-000000000003',
      'quotation_no', NULL, 'quotation_date', '2026-07-01', 'valid_until_date', '2026-07-16',
      'customer_type', 'CUSTOMER', 'customer_id', '00000000-0000-0000-0081-000000000005',
      'party_name', 'Test081 Customer', 'party_phone', '0810000000', 'party_email', 'customer@test081.com',
      'quotation_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0081-000000000001'
                                   AND company_id = '00000000-0000-0000-0081-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 300, 'discount_amount', 0, 'charges_amount', 20, 'tax_amount', 0, 'grand_total', 320,
      'remarks', 'Initial draft'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
      'uom_id', '00000000-0000-0000-0081-000000000008', 'uom_conversion_factor', 1,
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 30,
      'gross_amount', 300, 'discount_percent', 0, 'discount_amount', 0, 'tax_amount', 0,
      'final_amount', 300, 'base_amount', 300, 'local_amount', 300,
      'charge_amount', 20, 'landed_amount', 320
    )),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'charge_id', '00000000-0000-0000-0081-000000000007', 'charge_name', 'Delivery',
      'is_taxable', false, 'nature', 'ADD', 'amount_or_percent', 'AMOUNT',
      'amount', 20, 'tax_amount', 0, 'allocation_factor', 0.06666667
    )),
    '00000000-0000-0000-0081-000000000004'
  );
  PERFORM set_config('pgtap.v_quo_a_081', v_quo_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_quo_a_081') LIKE 'SQ/T81/%',
  'ok 1 — quotation_no assigned via fn_next_trans_no, embeds SQ type + T81 location code'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 'DRAFT',
  'ok 2 — new quotation saved as DRAFT'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT party_name FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 'Test081 Customer'
  AND (SELECT customer_id FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = '00000000-0000-0000-0081-000000000005',
  'ok 3 — CUSTOMER-type party snapshot stored correctly alongside the real customer_id'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rid_sales_quotation_lines WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 1
  AND (SELECT landed_amount FROM rid_sales_quotation_lines WHERE quotation_no = current_setting('pgtap.v_quo_a_081') AND serial_no = 1) = 320,
  'ok 4 — 1 line saved, landed_amount (final 300 + apportioned charge 20) = 320'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rid_sales_quotation_charges WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 1
  AND round((SELECT allocation_factor FROM rid_sales_quotation_charges WHERE quotation_no = current_setting('pgtap.v_quo_a_081'))::numeric, 4) = 0.0667,
  'ok 5 — 1 charge saved with its allocation_factor (20/300 ~= 0.0667)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT grand_total FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 320,
  'ok 6 — header grand_total stored as passed (300 + 20 charges)'
);

-- ── Re-save (edit) the same DRAFT — remarks changes, line count must not double ──
DO $$
BEGIN
  PERFORM fn_save_sales_quotation(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
      'location_id', '00000000-0000-0000-0081-000000000003',
      'quotation_no', current_setting('pgtap.v_quo_a_081'), 'quotation_date', '2026-07-01', 'valid_until_date', '2026-07-16',
      'customer_type', 'CUSTOMER', 'customer_id', '00000000-0000-0000-0081-000000000005',
      'party_name', 'Test081 Customer',
      'quotation_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0081-000000000001'
                                   AND company_id = '00000000-0000-0000-0081-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 300, 'discount_amount', 0, 'charges_amount', 20, 'tax_amount', 0, 'grand_total', 320,
      'remarks', 'Edited draft'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
      'uom_id', '00000000-0000-0000-0081-000000000008', 'uom_conversion_factor', 1,
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 30,
      'gross_amount', 300, 'discount_percent', 0, 'discount_amount', 0, 'tax_amount', 0,
      'final_amount', 300, 'base_amount', 300, 'local_amount', 300, 'charge_amount', 20, 'landed_amount', 320
    )),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'charge_id', '00000000-0000-0000-0081-000000000007', 'charge_name', 'Delivery',
      'is_taxable', false, 'nature', 'ADD', 'amount_or_percent', 'AMOUNT', 'amount', 20, 'tax_amount', 0, 'allocation_factor', 0.06666667
    )),
    '00000000-0000-0000-0081-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT remarks FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 'Edited draft'
  AND (SELECT count(*) FROM rid_sales_quotation_lines WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 1,
  'ok 7 — re-saving a DRAFT updates the header and does not duplicate lines'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Validation failures at Save time
-- ══════════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_save_sales_quotation(
       jsonb_build_object('client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
         'location_id', '00000000-0000-0000-0081-000000000003', 'quotation_no', NULL, 'quotation_date', '2026-07-02',
         'valid_until_date', '2026-07-17', 'customer_type', 'CUSTOMER', 'customer_id', '00000000-0000-0000-0081-000000000005',
         'party_name', 'Test081 Customer'),
       '[]'::jsonb, '[]'::jsonb, '00000000-0000-0000-0081-000000000004'
     ) $$,
  'Add at least one line to raise a Sales Quotation.',
  'ok 8 — saving with zero lines is rejected'
);

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_save_sales_quotation(
       jsonb_build_object('client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
         'location_id', '00000000-0000-0000-0081-000000000003', 'quotation_no', NULL, 'quotation_date', '2026-07-02',
         'valid_until_date', '2026-07-17', 'customer_type', 'CUSTOMER', 'party_name', 'Whoever'),
       jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
         'uom_id', '00000000-0000-0000-0081-000000000008', 'base_qty', 1, 'rate', 10, 'final_amount', 10)),
       '[]'::jsonb, '00000000-0000-0000-0081-000000000004'
     ) $$,
  'Select a customer, or switch to Prospect and enter their details.',
  'ok 9 — CUSTOMER type with no customer_id is rejected'
);

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_save_sales_quotation(
       jsonb_build_object('client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
         'location_id', '00000000-0000-0000-0081-000000000003', 'quotation_no', NULL, 'quotation_date', '2026-07-02',
         'valid_until_date', '2026-07-17', 'customer_type', 'PROSPECT', 'party_name', ''),
       jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
         'uom_id', '00000000-0000-0000-0081-000000000008', 'base_qty', 1, 'rate', 10, 'final_amount', 10)),
       '[]'::jsonb, '00000000-0000-0000-0081-000000000004'
     ) $$,
  'Enter the prospect''s name.',
  'ok 10 — PROSPECT type with no party_name is rejected'
);

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_save_sales_quotation(
       jsonb_build_object('client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
         'location_id', '00000000-0000-0000-0081-000000000003', 'quotation_no', NULL, 'quotation_date', '2026-07-10',
         'valid_until_date', '2026-07-05', -- BEFORE quotation_date — violates chk_sales_quotation_validity
         'customer_type', 'CUSTOMER', 'customer_id', '00000000-0000-0000-0081-000000000005', 'party_name', 'Test081 Customer',
         'quotation_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0081-000000000001'
                                      AND company_id = '00000000-0000-0000-0081-000000000002' AND currency_id = 'USD')),
       jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
         'uom_id', '00000000-0000-0000-0081-000000000008', 'base_qty', 1, 'rate', 10, 'final_amount', 10)),
       '[]'::jsonb, '00000000-0000-0000-0081-000000000004'
     ) $$,
  '23514', -- check_violation SQLSTATE — chk_sales_quotation_validity fires at the DB level, not a custom RAISE
  'ok 11 — Valid Until before Quotation Date is rejected (chk_sales_quotation_validity)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Quotation B: PROSPECT — no rim_accounts row involved at all.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_quo_no text;
BEGIN
  v_quo_no := fn_save_sales_quotation(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
      'location_id', '00000000-0000-0000-0081-000000000003',
      'quotation_no', NULL, 'quotation_date', '2026-07-03', 'valid_until_date', '2026-07-18',
      'customer_type', 'PROSPECT', 'party_name', 'Jane Prospect', 'party_phone', '0820000000',
      'quotation_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0081-000000000001'
                                   AND company_id = '00000000-0000-0000-0081-000000000002' AND currency_id = 'USD'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 100, 'discount_amount', 0, 'charges_amount', 0, 'tax_amount', 0, 'grand_total', 100
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
      'uom_id', '00000000-0000-0000-0081-000000000008', 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 20,
      'gross_amount', 100, 'final_amount', 100, 'base_amount', 100, 'local_amount', 100
    )),
    '[]'::jsonb,
    '00000000-0000-0000-0081-000000000004'
  );
  PERFORM set_config('pgtap.v_quo_b_081', v_quo_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT customer_id IS NULL AND customer_type = 'PROSPECT' AND party_name = 'Jane Prospect'
   FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_b_081')),
  'ok 12 — Prospect quotation saves with customer_id NULL and the typed party_name'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Approve-time line validation (separate throwaway quotations)
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_quo_no text;
BEGIN
  v_quo_no := fn_save_sales_quotation(
    jsonb_build_object('client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
      'location_id', '00000000-0000-0000-0081-000000000003', 'quotation_no', NULL, 'quotation_date', '2026-07-04',
      'valid_until_date', '2026-07-19', 'customer_type', 'CUSTOMER', 'customer_id', '00000000-0000-0000-0081-000000000005',
      'party_name', 'Test081 Customer',
      'quotation_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0081-000000000001'
                                   AND company_id = '00000000-0000-0000-0081-000000000002' AND currency_id = 'USD')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
      'uom_id', '00000000-0000-0000-0081-000000000008', 'base_qty', 0, 'rate', 10, 'final_amount', 0)), -- qty 0 — invalid at Approve
    '[]'::jsonb, '00000000-0000-0000-0081-000000000004'
  );
  PERFORM set_config('pgtap.v_quo_zeroqty_081', v_quo_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_approve_sales_quotation(
       '00000000-0000-0000-0081-000000000001', '00000000-0000-0000-0081-000000000002',
       current_setting('pgtap.v_quo_zeroqty_081'), '2026-07-04'::date, '00000000-0000-0000-0081-000000000004'
     ) $$,
  'LINE_QTY_REQUIRED',
  'ok 13 — a zero-quantity line is rejected at Approve time'
);

DO $$
DECLARE v_quo_no text;
BEGIN
  v_quo_no := fn_save_sales_quotation(
    jsonb_build_object('client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
      'location_id', '00000000-0000-0000-0081-000000000003', 'quotation_no', NULL, 'quotation_date', '2026-07-04',
      'valid_until_date', '2026-07-19', 'customer_type', 'CUSTOMER', 'customer_id', '00000000-0000-0000-0081-000000000005',
      'party_name', 'Test081 Customer',
      'quotation_currency_id', (SELECT id FROM rim_currencies WHERE client_id = '00000000-0000-0000-0081-000000000001'
                                   AND company_id = '00000000-0000-0000-0081-000000000002' AND currency_id = 'USD')),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
      'uom_id', '00000000-0000-0000-0081-000000000008', 'base_qty', 1, 'rate', -5, 'final_amount', -5)), -- negative rate — invalid at Approve
    '[]'::jsonb, '00000000-0000-0000-0081-000000000004'
  );
  PERFORM set_config('pgtap.v_quo_negrate_081', v_quo_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_approve_sales_quotation(
       '00000000-0000-0000-0081-000000000001', '00000000-0000-0000-0081-000000000002',
       current_setting('pgtap.v_quo_negrate_081'), '2026-07-04'::date, '00000000-0000-0000-0081-000000000004'
     ) $$,
  'LINE_RATE_INVALID',
  'ok 14 — a negative rate line is rejected at Approve time'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Quotation A: Approve, then exercise the DRAFT-only lock + status transitions
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_approve_sales_quotation(
    '00000000-0000-0000-0081-000000000001', '00000000-0000-0000-0081-000000000002',
    current_setting('pgtap.v_quo_a_081'), '2026-07-01'::date, '00000000-0000-0000-0081-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status = 'APPROVED' AND approved_by = '00000000-0000-0000-0081-000000000004' AND approved_at IS NOT NULL
   FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')),
  'ok 15 — Approve succeeds: status APPROVED, approved_by/approved_at stamped'
);

DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM fn_approve_sales_quotation(
      '00000000-0000-0000-0081-000000000001', '00000000-0000-0000-0081-000000000002',
      current_setting('pgtap.v_quo_a_081'), '2026-07-01'::date, '00000000-0000-0000-0081-000000000004'
    );
  EXCEPTION WHEN OTHERS THEN
    v_caught := true;
  END;
  PERFORM set_config('pgtap.v_reapprove_caught_081', v_caught::text, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_reapprove_caught_081')::boolean = true,
  'ok 16 — re-approving an already-APPROVED quotation raises an exception'
);

DO $$
DECLARE v_caught boolean := false;
BEGIN
  BEGIN
    PERFORM fn_save_sales_quotation(
      jsonb_build_object('client_id', '00000000-0000-0000-0081-000000000001', 'company_id', '00000000-0000-0000-0081-000000000002',
        'location_id', '00000000-0000-0000-0081-000000000003', 'quotation_no', current_setting('pgtap.v_quo_a_081'),
        'quotation_date', '2026-07-01', 'valid_until_date', '2026-07-16', 'customer_type', 'CUSTOMER',
        'customer_id', '00000000-0000-0000-0081-000000000005', 'party_name', 'Test081 Customer'),
      jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', '00000000-0000-0000-0081-000000000006',
        'uom_id', '00000000-0000-0000-0081-000000000008', 'base_qty', 10, 'rate', 30, 'final_amount', 300)),
      '[]'::jsonb, '00000000-0000-0000-0081-000000000004'
    );
  EXCEPTION WHEN OTHERS THEN
    v_caught := true;
  END;
  PERFORM set_config('pgtap.v_editapproved_caught_081', v_caught::text, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_editapproved_caught_081')::boolean = true,
  'ok 17 — editing an APPROVED quotation (no longer DRAFT) raises an exception'
);

DO $$
BEGIN
  PERFORM fn_update_sales_quotation_status(
    '00000000-0000-0000-0081-000000000001', '00000000-0000-0000-0081-000000000002',
    current_setting('pgtap.v_quo_a_081'), '2026-07-01'::date, 'SENT', '00000000-0000-0000-0081-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 'SENT',
  'ok 18 — APPROVED -> SENT transition succeeds'
);

DO $$
BEGIN
  PERFORM fn_update_sales_quotation_status(
    '00000000-0000-0000-0081-000000000001', '00000000-0000-0000-0081-000000000002',
    current_setting('pgtap.v_quo_a_081'), '2026-07-01'::date, 'ACCEPTED', '00000000-0000-0000-0081-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_quotations WHERE quotation_no = current_setting('pgtap.v_quo_a_081')) = 'ACCEPTED',
  'ok 19 — SENT -> ACCEPTED transition succeeds'
);

INSERT INTO test_results (result) SELECT throws_ok(
  $$ SELECT fn_update_sales_quotation_status(
       '00000000-0000-0000-0081-000000000001', '00000000-0000-0000-0081-000000000002',
       current_setting('pgtap.v_quo_a_081'), '2026-07-01'::date, 'SENT', '00000000-0000-0000-0081-000000000004'
     ) $$,
  'INVALID_STATUS_TRANSITION',
  'ok 20 — ACCEPTED -> SENT (going backwards) is rejected'
);

-- Final result: every one of the 20 assertions, in order. Look for any row
-- NOT starting with "ok " — that's the failing one, with pgTAP's own
-- expected-vs-actual diagnostic text right below it in the same column.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
