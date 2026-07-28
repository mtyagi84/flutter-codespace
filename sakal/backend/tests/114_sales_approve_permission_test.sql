-- ============================================================
-- 114_sales_approve_permission_test.sql — pgTAP tests for migration 114
-- (fn_check_approve_permission wired into all 6 Sales approve functions
-- + 2 cancel functions: Quotation, Order+cancel, Invoice+cancel, Return,
-- Delivery, Cash Receipt)
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run the ENTIRE file (Ctrl+A then Run).
--   3. Look for any row NOT starting with "ok " in the final grid.
--
-- v_user_ok holds approve_allowed=true for every SL-* feature_code used
-- here, but is DELIBERATELY never granted FN-PRV (Payment/Receipt
-- Voucher) — proving the composition-guard fix in this same migration:
-- Sales Invoice/Sales Return/Cash Receipt each compose a CRV/CPV
-- settlement voucher directly whenever cash actually moves, and their
-- approval must succeed WITHOUT the approver needing unrelated FN-PRV
-- permission (see this migration's own header comment, and
-- feedback_shared_engine_bugs_fix_once's 4th/5th/6th incidents for the
-- three prior occurrences of this exact bug class).
-- ============================================================

BEGIN;

CREATE TEMP TABLE test_results (n SERIAL PRIMARY KEY, result TEXT);

SELECT plan(25);

