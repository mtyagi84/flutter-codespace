-- ============================================================
-- 080_manufacturing_date_test.sql — pgTAP tests for migration 080
-- (manufacturing_date alongside expiry_date, full footprint)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--
-- Scope (per the migration 080 plan — proportionate, not exhaustive):
--   1-2. fn_post_stock_movement accepts/stores the new param, and the
--        pre-080 17-arg call shape still works with a NULL result.
--   3-4. fn_save_grn/fn_approve_grn round-trip through rid_transaction_
--        line_batches into ril_stock_ledger; a batch object that OMITS
--        manufacturing_date entirely still saves fine (backward compat).
--   5.   Consolidation check: GRN -> Purchase Return carries the value
--        through to the reversing ledger row.
--   6.   Stock Count -> Stock Count Review -> composed Stock Adjustment
--        chain carries it end to end via fn_compute_stock_count_variance.
--   7.   Opening Stock (structurally different: flat column, not a JSONB
--        batches array) gets its own explicit round-trip case.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client        uuid := '00000000-0000-0000-0080-000000000001';
  v_company       uuid := '00000000-0000-0000-0080-000000000002';
  v_loc           uuid := '00000000-0000-0000-0080-000000000003';
  v_user          uuid := '00000000-0000-0000-0080-000000000004';
  v_usd           uuid;
  v_supplier      uuid := '00000000-0000-0000-0080-000000000005';
  v_stock_acc     uuid := '00000000-0000-0000-0080-000000000006';
  v_accrual_acc   uuid := '00000000-0000-0000-0080-000000000007';
  v_returns_acc   uuid := '00000000-0000-0000-0080-000000000008';
  v_prod_grn      uuid := '00000000-0000-0000-0080-000000000009';
  v_prod_direct   uuid := '00000000-0000-0000-0080-00000000000a';
  v_prod_opening  uuid := '00000000-0000-0000-0080-00000000000b';
  v_prod_count    uuid := '00000000-0000-0000-0080-00000000000c';
  v_fy            uuid := '00000000-0000-0000-0080-00000000000d';
  v_reason        uuid := '00000000-0000-0000-0080-00000000000e';
  v_stock_link    uuid; v_accrual_link uuid; v_returns_link uuid; v_adj_link uuid;
  v_reason_type   uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client, 'TEST080', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company, v_client, 'TEST080 CO', 'USD', 'USD', 'SIMPLE', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES (v_loc, v_client, v_company, 'TEST080 Loc', 'T080L', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user, v_client, v_company, 'test080', 'Test User 080', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd FROM rim_currencies WHERE client_id = v_client AND company_id = v_company AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier,    v_client, v_company, '5080', 'Test080 Supplier',  'Supplier', 'OHADA', true, true, false, now()),
    (v_stock_acc,   v_client, v_company, '1380', 'Stock Account 080', 'General',  'OHADA', true, true, false, now()),
    (v_accrual_acc, v_client, v_company, '2280', 'Purchase Accrual 080', 'General', 'OHADA', true, true, false, now()),
    (v_returns_acc, v_client, v_company, '5180', 'Purchase Returns Contra 080', 'General', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_prod_grn,     v_client, v_company, 'MFG-GRN', 'MfgDate Test GRN',     v_usd, 'BATCH_WITH_EXPIRY', v_user),
    (v_prod_direct,  v_client, v_company, 'MFG-DIR', 'MfgDate Test Direct',  v_usd, 'BATCH', v_user),
    (v_prod_opening, v_client, v_company, 'MFG-OPN', 'MfgDate Test Opening', v_usd, 'BATCH', v_user),
    (v_prod_count,   v_client, v_company, 'MFG-CNT', 'MfgDate Test Count',   v_usd, 'BATCH', v_user)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy, v_client, v_company, 'FY TEST080', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_reason_type FROM rim_common_master_types WHERE type_key = 'STOCK_ADJUSTMENT_REASON';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, sort_order, created_by)
  VALUES (v_reason, v_client, v_company, v_reason_type, 'TEST080 Physical Count Variance', 90, v_user)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_accrual_link FROM rim_account_link_types WHERE link_key = 'PURCHASE_ACCRUAL_ACCOUNT';
  SELECT id INTO v_returns_link FROM rim_account_link_types WHERE link_key = 'PURCHASE_RETURNS_ACCOUNT';
  SELECT id INTO v_adj_link     FROM rim_account_link_types WHERE link_key = 'STOCK_ADJUSTMENT_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client, v_company, v_stock_link, 'COMPANY'),
    (v_client, v_company, v_accrual_link, 'COMPANY'),
    (v_client, v_company, v_returns_link, 'COMPANY'),
    (v_client, v_company, v_adj_link, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client, v_company, v_stock_link, NULL, v_stock_acc),
    (v_client, v_company, v_accrual_link, NULL, v_accrual_acc),
    (v_client, v_company, v_returns_link, NULL, v_returns_acc),
    (v_client, v_company, v_adj_link, NULL, v_accrual_acc)
  ON CONFLICT DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client::text, false);
  PERFORM set_config('pgtap.v_company', v_company::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc::text, false);
  PERFORM set_config('pgtap.v_user', v_user::text, false);
  PERFORM set_config('pgtap.v_supplier', v_supplier::text, false);
  PERFORM set_config('pgtap.v_usd', v_usd::text, false);
  PERFORM set_config('pgtap.v_prod_grn', v_prod_grn::text, false);
  PERFORM set_config('pgtap.v_prod_direct', v_prod_direct::text, false);
  PERFORM set_config('pgtap.v_prod_opening', v_prod_opening::text, false);
  PERFORM set_config('pgtap.v_prod_count', v_prod_count::text, false);
  PERFORM set_config('pgtap.v_reason', v_reason::text, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(10);

-- ══════════════════════════════════════════════════════════════════════════
-- 1-2. fn_post_stock_movement — accepts/stores the new param, and the
-- pre-080 call shape (17 args, no manufacturing_date) still works.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_post_stock_movement(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    current_setting('pgtap.v_prod_direct')::uuid, '2026-01-01'::date, 'OPENING_STOCK', 10, 5, 5,
    'MFGDIR-B1', '2027-01-01'::date, NULL, 'OPENING_BALANCE', 'MFG-OB-001', '2026-01-01'::date,
    current_setting('pgtap.v_user')::uuid, 1, '2025-06-01'::date
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT manufacturing_date FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'OPENING_BALANCE' AND source_doc_no = 'MFG-OB-001') = '2025-06-01'::date,
  'ok 1 — fn_post_stock_movement stores p_manufacturing_date on ril_stock_ledger'
);

