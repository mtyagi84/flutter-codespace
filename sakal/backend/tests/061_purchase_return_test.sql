-- ============================================================
-- 061_purchase_return_test.sql — pgTAP tests for migrations 060/061
--
-- Functions: fn_post_stock_movement (negative-stock check),
--            fn_save_purchase_return, fn_approve_purchase_return
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. All rows show "ok N — ..." with no "not ok" lines.
--   4. finish() returns no rows = all passed.
--
-- Hardcoded fixture UUIDs — no temp tables (Supabase auto-commits DO
-- blocks). Everything in USD only (base=local=return currency) — FX
-- behavior is already covered by 054's test, this file focuses on the
-- return-specific logic instead.
--
-- Three scenarios, one product, one supplier, two GRNs:
--   GRN1 (DIRECT, no tax)   — stays UNBILLED throughout.
--   GRN2 (AGAINST a PO, taxed) — billed in full before any return, so the
--     PO reopen behavior can be exercised too.
--   A. Return 3 units against GRN1 (unbilled)      -> JV only.
--   B. Return 2 units against GRN2 (billed), reopen the PO -> SDN only,
--      real VAT reversed, PO status flips back to PARTIALLY_RECEIVED.
--   C. One return spanning BOTH GRN1 and GRN2 in a single document
--      -> posts both a JV and an SDN together.
-- Plus a standalone negative-stock check (migration 060).
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_client_id        uuid := '00000000-0000-0000-0061-000000000001';
  v_company_id       uuid := '00000000-0000-0000-0061-000000000002';
  v_loc_id           uuid := '00000000-0000-0000-0061-000000000003';
  v_user_id          uuid := '00000000-0000-0000-0061-000000000004';
  v_usd_ccy_id       uuid;
  v_supplier_id      uuid := '00000000-0000-0000-0061-000000000006';
  v_stock_acc_id     uuid := '00000000-0000-0000-0061-000000000007';
  v_accrual_acc_id   uuid := '00000000-0000-0000-0061-000000000008';
  v_input_vat_acc_id uuid := '00000000-0000-0000-0061-000000000009';
  v_returns_acc_id   uuid := '00000000-0000-0000-0061-000000000010';
  v_product_id       uuid := '00000000-0000-0000-0061-000000000011';
  v_product2_id      uuid := '00000000-0000-0000-0061-000000000012';
  v_fy_id            uuid := '00000000-0000-0000-0061-000000000013';
  v_tax_id           uuid := '00000000-0000-0000-0061-000000000014';
  v_tax_rate_id      uuid := '00000000-0000-0000-0061-000000000015';
  v_tax_group_id     uuid := '00000000-0000-0000-0061-000000000016';
  v_tax_member_id    uuid := '00000000-0000-0000-0061-000000000017';
  v_stock_link_type uuid; v_accrual_link_type uuid; v_returns_link_type uuid;
  v_uom_type_id uuid; v_uom_id uuid := '00000000-0000-0000-0061-000000000018';
  v_po_order_no text := 'PO-TEST-061-1';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST061', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST061 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test061 Loc', 'T61', true, false, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test061', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- ric_companies auto-seeds every currency via trg_seed_company_currencies
  -- (007) — read back USD's trigger-assigned id rather than inserting our
  -- own (see 054's test for the full explanation of this gotcha).
  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier_id,      v_client_id, v_company_id, '5061', 'Test061 Supplier',      'Supplier', 'OHADA', true, true, false, now()),
    (v_stock_acc_id,     v_client_id, v_company_id, '1361', 'Stock Account',         'General',  'OHADA', true, true, false, now()),
    (v_accrual_acc_id,   v_client_id, v_company_id, '2261', 'Purchase Accrual',      'General',  'OHADA', true, true, false, now()),
    (v_input_vat_acc_id, v_client_id, v_company_id, '1461', 'Input VAT',             'General',  'OHADA', true, true, false, now()),
    (v_returns_acc_id,   v_client_id, v_company_id, '7861', 'Purchase Returns',      'General',  'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, created_by)
  VALUES
    (v_product_id,  v_client_id, v_company_id, 'PRET-001', 'Purchase Return Test Item A', v_usd_ccy_id, v_user_id),
    (v_product2_id, v_client_id, v_company_id, 'PRET-002', 'Purchase Return Test Item B', v_usd_ccy_id, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST061', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, gl_input_account_id, created_by)
  VALUES (v_tax_id, v_client_id, v_company_id, 'VAT16', 'VAT 16%', 'VAT', 'PURCHASE', v_input_vat_acc_id, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (id, client_id, company_id, tax_id, rate_label, rate, effective_from, created_by)
  VALUES (v_tax_rate_id, v_client_id, v_company_id, v_tax_id, 'STANDARD', 16.0000, '2020-01-01', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, created_by)
  VALUES (v_tax_group_id, v_client_id, v_company_id, 'VAT_STD', 'VAT Standard', 'PURCHASE', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_tax_member_id, v_client_id, v_company_id, v_tax_group_id, v_tax_id, 1)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link_type   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_accrual_link_type FROM rim_account_link_types WHERE link_key = 'PURCHASE_ACCRUAL_ACCOUNT';
  SELECT id INTO v_returns_link_type FROM rim_account_link_types WHERE link_key = 'PURCHASE_RETURNS_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_accrual_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_returns_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, NULL, v_stock_acc_id),
    (v_client_id, v_company_id, v_accrual_link_type, NULL, v_accrual_acc_id),
    (v_client_id, v_company_id, v_returns_link_type, NULL, v_returns_acc_id)
  ON CONFLICT DO NOTHING;

  PERFORM set_config('pgtap.v_usd_ccy_061', v_usd_ccy_id::text, false);

  -- rid_purchase_order_lines.uom_id is NOT NULL (unlike GRN/Return lines,
  -- which leave it nullable) — 038's own test fixture has this identical
  -- gap too. rim_common_master_types is a globally-seeded, un-tenanted
  -- table (type_key='UNIT' always exists); rim_common_masters itself is
  -- client+company scoped.
  SELECT id INTO v_uom_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_uom_type_id, 'Piece', v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- PO for GRN2 (Against-PO, so the reopen behavior can be exercised) —
  -- inserted directly, same shortcut 038's own test uses (PO's own
  -- save/approve path is covered elsewhere).
  INSERT INTO rih_purchase_orders (
    client_id, company_id, location_id, order_no, order_date, po_type,
    supplier_id, po_currency_id, status, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, v_po_order_no, '2026-05-01', 'LOCAL',
    v_supplier_id, v_usd_ccy_id, 'APPROVED', v_user_id, v_user_id
  ) ON CONFLICT (client_id, company_id, order_no, order_date) DO NOTHING;

  INSERT INTO rid_purchase_order_lines (
    client_id, company_id, order_no, order_date, serial_no,
    product_id, uom_id, base_qty, rate, gross_amount, tax_group_id, tax_amount, final_amount,
    charge_amount, landed_amount, qty_received, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_po_order_no, '2026-05-01', 1,
    v_product_id, v_uom_id, 10, 50, 500, v_tax_group_id, 80, 580,
    0, 580, 0, v_user_id, v_user_id
  ) ON CONFLICT (client_id, company_id, order_no, order_date, serial_no) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ── GRN1: DIRECT, 10 units @ 50 = 500, no tax — stays UNBILLED ───────────────
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0061-000000000001',
      'company_id', '00000000-0000-0000-0061-000000000002',
      'location_id', '00000000-0000-0000-0061-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-01',
      'supplier_id', '00000000-0000-0000-0061-000000000006',
      'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_usd_ccy_061'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0061-000000000011',
        'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 50,
        'gross_amount', 500, 'tax_amount', 0, 'final_amount', 500, 'charge_amount', 0, 'landed_amount', 500
      )
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0061-000000000004'
  );
  PERFORM set_config('pgtap.v_grn1_061', v_grn_no, false);

  PERFORM fn_approve_grn(
    '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-000000000002',
    v_grn_no, '2026-06-01'::date, '00000000-0000-0000-0061-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

-- ── GRN2: AGAINST PO, 10 units @ 50 = 500, 16% VAT = 80, final 580 ───────────
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0061-000000000001',
      'company_id', '00000000-0000-0000-0061-000000000002',
      'location_id', '00000000-0000-0000-0061-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-02',
      'supplier_id', '00000000-0000-0000-0061-000000000006',
      'receipt_mode', 'AGAINST_PO',
      'grn_currency_id', current_setting('pgtap.v_usd_ccy_061'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0061-000000000011',
        'source_po_order_no', 'PO-TEST-061-1', 'source_po_order_date', '2026-05-01', 'source_po_line_serial', 1,
        'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 50,
        'gross_amount', 500, 'tax_group_id', '00000000-0000-0000-0061-000000000016',
        'tax_amount', 80, 'final_amount', 580, 'charge_amount', 0, 'landed_amount', 580
      )
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0061-000000000004'
  );
  PERFORM set_config('pgtap.v_grn2_061', v_grn_no, false);

  PERFORM fn_approve_grn(
    '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-000000000002',
    v_grn_no, '2026-06-02'::date, '00000000-0000-0000-0061-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

-- ── Bill GRN2 in full (500 taxable + 80 VAT = 580), so it's BILLED before
--    any return — this is what unlocks the SDN path and the PO reopen test.
DO $$
DECLARE
  v_invoice_no text;
BEGIN
  v_invoice_no := fn_save_purchase_invoice(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0061-000000000001',
      'company_id', '00000000-0000-0000-0061-000000000002',
      'location_id', '00000000-0000-0000-0061-000000000003',
      'invoice_no', NULL, 'invoice_date', '2026-06-05',
      'supplier_id', '00000000-0000-0000-0061-000000000006',
      'supplier_invoice_no', 'SUPP-INV-061', 'supplier_invoice_date', '2026-06-04',
      'invoice_currency_id', current_setting('pgtap.v_usd_ccy_061'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 500, 'tax_amount', 80, 'invoice_total', 580
    ),
    jsonb_build_array(jsonb_build_object('grn_no', current_setting('pgtap.v_grn2_061'), 'grn_date', '2026-06-02')),
    '00000000-0000-0000-0061-000000000004'
  );

  PERFORM fn_approve_purchase_invoice(
    '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-000000000002',
    v_invoice_no, '2026-06-05'::date,
    '00000000-0000-0000-0061-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT plan(21);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0061-000000000001' AND product_id = '00000000-0000-0000-0061-000000000011') = 20,
  'ok 1 — both GRNs posted: current_stock = 10 (GRN1) + 10 (GRN2) = 20 before any return'
);

