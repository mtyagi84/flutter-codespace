-- ============================================================
-- 063_purchase_return_batch_serial_test.sql — pgTAP tests for migration 063
--
-- Functions: fn_post_stock_movement (strict batch/serial check),
--            fn_save_purchase_return (p_batches/p_serials),
--            fn_approve_purchase_return (per-batch/serial reversal)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. All rows show "ok N — ..." with no "not ok" lines.
--   4. finish() returns no rows = all passed.
--
-- Both the item AND the location have allow_negative_stock = true in this
-- fixture — deliberately, to prove the batch/serial check in migration 063
-- is NOT gated by those flags (unlike the aggregate check in 060). If a
-- batch/serial check were still honoring the flags, these "should fail"
-- assertions would wrongly succeed.
--
-- Two products, one DIRECT GRN each:
--   Batch product  — 10 units received as LOT-A (6) + LOT-B (4).
--   Serial product — 3 units received as SN-1, SN-2, SN-3.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_client_id       uuid := '00000000-0000-0000-0063-000000000001';
  v_company_id      uuid := '00000000-0000-0000-0063-000000000002';
  v_loc_id          uuid := '00000000-0000-0000-0063-000000000003';
  v_user_id         uuid := '00000000-0000-0000-0063-000000000004';
  v_usd_ccy_id      uuid;
  v_supplier_id     uuid := '00000000-0000-0000-0063-000000000006';
  v_stock_acc_id    uuid := '00000000-0000-0000-0063-000000000007';
  v_accrual_acc_id  uuid := '00000000-0000-0000-0063-000000000008';
  v_batch_product_id  uuid := '00000000-0000-0000-0063-000000000011';
  v_serial_product_id uuid := '00000000-0000-0000-0063-000000000012';
  v_fy_id           uuid := '00000000-0000-0000-0063-000000000013';
  v_stock_link_type uuid; v_accrual_link_type uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST063', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST063 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- is_negative_stock_allowed = TRUE at the location — deliberately, see
  -- header comment: proves the batch/serial check ignores this flag.
  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test063 Loc', 'T63', true, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test063', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier_id,     v_client_id, v_company_id, '5063', 'Test063 Supplier', 'Supplier', 'OHADA', true, true, false, now()),
    (v_stock_acc_id,    v_client_id, v_company_id, '1363', 'Stock Account',    'General',  'OHADA', true, true, false, now()),
    (v_accrual_acc_id,  v_client_id, v_company_id, '2263', 'Purchase Accrual', 'General',  'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- flags->>'allow_negative_stock' = true — deliberately, see header comment.
  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, flags, created_by)
  VALUES
    (v_batch_product_id,  v_client_id, v_company_id, 'PRET-B01', 'Batch Test Item',  v_usd_ccy_id, 'BATCH',  '{"allow_negative_stock": true}'::jsonb, v_user_id),
    (v_serial_product_id, v_client_id, v_company_id, 'PRET-S01', 'Serial Test Item', v_usd_ccy_id, 'SERIAL', '{"allow_negative_stock": true}'::jsonb, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST063', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link_type   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
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

  PERFORM set_config('pgtap.v_usd_ccy_063', v_usd_ccy_id::text, false);
END;
$$ LANGUAGE plpgsql;

-- ── GRN1: batch product, 10 units as LOT-A(6) + LOT-B(4) @ 20 = 200 ─────────
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0063-000000000001',
      'company_id', '00000000-0000-0000-0063-000000000002',
      'location_id', '00000000-0000-0000-0063-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-01',
      'supplier_id', '00000000-0000-0000-0063-000000000006',
      'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_usd_ccy_063'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0063-000000000011',
        'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 20,
        'gross_amount', 200, 'tax_amount', 0, 'final_amount', 200, 'charge_amount', 0, 'landed_amount', 200
      )
    ),
    jsonb_build_array(
      jsonb_build_object('line_serial', 1, 'batch_no', 'LOT-A', 'qty_pack', 6, 'qty_loose', 0, 'base_qty', 6),
      jsonb_build_object('line_serial', 1, 'batch_no', 'LOT-B', 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4)
    ),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0063-000000000004'
  );
  PERFORM set_config('pgtap.v_grn_batch_063', v_grn_no, false);

  PERFORM fn_approve_grn(
    '00000000-0000-0000-0063-000000000001', '00000000-0000-0000-0063-000000000002',
    v_grn_no, '2026-06-01'::date, '00000000-0000-0000-0063-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

-- ── GRN2: serial product, 3 units as SN-1/SN-2/SN-3 @ 100 = 300 ─────────────
DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0063-000000000001',
      'company_id', '00000000-0000-0000-0063-000000000002',
      'location_id', '00000000-0000-0000-0063-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-01',
      'supplier_id', '00000000-0000-0000-0063-000000000006',
      'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_usd_ccy_063'),
      'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0063-000000000012',
        'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3, 'rate', 100,
        'gross_amount', 300, 'tax_amount', 0, 'final_amount', 300, 'charge_amount', 0, 'landed_amount', 300
      )
    ),
    '[]'::jsonb,
    jsonb_build_array(
      jsonb_build_object('line_serial', 1, 'serial_no', 'SN-1'),
      jsonb_build_object('line_serial', 1, 'serial_no', 'SN-2'),
      jsonb_build_object('line_serial', 1, 'serial_no', 'SN-3')
    ),
    '[]'::jsonb,
    '00000000-0000-0000-0063-000000000004'
  );
  PERFORM set_config('pgtap.v_grn_serial_063', v_grn_no, false);

  PERFORM fn_approve_grn(
    '00000000-0000-0000-0063-000000000001', '00000000-0000-0000-0063-000000000002',
    v_grn_no, '2026-06-01'::date, '00000000-0000-0000-0063-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT plan(11);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000011') = 10,
  'ok 1 — batch product GRN posted: current_stock = 10'
);

