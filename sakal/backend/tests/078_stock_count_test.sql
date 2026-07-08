-- ============================================================
-- 078_stock_count_test.sql — pgTAP tests for Stock Count Screen 1
-- (migration 078).
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--
-- One company (SIMPLE), one location, a small category tree (Grocery ->
-- Snacks) and four products covering NONE/BATCH/SERIAL tracking and a mix
-- of category/nature, to exercise fn_stock_count_eligible_products'
-- fn_category_subtree expansion + nature filter independently:
--   v_prod_snack  (NONE,   category=Snacks, nature=TRADING)
--   v_prod_batch  (BATCH,  category=Snacks, nature=RAW_MATERIAL)
--   v_prod_serial (SERIAL, category=NULL,   nature=TRADING)
--   v_prod_other  (NONE,   category=NULL,   nature=RAW_MATERIAL)
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client       uuid := '00000000-0000-0000-0078-000000000001';
  v_company      uuid := '00000000-0000-0000-0078-000000000002';
  v_loc          uuid := '00000000-0000-0000-0078-000000000003';
  v_user         uuid := '00000000-0000-0000-0078-000000000004';
  v_usd          uuid;
  v_cat_root     uuid := '00000000-0000-0000-0078-000000000005';
  v_cat_child    uuid := '00000000-0000-0000-0078-000000000006';
  v_prod_snack   uuid := '00000000-0000-0000-0078-000000000007';
  v_prod_batch   uuid := '00000000-0000-0000-0078-000000000008';
  v_prod_serial  uuid := '00000000-0000-0000-0078-000000000009';
  v_prod_other   uuid := '00000000-0000-0000-0078-00000000000a';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client, 'TEST078', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company, v_client, 'TEST078 CO', 'USD', 'USD', 'SIMPLE', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES (v_loc, v_client, v_company, 'TEST078 Loc', 'T078L', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user, v_client, v_company, 'test078', 'Test User 078', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd FROM rim_currencies WHERE client_id = v_client AND company_id = v_company AND currency_id = 'USD';

  INSERT INTO rim_item_categories (id, client_id, company_id, parent_id, level_no, category_name, is_active, created_by)
  VALUES
    (v_cat_root,  v_client, v_company, NULL,       1, 'Grocery', true, v_user),
    (v_cat_child, v_client, v_company, v_cat_root, 2, 'Snacks',  true, v_user)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, category_id, product_nature, created_by)
  VALUES
    (v_prod_snack,  v_client, v_company, 'CNT-SNK', 'Count Test Snack',  v_usd, 'NONE',   v_cat_child, 'TRADING',      v_user),
    (v_prod_batch,  v_client, v_company, 'CNT-BAT', 'Count Test Batch',  v_usd, 'BATCH',  v_cat_child, 'RAW_MATERIAL', v_user),
    (v_prod_serial, v_client, v_company, 'CNT-SER', 'Count Test Serial', v_usd, 'SERIAL', NULL,        'TRADING',      v_user),
    (v_prod_other,  v_client, v_company, 'CNT-OTH', 'Count Test Other',  v_usd, 'NONE',   NULL,        'RAW_MATERIAL', v_user)
  ON CONFLICT (id) DO NOTHING;

  PERFORM set_config('pgtap.v_client', v_client::text, false);
  PERFORM set_config('pgtap.v_company', v_company::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc::text, false);
  PERFORM set_config('pgtap.v_user', v_user::text, false);
  PERFORM set_config('pgtap.v_cat_root', v_cat_root::text, false);
  PERFORM set_config('pgtap.v_prod_snack', v_prod_snack::text, false);
  PERFORM set_config('pgtap.v_prod_batch', v_prod_batch::text, false);
  PERFORM set_config('pgtap.v_prod_serial', v_prod_serial::text, false);
  PERFORM set_config('pgtap.v_prod_other', v_prod_other::text, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(12);

-- ══════════════════════════════════════════════════════════════════════════
-- fn_stock_count_eligible_products — category subtree + nature filter,
-- independently and combined.
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  (SELECT array_agg(product_code ORDER BY product_code) FROM fn_stock_count_eligible_products(
     current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_cat_root')::uuid, NULL))
  = ARRAY['CNT-BAT','CNT-SNK'],
  'ok 1 — category-subtree filter (Grocery root) returns exactly the two Snacks-category products, via fn_category_subtree'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT array_agg(product_code ORDER BY product_code) FROM fn_stock_count_eligible_products(
     current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, NULL, 'TRADING'))
  = ARRAY['CNT-SER','CNT-SNK'],
  'ok 2 — nature filter (TRADING) returns exactly the two TRADING products regardless of category'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT array_agg(product_code) FROM fn_stock_count_eligible_products(
     current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_cat_root')::uuid, 'TRADING'))
  = ARRAY['CNT-SNK'],
  'ok 3 — combined category + nature filter narrows to exactly one product'
);

-- ══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_count — worksheet with a mix of counted/uncounted/zero-
-- counted/batch-tracked lines.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_count_no text;
BEGIN
  v_count_no := fn_save_stock_count(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-07-15',
      'category_filter_id', current_setting('pgtap.v_cat_root'), 'nature_filter', NULL, 'remarks', 'Test count'
    ),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_snack'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 15, 'counted_qty_loose', 0, 'counted_base_qty', 15),
      jsonb_build_object('serial_no', 2, 'product_id', current_setting('pgtap.v_prod_batch'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 8, 'counted_qty_loose', 0, 'counted_base_qty', 8),
      jsonb_build_object('serial_no', 3, 'product_id', current_setting('pgtap.v_prod_serial'),
        'uom_conversion_factor', 1, 'is_counted', false),
      jsonb_build_object('serial_no', 4, 'product_id', current_setting('pgtap.v_prod_other'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 0, 'counted_qty_loose', 0, 'counted_base_qty', 0)
    ),
    jsonb_build_array(
      jsonb_build_object('line_serial', 2, 'batch_no', 'B1', 'expiry_date', NULL, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5),
      jsonb_build_object('line_serial', 2, 'batch_no', 'B2', 'expiry_date', NULL, 'qty_pack', 3, 'qty_loose', 0, 'base_qty', 3)
    ),
    '[]'::jsonb,
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_count_no', v_count_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_count_headers WHERE count_no = current_setting('pgtap.v_count_no')) = 'DRAFT',
  'ok 4 — Stock Count saved as DRAFT'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT is_counted FROM rid_stock_count_lines
   WHERE count_no = current_setting('pgtap.v_count_no') AND serial_no = 3) = false
  AND (SELECT counted_base_qty FROM rid_stock_count_lines
   WHERE count_no = current_setting('pgtap.v_count_no') AND serial_no = 3) IS NULL,
  'ok 5 — untouched serial-product line stays is_counted=false with counted_base_qty NULL (never defaulted to zero)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT is_counted FROM rid_stock_count_lines
   WHERE count_no = current_setting('pgtap.v_count_no') AND serial_no = 4) = true
  AND (SELECT counted_base_qty FROM rid_stock_count_lines
   WHERE count_no = current_setting('pgtap.v_count_no') AND serial_no = 4) = 0,
  'ok 6 — explicitly-counted-empty line is is_counted=true with counted_base_qty=0, distinct from NULL'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM rid_transaction_line_batches
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'STOCK_COUNT'
     AND source_doc_no = current_setting('pgtap.v_count_no') AND line_serial = 2) = 2
  AND (SELECT sum(base_qty) FROM rid_transaction_line_batches
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'STOCK_COUNT'
     AND source_doc_no = current_setting('pgtap.v_count_no') AND line_serial = 2) = 8,
  'ok 7 — batch-tracked line persisted 2 batch children (B1=5, B2=3) summing to the counted 8'
);

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_stock_count(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'count_no', NULL, 'count_date', '2026-07-16'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L,
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 10, 'counted_qty_loose', 0, 'counted_base_qty', 10)),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'BX', 'expiry_date', NULL, 'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4)),
    '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_prod_batch'), current_setting('pgtap.v_user')),
  'BATCH_QTY_MISMATCH',
  'ok 8 — a batch-children sum (4) not matching the line''s counted_base_qty (10) is rejected'
);