-- ════════════════════════════════════════════════════════════════════
-- Fixture setup — one company, SIMPLE, DEFERRED stock dispatch (so a
-- Sales Delivery has something genuinely pending to deliver) + immediate
-- cash collection (the two are independent company-wide flags), zero tax
-- throughout (permission wiring is what's under test, not tax math).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_client_id        uuid := '00000000-0000-0000-0114-000000000001';
  v_company_id       uuid := '00000000-0000-0000-0114-000000000002';
  v_loc_id           uuid := '00000000-0000-0000-0114-000000000003';
  v_user_ok          uuid := '00000000-0000-0000-0114-000000000004';
  v_user_denied      uuid := '00000000-0000-0000-0114-000000000005';
  v_customer_grp     uuid := '00000000-0000-0000-0114-000000000006';
  v_credit_customer  uuid := '00000000-0000-0000-0114-000000000007';
  v_cash_customer    uuid := '00000000-0000-0000-0114-000000000008';
  v_sales_acc        uuid := '00000000-0000-0000-0114-000000000009';
  v_cos_acc          uuid := '00000000-0000-0000-0114-00000000000a';
  v_stock_acc        uuid := '00000000-0000-0000-0114-00000000000b';
  v_returns_acc      uuid := '00000000-0000-0000-0114-00000000000c';
  v_local_cash_acc   uuid := '00000000-0000-0000-0114-00000000000d';
  v_base_cash_acc    uuid := '00000000-0000-0000-0114-00000000000e';
  v_product_id       uuid := '00000000-0000-0000-0114-00000000000f';
  v_uom_id           uuid := '00000000-0000-0000-0114-000000000010';
  v_fy_id            uuid := '00000000-0000-0000-0114-000000000011';
  v_module_id        uuid := '00000000-0000-0000-0114-000000000012';
  v_usd_ccy_id       uuid;
  v_unit_type_id     uuid;
  v_sales_link       uuid; v_cos_link uuid; v_stock_link uuid; v_returns_link uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST114', true, false, now()) ON CONFLICT (id) DO NOTHING;

  -- quick_invoice_dispatch_stock = false (DEFERRED): fn_save_sales_delivery
  -- hard-blocks (INVOICE_NOT_ELIGIBLE_FOR_DELIVERY) against an invoice that
  -- already dispatched stock at approve time, so the SL-DEL test below
  -- needs a genuinely-pending invoice. quick_invoice_collect_cash stays
  -- true — cash collection is a separate, independent snapshot flag, and
  -- is what the SL-INV/SL-RET CRV/CPV composition-guard tests actually
  -- depend on, not stock dispatch.
  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency,
    inter_location_model, quick_invoice_dispatch_stock, quick_invoice_collect_cash, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST114 CO', 'USD', 'USD', 'SIMPLE', false, true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test114 Loc', 'T114', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES
    (v_user_ok,     v_client_id, v_company_id, 'test114_ok',  'Test114 Approver', crypt('userpw', gen_salt('bf')), true, false, now()),
    (v_user_denied, v_client_id, v_company_id, 'test114_den', 'Test114 Clerk',    crypt('userpw', gen_salt('bf')), true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- can_override_price=true + max_discount_percent=100: no Price Master
  -- fixture needed — every line below resolves via MANUAL_OVERRIDE, same
  -- shortcut Sales Order's own test file uses.
  INSERT INTO ric_user_sales_controls (client_id, company_id, user_id, can_override_price, can_give_discount, max_discount_percent, can_view_cost_price)
  VALUES (v_client_id, v_company_id, v_user_ok, true, true, 100, true)
  ON CONFLICT (client_id, company_id, user_id) DO NOTHING;

  SELECT id INTO v_usd_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES (v_customer_grp, v_client_id, v_company_id, '3000', 'Sundry Debtors 114', 'Customer', 'OHADA', false, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, parent_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_credit_customer, v_client_id, v_company_id, v_customer_grp, '3000001', 'Test114 Credit Customer', 'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_cash_customer,   v_client_id, v_company_id, v_customer_grp, '3000002', 'Test114 Cash Customer',   'Customer', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, account_currency_id, is_active, is_deleted, created_at)
  VALUES
    (v_sales_acc,      v_client_id, v_company_id, '4000', 'Test114 Sales',         'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_cos_acc,        v_client_id, v_company_id, '5000', 'Test114 COGS',          'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_stock_acc,      v_client_id, v_company_id, '1300', 'Test114 Stock',         'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_returns_acc,    v_client_id, v_company_id, '4900', 'Test114 Sales Returns', 'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_local_cash_acc, v_client_id, v_company_id, '1000', 'Test114 Local Cash',    'General', 'OHADA', true, v_usd_ccy_id, true, false, now()),
    (v_base_cash_acc,  v_client_id, v_company_id, '1001', 'Test114 Base Cash',     'General', 'OHADA', true, v_usd_ccy_id, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  SELECT id INTO v_sales_link   FROM rim_account_link_types WHERE link_key = 'SALES_ACCOUNT';
  SELECT id INTO v_cos_link     FROM rim_account_link_types WHERE link_key = 'COST_OF_SALES_ACCOUNT';
  SELECT id INTO v_stock_link   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_returns_link FROM rim_account_link_types WHERE link_key = 'SALES_RETURNS_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_sales_link, 'COMPANY'),
    (v_client_id, v_company_id, v_cos_link, 'COMPANY'),
    (v_client_id, v_company_id, v_stock_link, 'COMPANY'),
    (v_client_id, v_company_id, v_returns_link, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_sales_link, NULL, v_sales_acc),
    (v_client_id, v_company_id, v_cos_link, NULL, v_cos_acc),
    (v_client_id, v_company_id, v_stock_link, NULL, v_stock_acc),
    (v_client_id, v_company_id, v_returns_link, NULL, v_returns_acc)
  ON CONFLICT DO NOTHING;

  -- Quick Invoice Setup for v_user_ok — needed for both CASH invoice
  -- collection AND Cash Receipt's own cash-drawer resolution.
  INSERT INTO ric_user_quick_invoice_setup (client_id, company_id, user_id, location_id, cash_customer_id, local_cash_account_id, base_cash_account_id, is_active, is_deleted)
  VALUES (v_client_id, v_company_id, v_user_ok, v_loc_id, v_cash_customer, v_local_cash_acc, v_base_cash_acc, true, false)
  ON CONFLICT (client_id, company_id, user_id) DO NOTHING;

  SELECT id INTO v_unit_type_id FROM rim_common_master_types WHERE type_key = 'UNIT';
  INSERT INTO rim_common_masters (id, client_id, company_id, type_id, description, created_by)
  VALUES (v_uom_id, v_client_id, v_company_id, v_unit_type_id, 'Piece114', v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, tracking_type, created_by)
  VALUES (v_product_id, v_client_id, v_company_id, 'SL114-001', 'Test114 Item', v_usd_ccy_id, 'NONE', v_user_ok)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST114', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- Opening stock: 100 units @ cost 10.
  PERFORM fn_post_stock_movement(
    v_client_id, v_company_id, v_loc_id, v_product_id,
    '2026-01-01'::date, 'OPENING_STOCK', 100, 10, 10, NULL, NULL, NULL,
    'OPENING_BALANCE', 'OB-114-001', '2026-01-01'::date, v_user_ok
  );

  -- Menu-permission fixture. v_user_ok gets approve_allowed=true on every
  -- SL-* feature_code used in this file, but DELIBERATELY never gets
  -- FN-PRV — see this file's own header comment for why.
  INSERT INTO ric_system_modules (id, client_id, company_id, module_code, module_name)
  VALUES (v_module_id, v_client_id, v_company_id, 'SL', 'Sales')
  ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

  INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_module_id, 'SL-QUO', 'Sales Quotation', '/sales/quotations', true),
    (v_client_id, v_company_id, v_module_id, 'SL-SO',  'Sales Order',     '/sales/orders',      true),
    (v_client_id, v_company_id, v_module_id, 'SL-INV', 'Sales Invoice',   '/sales/invoices',    true),
    (v_client_id, v_company_id, v_module_id, 'SL-RET', 'Sales Return',    '/sales/returns',     true),
    (v_client_id, v_company_id, v_module_id, 'SL-DEL', 'Sales Delivery',  '/sales/deliveries',  true),
    (v_client_id, v_company_id, v_module_id, 'SL-RCP', 'Cash Receipt',    '/sales/cash-receipts', true)
  ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;

  INSERT INTO ric_user_menus (client_id, company_id, user_id, module_id, feature_code, view_allowed, edit_allowed, approve_allowed)
  VALUES
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'SL-QUO', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'SL-SO',  true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'SL-INV', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'SL-RET', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'SL-DEL', true, true, true),
    (v_client_id, v_company_id, v_user_ok, v_module_id, 'SL-RCP', true, true, true)
  ON CONFLICT (client_id, company_id, user_id, feature_code) DO NOTHING;

  PERFORM set_config('pgtap.v_client_114',   v_client_id::text, false);
  PERFORM set_config('pgtap.v_company_114',  v_company_id::text, false);
  PERFORM set_config('pgtap.v_loc_114',      v_loc_id::text, false);
  PERFORM set_config('pgtap.v_user_ok_114',       v_user_ok::text, false);
  PERFORM set_config('pgtap.v_user_denied_114',   v_user_denied::text, false);
  PERFORM set_config('pgtap.v_credit_customer_114', v_credit_customer::text, false);
  PERFORM set_config('pgtap.v_product_114', v_product_id::text, false);
  PERFORM set_config('pgtap.v_uom_114',     v_uom_id::text, false);
  PERFORM set_config('pgtap.v_usd_114',     v_usd_ccy_id::text, false);
END $$ LANGUAGE plpgsql;

-- ════════════════════════════════════════════════════════════════════
-- SALES QUOTATION (SL-QUO)
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_quo_no text;
BEGIN
  v_quo_no := fn_save_sales_quotation(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_114'), 'company_id', current_setting('pgtap.v_company_114'),
      'location_id', current_setting('pgtap.v_loc_114'),
      'quotation_no', NULL, 'quotation_date', '2026-06-01', 'valid_until_date', '2026-06-30',
      'customer_type', 'CUSTOMER', 'customer_id', current_setting('pgtap.v_credit_customer_114'),
      'party_name', 'Test114 Credit Customer',
      'quotation_currency_id', current_setting('pgtap.v_usd_114'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 200, 'discount_amount', 0, 'charges_amount', 0, 'tax_amount', 0, 'grand_total', 200
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_114'),
      'uom_id', current_setting('pgtap.v_uom_114'), 'uom_conversion_factor', 1,
      'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 20,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 200, 'discount_percent', 0, 'discount_amount', 0, 'tax_amount', 0,
      'final_amount', 200, 'base_amount', 200, 'local_amount', 200, 'charge_amount', 0, 'landed_amount', 200
    )),
    '[]'::jsonb,
    current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_quo_no_114', v_quo_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_approve_sales_quotation(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_quo_no_114'), '2026-06-01'::date, current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t1_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t1_114')::boolean, 'ok 1 — fn_approve_sales_quotation: a denied user cannot approve (SL-QUO mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND quotation_no = current_setting('pgtap.v_quo_no_114')) = 'DRAFT',
  'ok 2 — the rejected quotation stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  PERFORM fn_approve_sales_quotation(
    current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
    current_setting('pgtap.v_quo_no_114'), '2026-06-01'::date, current_setting('pgtap.v_user_ok_114')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_quotations WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND quotation_no = current_setting('pgtap.v_quo_no_114')) = 'APPROVED',
  'ok 3 — fn_approve_sales_quotation: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- SALES ORDER (SL-SO) — DIRECT mode, own denied/approved pair.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_order_no text;
