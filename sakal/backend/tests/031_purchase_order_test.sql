-- ============================================================
-- 031_purchase_order_test.sql — pgTAP tests for fn_save_purchase_order /
-- fn_approve_purchase_order (final behavior after 031/039/040/041/042)
--
-- Functions: fn_save_purchase_order, fn_approve_purchase_order
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
  v_client_id      uuid := '00000000-0000-0000-0031-000000000001';
  v_company_id     uuid := '00000000-0000-0000-0031-000000000002';
  v_loc_id         uuid := '00000000-0000-0000-0031-000000000003';
  v_user_id        uuid := '00000000-0000-0000-0031-000000000004';
  v_currency_id    uuid;  -- read back trigger-seeded USD, see below
  v_supplier_id    uuid := '00000000-0000-0000-0031-000000000006';
  v_product_id     uuid := '00000000-0000-0000-0031-000000000007';
  v_fy_id          uuid := '00000000-0000-0000-0031-000000000008';
  v_tax_id         uuid := '00000000-0000-0000-0031-000000000009';
  v_tax_rate_id    uuid := '00000000-0000-0000-0031-000000000010';
  v_tax_group_id   uuid := '00000000-0000-0000-0031-000000000011';
  v_tax_member_id  uuid := '00000000-0000-0000-0031-000000000012';
  v_uom_id         uuid := '00000000-0000-0000-0031-000000000013';
  v_term_master_id uuid := '00000000-0000-0000-0031-000000000014';
  v_charge_id      uuid := '00000000-0000-0000-0031-000000000015';
  v_unit_type_id   uuid;
  v_term_type_id   uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST031', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST031 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test031 Loc', 'T31', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test031', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- ric_companies has an AFTER INSERT trigger (trg_seed_company_currencies,
  -- migration 007) that auto-seeds every world currency, including USD, for
  -- the new company. Explicitly inserting our own USD row here collides on
  -- the real unique constraint (client_id, company_id, currency_id), which
  -- an ON CONFLICT (id) target doesn't catch (different id). Read back the
  -- trigger-seeded id instead (same fix already applied in 054/061's tests).
  SELECT id INTO v_currency_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_supplier_id, v_client_id, v_company_id, '5001', 'Test Supplier', 'Supplier', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'PO-TEST-00001', 'PO Test Item', v_currency_id, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST031', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- Tax: 16% VAT, one-member group (mirrors 038_grn_test.sql's fixture shape)
  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, gl_input_account_id, created_by)
  VALUES (v_tax_id, v_client_id, v_company_id, 'VAT16', 'VAT 16%', 'VAT', 'PURCHASE', v_supplier_id, v_user_id)
  ON CONFLICT (id) DO NOTHING;
  -- (gl_input_account_id reuses v_supplier_id purely to keep the fixture list
  --  short — PO approval never posts GL, so this FK is never actually read.)

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_tax_rate_id, v_client_id, v_company_id, v_tax_id, 'STANDARD', 16.0000, '2020-01-01', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, created_by)
  VALUES (v_tax_group_id, v_client_id, v_company_id, 'VAT_STD', 'VAT Standard', 'PURCHASE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_tax_member_id, v_client_id, v_company_id, v_tax_group_id, v_tax_id, 1)
  ON CONFLICT (id) DO NOTHING;

  -- UOM common master (type_key='UNIT', seeded in 022) + Payment Term master (type_key='PAYMENT_TERMS', seeded in 040)
  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, is_active, is_deleted, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece', true, false, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_term_type_id FROM rim_common_master_types WHERE type_key = 'PAYMENT_TERMS';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, is_active, is_deleted, created_by)
  VALUES (v_term_master_id, v_client_id, v_company_id, v_term_type_id, 'Credit 30 Days', true, false, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_additional_charges (id, client_id, company_id, charge_code, charge_name, applicable_on, is_taxable, nature, amount_or_percent, is_active, is_deleted, created_by)
  VALUES (v_charge_id, v_client_id, v_company_id, 'FRT', 'Freight', 'PURCHASE', false, 'ADD', 'AMOUNT', true, false, v_user_id)
  ON CONFLICT (id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ── Test 1: fn_save_purchase_order — new DRAFT with line + charge + payment term ──
DO $$
DECLARE
  v_order_no text;
BEGIN
  v_order_no := fn_save_purchase_order(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0031-000000000001',
      'company_id', '00000000-0000-0000-0031-000000000002',
      'location_id', '00000000-0000-0000-0031-000000000003',
      'order_no', NULL, 'order_date', '2026-06-01', 'po_type', 'LOCAL',
      'supplier_id', '00000000-0000-0000-0031-000000000006',
      'po_currency_id', '00000000-0000-0000-0031-000000000005',
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0031-000000000007',
        'uom_id', '00000000-0000-0000-0031-000000000013',
        'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 100,
        'gross_amount', 1000, 'tax_group_id', '00000000-0000-0000-0031-000000000011',
        'tax_amount', 160, 'final_amount', 1160
      )
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'charge_id', '00000000-0000-0000-0031-000000000015',
          'charge_name', 'Freight', 'amount_or_percent', 'AMOUNT', 'amount', 50)
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'term_id', '00000000-0000-0000-0031-000000000014',
          'term_name', 'Credit 30 Days', 'description', '30 days from GRN date')
    ),
    '00000000-0000-0000-0031-000000000004'
  );
  PERFORM set_config('pgtap.v_order_no_031', v_order_no, false);
