-- ============================================================
-- 038_grn_test.sql — pgTAP tests for migration 038
--
-- Functions: fn_save_grn, fn_approve_grn
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
  v_client_id    uuid := '00000000-0000-0000-0038-000000000001';
  v_company_id   uuid := '00000000-0000-0000-0038-000000000002';
  v_loc_id       uuid := '00000000-0000-0000-0038-000000000003';
  v_user_id      uuid := '00000000-0000-0000-0038-000000000004';
  v_currency_id  uuid := '00000000-0000-0000-0038-000000000005';
  v_supplier_id  uuid := '00000000-0000-0000-0038-000000000006';
  v_stock_acc_id uuid := '00000000-0000-0000-0038-000000000007';
  v_accrual_acc_id uuid := '00000000-0000-0000-0038-000000000008';
  v_product_id   uuid := '00000000-0000-0000-0038-000000000009';
  v_fy_id        uuid := '00000000-0000-0000-0038-000000000010';
  v_tax_id       uuid := '00000000-0000-0000-0038-000000000011';
  v_tax_rate_id  uuid := '00000000-0000-0000-0038-000000000012';
  v_tax_group_id uuid := '00000000-0000-0000-0038-000000000013';
  v_tax_member_id uuid := '00000000-0000-0000-0038-000000000014';
  v_stock_link_type uuid; v_accrual_link_type uuid;
  v_po_order_no  text := 'PO-TEST-038-1';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST038', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST038 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test038 Loc', 'T38', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test038', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_currencies (id, client_id, company_id, currency_id, currency_name, currency_notation, is_active, created_at)
  VALUES (v_currency_id, v_client_id, v_company_id, 'USD', 'US Dollar', '$', true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier_id,    v_client_id, v_company_id, '5001', 'Test Supplier',      'Supplier', true, true, false, now()),
    (v_stock_acc_id,   v_client_id, v_company_id, '1300', 'Stock Account',      'General',  true, true, false, now()),
    (v_accrual_acc_id, v_client_id, v_company_id, '2200', 'Purchase Accrual',   'General',  true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'GRN-00001', 'GRN Test Item', v_currency_id, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST038', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- Tax: 16% VAT, one-member group
  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, gl_input_account_id, created_by)
  VALUES (v_tax_id, v_client_id, v_company_id, 'VAT16', 'VAT 16%', 'VAT', 'PURCHASE', v_accrual_acc_id, v_user_id)
  ON CONFLICT (id) DO NOTHING;
  -- (gl_input_account_id reuses v_accrual_acc_id here purely to keep the fixture
  --  list short — a real deployment would use a dedicated Input VAT account.)

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_tax_rate_id, v_client_id, v_company_id, v_tax_id, 'STANDARD', 16.0000, '2020-01-01', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, created_by)
  VALUES (v_tax_group_id, v_client_id, v_company_id, 'VAT_STD', 'VAT Standard', 'PURCHASE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_tax_member_id, v_client_id, v_company_id, v_tax_group_id, v_tax_id, 1)
  ON CONFLICT (id) DO NOTHING;

  -- Account Link Setup: COMPANY-level defaults for STOCK_ACCOUNT + PURCHASE_ACCRUAL_ACCOUNT
  SELECT id INTO v_stock_link_type FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_accrual_link_type FROM rim_account_link_types WHERE link_key = 'PURCHASE_ACCRUAL_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_accrual_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, NULL, v_stock_acc_id),
    (v_client_id, v_company_id, v_accrual_link_type, NULL, v_accrual_acc_id)
  ON CONFLICT DO NOTHING;

  -- PO: one line, 10 units @ 100, 16% VAT — gross 1000, tax 160, final 1160.
  -- Inserted directly (not via fn_save/fn_approve_purchase_order) since this
  -- test targets GRN, not PO's own save/approve path — already covered
  -- elsewhere. status = 'APPROVED' so GRN can legally reference it.
  INSERT INTO rih_purchase_orders (
    client_id, company_id, location_id, order_no, order_date, po_type,
    supplier_id, po_currency_id, status, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, v_po_order_no, '2026-05-01', 'LOCAL',
    v_supplier_id, v_currency_id, 'APPROVED', v_user_id, v_user_id
  ) ON CONFLICT (client_id, company_id, order_no, order_date) DO NOTHING;

  INSERT INTO rid_purchase_order_lines (
    client_id, company_id, order_no, order_date, serial_no,
    product_id, base_qty, rate, gross_amount, tax_group_id, tax_amount, final_amount,
    charge_amount, landed_amount, qty_received, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_po_order_no, '2026-05-01', 1,
    v_product_id, 10, 100, 1000, v_tax_group_id, 160, 1160,
    0, 1160, 0, v_user_id, v_user_id
  ) ON CONFLICT (client_id, company_id, order_no, order_date, serial_no) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ── Save + approve the GRN (Against-PO, full receipt) ────────────────────────
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0038-000000000001',
      'company_id', '00000000-0000-0000-0038-000000000002',
      'location_id', '00000000-0000-0000-0038-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-01',
      'supplier_id', '00000000-0000-0000-0038-000000000006',
      'receipt_mode', 'AGAINST_PO',
      'grn_currency_id', '00000000-0000-0000-0038-000000000005',
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0038-000000000009',
        'source_po_order_no', 'PO-TEST-038-1', 'source_po_order_date', '2026-05-01', 'source_po_line_serial', 1,
        'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 100,
        'gross_amount', 1000, 'tax_group_id', '00000000-0000-0000-0038-000000000013',
        'tax_amount', 160, 'final_amount', 1160, 'charge_amount', 0, 'landed_amount', 1160
      )
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0038-000000000004'
  );
  PERFORM set_config('pgtap.v_grn_no_038', v_grn_no, false);

  PERFORM fn_approve_grn(
    '00000000-0000-0000-0038-000000000001', '00000000-0000-0000-0038-000000000002',
    v_grn_no, '2026-06-01'::date, '00000000-0000-0000-0038-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

-- ── Plan ──────────────────────────────────────────────────────────────────────
SELECT plan(10);

SELECT ok(
  (SELECT status FROM rih_grn_headers
   WHERE client_id = '00000000-0000-0000-0038-000000000001' AND grn_no = current_setting('pgtap.v_grn_no_038')) = 'APPROVED',
  'ok 1 — GRN header status is APPROVED after fn_approve_grn'
);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0038-000000000001' AND product_id = '00000000-0000-0000-0038-000000000009') = 10
  AND
  (SELECT cost_price FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0038-000000000001' AND product_id = '00000000-0000-0000-0038-000000000009') = 100,
  'ok 2 — stock posted: current_stock = 10, cost_price = 100 (rate * rate_to_base, qty_before was 0)'
);

SELECT ok(
  (SELECT status FROM rih_purchase_orders
   WHERE client_id = '00000000-0000-0000-0038-000000000001' AND order_no = 'PO-TEST-038-1') = 'CLOSED',
  'ok 3 — PO status rolled up to CLOSED (qty_received 10 = ordered 10)'
);

SELECT ok(
  (SELECT qty_received FROM rid_purchase_order_lines
   WHERE client_id = '00000000-0000-0000-0038-000000000001' AND order_no = 'PO-TEST-038-1' AND serial_no = 1) = 10,
  'ok 4 — PO line qty_received incremented by the GRN''s base_qty'
);

SELECT ok(
  (SELECT posted_voucher_no FROM rih_grn_headers
   WHERE client_id = '00000000-0000-0000-0038-000000000001' AND grn_no = current_setting('pgtap.v_grn_no_038')) IS NOT NULL,
  'ok 5 — GRN header records the finance voucher it triggered (traceability)'
);

SELECT ok(
  (SELECT is_posted FROM rih_finance_headers
   WHERE client_id = '00000000-0000-0000-0038-000000000001'
     AND trans_no = (SELECT posted_voucher_no FROM rih_grn_headers WHERE grn_no = current_setting('pgtap.v_grn_no_038'))) = true,
  'ok 6 — the auto-generated finance voucher posted successfully (balanced: Stock Dr 1000 = Purchase Accrual Cr 1000, VAT deferred to the future Purchase Invoice)'
);

-- migration 050: VAT is deliberately NOT posted at GRN time (recoverable
-- asset, not recognized until the real supplier tax invoice exists) — so
-- this GRN (gross 1000, tax 160, final 1160) must produce exactly 2 finance
-- lines, not 3, and the Purchase Accrual Cr must be the tax-EXCLUSIVE 1000.
SELECT ok(
  (SELECT count(*) FROM rid_finance_lines
   WHERE client_id = '00000000-0000-0000-0038-000000000001'
     AND trans_no = (SELECT posted_voucher_no FROM rih_grn_headers WHERE grn_no = current_setting('pgtap.v_grn_no_038'))
     AND is_deleted = false) = 2,
  'ok 7 — exactly 2 finance lines posted (Stock Dr + Accrual Cr) — no separate VAT line at GRN time'
);

SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE client_id = '00000000-0000-0000-0038-000000000001'
     AND trans_no = (SELECT posted_voucher_no FROM rih_grn_headers WHERE grn_no = current_setting('pgtap.v_grn_no_038'))
     AND source_line_type = 'ACCRUAL' AND source_line_no = 1) = 1000,
  'ok 8 — Purchase Accrual Cr is the tax-exclusive 1000 (not 1160), tagged source_line_type=ACCRUAL/source_line_no=1'
);

SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE client_id = '00000000-0000-0000-0038-000000000001'
     AND trans_no = (SELECT posted_voucher_no FROM rih_grn_headers WHERE grn_no = current_setting('pgtap.v_grn_no_038'))
     AND source_line_type = 'STOCK' AND source_line_no = 1) = 1000,
  'ok 9 — Stock Dr is tagged source_line_type=STOCK/source_line_no=1, traceable back to this GRN line'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Direct GRN (no PO) save path
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_direct_grn_no text;
BEGIN
  v_direct_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0038-000000000001',
      'company_id', '00000000-0000-0000-0038-000000000002',
      'location_id', '00000000-0000-0000-0038-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-02',
      'supplier_id', '00000000-0000-0000-0038-000000000006',
      'receipt_mode', 'DIRECT',
      'grn_currency_id', '00000000-0000-0000-0038-000000000005',
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0038-000000000009',
        'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 50,
        'gross_amount', 250, 'tax_amount', 0, 'final_amount', 250, 'charge_amount', 0, 'landed_amount', 250
      )
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0038-000000000004'
  );
  PERFORM set_config('pgtap.v_direct_grn_no_038', v_direct_grn_no, false);
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT receipt_mode FROM rih_grn_headers
   WHERE client_id = '00000000-0000-0000-0038-000000000001' AND grn_no = current_setting('pgtap.v_direct_grn_no_038')) = 'DIRECT'
  AND NOT EXISTS (
    SELECT 1 FROM v_grn_po_links
    WHERE client_id = '00000000-0000-0000-0038-000000000001' AND grn_no = current_setting('pgtap.v_direct_grn_no_038')
  ),
  'ok 10 — Direct GRN saves with receipt_mode=DIRECT and shows zero rows in v_grn_po_links (no PO reference on its line)'
);

SELECT * FROM finish();
ROLLBACK;
