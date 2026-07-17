-- ============================================================
-- 089_sales_invoice_test.sql — pgTAP tests for migrations 088/089
-- (ric_user_quick_invoice_setup + lock trigger, fn_save_sales_invoice,
--  fn_approve_sales_invoice, fn_cancel_sales_invoice,
--  fn_verify_discount_override)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- Fb0ixture: base=local=USD (keeps the money-math tests focused on the
-- Sales Invoice logic itself, not currency conversion — currency
-- correctness is exercised elsewhere, e.g. Sales Order/Purchase Bill's
-- own test suites) — 1 location, 1 cashier (ric_user_sales_controls
-- max_discount_percent=5) with a Quick Invoice Setup row, 1 supervisor
-- (max_discount_percent=20, no Quick Invoice Setup row — proves the
-- override path doesn't need one), a Cash Customer + a Credit Customer
-- account, Sales/COS/Stock GL accounts + account links, a 10% tax on
-- one product, 100 units opening stock @ cost 10, and one APPROVED
-- Sales Quotation for the AGAINST_QUOTATION whole-document tests.
--
-- NOT covered here (lower-risk, simpler code paths — noted, not
-- silently skipped): DEFERRED stock_dispatch_mode/cash_collection_mode
-- (each is just "skip the block", no new branching logic to break),
-- QUOTATION_HAS_ORDER (needs a full Sales Order fixture on top of the
-- quotation one), multi-currency receipt math (exercised by construction
-- in Sales Order/Purchase Bill's own suites, base=local=USD here keeps
-- this file's fixture tractable).
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

-- pgTAP requires a plan() before any ok()/is()/throws_ok() call.
SELECT plan(20);

DO $$
DECLARE
  v_client_id        uuid := '00000000-0000-0000-0089-000000000001';
  v_company_id       uuid := '00000000-0000-0000-0089-000000000002';
  v_loc_id           uuid := '00000000-0000-0000-0089-000000000003';
  v_cashier_id       uuid := '00000000-0000-0000-0089-000000000004';
  v_supervisor_id    uuid := '00000000-0000-0000-0089-000000000005';
  v_cash_cust_grp    uuid := '00000000-0000-0000-0089-000000000006';
  v_cash_customer_id uuid := '00000000-0000-0000-0089-000000000007';
  v_credit_customer_id uuid := '00000000-0000-0000-0089-000000000008';
  v_sales_acc        uuid := '00000000-0000-0000-0089-000000000009';
  v_cos_acc          uuid := '00000000-0000-0000-0089-00000000000a';
  v_stock_acc        uuid := '00000000-0000-0000-0089-00000000000b';
  v_tax_out_acc      uuid := '00000000-0000-0000-0089-00000000000c';
  v_local_cash_acc   uuid := '00000000-0000-0000-0089-00000000000d';
  v_base_cash_acc    uuid := '00000000-0000-0000-0089-00000000000e';
  v_product_id       uuid := '00000000-0000-0000-0089-00000000000f';
  v_uom_id           uuid := '00000000-0000-0000-0089-000000000010';
  v_tax_id           uuid := '00000000-0000-0000-0089-000000000011';
  v_tax_group_id     uuid := '00000000-0000-0000-0089-000000000012';
  v_tax_type_code    text;
  v_usd_ccy_id       uuid;
  v_unit_type_id     uuid;
  v_sales_link       uuid;
  v_cos_link         uuid;
  v_stock_link       uuid;
  v_freight_acc      uuid := '00000000-0000-0000-0089-000000000013';
  v_charge_id        uuid := '00000000-0000-0000-0089-000000000014';
  v_fy_id            uuid := '00000000-0000-0000-0089-000000000015';
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST089', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency,
    quick_invoice_dispatch_stock, quick_invoice_collect_cash, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST089 CO', 'USD', 'USD', true, true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test089 Loc', 'T89L', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_cashier_id,    v_client_id, v_company_id, 'test089_cashier', 'Test089 Cashier',    crypt('cashierpw', gen_salt('bf')), true, false, now()),
    (v_supervisor_id, v_client_id, v_company_id, 'test089_super',   'Test089 Supervisor', crypt('superpw', gen_salt('bf')),   true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- can_override_price=true: this fixture has no Price Master entries at
  -- all (out of scope — building a compliant rih_price_master_headers/
  -- rid_price_master_lines fixture is a separate concern from this
  -- module's own tests), so every DIRECT-mode line below resolves via
  -- MANUAL_OVERRIDE (with its own price_override_reason) rather than
  -- PRICE_MASTER — same shortcut Sales Order's own test file uses for the
  -- identical reason. No assertion in this file checks price_source, so
  -- this doesn't weaken anything actually being tested here.
  INSERT INTO ric_user_sales_controls (client_id, company_id, user_id, can_override_price, can_give_discount, max_discount_percent, can_view_cost_price)
  VALUES
    (v_client_id, v_company_id, v_cashier_id,    true, true, 5,  false),
    (v_client_id, v_company_id, v_supervisor_id, true, true, 20, false)
  ON CONFLICT (client_id, company_id, user_id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  -- Financial year covering every date this fixture posts against
  -- (opening stock 2026-01-01, invoices 2026-07-02..04) — fn_check_period_open
  -- (the mandatory first check in every fn_approve_*/fn_post_stock_movement)
  -- raises FY_CLOSED without one.
  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST089', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- Accounts: Customer group + cash/credit customers, Sales/COS/Stock/Tax
  -- GL accounts, and the two cash-drawer accounts for Quick Invoice Setup.
  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_cash_cust_grp, v_client_id, v_company_id, '3000', 'Sundry Debtors 089', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_cash_customer_id,   v_client_id, v_company_id, v_cash_cust_grp, '3000001', 'Test089 Cash Customer',   'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_credit_customer_id, v_client_id, v_company_id, v_cash_cust_grp, '3000002', 'Test089 Credit Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_sales_acc,      v_client_id, v_company_id, '4000', 'Test089 Sales',         'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_cos_acc,        v_client_id, v_company_id, '5000', 'Test089 COGS',          'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_stock_acc,      v_client_id, v_company_id, '1300', 'Test089 Stock',         'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_tax_out_acc,    v_client_id, v_company_id, '2200', 'Test089 Output Tax',    'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_local_cash_acc, v_client_id, v_company_id, '1000', 'Test089 Local Cash',    'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_base_cash_acc,  v_client_id, v_company_id, '1001', 'Test089 Base Cash',     'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_sales_link FROM rim_account_link_types WHERE link_key = 'SALES_ACCOUNT';
  SELECT id INTO v_cos_link   FROM rim_account_link_types WHERE link_key = 'COST_OF_SALES_ACCOUNT';
  SELECT id INTO v_stock_link FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_sales_link, 'COMPANY'),
    (v_client_id, v_company_id, v_cos_link,   'COMPANY'),
    (v_client_id, v_company_id, v_stock_link, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_sales_link, NULL, v_sales_acc),
    (v_client_id, v_company_id, v_cos_link,   NULL, v_cos_acc),
    (v_client_id, v_company_id, v_stock_link, NULL, v_stock_acc)
  ON CONFLICT DO NOTHING;

  -- Quick Invoice Setup for the cashier only — supervisor deliberately has none.
  INSERT INTO ric_user_quick_invoice_setup (client_id, company_id, user_id, location_id, cash_customer_id, local_cash_account_id, base_cash_account_id, is_active, is_deleted)
  VALUES (v_client_id, v_company_id, v_cashier_id, v_loc_id, v_cash_customer_id, v_local_cash_acc, v_base_cash_acc, true, false)
  ON CONFLICT (client_id, company_id, user_id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece089', v_cashier_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'SI-001', 'Test089 Item', v_usd_ccy_id, 'NONE', v_cashier_id)
  ON CONFLICT (id) DO NOTHING;

  -- 10% output tax on the product's own tax group.
  SELECT tax_type_code INTO v_tax_type_code FROM rim_tax_types LIMIT 1;
  INSERT INTO rim_taxes (id, client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, calculation_type, gl_output_account_id, is_active, is_deleted, created_by)
  VALUES (v_tax_id, v_client_id, v_company_id, 'T089', 'Test089 Tax 10%', v_tax_type_code, 'SALES', 'PERCENTAGE', v_tax_out_acc, true, false, v_cashier_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_rates (client_id, company_id, tax_id, rate_label, rate, effective_from)
  VALUES (v_client_id, v_company_id, v_tax_id, 'STANDARD', 10, '2020-01-01')
  ON CONFLICT (client_id, company_id, tax_id, rate_label, effective_from) DO NOTHING;

  INSERT INTO rim_tax_groups (id, client_id, company_id, group_code, group_name, applicable_on, is_active, is_deleted)
  VALUES (v_tax_group_id, v_client_id, v_company_id, 'TG089', 'Test089 Group', 'SALES', true, false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_tax_group_members (client_id, company_id, tax_group_id, tax_id, sequence_no)
  VALUES (v_client_id, v_company_id, v_tax_group_id, v_tax_id, 1)
  ON CONFLICT (client_id, company_id, tax_group_id, tax_id) DO NOTHING;

  -- Opening stock: 100 units @ cost 10.
  PERFORM fn_post_stock_movement(
    v_client_id, v_company_id, v_loc_id, v_product_id,
    '2026-01-01'::date, 'OPENING_STOCK', 100,
    10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-089-001', '2026-01-01'::date, v_cashier_id
  );

  -- Sales Quotation fixture (APPROVED, real customer) for the
  -- AGAINST_QUOTATION whole-document tests.
  INSERT INTO rih_sales_quotations (
    client_id, company_id, location_id, quotation_no, quotation_date, status,
    customer_type, customer_id, party_name, quotation_currency_id, rate_to_base, rate_to_local,
    valid_until_date, gross_amount, discount_amount, tax_amount, grand_total, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, v_loc_id, 'SQ/T89L/2026/00001', '2026-07-01', 'APPROVED',
    'CUSTOMER', v_credit_customer_id, 'Test089 Credit Customer', v_usd_ccy_id, 1, 1,
    '2026-12-31', 100, 0, 10, 110, v_cashier_id, v_cashier_id
  ) ON CONFLICT DO NOTHING;

  INSERT INTO rid_sales_quotation_lines (
    client_id, company_id, quotation_no, quotation_date, serial_no,
    product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate,
    gross_amount, discount_percent, discount_amount, tax_group_id, tax_amount, final_amount,
    base_amount, local_amount, charge_amount, landed_amount, converted_qty, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, 'SQ/T89L/2026/00001', '2026-07-01', 1,
    v_product_id, v_uom_id, 1, 10, 0, 10, 10,
    100, 0, 0, v_tax_group_id, 10, 110,
    110, 110, 20, 130, 0, v_cashier_id, v_cashier_id
  ) ON CONFLICT DO NOTHING;

  -- Freight charge master (ADD, taxable, reuses the same 10% tax/account
  -- as the product line for a tractable fixture) + the quotation's own
  -- charge row, for the AGAINST_QUOTATION carry-forward test.
  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES (v_freight_acc, v_client_id, v_company_id, '4100', 'Test089 Freight Income', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_additional_charges (id, client_id, company_id, charge_code, charge_name, applicable_on, is_taxable, tax_id, nature, amount_or_percent, default_amount, default_gl_account_id, is_active, is_deleted, created_by)
  VALUES (v_charge_id, v_client_id, v_company_id, 'FREIGHT089', 'Test089 Freight', 'SALES', true, v_tax_id, 'ADD', 'AMOUNT', 20, v_freight_acc, true, false, v_cashier_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rid_sales_quotation_charges (
    client_id, company_id, quotation_no, quotation_date, serial_no,
    charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
    amount_or_percent, amount, tax_amount, allocation_factor, created_by, updated_by
  ) VALUES (
    v_client_id, v_company_id, 'SQ/T89L/2026/00001', '2026-07-01', 1,
    v_charge_id, 'Test089 Freight', true, v_tax_id, 'ADD', v_freight_acc,
    'AMOUNT', 20, 2, 0.2, v_cashier_id, v_cashier_id
  ) ON CONFLICT DO NOTHING;

  PERFORM set_config('pgtap.v_freight_acc', v_freight_acc::text, false);
  PERFORM set_config('pgtap.v_charge_id', v_charge_id::text, false);
  PERFORM set_config('pgtap.v_tax_id', v_tax_id::text, false);
  PERFORM set_config('pgtap.v_client', v_client_id::text, false);
  PERFORM set_config('pgtap.v_company', v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc', v_loc_id::text, false);
  PERFORM set_config('pgtap.v_cashier', v_cashier_id::text, false);
  PERFORM set_config('pgtap.v_supervisor', v_supervisor_id::text, false);
  PERFORM set_config('pgtap.v_cash_customer', v_cash_customer_id::text, false);
  PERFORM set_config('pgtap.v_credit_customer', v_credit_customer_id::text, false);
  PERFORM set_config('pgtap.v_product', v_product_id::text, false);
  PERFORM set_config('pgtap.v_uom', v_uom_id::text, false);
  PERFORM set_config('pgtap.v_tax_group', v_tax_group_id::text, false);
  PERFORM set_config('pgtap.v_usd', v_usd_ccy_id::text, false);
END $$ LANGUAGE plpgsql;


-- ══════════════════════════════════════════════════════════════════════════
-- 1. DIRECT CASH sale — full happy path: dispatch immediate + collect
--    immediate. Verifies stock, SI voucher balance, COS voucher, and
--    settled Receipt Voucher all in one flow.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_inv_no text;
  v_stock_before numeric;
BEGIN
  SELECT current_stock INTO v_stock_before FROM rim_product_location
  WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
    AND location_id = current_setting('pgtap.v_loc')::uuid AND product_id = current_setting('pgtap.v_product')::uuid;

  v_inv_no := fn_save_sales_invoice(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'invoice_no', NULL, 'invoice_date', '2026-07-02',
      'invoice_mode', 'DIRECT', 'sale_type', 'CASH', 'party_name', 'Walk-in Test',
      'invoice_currency_id', current_setting('pgtap.v_usd'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 500, 'discount_amount', 0, 'tax_amount', 50, 'grand_total', 550,
      'collected_amount_local', 550
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product'), 'uom_id', current_setting('pgtap.v_uom'),
      'uom_conversion_factor', 1, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 100,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 500, 'discount_percent', 0, 'discount_amount', 0,
      'tax_group_id', current_setting('pgtap.v_tax_group'), 'tax_amount', 50, 'final_amount', 550,
      'base_amount', 550, 'local_amount', 550
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_cashier')::uuid
  );
  PERFORM set_config('pgtap.v_inv1', v_inv_no, false);
  PERFORM set_config('pgtap.v_stock_before', v_stock_before::text, false);

  PERFORM fn_approve_sales_invoice(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_inv_no, '2026-07-02'::date, current_setting('pgtap.v_cashier')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv1')) = 'APPROVED',
  'ok 1 — DIRECT CASH invoice approves successfully'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT current_stock FROM rim_product_location
   WHERE client_id = current_setting('pgtap.v_client')::uuid AND company_id = current_setting('pgtap.v_company')::uuid
     AND location_id = current_setting('pgtap.v_loc')::uuid AND product_id = current_setting('pgtap.v_product')::uuid)
  = current_setting('pgtap.v_stock_before')::numeric - 5,
  'ok 2 — Stock dispatched immediately (qty 5 deducted)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sales_voucher_no IS NOT NULL AND cos_voucher_no IS NOT NULL AND local_receipt_voucher_no IS NOT NULL
   FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv1')),
  'ok 3 — SI, COS, and local Receipt vouchers all posted'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT abs(sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END)) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT sales_voucher_no FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv1'))),
  'ok 4 — SI voucher is balanced (DR = CR on base_amount)'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT abs(sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END)) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT cos_voucher_no FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv1'))),
  'ok 5 — COS voucher is balanced'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT coalesce(settled_amount, 0) >= 549.99
   FROM rid_finance_lines
   WHERE trans_no = (SELECT sales_voucher_no FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv1'))
     AND account_id = current_setting('pgtap.v_cash_customer')::uuid),
  'ok 6 — Cash Customer receivable fully settled by the auto-generated Receipt Voucher'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 2. Quick Invoice Setup lock — cashier has now made an invoice, so their
--    setup row can no longer be edited.
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ UPDATE ric_user_quick_invoice_setup SET location_id = %L WHERE client_id = %L::uuid AND company_id = %L::uuid AND user_id = %L::uuid $$,
    current_setting('pgtap.v_loc'), current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_cashier')),
  'QUICK_INVOICE_SETUP_LOCKED',
  'ok 7 — Quick Invoice Setup is locked once the user has made an invoice'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 3. DIRECT CREDIT sale — discount within the cashier's own 5% cap.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_inv_no text;
BEGIN
  v_inv_no := fn_save_sales_invoice(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'invoice_no', NULL, 'invoice_date', '2026-07-02',
      'invoice_mode', 'DIRECT', 'sale_type', 'CREDIT', 'customer_id', current_setting('pgtap.v_credit_customer'),
      'invoice_currency_id', current_setting('pgtap.v_usd'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 200, 'discount_amount', 6, 'tax_amount', 19.4, 'grand_total', 213.4
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product'), 'uom_id', current_setting('pgtap.v_uom'),
      'uom_conversion_factor', 1, 'qty_pack', 2, 'qty_loose', 0, 'base_qty', 2, 'rate', 100,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 200, 'discount_percent', 3, 'discount_amount', 6,
      'tax_group_id', current_setting('pgtap.v_tax_group'), 'tax_amount', 19.4, 'final_amount', 213.4,
      'base_amount', 213.4, 'local_amount', 213.4
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_cashier')::uuid
  );
  PERFORM set_config('pgtap.v_inv3', v_inv_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT discount_given_by FROM rid_sales_invoice_lines WHERE invoice_no = current_setting('pgtap.v_inv3') AND serial_no = 1)
  = current_setting('pgtap.v_cashier')::uuid,
  'ok 8 — In-cap discount is attributed to the cashier themself'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 4. Discount exceeding the cashier's cap, no override — blocked.
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_invoice(
    jsonb_build_object('client_id', %L::uuid, 'company_id', %L::uuid, 'location_id', %L::uuid,
      'invoice_no', NULL, 'invoice_date', '2026-07-02', 'invoice_mode', 'DIRECT', 'sale_type', 'CREDIT',
      'customer_id', %L::uuid, 'invoice_currency_id', %L::uuid, 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 100, 'discount_amount', 15, 'tax_amount', 8.5, 'grand_total', 93.5),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', %L::uuid, 'uom_id', %L::uuid,
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 100,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 100, 'discount_percent', 15, 'discount_amount', 15,
      'tax_group_id', %L::uuid, 'tax_amount', 8.5, 'final_amount', 93.5, 'base_amount', 93.5, 'local_amount', 93.5)),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
    current_setting('pgtap.v_credit_customer'), current_setting('pgtap.v_usd'),
    current_setting('pgtap.v_product'), current_setting('pgtap.v_uom'), current_setting('pgtap.v_tax_group'),
    current_setting('pgtap.v_cashier')),
  'DISCOUNT_OVERRIDE_REQUIRED',
  'ok 9 — Discount beyond the cashier''s own cap is blocked without a supervisor override'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 5. fn_verify_discount_override — wrong password fails; correct
--    credentials + within the supervisor's own cap succeeds; the same
--    over-cap line then saves successfully with discount_given_by set.
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_verify_discount_override(%L::uuid, %L::uuid, 'test089_super', 'wrongpassword', 15) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company')),
  'INVALID_CREDENTIALS',
  'ok 10 — fn_verify_discount_override rejects a wrong password'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT user_id FROM fn_verify_discount_override(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid, 'test089_super', 'superpw', 15))
  = current_setting('pgtap.v_supervisor')::uuid,
  'ok 11 — fn_verify_discount_override accepts correct credentials within the supervisor''s own cap'
);

DO $$
DECLARE v_inv_no text;
BEGIN
  v_inv_no := fn_save_sales_invoice(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'invoice_no', NULL, 'invoice_date', '2026-07-02',
      'invoice_mode', 'DIRECT', 'sale_type', 'CREDIT', 'customer_id', current_setting('pgtap.v_credit_customer'),
      'invoice_currency_id', current_setting('pgtap.v_usd'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 100, 'discount_amount', 15, 'tax_amount', 8.5, 'grand_total', 93.5),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product'), 'uom_id', current_setting('pgtap.v_uom'),
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 100,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 100, 'discount_percent', 15, 'discount_amount', 15, 'discount_given_by', current_setting('pgtap.v_supervisor'),
      'tax_group_id', current_setting('pgtap.v_tax_group'), 'tax_amount', 8.5, 'final_amount', 93.5, 'base_amount', 93.5, 'local_amount', 93.5)),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_cashier')::uuid
  );
  PERFORM set_config('pgtap.v_inv5', v_inv_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT discount_given_by FROM rid_sales_invoice_lines WHERE invoice_no = current_setting('pgtap.v_inv5') AND serial_no = 1)
  = current_setting('pgtap.v_supervisor')::uuid,
  'ok 12 — With a verified supervisor override, the over-cap discount saves and is attributed to the supervisor'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 6. Cancel — DRAFT can be cancelled; once APPROVED, cannot.
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv5')) = 'DRAFT',
  'ok 13 — Invoice 5 is still DRAFT (never approved)'
);

DO $$ BEGIN
  PERFORM fn_cancel_sales_invoice(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    current_setting('pgtap.v_inv5'), '2026-07-02'::date, 'Test cancellation', current_setting('pgtap.v_cashier')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv5')) = 'CANCELLED',
  'ok 14 — DRAFT invoice cancels successfully'
);

-- throws_ok's message argument requires an EXACT match (see
-- feedback_pgtap_date_design.md) — the real message is
-- "Sales Invoice <no> is APPROVED and cannot be cancelled — ...", which
-- embeds the dynamically-generated invoice_no, so throws_like's %-wildcard
-- match is the right tool here rather than reconstructing the exact string.
INSERT INTO test_results (result) SELECT throws_like(
  format($$ SELECT fn_cancel_sales_invoice(%L::uuid, %L::uuid, %L, '2026-07-02'::date, 'test', %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_inv1'), current_setting('pgtap.v_cashier')),
  '%cannot be cancelled%',
  'ok 15 — An already-APPROVED invoice cannot be cancelled (Immutability — future Sales Return''s job)'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 7. AGAINST_QUOTATION — whole-document consumption; the same quotation
--    cannot be invoiced twice.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_inv_no text;
BEGIN
  v_inv_no := fn_save_sales_invoice(
    jsonb_build_object('client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'invoice_no', NULL, 'invoice_date', '2026-07-03',
      'invoice_mode', 'AGAINST_QUOTATION', 'sale_type', 'CREDIT',
      'quotation_no', 'SQ/T89L/2026/00001', 'quotation_date', '2026-07-01',
      'invoice_currency_id', current_setting('pgtap.v_usd'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 100, 'discount_amount', 0, 'tax_amount', 10, 'grand_total', 110),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_cashier')::uuid
  );
  PERFORM set_config('pgtap.v_inv7', v_inv_no, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT base_qty FROM rid_sales_invoice_lines WHERE invoice_no = current_setting('pgtap.v_inv7') AND serial_no = 1) = 10,
  'ok 16 — AGAINST_QUOTATION mode copies the source quotation line verbatim (qty 10, ignoring the empty p_lines payload)'
);

INSERT INTO test_results (result) SELECT throws_ok(
  format($$ SELECT fn_save_sales_invoice(
    jsonb_build_object('client_id', %L::uuid, 'company_id', %L::uuid, 'location_id', %L::uuid,
      'invoice_no', NULL, 'invoice_date', '2026-07-03', 'invoice_mode', 'AGAINST_QUOTATION', 'sale_type', 'CREDIT',
      'quotation_no', 'SQ/T89L/2026/00001', 'quotation_date', '2026-07-01',
      'invoice_currency_id', %L::uuid, 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 100, 'discount_amount', 0, 'tax_amount', 10, 'grand_total', 110),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, %L::uuid) $$,
    current_setting('pgtap.v_client'), current_setting('pgtap.v_company'), current_setting('pgtap.v_loc'),
    current_setting('pgtap.v_usd'), current_setting('pgtap.v_cashier')),
  'QUOTATION_ALREADY_INVOICED',
  'ok 17 — The same Sales Quotation cannot be invoiced a second time'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 8. DIRECT sale with a Freight charge (ADD, taxable) — the charge posts
--    its own GL account, and the SI voucher still balances with a charge
--    line included.
-- ══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_inv_no text;
BEGIN
  v_inv_no := fn_save_sales_invoice(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client'), 'company_id', current_setting('pgtap.v_company'),
      'location_id', current_setting('pgtap.v_loc'), 'invoice_no', NULL, 'invoice_date', '2026-07-04',
      'invoice_mode', 'DIRECT', 'sale_type', 'CREDIT', 'customer_id', current_setting('pgtap.v_credit_customer'),
      'invoice_currency_id', current_setting('pgtap.v_usd'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 100, 'discount_amount', 0, 'charges_amount', 20, 'tax_amount', 12, 'grand_total', 132
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product'), 'uom_id', current_setting('pgtap.v_uom'),
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 100,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 100, 'discount_percent', 0, 'discount_amount', 0,
      'tax_group_id', current_setting('pgtap.v_tax_group'), 'tax_amount', 10, 'final_amount', 110,
      'base_amount', 110, 'local_amount', 110, 'charge_amount', 20, 'landed_amount', 130
    )),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'charge_id', current_setting('pgtap.v_charge_id'), 'charge_name', 'Test089 Freight',
      'is_taxable', true, 'tax_id', current_setting('pgtap.v_tax_id'), 'nature', 'ADD',
      'gl_account_id', current_setting('pgtap.v_freight_acc'), 'amount_or_percent', 'AMOUNT',
      'amount', 20, 'tax_amount', 2, 'allocation_factor', 0.2
    )),
    '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_cashier')::uuid
  );
  PERFORM set_config('pgtap.v_inv8', v_inv_no, false);

  PERFORM fn_approve_sales_invoice(
    current_setting('pgtap.v_client')::uuid, current_setting('pgtap.v_company')::uuid,
    v_inv_no, '2026-07-04'::date, current_setting('pgtap.v_cashier')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT abs(sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END)) < 0.01
   FROM rid_finance_lines WHERE trans_no = (SELECT sales_voucher_no FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv8'))),
  'ok 18 — SI voucher still balances with a charge line included'
);

INSERT INTO test_results (result) SELECT ok(
  (SELECT sum(base_amount) FROM rid_finance_lines
   WHERE trans_no = (SELECT sales_voucher_no FROM rih_sales_invoices WHERE invoice_no = current_setting('pgtap.v_inv8'))
     AND account_id = current_setting('pgtap.v_freight_acc')::uuid AND trans_nature = 'CR') = 20,
  'ok 19 — Freight charge posts its own CR line to its own gl_account_id'
);


-- ══════════════════════════════════════════════════════════════════════════
-- 9. AGAINST_QUOTATION carries the source quotation's own charges forward
--    verbatim — the client's own (empty) p_charges payload is ignored.
-- ══════════════════════════════════════════════════════════════════════════
INSERT INTO test_results (result) SELECT ok(
  (SELECT charge_id FROM rid_sales_invoice_charges WHERE invoice_no = current_setting('pgtap.v_inv7') AND serial_no = 1)
  = current_setting('pgtap.v_charge_id')::uuid
  AND (SELECT amount FROM rid_sales_invoice_charges WHERE invoice_no = current_setting('pgtap.v_inv7') AND serial_no = 1) = 20,
  'ok 20 — AGAINST_QUOTATION mode copies the source quotation''s own charge verbatim'
);


-- Final result dump.
SELECT n, result FROM test_results ORDER BY n;

ROLLBACK;