SELECT ok(
  (SELECT balance FROM v_batch_stock_balance
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000011' AND batch_no = 'LOT-A') = 6
  AND
  (SELECT balance FROM v_batch_stock_balance
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000011' AND batch_no = 'LOT-B') = 4,
  'ok 2 — v_batch_stock_balance reports LOT-A=6, LOT-B=4 after the GRN'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- BATCH_QTY_MISMATCH — return line says base_qty=2 but the batch split sums to 3.
-- ══════════════════════════════════════════════════════════════════════════════
SELECT throws_ok(
  $$ SELECT fn_save_purchase_return(
       jsonb_build_object(
         'client_id', '00000000-0000-0000-0063-000000000001',
         'company_id', '00000000-0000-0000-0063-000000000002',
         'location_id', '00000000-0000-0000-0063-000000000003',
         'return_no', NULL, 'return_date', '2026-06-15',
         'supplier_id', '00000000-0000-0000-0063-000000000006',
         'return_currency_id', current_setting('pgtap.v_usd_ccy_063'),
         'rate_to_base', 1, 'rate_to_local', 1,
         'taxable_amount', 40, 'tax_amount', 0, 'return_total', 40,
         'reason', 'Mismatch test'
       ),
       jsonb_build_array(jsonb_build_object(
         'serial_no', 1,
         'source_grn_no', current_setting('pgtap.v_grn_batch_063'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
         'product_id', '00000000-0000-0000-0063-000000000011',
         'uom_conversion_factor', 1, 'qty_pack', 2, 'qty_loose', 0, 'base_qty', 2, 'rate', 20,
         'gross_amount', 40, 'tax_amount', 0, 'final_amount', 40
       )),
       jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'LOT-A', 'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3)),
       '[]'::jsonb, '[]'::jsonb,
       '00000000-0000-0000-0063-000000000004'
     ) $$,
  'BATCH_QTY_MISMATCH',
  'ok 3 — fn_save_purchase_return rejects a batch split that does not sum to the line''s own return qty'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- A. Return 4 units from LOT-A — succeeds, LOT-A balance 6 -> 2, LOT-B untouched.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0063-000000000001',
      'company_id', '00000000-0000-0000-0063-000000000002',
      'location_id', '00000000-0000-0000-0063-000000000003',
      'return_no', NULL, 'return_date', '2026-06-16',
      'supplier_id', '00000000-0000-0000-0063-000000000006',
      'return_currency_id', current_setting('pgtap.v_usd_ccy_063'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 80, 'tax_amount', 0, 'return_total', 80,
      'reason', 'Batch return test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1,
      'source_grn_no', current_setting('pgtap.v_grn_batch_063'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
      'product_id', '00000000-0000-0000-0063-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4, 'rate', 20,
      'gross_amount', 80, 'tax_amount', 0, 'final_amount', 80
    )),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'LOT-A', 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4)),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0063-000000000004'
  );
  PERFORM set_config('pgtap.v_return_batch_a_063', v_return_no, false);

  PERFORM fn_approve_purchase_return(
    '00000000-0000-0000-0063-000000000001', '00000000-0000-0000-0063-000000000002',
    v_return_no, '2026-06-16'::date, false,
    '00000000-0000-0000-0063-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT status FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_batch_a_063')) = 'APPROVED',
  'ok 4 — batch return of 4 units from LOT-A approved successfully'
);