SELECT ok(
  (SELECT status FROM rih_purchase_orders WHERE order_no = 'PO-TEST-061-1') = 'CLOSED',
  'ok 2 — PO closed after GRN2 fully received it (10 = 10 ordered)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Scenario A: return 3 units against GRN1 (unbilled) — JV only.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0061-000000000001',
      'company_id', '00000000-0000-0000-0061-000000000002',
      'location_id', '00000000-0000-0000-0061-000000000003',
      'return_no', NULL, 'return_date', '2026-06-10',
      'supplier_id', '00000000-0000-0000-0061-000000000006',
      'return_currency_id', current_setting('pgtap.v_usd_ccy_061'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 150, 'tax_amount', 0, 'return_total', 150,
      'reason', 'Defective'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1,
      'source_grn_no', current_setting('pgtap.v_grn1_061'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
      'product_id', '00000000-0000-0000-0061-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3, 'rate', 50,
      'gross_amount', 150, 'tax_amount', 0, 'final_amount', 150
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0061-000000000004'
  );
  PERFORM set_config('pgtap.v_return_a_061', v_return_no, false);

  PERFORM fn_approve_purchase_return(
    '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-000000000002',
    v_return_no, '2026-06-10'::date, false,
    '00000000-0000-0000-0061-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT status FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_a_061')) = 'APPROVED',
  'ok 3 — Scenario A return APPROVED'
);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0061-000000000001' AND product_id = '00000000-0000-0000-0061-000000000011') = 17,
  'ok 4 — stock drops by the returned 3 units: 20 -> 17'
);

SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_a_061'))) = 'JV',
  'ok 5 — unbilled-only return posts a plain JV, not SDN'
);

SELECT ok(
  (SELECT count(*) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_a_061'))
     AND is_deleted = false) = 2,
  'ok 6 — exactly 2 lines (Accrual reversal Dr, Stock reversal Cr) — no VAT, GRN1 was never billed'
);

SELECT ok(
  (SELECT base_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_a_061'))
     AND source_line_type = 'ACCRUAL_REVERSAL' AND trans_nature = 'DR') = 150,
  'ok 7 — DR Purchase Accrual reversed for exactly the returned value: 3 * 50 = 150'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Scenario B: return 2 units against GRN2 (billed), reopen the PO — SDN only.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0061-000000000001',
      'company_id', '00000000-0000-0000-0061-000000000002',
      'location_id', '00000000-0000-0000-0061-000000000003',
      'return_no', NULL, 'return_date', '2026-06-11',
      'supplier_id', '00000000-0000-0000-0061-000000000006',
      'return_currency_id', current_setting('pgtap.v_usd_ccy_061'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 100, 'tax_amount', 16, 'return_total', 116,
      'reason', 'Excess Delivery'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1,
      'source_grn_no', current_setting('pgtap.v_grn2_061'), 'source_grn_date', '2026-06-02', 'source_grn_line_serial', 1,
      'product_id', '00000000-0000-0000-0061-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 2, 'qty_loose', 0, 'base_qty', 2, 'rate', 50,
      'tax_group_id', '00000000-0000-0000-0061-000000000016',
      'gross_amount', 100, 'tax_amount', 16, 'final_amount', 116
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0061-000000000004'
  );
  PERFORM set_config('pgtap.v_return_b_061', v_return_no, false);

  PERFORM fn_approve_purchase_return(
    '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-000000000002',
    v_return_no, '2026-06-11'::date, true,
    '00000000-0000-0000-0061-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_b_061'))) = 'SDN',
  'ok 8 — billed-only return posts an SDN (Supplier Debit Note), not JV'
);

