-- ============================================================
-- 079_stock_count_review_test.sql — pgTAP tests for Stock Count Review
-- Screen 2 (migration 079).
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--
-- One company (SIMPLE), two locations (v_loc for most scenarios, v_loc2
-- only for the location-mismatch guard), products purpose-built one per
-- scenario so each assertion is unambiguous:
--   v_prod_asof        (NONE)   — as-of-date correctness
--   v_prod_uncounted    (NONE)   — uncounted-exclusion
--   v_prod_batch_net    (BATCH)  — batch netting across two source counts
--   v_prod_serial_dup   (SERIAL) — serial dedupe + unknown-serial exception
--   v_prod_zero         (NONE)   — exact match, zero variance
--   v_prod_no_cost      (NONE)   — COST_NOT_ESTABLISHED guard still holds
--   v_prod_batch_neg    (BATCH)  — negative-stock rule still holds
--
-- Two "must succeed" source counts (A, B) feed the main Review (REV1),
-- used for variance-computation correctness + the full successful
-- end-to-end Approve. Two isolated single-line reviews (REV_COST,
-- REV_NEG) exercise the two failure modes without disturbing REV1's
-- happy path. Separate small counts/reviews cover reservation and
-- location-mismatch.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

DO $$
DECLARE
  v_client   uuid := '00000000-0000-0000-0079-000000000001';
  v_company  uuid := '00000000-0000-0000-0079-000000000002';
  v_loc      uuid := '00000000-0000-0000-0079-000000000003';
  v_loc2     uuid := '00000000-0000-0000-0079-000000000004';
  v_user     uuid := '00000000-0000-0000-0079-000000000005';
  v_stock_acc uuid := '00000000-0000-0000-0079-000000000006';
  v_adj_acc   uuid := '00000000-0000-0000-0079-000000000007';
  v_reason    uuid := '00000000-0000-0000-0079-000000000008';
  v_fy        uuid := '00000000-0000-0000-0079-000000000009';
  v_usd       uuid;
  v_prod_asof        uuid := '00000000-0000-0000-0079-00000000000a';
  v_prod_uncounted   uuid := '00000000-0000-0000-0079-00000000000b';
  v_prod_batch_net   uuid := '00000000-0000-0000-0079-00000000000c';
  v_prod_serial_dup  uuid := '00000000-0000-0000-0079-00000000000d';
  v_prod_zero        uuid := '00000000-0000-0000-0079-00000000000e';
  v_prod_no_cost     uuid := '00000000-0000-0000-0079-00000000000f';
  v_prod_batch_neg   uuid := '00000000-0000-0000-0079-000000000010';
  v_reason_type_id   uuid;
  v_stock_link_type  uuid;
  v_adj_link_type    uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client, 'TEST079', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, inter_location_model, is_active, is_deleted, created_at)
  VALUES (v_company, v_client, 'TEST079 CO', 'USD', 'USD', 'SIMPLE', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted,
                              is_negative_stock_allowed, is_issue_allowed, created_at)
  VALUES
    (v_loc,  v_client, v_company, 'TEST079 Loc',  'T079L1', true, false, false, true, now()),
    (v_loc2, v_client, v_company, 'TEST079 Loc2', 'T079L2', true, false, false, true, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user, v_client, v_company, 'test079', 'Test User 079', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd FROM rim_currencies WHERE client_id = v_client AND company_id = v_company AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_stock_acc, v_client, v_company, '13Y1', 'Stock Account 079',            'General', 'OHADA', true, true, false, now()),
    (v_adj_acc,   v_client, v_company, '61Y1', 'Stock Adjustment Account 079', 'General', 'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_stock_link_type FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_adj_link_type   FROM rim_account_link_types WHERE link_key = 'STOCK_ADJUSTMENT_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client, v_company, v_stock_link_type, 'COMPANY'),
    (v_client, v_company, v_adj_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client, v_company, v_stock_link_type, NULL, v_stock_acc),
    (v_client, v_company, v_adj_link_type, NULL, v_adj_acc)
  ON CONFLICT DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy, v_client, v_company, 'FY TEST079', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_reason_type_id FROM rim_common_master_types WHERE type_key = 'STOCK_ADJUSTMENT_REASON';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, sort_order, created_by)
  VALUES (v_reason, v_client, v_company, v_reason_type_id, 'TEST079 Physical Count Variance', 90, v_user)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES
    (v_prod_asof,       v_client, v_company, 'CNR-ASF', 'Review Test AsOf',      v_usd, 'NONE',   v_user),
    (v_prod_uncounted,  v_client, v_company, 'CNR-UNC', 'Review Test Uncounted', v_usd, 'NONE',   v_user),
    (v_prod_batch_net,  v_client, v_company, 'CNR-BNT', 'Review Test BatchNet',  v_usd, 'BATCH',  v_user),
    (v_prod_serial_dup, v_client, v_company, 'CNR-SDP', 'Review Test SerialDup', v_usd, 'SERIAL', v_user),
    (v_prod_zero,       v_client, v_company, 'CNR-ZER', 'Review Test Zero',      v_usd, 'NONE',   v_user),
    (v_prod_no_cost,    v_client, v_company, 'CNR-NOC', 'Review Test NoCost',    v_usd, 'NONE',   v_user),
    (v_prod_batch_neg,  v_client, v_company, 'CNR-BNG', 'Review Test BatchNeg',  v_usd, 'BATCH',  v_user)
  ON CONFLICT (id) DO NOTHING;

  -- Opening stock, all dated 2026-05-20
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_asof,
    '2026-05-20'::date, 'OPENING_STOCK', 100, 10, 10, NULL, NULL, NULL, 'OPENING_BALANCE', 'OB-079-001', '2026-05-20'::date, v_user);
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_uncounted,
    '2026-05-20'::date, 'OPENING_STOCK', 30, 8, 8, NULL, NULL, NULL, 'OPENING_BALANCE', 'OB-079-002', '2026-05-20'::date, v_user);
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_batch_net,
    '2026-05-20'::date, 'OPENING_STOCK', 20, 5, 5, 'BN1', NULL, NULL, 'OPENING_BALANCE', 'OB-079-003', '2026-05-20'::date, v_user);
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_serial_dup,
    '2026-05-20'::date, 'OPENING_STOCK', 1, 20, 20, NULL, NULL, 'SD-1', 'OPENING_BALANCE', 'OB-079-004', '2026-05-20'::date, v_user);
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_serial_dup,
    '2026-05-20'::date, 'OPENING_STOCK', 1, 20, 20, NULL, NULL, 'SD-2', 'OPENING_BALANCE', 'OB-079-005', '2026-05-20'::date, v_user);
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_zero,
    '2026-05-20'::date, 'OPENING_STOCK', 40, 6, 6, NULL, NULL, NULL, 'OPENING_BALANCE', 'OB-079-006', '2026-05-20'::date, v_user);
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_batch_neg,
    '2026-05-20'::date, 'OPENING_STOCK', 20, 5, 5, 'BNEG', NULL, NULL, 'OPENING_BALANCE', 'OB-079-007', '2026-05-20'::date, v_user);

  -- A later transaction on v_prod_asof, AFTER as-of-date 2026-05-29, proving
  -- the review's variance computation stays pinned to the as-of-date and is
  -- immune to what happens afterward.
  PERFORM fn_post_stock_movement(v_client, v_company, v_loc, v_prod_asof,
    '2026-05-31'::date, 'ADJUSTMENT_IN', 50, 10, 10, NULL, NULL, NULL, 'TEST_LATER_TXN', 'LATER-001', '2026-05-31'::date, v_user);

  PERFORM set_config('pgtap.v_client', v_client::text, false);
  PERFORM set_config('pgtap.v_company', v_company::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc::text, false);
  PERFORM set_config('pgtap.v_loc2', v_loc2::text, false);
  PERFORM set_config('pgtap.v_user', v_user::text, false);
  PERFORM set_config('pgtap.v_stock_acc', v_stock_acc::text, false);
  PERFORM set_config('pgtap.v_adj_acc', v_adj_acc::text, false);
  PERFORM set_config('pgtap.v_reason', v_reason::text, false);
  PERFORM set_config('pgtap.v_prod_asof', v_prod_asof::text, false);
  PERFORM set_config('pgtap.v_prod_uncounted', v_prod_uncounted::text, false);
  PERFORM set_config('pgtap.v_prod_batch_net', v_prod_batch_net::text, false);
  PERFORM set_config('pgtap.v_prod_serial_dup', v_prod_serial_dup::text, false);
  PERFORM set_config('pgtap.v_prod_zero', v_prod_zero::text, false);
  PERFORM set_config('pgtap.v_prod_no_cost', v_prod_no_cost::text, false);
  PERFORM set_config('pgtap.v_prod_batch_neg', v_prod_batch_neg::text, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(18);

-- ══════════════════════════════════════════════════════════════════════════
-- Source counts A + B (both SUBMITTED, same location) feeding REV1.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_a text; v_b text;
BEGIN
  v_a := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_asof'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 100, 'counted_qty_loose', 0, 'counted_base_qty', 100),
      jsonb_build_object('serial_no', 2, 'product_id', current_setting('pgtap.v_prod_uncounted'),
        'uom_conversion_factor', 1, 'is_counted', false),
      jsonb_build_object('serial_no', 3, 'product_id', current_setting('pgtap.v_prod_batch_net'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 12, 'counted_qty_loose', 0, 'counted_base_qty', 12),
      jsonb_build_object('serial_no', 4, 'product_id', current_setting('pgtap.v_prod_serial_dup'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 2, 'counted_qty_loose', 0, 'counted_base_qty', 2),
      jsonb_build_object('serial_no', 5, 'product_id', current_setting('pgtap.v_prod_zero'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 40, 'counted_qty_loose', 0, 'counted_base_qty', 40)
    ),
    jsonb_build_array(jsonb_build_object('line_serial', 3, 'batch_no', 'BN1', 'expiry_date', NULL, 'qty_pack', 12, 'qty_loose', 0, 'base_qty', 12)),
    jsonb_build_array(
      jsonb_build_object('line_serial', 4, 'serial_no', 'SD-1'),
      jsonb_build_object('line_serial', 4, 'serial_no', 'SD-2')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_a, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);
  PERFORM set_config('pgtap.v_count_a', v_a, false);

  v_b := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-25'),
    jsonb_build_array(
      jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_batch_net'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 9, 'counted_qty_loose', 0, 'counted_base_qty', 9),
      jsonb_build_object('serial_no', 2, 'product_id', current_setting('pgtap.v_prod_serial_dup'),
        'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 2, 'counted_qty_loose', 0, 'counted_base_qty', 2)
    ),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'BN1', 'expiry_date', NULL, 'qty_pack', 9, 'qty_loose', 0, 'base_qty', 9)),
    jsonb_build_array(
      jsonb_build_object('line_serial', 2, 'serial_no', 'SD-1'),   -- overlap with Count A — same physical unit
      jsonb_build_object('line_serial', 2, 'serial_no', 'SD-X')    -- never received — unknown-serial exception
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_b, '2026-05-25'::date, current_setting('pgtap.v_user')::uuid);
  PERFORM set_config('pgtap.v_count_b', v_b, false);
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE v_rev text;
BEGIN
  v_rev := fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', NULL, 'review_date', '2026-07-20',
      'as_of_date', '2026-05-29', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV1'),
    jsonb_build_array(
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_a'), 'source_count_date', '2026-05-24'),
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_b'), 'source_count_date', '2026-05-25')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_rev1', v_rev, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
    WHERE product_id = current_setting('pgtap.v_prod_uncounted')::uuid
  ),
  'ok 1 — an uncounted product (live system balance 30) never appears in the variance output — missed != phantom line'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT system_qty FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_asof')::uuid) = 100,
  'ok 2 — as_of_date=2026-05-29 (before the later +50 txn dated 05-31): system_qty=100'
);

DO $$
BEGIN
  PERFORM fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', current_setting('pgtap.v_rev1'), 'review_date', '2026-07-20',
      'as_of_date', '2026-06-01', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV1'),
    jsonb_build_array(
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_a'), 'source_count_date', '2026-05-24'),
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_b'), 'source_count_date', '2026-05-25')
    ),
    current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT system_qty FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_asof')::uuid) = 150,
  'ok 3 — re-saved as_of_date=2026-06-01 (after the +50 txn): system_qty now 150 — proves as-of-date sensitivity, not a cached/stale figure'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT counted_qty FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_batch_net')::uuid AND batch_no = 'BN1') = 21
  AND (SELECT variance_qty FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_batch_net')::uuid AND batch_no = 'BN1') = 1
  AND (SELECT adjust_flag FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_batch_net')::uuid AND batch_no = 'BN1') = '+',
  'ok 4 — batch BN1 counted by two different counters (12+9) clubs to 21 vs system 20 -> variance +1'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT count(*) FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_serial_dup')::uuid AND serial_no = 'SD-1') = 1,
  'ok 5 — serial SD-1, entered in two overlapping counts, is counted ONCE (deduped), not summed to 2'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT is_unknown_serial FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_serial_dup')::uuid AND serial_no = 'SD-X') = true
  AND (SELECT adjust_flag FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_serial_dup')::uuid AND serial_no = 'SD-X') IS NULL,
  'ok 6 — serial SD-X (never received, zero system history) is flagged is_unknown_serial with no adjust_flag'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT variance_qty FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_zero')::uuid) = 0
  AND (SELECT adjust_flag FROM fn_compute_stock_count_variance(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_rev1'), '2026-07-20'::date)
   WHERE product_id = current_setting('pgtap.v_prod_zero')::uuid) IS NULL,
  'ok 7 — counted exactly matching system (40=40) produces zero variance and no adjust_flag — no line will be posted for it'
);

-- ══════════════════════════════════════════════════════════════════════════
-- Reservation-once-consumed + location-mismatch + draft-count guard.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_d text; v_h text; v_i text; v_e text; v_c text;
BEGIN
  v_d := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_zero'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 1, 'counted_qty_loose', 0, 'counted_base_qty', 1)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_d, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);
  PERFORM set_config('pgtap.v_count_d', v_d, false);

  v_h := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_zero'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 1, 'counted_qty_loose', 0, 'counted_base_qty', 1)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_h, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);
  PERFORM set_config('pgtap.v_count_h', v_h, false);

  v_i := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_zero'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 1, 'counted_qty_loose', 0, 'counted_base_qty', 1)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_i, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);
  PERFORM set_config('pgtap.v_count_i', v_i, false);

  -- DRAFT (never submitted) — for the "must be Submitted first" guard.
  v_e := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_zero'),
      'uom_conversion_factor', 1, 'is_counted', false)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_count_e', v_e, false);

  -- At the OTHER location — for the location-mismatch guard.
  v_c := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc2'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_zero'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 1, 'counted_qty_loose', 0, 'counted_base_qty', 1)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_c, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);
  PERFORM set_config('pgtap.v_count_c', v_c, false);
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE v_x text;
BEGIN
  v_x := fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', NULL, 'review_date', '2026-07-21',
      'as_of_date', '2026-05-24', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV_X'),
    jsonb_build_array(
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_d'), 'source_count_date', '2026-05-24'),
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_h'), 'source_count_date', '2026-05-24')
    ),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_rev_x', v_x, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_stock_count_review(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'review_no', NULL, 'review_date', '2026-07-22',
      'as_of_date', '2026-05-24', 'reason_id', %L),
    jsonb_build_array(jsonb_build_object('source_count_no', %L, 'source_count_date', '2026-05-24')),
    %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_reason'), current_setting('pgtap.v_count_d'), current_setting('pgtap.v_user')),
  'P0001', NULL, -- dynamic message (interpolates count_no/review_no) — check SQLSTATE only, not exact text
  'ok 8 — a second Review cannot pick a Stock Count already reserved by Review REV_X'
);