BEGIN
  v_order_no := fn_save_sales_order(
    jsonb_build_object('client_id', current_setting('pgtap.v_client_114'), 'company_id', current_setting('pgtap.v_company_114'),
      'location_id', current_setting('pgtap.v_loc_114'), 'order_no', NULL, 'order_date', '2026-06-02',
      'order_mode', 'DIRECT', 'customer_id', current_setting('pgtap.v_credit_customer_114'),
      'order_currency_id', current_setting('pgtap.v_usd_114'), 'rate_to_base', 1, 'rate_to_local', 1),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_114'),
      'uom_id', current_setting('pgtap.v_uom_114'), 'uom_conversion_factor', 1, 'qty_pack', 5, 'base_qty', 5,
      'rate', 20, 'price_override_reason', 'No Price Master in test fixture')),
    '[]'::jsonb, current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_order_no_114', v_order_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_approve_sales_order(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_order_no_114'), '2026-06-02'::date, current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t4_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t4_114')::boolean, 'ok 4 — fn_approve_sales_order: a denied user cannot approve (SL-SO mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_orders WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND order_no = current_setting('pgtap.v_order_no_114')) = 'DRAFT',
  'ok 5 — the rejected order stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  PERFORM fn_approve_sales_order(
    current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
    current_setting('pgtap.v_order_no_114'), '2026-06-02'::date, current_setting('pgtap.v_user_ok_114')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_orders WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND order_no = current_setting('pgtap.v_order_no_114')) = 'APPROVED',
  'ok 6 — fn_approve_sales_order: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- SALES ORDER CANCEL (SL-SO, same feature_code as approve) — a second,