SELECT ok(
  (SELECT count(*) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_b_061'))
     AND is_deleted = false) = 3,
  'ok 9 — exactly 3 lines (Stock Cr, Input VAT Cr, Supplier Dr) — Accrual untouched, already cleared by the Bill'
);

SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_b_061'))
     AND source_line_type = 'SUPPLIER_REVERSAL') = 116
  AND
  (SELECT trans_nature FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_b_061'))
     AND source_line_type = 'SUPPLIER_REVERSAL') = 'DR',
  'ok 10 — DR Supplier 116 (taxable 100 + VAT 16), reducing the real payable this Bill created'
);

SELECT ok(
  (SELECT account_id FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_b_061'))
     AND source_line_type = 'INPUT_VAT_REVERSAL') = '00000000-0000-0000-0061-000000000009'
  AND
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_b_061'))
     AND source_line_type = 'INPUT_VAT_REVERSAL') = 16,
  'ok 11 — CR Input VAT 16 reversed against the tax''s own gl_input_account_id'
);

SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_b_061'))) = 0,
  'ok 12 — SDN balances exactly on its own (no Purchase Returns plug needed — 100+16 splits evenly across Stock+VAT)'
);

SELECT ok(
  (SELECT qty_received FROM rid_purchase_order_lines
   WHERE client_id = '00000000-0000-0000-0061-000000000001' AND order_no = 'PO-TEST-061-1' AND serial_no = 1) = 8,
  'ok 13 — PO line qty_received rolled back by the returned 2 units: 10 -> 8'
);

SELECT ok(
  (SELECT status FROM rih_purchase_orders WHERE order_no = 'PO-TEST-061-1') = 'PARTIALLY_RECEIVED',
  'ok 14 — PO reopened (p_reopen_po=true): status flips CLOSED -> PARTIALLY_RECEIVED since 8 < 10 ordered'
);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0061-000000000001' AND product_id = '00000000-0000-0000-0061-000000000011') = 15,
  'ok 15 — stock drops by another 2 units: 17 -> 15'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Scenario C: ONE return spanning BOTH GRN1 (unbilled, 2 more units) and