DO $$
BEGIN
  -- Re-save REV_X keeping only Count H — this un-reserves Count D.
  PERFORM fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', current_setting('pgtap.v_rev_x'), 'review_date', '2026-07-21',
      'as_of_date', '2026-05-24', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV_X'),
    jsonb_build_array(jsonb_build_object('source_count_no', current_setting('pgtap.v_count_h'), 'source_count_date', '2026-05-24')),
    current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_count_headers WHERE count_no = current_setting('pgtap.v_count_d')) = 'SUBMITTED'
  AND (SELECT fn_save_stock_count_review(
        jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
          'location_id', current_setting('pgtap.v_loc'), 'review_no', NULL, 'review_date', '2026-07-22',
          'as_of_date', '2026-05-24', 'reason_id', current_setting('pgtap.v_reason')),
        jsonb_build_array(jsonb_build_object('source_count_no', current_setting('pgtap.v_count_d'), 'source_count_date', '2026-05-24')),
        current_setting('pgtap.v_user')::uuid
      )) IS NOT NULL,
  'ok 9 — un-picking Count D from REV_X''s draft frees its reservation, and a new Review Y can now pick it'
);

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_stock_count_review(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'review_no', NULL, 'review_date', '2026-07-23',
      'as_of_date', '2026-05-24', 'reason_id', %L),
    jsonb_build_array(
      jsonb_build_object('source_count_no', %L, 'source_count_date', '2026-05-24'),
      jsonb_build_object('source_count_no', %L, 'source_count_date', '2026-05-24')
    ),
    %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_reason'), current_setting('pgtap.v_count_i'), current_setting('pgtap.v_count_c'), current_setting('pgtap.v_user')),
  'P0001', NULL, -- dynamic message (interpolates count_no) — check SQLSTATE only, not exact text
  'ok 10 — a Stock Count at a different location cannot be added to this Review'
);

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_stock_count_review(
    jsonb_build_object('client_id', %L, 'company_id', %L, 'location_id', %L, 'review_no', NULL, 'review_date', '2026-07-24',
      'as_of_date', '2026-05-24', 'reason_id', %L),
    jsonb_build_array(jsonb_build_object('source_count_no', %L, 'source_count_date', '2026-05-24')),
    %L::uuid
  ) $$, current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
       current_setting('pgtap.v_reason'), current_setting('pgtap.v_count_e'), current_setting('pgtap.v_user')),
  'P0001', NULL, -- dynamic message (interpolates count_no) — check SQLSTATE only, not exact text
  'ok 11 — a still-DRAFT Stock Count cannot be picked into a Review'
);