SELECT ok(
  (SELECT balance FROM v_batch_stock_balance
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000011' AND batch_no = 'LOT-A') = 2
  AND
  (SELECT balance FROM v_batch_stock_balance
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000011' AND batch_no = 'LOT-B') = 4,
  'ok 5 — LOT-A balance drops 6 -> 2, LOT-B untouched at 4 (per-batch reversal, not aggregate)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- B. Return 3 MORE units from LOT-A (only 2 remain) — must be rejected at
-- Approve time with BATCH_INSUFFICIENT_STOCK, even though BOTH the item and
-- the location allow_negative_stock flags are TRUE. The GRN-level qty check
-- alone would pass here (4 already returned + 3 = 7 <= 10 received), so this
-- specifically isolates the NEW per-batch check added in migration 063.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0063-000000000001',
      'company_id', '00000000-0000-0000-0063-000000000002',
      'location_id', '00000000-0000-0000-0063-000000000003',
      'return_no', NULL, 'return_date', '2026-06-17',
      'supplier_id', '00000000-0000-0000-0063-000000000006',
      'return_currency_id', current_setting('pgtap.v_usd_ccy_063'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 60, 'tax_amount', 0, 'return_total', 60,
      'reason', 'Over-return test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1,
      'source_grn_no', current_setting('pgtap.v_grn_batch_063'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
      'product_id', '00000000-0000-0000-0063-000000000011',
      'uom_conversion_factor', 1, 'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3, 'rate', 20,
      'gross_amount', 60, 'tax_amount', 0, 'final_amount', 60
    )),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'LOT-A', 'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3)),
    '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0063-000000000004'
  );
  PERFORM set_config('pgtap.v_return_batch_b_063', v_return_no, false);
END;
$$ LANGUAGE plpgsql;

SELECT throws_ok(
  $$ SELECT fn_approve_purchase_return(
       '00000000-0000-0000-0063-000000000001', '00000000-0000-0000-0063-000000000002',
       current_setting('pgtap.v_return_batch_b_063'), '2026-06-17'::date, false,
       '00000000-0000-0000-0063-000000000004'
     ) $$,
  'BATCH_INSUFFICIENT_STOCK',
  'ok 6 — returning 3 more from LOT-A (only 2 left) is rejected, despite both item AND location allowing negative stock'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- C. Serial return: return SN-2 — succeeds, SN-2 flips to OUT, product stock 3 -> 2.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0063-000000000001',
      'company_id', '00000000-0000-0000-0063-000000000002',
      'location_id', '00000000-0000-0000-0063-000000000003',
      'return_no', NULL, 'return_date', '2026-06-18',
      'supplier_id', '00000000-0000-0000-0063-000000000006',
      'return_currency_id', current_setting('pgtap.v_usd_ccy_063'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 100, 'tax_amount', 0, 'return_total', 100,
      'reason', 'Serial return test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1,
      'source_grn_no', current_setting('pgtap.v_grn_serial_063'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
      'product_id', '00000000-0000-0000-0063-000000000012',
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 100,
      'gross_amount', 100, 'tax_amount', 0, 'final_amount', 100
    )),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'serial_no', 'SN-2')),
    '[]'::jsonb,
    '00000000-0000-0000-0063-000000000004'
  );
  PERFORM set_config('pgtap.v_return_serial_a_063', v_return_no, false);

  PERFORM fn_approve_purchase_return(
    '00000000-0000-0000-0063-000000000001', '00000000-0000-0000-0063-000000000002',
    v_return_no, '2026-06-18'::date, false,
    '00000000-0000-0000-0063-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT status FROM rih_purchase_return_headers WHERE return_no = current_setting('pgtap.v_return_serial_a_063')) = 'APPROVED',
  'ok 7 — serial return of SN-2 approved successfully'
);