-- separate DRAFT order.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_order2_no text;
BEGIN
  v_order2_no := fn_save_sales_order(
    jsonb_build_object('client_id', current_setting('pgtap.v_client_114'), 'company_id', current_setting('pgtap.v_company_114'),
      'location_id', current_setting('pgtap.v_loc_114'), 'order_no', NULL, 'order_date', '2026-06-02',
      'order_mode', 'DIRECT', 'customer_id', current_setting('pgtap.v_credit_customer_114'),
      'order_currency_id', current_setting('pgtap.v_usd_114'), 'rate_to_base', 1, 'rate_to_local', 1),
    jsonb_build_array(jsonb_build_object('serial_no', 1, 'product_id', current_setting('pgtap.v_product_114'),
      'uom_id', current_setting('pgtap.v_uom_114'), 'uom_conversion_factor', 1, 'qty_pack', 1, 'base_qty', 1,
      'rate', 20, 'price_override_reason', 'No Price Master in test fixture')),
    '[]'::jsonb, current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_order2_no_114', v_order2_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_cancel_sales_order(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_order2_no_114'), '2026-06-02'::date, 'Test114 cancel reason', current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t7_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t7_114')::boolean, 'ok 7 — fn_cancel_sales_order: a denied user cannot cancel (SL-SO mapping enforced)');

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  PERFORM fn_cancel_sales_order(
    current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
    current_setting('pgtap.v_order2_no_114'), '2026-06-02'::date, 'Test114 cancel reason', current_setting('pgtap.v_user_ok_114')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_orders WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND order_no = current_setting('pgtap.v_order2_no_114')) = 'CANCELLED',
  'ok 8 — fn_cancel_sales_order: an approved user CAN cancel it'
);