-- ══════════════════════════════════════════════════════════════════════════
-- fn_submit_stock_count — NO_COUNTED_LINES block, success + lock, and
-- edit-after-submit block.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_count_no2 text;
BEGIN
  v_count_no2 := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-07-15'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_other'),
      'uom_conversion_factor', 1, 'is_counted', false)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_count_no2', v_count_no2, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_submit_stock_count(%L::uuid, %L::uuid, %L, '2026-07-15'::date, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_count_no2'), current_setting('pgtap.v_user')),
  'NO_COUNTED_LINES',
  'ok 9 — Submit is blocked when every line is still uncounted'
);

DO $$
BEGIN
  PERFORM fn_submit_stock_count(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_count_no'), '2026-07-15'::date, current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_count_headers WHERE count_no = current_setting('pgtap.v_count_no')) = 'SUBMITTED',
  'ok 10 — Stock Count with at least one counted line submits and locks'
);

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_submit_stock_count(%L::uuid, %L::uuid, %L, '2026-07-15'::date, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_count_no'), current_setting('pgtap.v_user')),
  'cannot be submitted again',
  'ok 11 — Submitting an already-SUBMITTED count a second time is rejected'
);

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_stock_count(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'count_no', %L, 'count_date', '2026-07-15'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L,
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 1, 'counted_qty_loose', 0, 'counted_base_qty', 1)),
    '[]'::jsonb, '[]'::jsonb, %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_count_no'), current_setting('pgtap.v_prod_snack'), current_setting('pgtap.v_user')),
  'cannot be edited',
  'ok 12 — Editing an already-SUBMITTED Stock Count is rejected'
);

-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