-- GRN2 (billed, 1 more unit) — must post BOTH a JV and an SDN together.
-- GRN1 has 10 - 3 = 7 returnable left; GRN2 has 10 - 2 = 8 returnable left.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0061-000000000001',
      'company_id', '00000000-0000-0000-0061-000000000002',
      'location_id', '00000000-0000-0000-0061-000000000003',
      'return_no', NULL, 'return_date', '2026-06-12',
      'supplier_id', '00000000-0000-0000-0061-000000000006',
      'return_currency_id', current_setting('pgtap.v_usd_ccy_061'),
      'rate_to_base', 1, 'rate_to_local', 1,
      -- taxable = 100 (GRN1, 2*50) + 50 (GRN2, 1*50) = 150; tax = only the
      -- GRN2 (billed) portion: 1/2 of that line's own 16 = 8.
      'taxable_amount', 150, 'tax_amount', 8, 'return_total', 158,
      'reason', 'Mixed batch inspection'
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1,
        'source_grn_no', current_setting('pgtap.v_grn1_061'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
        'product_id', '00000000-0000-0000-0061-000000000011',
        'uom_conversion_factor', 1, 'qty_pack', 2, 'qty_loose', 0, 'base_qty', 2, 'rate', 50,
        'gross_amount', 100, 'tax_amount', 0, 'final_amount', 100
      ),
      jsonb_build_object(
        'serial_no', 2,
        'source_grn_no', current_setting('pgtap.v_grn2_061'), 'source_grn_date', '2026-06-02', 'source_grn_line_serial', 1,
        'product_id', '00000000-0000-0000-0061-000000000011',
        'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 50,
        'tax_group_id', '00000000-0000-0000-0061-000000000016',
        'gross_amount', 50, 'tax_amount', 8, 'final_amount', 58
      )
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0061-000000000004'
  );
  PERFORM set_config('pgtap.v_return_c_061', v_return_no, false);

  PERFORM fn_approve_purchase_return(
    '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-000000000002',
    v_return_no, '2026-06-12'::date, false,
    '00000000-0000-0000-0061-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT posted_voucher_no FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_c_061')) IS NOT NULL,
  'ok 16 — Scenario C approved with a primary (SDN) voucher reference recorded'
);

SELECT ok(
  (SELECT count(*) FROM rih_finance_headers
   WHERE source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = current_setting('pgtap.v_return_c_061')
     AND voucher_type_code = 'JV') = 1
  AND
  (SELECT count(*) FROM rih_finance_headers
   WHERE source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = current_setting('pgtap.v_return_c_061')
     AND voucher_type_code = 'SDN') = 1,
  'ok 17 — a mixed-status return posts BOTH a JV (for the GRN1 portion) and an SDN (for the GRN2 portion)'
);

SELECT ok(
  (SELECT base_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = current_setting('pgtap.v_return_c_061')
                        AND voucher_type_code = 'JV')
     AND source_line_type = 'ACCRUAL_REVERSAL') = 100,
  'ok 18 — JV portion reverses exactly the GRN1 share: 2 * 50 = 100'
);

SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = current_setting('pgtap.v_return_c_061')
                        AND voucher_type_code = 'SDN')
     AND source_line_type = 'SUPPLIER_REVERSAL') = 58,
  'ok 19 — SDN portion reverses exactly the GRN2 share: taxable 50 + VAT 8 = 58'
);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0061-000000000001' AND product_id = '00000000-0000-0000-0061-000000000011') = 12,
  'ok 20 — stock drops by the combined 3 units (2+1): 15 -> 12'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Negative-stock check (migration 060) — product2 has zero stock, and
-- neither the item flag nor the location flag allows negative, so any
-- outward movement must be rejected.
-- ══════════════════════════════════════════════════════════════════════════════
SELECT throws_ok(
  $$ SELECT fn_post_stock_movement(
       '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-000000000002',
       '00000000-0000-0000-0061-000000000003', '00000000-0000-0000-0061-000000000012',
       '2026-06-13'::date, 'PURCHASE_RETURN', -1,
       NULL, NULL, NULL, NULL, NULL,
       'PURCHASE_RETURN', 'MANUAL-TEST', '2026-06-13'::date,
       '00000000-0000-0000-0061-000000000004'
     ) $$,
  'NEGATIVE_STOCK_NOT_ALLOWED',
  'ok 21 — an outward movement that would drive a zero-stock item negative is rejected when neither the item nor the location allows it'
);

SELECT * FROM finish();
ROLLBACK;