DO $$
BEGIN
  PERFORM fn_post_stock_movement(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    current_setting('pgtap.v_prod_direct')::uuid, '2026-01-01'::date, 'OPENING_STOCK', 5, 5, 5,
    'MFGDIR-B2', '2027-01-01'::date, NULL, 'OPENING_BALANCE', 'MFG-OB-002', '2026-01-01'::date,
    current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'OPENING_BALANCE' AND source_doc_no = 'MFG-OB-002'
     AND manufacturing_date IS NULL) = 1,
  'ok 2 — the pre-080 17-arg call shape (omitting manufacturing_date) still succeeds, with NULL — zero breakage for existing callers'
);

-- ══════════════════════════════════════════════════════════════════════════
-- 3-4. fn_save_grn / fn_approve_grn round-trip, plus backward-compat omit.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'grn_no', NULL, 'grn_date', '2026-06-01',
      'supplier_id', current_setting('pgtap.v_supplier'), 'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_usd'), 'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_prod_grn'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 50,
      'gross_amount', 500, 'discount_amount', 0, 'tax_amount', 0, 'final_amount', 500,
      'base_amount', 500, 'local_amount', 500
    )),
    jsonb_build_array(jsonb_build_object(
      'line_serial', 1, 'batch_no', 'MFG-B1', 'expiry_date', '2027-06-01', 'manufacturing_date', '2026-05-01',
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10
    )),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_grn_no', v_grn_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT manufacturing_date FROM rid_transaction_line_batches
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'GRN' AND source_doc_no = current_setting('pgtap.v_grn_no')
     AND batch_no = 'MFG-B1') = '2026-05-01'::date,
  'ok 3 — fn_save_grn persists manufacturing_date onto rid_transaction_line_batches'
);