-- ══════════════════════════════════════════════════════════════════════════
-- Future-date guard on REV1's as_of_date, then restore it for the real
-- Approve below.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  PERFORM fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', current_setting('pgtap.v_rev1'), 'review_date', '2026-07-20',
      'as_of_date', (CURRENT_DATE + 1)::text, 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV1'),
    jsonb_build_array(
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_a'), 'source_count_date', '2026-05-24'),
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_b'), 'source_count_date', '2026-05-25')
    ),
    current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_stock_count_review(%L::uuid, %L::uuid, %L, '2026-07-20'::date, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_rev1'), current_setting('pgtap.v_user')),
  'FUTURE_DATE_NOT_ALLOWED',
  'ok 12 — Approve is blocked when as_of_date is in the future'
);

DO $$
BEGIN
  -- Restore a valid as_of_date before the real end-to-end Approve.
  PERFORM fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', current_setting('pgtap.v_rev1'), 'review_date', '2026-07-20',
      'as_of_date', '2026-06-01', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV1'),
    jsonb_build_array(
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_a'), 'source_count_date', '2026-05-24'),
      jsonb_build_object('source_count_no', current_setting('pgtap.v_count_b'), 'source_count_date', '2026-05-25')
    ),
    current_setting('pgtap.v_user')::uuid
  );
