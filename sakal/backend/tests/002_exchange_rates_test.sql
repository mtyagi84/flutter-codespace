-- ============================================================
-- 002_exchange_rates_test.sql — pgTAP tests for exchange rate functions
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste this entire file and run.
--   3. If any test fails → you see a RED error with "not ok N" detail.
--      If all pass    → you see "Success. No rows returned" (DO block completes quietly).
--
-- Transaction is rolled back — no permanent data changes.
-- ============================================================

BEGIN;

-- ── Fixtures ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0000-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0000-000000000002';
  v_loc_a       uuid := '00000000-0000-0000-0000-000000000010';
  v_loc_b       uuid := '00000000-0000-0000-0000-000000000011';
  v_user_id     uuid := '00000000-0000-0000-0000-000000000003';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST CLIENT', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- base_currency must be set to 'USD' — fn_get_exchange_rate resolves it
  -- from ric_companies to decide which lookup path applies (direct/
  -- reciprocal/cross-rate), and every rate row below is seeded as
  -- from_currency='USD'. Left NULL before, every path fell through to the
  -- cross-rate branch and failed looking up "<NULL> -> USD".
  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST COMPANY', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, is_active, is_deleted, created_at)
  VALUES
    (v_loc_a, v_client_id, v_company_id, 'Head Office', true, false, now()),
    (v_loc_b, v_client_id, v_company_id, 'Branch',      true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test_user', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- Rate for 2026-01-15: USD → CDF  buying 2780, selling 2820 (mid = 2800)
  INSERT INTO rim_exchange_rates
    (client_id, company_id, location_id, rate_date, from_currency, to_currency,
     buying_rate, selling_rate, source, created_by)
  VALUES
    (v_client_id, v_company_id, v_loc_a, '2026-01-15', 'USD', 'CDF', 2780, 2820, 'MANUAL', v_user_id)
  ON CONFLICT (client_id, company_id, location_id, rate_date, from_currency, to_currency)
  DO UPDATE SET buying_rate = 2780, selling_rate = 2820;

  -- Older rate 2026-01-10 (for "on or before" fallback test)
  INSERT INTO rim_exchange_rates
    (client_id, company_id, location_id, rate_date, from_currency, to_currency,
     buying_rate, selling_rate, source, created_by)
  VALUES
    (v_client_id, v_company_id, v_loc_a, '2026-01-10', 'USD', 'CDF', 2700, 2740, 'MANUAL', v_user_id)
  ON CONFLICT (client_id, company_id, location_id, rate_date, from_currency, to_currency)
  DO UPDATE SET buying_rate = 2700, selling_rate = 2740;
END;
$$;

-- ── Tests ─────────────────────────────────────────────────────────────────────
-- Collects every result line. If anything is "not ok", raises EXCEPTION so
-- Supabase shows the full failure detail as a visible red error.

DO $$
DECLARE
  v            text;
  all_results  text := '';
BEGIN
  PERFORM plan(10);

  -- 1. MID rate
  v := is(
    fn_get_exchange_rate('00000000-0000-0000-0000-000000000002'::uuid,
                         '00000000-0000-0000-0000-000000000010'::uuid,
                         'USD', 'CDF', '2026-01-15'::date, 'MID'),
    2800.0::numeric, 'MID rate = (buying + selling) / 2');
  all_results := all_results || v || E'\n';

  -- 2. BUYING rate
  v := is(
    fn_get_exchange_rate('00000000-0000-0000-0000-000000000002'::uuid,
                         '00000000-0000-0000-0000-000000000010'::uuid,
                         'USD', 'CDF', '2026-01-15'::date, 'BUYING'),
    2780.0::numeric, 'BUYING rate returned correctly');
  all_results := all_results || v || E'\n';

  -- 3. SELLING rate
  v := is(
    fn_get_exchange_rate('00000000-0000-0000-0000-000000000002'::uuid,
                         '00000000-0000-0000-0000-000000000010'::uuid,
                         'USD', 'CDF', '2026-01-15'::date, 'SELLING'),
    2820.0::numeric, 'SELLING rate returned correctly');
  all_results := all_results || v || E'\n';

  -- 4. Same currency → returns 1
  v := is(
    fn_get_exchange_rate('00000000-0000-0000-0000-000000000002'::uuid,
                         '00000000-0000-0000-0000-000000000010'::uuid,
                         'USD', 'USD', '2026-01-15'::date, 'MID'),
    1::numeric, 'Returns 1 when from_currency = to_currency');
  all_results := all_results || v || E'\n';

  -- 5. Fallback to most recent rate on or before requested date
  v := is(
    fn_get_exchange_rate('00000000-0000-0000-0000-000000000002'::uuid,
                         '00000000-0000-0000-0000-000000000010'::uuid,
                         'USD', 'CDF', '2026-01-12'::date, 'BUYING'),
    2700.0::numeric, 'Falls back to most recent rate on or before the requested date');
  all_results := all_results || v || E'\n';

  -- 6. Exception when no rate exists
  --    throws_ok(sql, errcode, errmsg, description) — NULL errmsg = don't check message text
  v := throws_ok(
    $q$ SELECT fn_get_exchange_rate(
          '00000000-0000-0000-0000-000000000002'::uuid,
          '00000000-0000-0000-0000-000000000010'::uuid,
          'USD', 'ZMW', '2026-01-15'::date, 'MID') $q$,
    'P0001',
    NULL,
    'Raises exception when no rate exists for the currency pair');
  all_results := all_results || v || E'\n';

  -- 7. Replication returns correct row count
  v := is(
    fn_replicate_exchange_rates(
      '00000000-0000-0000-0000-000000000001'::uuid,
      '00000000-0000-0000-0000-000000000002'::uuid,
      '00000000-0000-0000-0000-000000000010'::uuid,
      '2026-01-15'::date,
      '00000000-0000-0000-0000-000000000003'::uuid),
    1::integer, 'fn_replicate_exchange_rates copies 1 row to the other location');
  all_results := all_results || v || E'\n';

  -- 8. Replicated buying_rate matches source
  v := is(
    (SELECT buying_rate FROM rim_exchange_rates
      WHERE company_id  = '00000000-0000-0000-0000-000000000002'
        AND location_id = '00000000-0000-0000-0000-000000000011'
        AND rate_date   = '2026-01-15'
        AND to_currency = 'CDF'),
    2780.0::numeric, 'Replicated buying_rate matches source location');
  all_results := all_results || v || E'\n';

  -- 9. Idempotency: second run returns same count
  v := is(
    fn_replicate_exchange_rates(
      '00000000-0000-0000-0000-000000000001'::uuid,
      '00000000-0000-0000-0000-000000000002'::uuid,
      '00000000-0000-0000-0000-000000000010'::uuid,
      '2026-01-15'::date,
      '00000000-0000-0000-0000-000000000003'::uuid),
    1::integer, 'fn_replicate_exchange_rates is idempotent (same count on re-run)');
  all_results := all_results || v || E'\n';

  -- 10. Source location row count unchanged after replication
  v := is(
    (SELECT COUNT(*)::integer FROM rim_exchange_rates
      WHERE company_id  = '00000000-0000-0000-0000-000000000002'
        AND location_id = '00000000-0000-0000-0000-000000000010'
        AND rate_date   = '2026-01-15'),
    1, 'Source location row count unchanged after replication');
  all_results := all_results || v || E'\n';

  -- Append finish() summary
  FOR v IN SELECT * FROM finish() LOOP
    all_results := all_results || v || E'\n';
  END LOOP;

  -- Fail loudly so Supabase shows the full detail in the error panel
  IF all_results LIKE '%not ok%' THEN
    RAISE EXCEPTION E'TESTS FAILED — see detail below:\n\n%', all_results;
  END IF;

END;
$$;

ROLLBACK;