DO $$
BEGIN
  PERFORM fn_approve_grn(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_grn_no'), '2026-06-01'::date, current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT manufacturing_date FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'GRN' AND source_doc_no = current_setting('pgtap.v_grn_no')
     AND batch_no = 'MFG-B1') = '2026-05-01'::date,
  'ok 4 — fn_approve_grn carries manufacturing_date through fn_post_stock_movement onto ril_stock_ledger'
);

-- Backward-compat: a batch object that OMITS manufacturing_date entirely
-- (simulating an un-upgraded client) must still save fine, with NULL.
DO $$
DECLARE v_grn_no2 text;
BEGIN
  v_grn_no2 := fn_save_grn(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'grn_no', NULL, 'grn_date', '2026-06-02',
      'supplier_id', current_setting('pgtap.v_supplier'), 'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_usd'), 'rate_to_base', 1, 'rate_to_local', 1
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_prod_grn'),
      'uom_conversion_factor', 1, 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4, 'rate', 50,
      'gross_amount', 200, 'discount_amount', 0, 'tax_amount', 0, 'final_amount', 200,
      'base_amount', 200, 'local_amount', 200
    )),
    jsonb_build_array(jsonb_build_object(
      'line_serial', 1, 'batch_no', 'MFG-B2', 'expiry_date', '2027-06-01',
      'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4
    )),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_grn_no2', v_grn_no2, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT manufacturing_date FROM rid_transaction_line_batches
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'GRN' AND source_doc_no = current_setting('pgtap.v_grn_no2')
     AND batch_no = 'MFG-B2') IS NULL,
  'ok 5 — a batch object omitting manufacturing_date entirely still saves fine, as NULL (backward compat for an un-upgraded client)'
);

-- ══════════════════════════════════════════════════════════════════════════
-- 6. Consolidation check: GRN -> Purchase Return carries the value through
-- to the reversing ledger row.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_return_no text;
BEGIN
  v_return_no := fn_save_purchase_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'return_no', NULL, 'return_date', '2026-06-05',
      'supplier_id', current_setting('pgtap.v_supplier'), 'return_currency_id', current_setting('pgtap.v_usd'),
      'rate_to_base', 1, 'rate_to_local', 1, 'taxable_amount', 250, 'tax_amount', 0, 'return_total', 250,
      'reason', 'Test return'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'source_grn_no', current_setting('pgtap.v_grn_no'), 'source_grn_date', '2026-06-01', 'source_grn_line_serial', 1,
      'product_id', current_setting('pgtap.v_prod_grn'), 'uom_conversion_factor', 1,
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 50,
      'gross_amount', 250, 'tax_amount', 0, 'final_amount', 250
    )),
    jsonb_build_array(jsonb_build_object(
      'line_serial', 1, 'batch_no', 'MFG-B1', 'expiry_date', '2027-06-01', 'manufacturing_date', '2026-05-01',
      'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5
    )),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_return_no', v_return_no, false);
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  PERFORM fn_approve_purchase_return(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_return_no'), '2026-06-05'::date, false, current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT manufacturing_date FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = current_setting('pgtap.v_return_no')
     AND batch_no = 'MFG-B1') = '2026-05-01'::date,
  'ok 6 — Purchase Return carries manufacturing_date from the GRN batch it references through to its own reversing ledger row'
);

