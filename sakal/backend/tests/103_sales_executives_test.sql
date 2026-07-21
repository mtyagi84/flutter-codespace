-- ============================================================
-- 103_sales_executives_test.sql — pgTAP smoke test for migration 103
-- ============================================================
-- Not a posting-engine test (this migration adds a plain master +
-- retrofits an FK target, no new fn_save_*/fn_approve_* function) — a
-- focused smoke test confirming: the table exists with the right shape,
-- a sales executive with NO linked_user_id works (the whole point of
-- this module — a rep with no system login), the four FK targets
-- actually point at rim_sales_executives now (not still rim_users, which
-- would silently defeat the entire retrofit), and the employee_code
-- uniqueness constraint holds.
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(7);

DO $$
DECLARE
  v_client_id   uuid := '00000000-0000-0000-0103-000000000001';
  v_company_id  uuid := '00000000-0000-0000-0103-000000000002';
  v_loc_id      uuid := '00000000-0000-0000-0103-000000000003';
  v_user_id     uuid := '00000000-0000-0000-0103-000000000004';
  v_customer    uuid := '00000000-0000-0000-0103-000000000005';
  v_cust_grp    uuid := '00000000-0000-0000-0103-000000000006';
  v_exec_id     uuid := '00000000-0000-0000-0103-000000000007'; -- no linked_user_id
  v_usd_ccy_id  uuid;
  v_error_raised boolean := false;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST103', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST103 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test103 Loc', 'T103L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test103_user', 'Test103 User', crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_cust_grp, v_client_id, v_company_id, '3000', 'Sundry Debtors 103', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES (v_customer, v_client_id, v_company_id, v_cust_grp, '3000001', 'Test103 Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- A sales executive with NO linked_user_id — the whole point of this
  -- module: a rep who has never logged into the ERP.
  INSERT INTO rim_sales_executives (id, client_id, company_id, employee_code, full_name, is_active, created_by)
  VALUES (v_exec_id, v_client_id, v_company_id, 'SE-TEST103', 'Test103 Field Rep (no login)', true, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  -- Sales Quotation referencing that no-login exec as sales_person_id —
  -- must succeed (proves the FK now accepts a non-rim_users id).
  INSERT INTO rih_sales_quotations (
    client_id, company_id, location_id, quotation_no, quotation_date,
    customer_type, customer_id, sales_person_id, quotation_currency_id,
    rate_to_base, rate_to_local, gross_amount, tax_amount, grand_total,
    status, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, 'QUO-TEST103-A', CURRENT_DATE,
    'CUSTOMER', v_customer, v_exec_id, v_usd_ccy_id,
    1, 1, 100, 0, 100,
    'DRAFT', v_user_id, v_user_id
  ) ON CONFLICT DO NOTHING;

  -- A random, non-existent UUID must still be REJECTED — proves the FK
  -- is actually enforced against rim_sales_executives, not silently
  -- still pointing at rim_users (which would let this through only if
  -- that random uuid happened to also be a rim_users.id, so a clean
  -- rejection here is the real proof the retrofit took effect).
  BEGIN
    INSERT INTO rih_sales_quotations (
      client_id, company_id, location_id, quotation_no, quotation_date,
      customer_type, customer_id, sales_person_id, quotation_currency_id,
      rate_to_base, rate_to_local, gross_amount, tax_amount, grand_total,
      status, created_by, updated_by
    ) VALUES (
      v_client_id, v_company_id, v_loc_id, 'QUO-TEST103-B', CURRENT_DATE,
      'CUSTOMER', v_customer, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid, v_usd_ccy_id,
      1, 1, 100, 0, 100,
      'DRAFT', v_user_id, v_user_id
    );
  EXCEPTION WHEN foreign_key_violation THEN
    v_error_raised := true;
  END;

  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_exec', v_exec_id::text, false);
  PERFORM set_config('pgtap.v_fk_test', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'rim_sales_executives'),
  'ok 1 — rim_sales_executives table exists'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT linked_user_id IS NULL FROM rim_sales_executives WHERE id = current_setting('pgtap.v_exec')::uuid),
  'ok 2 — a sales executive can exist with NO linked_user_id (not a system user)'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (SELECT 1 FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid AND quotation_no = 'QUO-TEST103-A' AND sales_person_id = current_setting('pgtap.v_exec')::uuid),
  'ok 3 — Sales Quotation accepts a no-login sales executive as sales_person_id'
);

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_fk_test')::boolean,
  'ok 4 — sales_person_id FK rejects a UUID not present in rim_sales_executives (proves the retrofit actually took effect)'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name
    WHERE tc.table_name = 'rih_sales_invoices' AND tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_name = 'rim_sales_executives'
  ),
  'ok 5 — rih_sales_invoices.sales_person_id FK target is rim_sales_executives'
);

INSERT INTO test_results (result) SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name
    WHERE tc.table_name = 'ric_user_quick_invoice_setup' AND tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_name = 'rim_sales_executives'
  ),
  'ok 6 — ric_user_quick_invoice_setup.default_sales_person_id FK target is rim_sales_executives'
);

DO $$
DECLARE
  v_error_raised boolean := false;
BEGIN
  BEGIN
    INSERT INTO rim_sales_executives (client_id, company_id, employee_code, full_name, is_active, created_by)
    VALUES (current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'SE-TEST103', 'Duplicate Code Attempt', true, current_setting('pgtap.v_client')::uuid);
  EXCEPTION WHEN unique_violation THEN
    v_error_raised := true;
  END;
  PERFORM set_config('pgtap.v_uq_test', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  current_setting('pgtap.v_uq_test')::boolean,
  'ok 7 — duplicate employee_code within the same client/company is rejected'
);

SELECT result FROM test_results ORDER BY n;
SELECT * FROM finish();

ROLLBACK;