-- ════════════════════════════════════════════════════════════════════
-- SALES INVOICE (SL-INV) — CASH DIRECT, immediate cash collection
-- (stock dispatch stays DEFERRED, per the company-level fixture flag).
-- The "approved" test here is the CRV-composition guard's real payoff:
-- v_user_ok has NO FN-PRV, yet the internally composed CRV settlement
-- voucher must still post successfully.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_inv_no text;
BEGIN
  v_inv_no := fn_save_sales_invoice(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_114'), 'company_id', current_setting('pgtap.v_company_114'),
      'location_id', current_setting('pgtap.v_loc_114'), 'invoice_no', NULL, 'invoice_date', '2026-06-03',
      'invoice_mode', 'DIRECT', 'sale_type', 'CASH', 'party_name', 'Walk-in Test114',
      'invoice_currency_id', current_setting('pgtap.v_usd_114'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 100, 'discount_amount', 0, 'tax_amount', 0, 'grand_total', 100,
      'collected_amount_local', 100
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_114'), 'uom_id', current_setting('pgtap.v_uom_114'),
      'uom_conversion_factor', 1, 'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 20,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 100, 'discount_percent', 0, 'discount_amount', 0,
      'tax_amount', 0, 'final_amount', 100, 'base_amount', 100, 'local_amount', 100
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_inv_cash_114', v_inv_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_approve_sales_invoice(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_inv_cash_114'), '2026-06-03'::date, current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t9_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t9_114')::boolean, 'ok 9 — fn_approve_sales_invoice: a denied user cannot approve (SL-INV mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_invoices WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND invoice_no = current_setting('pgtap.v_inv_cash_114')) = 'DRAFT',
  'ok 10 — the rejected invoice stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  BEGIN
    PERFORM fn_approve_sales_invoice(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_inv_cash_114'), '2026-06-03'::date, current_setting('pgtap.v_user_ok_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t11_114', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t11_114')::boolean, 'ok 11 — fn_approve_sales_invoice: a user with SL-INV (but NO FN-PRV) can approve a CASH invoice without raising an error');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status = 'APPROVED' AND local_receipt_voucher_no IS NOT NULL
   FROM rih_sales_invoices WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND invoice_no = current_setting('pgtap.v_inv_cash_114')),
  'ok 12 — GUARD PAYOFF: the invoice is APPROVED and its composed CRV settlement voucher actually posted (local_receipt_voucher_no set) — proves the source_doc_type tagging + guard extension both work'
);