END;
$$ LANGUAGE plpgsql;

-- ══════════════════════════════════════════════════════════════════════════
-- End-to-end Approve — composes the EXISTING Stock Adjustment engine.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_adj_no text;
BEGIN
  v_adj_no := fn_approve_stock_count_review(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_rev1'), '2026-07-20'::date, current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_posted_adj', v_adj_no, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT source_doc_type FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_posted_adj')) = 'STOCK_COUNT_REVIEW'
  AND (SELECT source_doc_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_posted_adj')) = current_setting('pgtap.v_rev1'),
  'ok 13 — the auto-created Stock Adjustment traces back to Review REV1 via source_doc_type/no'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT trans_type FROM ril_stock_ledger
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND source_doc_type = 'STOCK_ADJUSTMENT'
     AND source_doc_no = current_setting('pgtap.v_posted_adj') AND product_id = current_setting('pgtap.v_prod_batch_net')::uuid
     AND batch_no = 'BN1') = 'ADJUSTMENT_IN',
  'ok 14 — the +1 batch variance posts an ADJUSTMENT_IN ledger row'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_stock_adjustment_headers WHERE adjustment_no = current_setting('pgtap.v_posted_adj'))) = 0,
  'ok 15 — the ADJV voucher balances DR=CR on its own'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_stock_count_review_headers WHERE review_no = current_setting('pgtap.v_rev1')) = 'APPROVED'
  AND (SELECT posted_adjustment_no FROM rih_stock_count_review_headers WHERE review_no = current_setting('pgtap.v_rev1')) = current_setting('pgtap.v_posted_adj'),
  'ok 16 — Review REV1 is APPROVED and its posted_adjustment_no is stored'
);