-- ══════════════════════════════════════════════════════════════════════════
-- 7. Stock Count -> Stock Count Review -> composed Stock Adjustment chain.
-- ══════════════════════════════════════════════════════════════════════════
-- v_prod_count has no prior movement anywhere in this fixture -- a "+"
-- adjustment (which is exactly what a newly-counted, never-before-seen
-- batch nets to) is hard-blocked with COST_NOT_ESTABLISHED unless the
-- PRODUCT already has some cost basis at this location (the check is
-- per-product, not per-batch -- a brand-new batch is legitimately allowed
-- to "+", same as Stock Adjustment itself allows, but only once the
-- product's own cost_price is non-zero). Seed a small prior movement
-- under a different batch, well before the count date, purely to
-- establish that cost basis.
DO $$
BEGIN
  PERFORM fn_post_stock_movement(
    p_client_id => current_setting('pgtap.v_client')::uuid, p_company_id => current_setting('pgtap.v_company')::uuid,
    p_location_id => current_setting('pgtap.v_loc')::uuid, p_product_id => current_setting('pgtap.v_prod_count')::uuid,
    p_trans_date => '2026-01-01'::date, p_trans_type => 'OPENING_STOCK', p_qty_change => 1,
    p_unit_cost_base => 5, p_unit_cost_specific => 5, p_batch_no => 'MFG-CNT-SEED',
    p_source_doc_type => 'OPENING_STOCK', p_source_doc_no => 'MFG-CNT-SEED-DOC',
    p_source_doc_date => '2026-01-01'::date, p_user_id => current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE v_count_no text; v_rev_no text; v_adj_no text;
BEGIN
  v_count_no := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_count'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 6, 'counted_qty_loose', 0, 'counted_base_qty', 6)),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'MFG-CNT-B1', 'expiry_date', NULL,
      'manufacturing_date', '2026-04-01', 'qty_pack', 6, 'qty_loose', 0, 'base_qty', 6)),
    '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_count_no, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);

  v_rev_no := fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', NULL, 'review_date', '2026-07-09',
      'as_of_date', '2026-05-24', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'MFG test review'),
    jsonb_build_array(jsonb_build_object('source_count_no', v_count_no, 'source_count_date', '2026-05-24')),
    current_setting('pgtap.v_user')::uuid
  );

  INSERT INTO test_results (result) SELECT ok(
    (SELECT manufacturing_date FROM fn_compute_stock_count_variance(
       current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_rev_no, '2026-07-09'::date)
     WHERE product_id = current_setting('pgtap.v_prod_count')::uuid AND batch_no = 'MFG-CNT-B1') = '2026-04-01'::date,
    'ok 7 — fn_compute_stock_count_variance surfaces manufacturing_date for a counted new batch'
  );

  v_adj_no := fn_approve_stock_count_review(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_rev_no, '2026-07-09'::date, current_setting('pgtap.v_user')::uuid
  );

  INSERT INTO test_results (result) SELECT ok(
    (SELECT manufacturing_date FROM rid_transaction_line_batches
     WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = v_adj_no
       AND batch_no = 'MFG-CNT-B1') = '2026-04-01'::date,
    'ok 8 — fn_approve_stock_count_review carries manufacturing_date into the composed Stock Adjustment''s batch row (JSONB-composition hop preserved it)'
  );
END;
$$ LANGUAGE plpgsql;

-- ══════════════════════════════════════════════════════════════════════════
-- 9-10. Opening Stock — structurally different shape (flat column, not a
-- JSONB batches array) — its own explicit round-trip case.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_opening_no text;
BEGIN
  v_opening_no := fn_save_opening_stock(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'opening_no', NULL, 'opening_date', '2026-01-01', 'remarks', 'MFG opening test'),
    jsonb_build_array(jsonb_build_object(
      'line_no', 1, 'product_id', current_setting('pgtap.v_prod_opening'),
      'uom_conversion_factor', 1, 'pack_qty', 8, 'loose_qty', 0, 'base_qty', 8,
      'batch_no', 'MFG-OPN-B1', 'expiry_date', '2027-01-01', 'manufacturing_date', '2025-12-01',
      'unit_cost', 20
    )),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_opening_no', v_opening_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT manufacturing_date FROM rid_opening_stock_lines
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND opening_no = current_setting('pgtap.v_opening_no')
     AND batch_no = 'MFG-OPN-B1') = '2025-12-01'::date,
  'ok 9 — fn_save_opening_stock persists manufacturing_date directly on rid_opening_stock_lines (flat column, no batches array)'
);

DO $$
BEGIN
  PERFORM fn_approve_opening_stock(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_opening_no'), '2026-01-01'::date, current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT manufacturing_date FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'OPENING_STOCK' AND source_doc_no = current_setting('pgtap.v_opening_no')
     AND batch_no = 'MFG-OPN-B1') = '2025-12-01'::date,
  'ok 10 — fn_approve_opening_stock carries manufacturing_date through fn_post_stock_movement onto ril_stock_ledger'
);

-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