-- ════════════════════════════════════════════════════════════════════
-- SALES INVOICE CANCEL (SL-INV, same feature_code) — a second, separate
-- DRAFT invoice (CREDIT, no collection — cancel only allowed from DRAFT).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_inv2_no text;
BEGIN
  v_inv2_no := fn_save_sales_invoice(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_114'), 'company_id', current_setting('pgtap.v_company_114'),
      'location_id', current_setting('pgtap.v_loc_114'), 'invoice_no', NULL, 'invoice_date', '2026-06-03',
      'invoice_mode', 'DIRECT', 'sale_type', 'CREDIT', 'customer_id', current_setting('pgtap.v_credit_customer_114'),
      'invoice_currency_id', current_setting('pgtap.v_usd_114'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 20, 'discount_amount', 0, 'tax_amount', 0, 'grand_total', 20
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_114'), 'uom_id', current_setting('pgtap.v_uom_114'),
      'uom_conversion_factor', 1, 'qty_pack', 1, 'qty_loose', 0, 'base_qty', 1, 'rate', 20,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 20, 'discount_percent', 0, 'discount_amount', 0,
      'tax_amount', 0, 'final_amount', 20, 'base_amount', 20, 'local_amount', 20
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_inv2_114', v_inv2_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_cancel_sales_invoice(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_inv2_114'), '2026-06-03'::date, 'Test114 cancel reason', current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t13_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t13_114')::boolean, 'ok 13 — fn_cancel_sales_invoice: a denied user cannot cancel (SL-INV mapping enforced)');

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  PERFORM fn_cancel_sales_invoice(
    current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
    current_setting('pgtap.v_inv2_114'), '2026-06-03'::date, 'Test114 cancel reason', current_setting('pgtap.v_user_ok_114')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_invoices WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND invoice_no = current_setting('pgtap.v_inv2_114')) = 'CANCELLED',
  'ok 14 — fn_cancel_sales_invoice: an approved user CAN cancel it'
);

-- ════════════════════════════════════════════════════════════════════
-- SALES RETURN (SL-RET) — against the CASH invoice, with a cash refund.
-- The "approved" test is the CPV-composition guard's real payoff.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_ret_no text;
BEGIN
  v_ret_no := fn_save_sales_return(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_114')::uuid, 'company_id', current_setting('pgtap.v_company_114')::uuid,
      'return_no', NULL, 'return_date', '2026-06-04',
      'invoice_no', current_setting('pgtap.v_inv_cash_114'), 'invoice_date', '2026-06-03'::date,
      'taxable_amount', 40, 'tax_amount', 0, 'charges_amount', 0, 'return_total', 40,
      'refund_amount_local', 40, 'refund_amount_base', 0,
      'reason', 'Test114 defective', 'remarks', 'pgTAP 114 return'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product_114')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom_114')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 2, 'qty_loose', 0, 'base_qty', 2, 'rate', 20,
      'gross_amount', 40, 'tax_amount', 0, 'final_amount', 40
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_ret_no_114', v_ret_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_approve_sales_return(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_ret_no_114'), '2026-06-04'::date, current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t15_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t15_114')::boolean, 'ok 15 — fn_approve_sales_return: a denied user cannot approve (SL-RET mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND return_no = current_setting('pgtap.v_ret_no_114')) = 'DRAFT',
  'ok 16 — the rejected return stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  BEGIN
    PERFORM fn_approve_sales_return(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_ret_no_114'), '2026-06-04'::date, current_setting('pgtap.v_user_ok_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t17_114', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t17_114')::boolean, 'ok 17 — fn_approve_sales_return: a user with SL-RET (but NO FN-PRV) can approve a cash-refund return without raising an error');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status = 'APPROVED' AND refund_voucher_no_local IS NOT NULL
   FROM rih_sales_return_headers WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND return_no = current_setting('pgtap.v_ret_no_114')),
  'ok 18 — GUARD PAYOFF: the return is APPROVED and its composed CPV refund voucher actually posted (refund_voucher_no_local set)'
);

-- ════════════════════════════════════════════════════════════════════
-- SALES DELIVERY (SL-DEL) — against a fresh CREDIT invoice (approved by
-- v_user_ok, who already has SL-INV — no need to re-test that here).
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_inv3_no text;
  v_sales_voucher_no text;
  v_sales_voucher_date date;