-- ══════════════════════════════════════════════════════════════════════════
-- Isolated failure-mode reviews — never mixed into REV1's happy path.
-- ══════════════════════════════════════════════════════════════════════════

-- Negative-stock rule still holds: drain batch BNEG down to 4 (via a
-- transaction dated AFTER as_of_date, so the review's own as-of-date
-- variance computation still sees 20 and asks to remove 15 — but the
-- REAL current balance at Approve time is only 4, so it must fail).
DO $$
DECLARE v_g text; v_rev_neg text;
BEGIN
  PERFORM fn_post_stock_movement(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, current_setting('pgtap.v_loc')::uuid,
    current_setting('pgtap.v_prod_batch_neg')::uuid, '2026-05-25'::date, 'ADJUSTMENT_OUT', -16,
    NULL, NULL, 'BNEG', NULL, NULL, 'TEST_DRAIN', 'DRAIN-001', '2026-05-25'::date, current_setting('pgtap.v_user')::uuid
  );

  v_g := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_batch_neg'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 5, 'counted_qty_loose', 0, 'counted_base_qty', 5)),
    jsonb_build_array(jsonb_build_object('line_serial', 1, 'batch_no', 'BNEG', 'expiry_date', NULL, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5)),
    '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_g, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);

  v_rev_neg := fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', NULL, 'review_date', '2026-07-25',
      'as_of_date', '2026-05-24', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV_NEG'),
    jsonb_build_array(jsonb_build_object('source_count_no', v_g, 'source_count_date', '2026-05-24')),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_rev_neg', v_rev_neg, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_stock_count_review(%L::uuid, %L::uuid, %L, '2026-07-25'::date, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_rev_neg'), current_setting('pgtap.v_user')),
  'BATCH_INSUFFICIENT_STOCK',
  'ok 17 — a variance computed against a stale as-of-date snapshot still fails if the batch''s CURRENT balance can''t cover it — proves Approve genuinely routes through fn_post_stock_movement''s real-time check, not a bypass'
);