END;
$$ LANGUAGE plpgsql;

-- ── Plan ──────────────────────────────────────────────────────────────────────
SELECT plan(10);

SELECT ok(
  (SELECT status FROM rih_purchase_orders
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031')) = 'DRAFT'
  AND (SELECT po_type FROM rih_purchase_orders
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031')) = 'LOCAL',
  'ok 1 — fn_save_purchase_order creates a DRAFT LOCAL header'
);

SELECT ok(
  (SELECT base_qty FROM rid_purchase_order_lines
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031') AND serial_no = 1) = 10
  AND (SELECT final_amount FROM rid_purchase_order_lines
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031') AND serial_no = 1) = 1160,
  'ok 2 — line saved with correct base_qty (10) and final_amount (1160 = 1000 + 160 tax)'
);

SELECT ok(
  (SELECT amount FROM rid_po_charge_lines
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031') AND serial_no = 1) = 50,
  'ok 3 — charge line saved with correct amount (50)'
);

SELECT ok(
  (SELECT term_name FROM rid_po_payment_terms
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031') AND serial_no = 1) = 'Credit 30 Days'
  AND (SELECT updated_by FROM rid_po_payment_terms
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031') AND serial_no = 1) = '00000000-0000-0000-0031-000000000004',
  'ok 4 — payment term saved with frozen term_name and updated_by set (migration 042 audit-column fix)'
);

-- ── Test 2: editing the DRAFT replaces lines (delete+reinsert) ────────────────
DO $$
BEGIN
  PERFORM fn_save_purchase_order(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0031-000000000001',
      'company_id', '00000000-0000-0000-0031-000000000002',
      'location_id', '00000000-0000-0000-0031-000000000003',
      'order_no', current_setting('pgtap.v_order_no_031'), 'order_date', '2026-06-01', 'po_type', 'LOCAL',
      'supplier_id', '00000000-0000-0000-0031-000000000006',
      'po_currency_id', '00000000-0000-0000-0031-000000000005',
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0031-000000000007',
        'uom_id', '00000000-0000-0000-0031-000000000013',
        'uom_conversion_factor', 1, 'qty_pack', 25, 'qty_loose', 0, 'base_qty', 25, 'rate', 100,
        'gross_amount', 2500, 'tax_amount', 0, 'final_amount', 2500
      )
    ),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0031-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT base_qty FROM rid_purchase_order_lines
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031') AND serial_no = 1) = 25
  AND NOT EXISTS (
    SELECT 1 FROM rid_po_charge_lines
    WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031')
  ),
  'ok 5 — re-saving the DRAFT replaces the line (base_qty now 25) and clears the removed charge'
);

-- ── Test 3: PO_NO_LINES — approving a PO with zero lines is rejected ─────────
DO $$
DECLARE
  v_no_lines_order text;
BEGIN
  v_no_lines_order := fn_save_purchase_order(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0031-000000000001',
      'company_id', '00000000-0000-0000-0031-000000000002',
      'location_id', '00000000-0000-0000-0031-000000000003',
      'order_no', NULL, 'order_date', '2026-06-01', 'po_type', 'LOCAL',
      'supplier_id', '00000000-0000-0000-0031-000000000006',
      'po_currency_id', '00000000-0000-0000-0031-000000000005',
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0031-000000000004'
  );
  PERFORM set_config('pgtap.v_no_lines_order_031', v_no_lines_order, false);
END;
$$ LANGUAGE plpgsql;

SELECT throws_ok(
  format($$ SELECT fn_approve_purchase_order(
    '00000000-0000-0000-0031-000000000001', '00000000-0000-0000-0031-000000000002',
    %L, '2026-06-01'::date, '00000000-0000-0000-0031-000000000004') $$,
    current_setting('pgtap.v_no_lines_order_031')),
  'PO_NO_LINES',
  'ok 6 — approving a PO with zero lines raises PO_NO_LINES'
);

-- ── Test 4: PO_LINE_INCOMPLETE — a zero-rate line is rejected ────────────────
DO $$
DECLARE
  v_incomplete_order text;
BEGIN
  v_incomplete_order := fn_save_purchase_order(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0031-000000000001',
      'company_id', '00000000-0000-0000-0031-000000000002',
      'location_id', '00000000-0000-0000-0031-000000000003',
      'order_no', NULL, 'order_date', '2026-06-01', 'po_type', 'LOCAL',
      'supplier_id', '00000000-0000-0000-0031-000000000006',
      'po_currency_id', '00000000-0000-0000-0031-000000000005',
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0031-000000000007',
        'uom_id', '00000000-0000-0000-0031-000000000013',
        'uom_conversion_factor', 1, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 0,
        'gross_amount', 0, 'tax_amount', 0, 'final_amount', 0
      )
    ),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0031-000000000004'
  );
  PERFORM set_config('pgtap.v_incomplete_order_031', v_incomplete_order, false);
END;
$$ LANGUAGE plpgsql;

SELECT throws_ok(
  format($$ SELECT fn_approve_purchase_order(
    '00000000-0000-0000-0031-000000000001', '00000000-0000-0000-0031-000000000002',
    %L, '2026-06-01'::date, '00000000-0000-0000-0031-000000000004') $$,
    current_setting('pgtap.v_incomplete_order_031')),
  'PO_LINE_INCOMPLETE',
  'ok 7 — approving a PO with a zero-rate line raises PO_LINE_INCOMPLETE'
);

-- ── Test 5: happy-path approve, then immutability + double-approve guards ────
DO $$
BEGIN
  PERFORM fn_approve_purchase_order(
    '00000000-0000-0000-0031-000000000001', '00000000-0000-0000-0031-000000000002',
    current_setting('pgtap.v_order_no_031'), '2026-06-01'::date, '00000000-0000-0000-0031-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT status FROM rih_purchase_orders
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031')) = 'APPROVED'
  AND (SELECT approved_by FROM rih_purchase_orders
   WHERE client_id = '00000000-0000-0000-0031-000000000001' AND order_no = current_setting('pgtap.v_order_no_031')) = '00000000-0000-0000-0031-000000000004',
  'ok 8 — approving a complete PO sets status=APPROVED and approved_by'
);

-- These two messages interpolate the actual order_no/status at runtime
-- (RAISE EXCEPTION 'Purchase Order % is % ...', ...) so we check the
-- SQLSTATE only (P0001 = plain PL/pgSQL raised exception, no explicit
-- code), not the exact text — same pattern as the unique-violation checks
-- in 026_product_master_test.sql (throws_ok(sql, sqlstate, NULL, desc)).
SELECT throws_ok(
  format($$ SELECT fn_approve_purchase_order(
    '00000000-0000-0000-0031-000000000001', '00000000-0000-0000-0031-000000000002',
    %L, '2026-06-01'::date, '00000000-0000-0000-0031-000000000004') $$,
    current_setting('pgtap.v_order_no_031')),
  'P0001', NULL,
  'ok 9 — approving an already-APPROVED PO is rejected'
);

SELECT throws_ok(
  format($$ SELECT fn_save_purchase_order(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0031-000000000001',
      'company_id', '00000000-0000-0000-0031-000000000002',
      'location_id', '00000000-0000-0000-0031-000000000003',
      'order_no', %L, 'order_date', '2026-06-01', 'po_type', 'LOCAL',
      'supplier_id', '00000000-0000-0000-0031-000000000006',
      'po_currency_id', '00000000-0000-0000-0031-000000000005',
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0031-000000000004') $$,
    current_setting('pgtap.v_order_no_031')),
  'P0001', NULL,
  'ok 10 — editing an already-APPROVED PO is rejected (immutability)'
);

SELECT * FROM finish();
ROLLBACK;