BEGIN
  v_inv3_no := fn_save_sales_invoice(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_114'), 'company_id', current_setting('pgtap.v_company_114'),
      'location_id', current_setting('pgtap.v_loc_114'), 'invoice_no', NULL, 'invoice_date', '2026-06-05',
      'invoice_mode', 'DIRECT', 'sale_type', 'CREDIT', 'customer_id', current_setting('pgtap.v_credit_customer_114'),
      'invoice_currency_id', current_setting('pgtap.v_usd_114'), 'rate_to_base', 1, 'rate_to_local', 1,
      'gross_amount', 200, 'discount_amount', 0, 'tax_amount', 0, 'grand_total', 200
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'product_id', current_setting('pgtap.v_product_114'), 'uom_id', current_setting('pgtap.v_uom_114'),
      'uom_conversion_factor', 1, 'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 20,
      'price_override_reason', 'No Price Master in test fixture',
      'gross_amount', 200, 'discount_percent', 0, 'discount_amount', 0,
      'tax_amount', 0, 'final_amount', 200, 'base_amount', 200, 'local_amount', 200
    )),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  PERFORM fn_approve_sales_invoice(
    current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
    v_inv3_no, '2026-06-05'::date, current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_inv3_114', v_inv3_no, false);

  -- The pending bill Cash Receipt settles against is the invoice's own
  -- SLS voucher (sales_voucher_no/date) — fn_approve_sales_invoice posts
  -- under a SEPARATE voucher number (migration 090: "posts as SLS, not
  -- SI"), and the Customer DR line's inv_bill_no/inv_bill_date get
  -- corrected to that voucher's own trans_no/trans_date, never the
  -- invoice_no/invoice_date. Using invoice_no directly (as an earlier
  -- draft of this test did) makes fn_approve_cash_receipt's bill lookup
  -- find nothing and raise PENDING_BILL_NOT_FOUND.
  SELECT sales_voucher_no, sales_voucher_date INTO v_sales_voucher_no, v_sales_voucher_date
  FROM rih_sales_invoices
  WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND company_id = current_setting('pgtap.v_company_114')::uuid
    AND invoice_no = v_inv3_no;
  PERFORM set_config('pgtap.v_inv3_voucher_no_114', v_sales_voucher_no, false);
  PERFORM set_config('pgtap.v_inv3_voucher_date_114', v_sales_voucher_date::text, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_del_no text;
BEGIN
  v_del_no := fn_save_sales_delivery(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_114')::uuid, 'company_id', current_setting('pgtap.v_company_114')::uuid,
      'delivery_no', NULL, 'delivery_date', '2026-06-06',
      'invoice_no', current_setting('pgtap.v_inv3_114'), 'invoice_date', '2026-06-05'::date,
      'received_by_name', 'Test114 Receiver', 'remarks', 'pgTAP 114 delivery'
    ),
    jsonb_build_array(jsonb_build_object(
      'serial_no', 1, 'invoice_line_serial', 1, 'product_id', current_setting('pgtap.v_product_114')::uuid, 'barcode', null,
      'uom_id', current_setting('pgtap.v_uom_114')::uuid, 'uom_conversion_factor', 1,
      'qty_pack', 4, 'qty_loose', 0, 'base_qty', 4
    )),
    '[]'::jsonb, '[]'::jsonb, NULL,
    current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_del_no_114', v_del_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_approve_sales_delivery(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_del_no_114'), '2026-06-06'::date, current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t19_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t19_114')::boolean, 'ok 19 — fn_approve_sales_delivery: a denied user cannot approve (SL-DEL mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND delivery_no = current_setting('pgtap.v_del_no_114')) = 'DRAFT',
  'ok 20 — the rejected delivery stays DRAFT'
);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  PERFORM fn_approve_sales_delivery(
    current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
    current_setting('pgtap.v_del_no_114'), '2026-06-06'::date, current_setting('pgtap.v_user_ok_114')::uuid
  );
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_sales_delivery_headers WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND delivery_no = current_setting('pgtap.v_del_no_114')) = 'APPROVED',
  'ok 21 — fn_approve_sales_delivery: an approved user CAN approve it'
);