-- COST_NOT_ESTABLISHED still holds for an uncosted '+' variance line.
DO $$
DECLARE v_f text; v_rev_cost text;
BEGIN
  v_f := fn_save_stock_count(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'count_no', NULL, 'count_date', '2026-05-24'),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_prod_no_cost'),
      'uom_conversion_factor', 1, 'is_counted', true, 'counted_qty_pack', 5, 'counted_qty_loose', 0, 'counted_base_qty', 5)),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user')::uuid
  );
  PERFORM fn_submit_stock_count(current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, v_f, '2026-05-24'::date, current_setting('pgtap.v_user')::uuid);

  v_rev_cost := fn_save_stock_count_review(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'review_no', NULL, 'review_date', '2026-07-26',
      'as_of_date', '2026-05-24', 'reason_id', current_setting('pgtap.v_reason'), 'remarks', 'REV_COST'),
    jsonb_build_array(jsonb_build_object('source_count_no', v_f, 'source_count_date', '2026-05-24')),
    current_setting('pgtap.v_user')::uuid
  );
  PERFORM set_config('pgtap.v_rev_cost', v_rev_cost, false);
END;
$$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_approve_stock_count_review(%L::uuid, %L::uuid, %L, '2026-07-26'::date, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'),
    current_setting('pgtap.v_rev_cost'), current_setting('pgtap.v_user')),
  'COST_NOT_ESTABLISHED',
  'ok 18 — a "+" variance line on a never-stocked product is still blocked by the composed Stock Adjustment engine''s existing guard'
);

-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