SELECT ok(
  (SELECT status FROM v_serial_stock_status
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000012' AND serial_no = 'SN-2') = 'OUT',
  'ok 8 — v_serial_stock_status flips SN-2 to OUT after the return'
);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000012') = 2,
  'ok 9 — serial product stock drops 3 -> 2'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- D. Attempt to return SN-2 again — must be rejected at Approve time with
-- SERIAL_NOT_IN_STOCK, despite both flags allowing negative stock. The
-- GRN-level qty check alone would pass (1 already returned + 1 = 2 <= 3
-- received), so this isolates the NEW per-serial check.
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0063-000000000001',
      'company_id', '00000000-0000-0000-0063-000000000002',
      'location_id', '00000000-0000-0000-0063-000000000003',
      'return_no', NULL, 'return_date', '2026-06-19',
      'supplier_id', '00000000-0000-0000-0063-000000000006',
      'return_currency_id', current_setting('pgtap.v_usd_ccy_063'),
      'rate_to_base', 1, 'rate_to_local', 1,
      'taxable_amount', 100, 'tax_amount', 0, 'return_total', 100,
      'reason', 'Double-return test'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1,
      'source_grn_no', current_setting('pgtap.v_grn_serial_063'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
      'product_id', '00000000-0000-0000-0063-000000000012',
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 100,
      'gross_amount', 100, 'tax_amount', 0, 'final_amount', 100
    )),
    '[]'::jsonb,
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'serial_no', 'SN-2')),
    '[]'::jsonb,
    '00000000-0000-0000-0063-000000000004'
  );
  PERFORM set_config('pgtap.v_return_serial_b_063', v_return_no, false);
END;
$$ LANGUAGE plpgsql;

SELECT throws_ok(
  $$ SELECT fn_approve_purchase_return(
       '00000000-0000-0000-0063-000000000001', '00000000-0000-0000-0063-000000000002',
       current_setting('pgtap.v_return_serial_b_063'), '2026-06-19'::date, false,
       '00000000-0000-0000-0063-000000000004'
     ) $$,
  'SERIAL_NOT_IN_STOCK',
  'ok 10 — returning SN-2 a second time is rejected (already OUT), despite both item AND location allowing negative stock'
);

SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = '00000000-0000-0000-0063-000000000001' AND product_id = '00000000-0000-0000-0063-000000000012') = 2,
  'ok 11 — serial product stock unchanged at 2 after the rejected double-return (whole transaction rolled back)'
);

SELECT * FROM finish();
ROLLBACK;