-- ════════════════════════════════════════════════════════════════════
-- CASH RECEIPT (SL-RCP) — applied against the SAME CREDIT invoice's own
-- pending bill (independent of delivery). The "approved" test is
-- ANOTHER CRV-composition guard payoff — Cash Receipt's own, distinct
-- from Sales Invoice's.
-- ════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_rcpt_no text;
BEGIN
  v_rcpt_no := fn_save_cash_receipt(
    jsonb_build_object(
      'client_id', current_setting('pgtap.v_client_114')::uuid, 'company_id', current_setting('pgtap.v_company_114')::uuid,
      'location_id', current_setting('pgtap.v_loc_114')::uuid,
      'receipt_no', NULL, 'receipt_date', '2026-06-07',
      'customer_id', current_setting('pgtap.v_credit_customer_114')::uuid,
      'local_amount', 100, 'base_amount', 0, 'remarks', 'pgTAP 114 receipt'
    ),
    jsonb_build_array(jsonb_build_object(
      'inv_bill_no', current_setting('pgtap.v_inv3_voucher_no_114'), 'inv_bill_date', current_setting('pgtap.v_inv3_voucher_date_114'),
      'bill_currency', 'USD', 'applied_amount_local', 100
    )),
    current_setting('pgtap.v_user_ok_114')::uuid
  );
  PERFORM set_config('pgtap.v_rcpt_no_114', v_rcpt_no, false);
END $$ LANGUAGE plpgsql;

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_denied_114'))::text, true);
  BEGIN
    PERFORM fn_approve_cash_receipt(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_rcpt_no_114'), '2026-06-07'::date, current_setting('pgtap.v_user_denied_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := (SQLERRM LIKE '%APPROVE_NOT_PERMITTED%');
  END;
  PERFORM set_config('pgtap.t22_114', v_error_raised::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t22_114')::boolean, 'ok 22 — fn_approve_cash_receipt: a denied user cannot approve (SL-RCP mapping enforced)');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND receipt_no = current_setting('pgtap.v_rcpt_no_114')) = 'DRAFT',
  'ok 23 — the rejected receipt stays DRAFT'
);

DO $$
DECLARE v_error_raised boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('user_id', current_setting('pgtap.v_user_ok_114'))::text, true);
  BEGIN
    PERFORM fn_approve_cash_receipt(
      current_setting('pgtap.v_client_114')::uuid, current_setting('pgtap.v_company_114')::uuid,
      current_setting('pgtap.v_rcpt_no_114'), '2026-06-07'::date, current_setting('pgtap.v_user_ok_114')::uuid
    );
  EXCEPTION WHEN OTHERS THEN v_error_raised := true;
  END;
  PERFORM set_config('pgtap.t24_114', (NOT v_error_raised)::text, false);
END $$ LANGUAGE plpgsql;

INSERT INTO test_results (result) SELECT ok(current_setting('pgtap.t24_114')::boolean, 'ok 24 — fn_approve_cash_receipt: a user with SL-RCP (but NO FN-PRV) can approve without raising an error');
INSERT INTO test_results (result) SELECT ok(
  (SELECT status = 'APPROVED' AND crv_local_voucher_no IS NOT NULL
   FROM rih_cash_receipt_headers WHERE client_id = current_setting('pgtap.v_client_114')::uuid AND receipt_no = current_setting('pgtap.v_rcpt_no_114')),
  'ok 25 — GUARD PAYOFF: the receipt is APPROVED and its composed CRV settlement voucher actually posted (crv_local_voucher_no set)'
);

-- finish() runs first (registers pgTAP's own pass/fail bookkeeping) but
-- its own summary-only output is deliberately NOT the last statement —
-- Supabase's SQL editor only renders the LAST statement's result grid,
-- and finish() alone only shows a summary notice ("Looks like you failed
-- N tests of M"), not which specific assertions failed. The detailed
-- per-assertion grid below is what must be last.
SELECT * FROM finish();
SELECT result FROM test_results ORDER BY n;

ROLLBACK;
