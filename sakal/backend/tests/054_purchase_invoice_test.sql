-- ============================================================
-- 054_purchase_invoice_test.sql — pgTAP tests for migrations 054/055/057/058/059
--
-- Functions: fn_save_purchase_invoice, fn_approve_purchase_invoice
--
-- HOW TO RUN (Supabase SQL Editor):
--   1. CREATE EXTENSION IF NOT EXISTS pgtap;
--   2. Paste and run entire file.
--   3. All rows show "ok N — ..." with no "not ok" lines.
--   4. finish() returns no rows = all passed.
--
-- Hardcoded fixture UUIDs — no temp tables (Supabase auto-commits DO blocks).
-- Two scenarios:
--   A. GRN and Bill raised at the SAME rate — exercises the GR/IR clearing
--      (DR Purchase Accrual replicated exactly, DR Input VAT apportioned,
--      CR Supplier tagged with inv_bill_no) with zero FX gap, and confirms
--      migration 055's fix: the voucher posts as PUR, not JV.
--   B. GRN and Bill raised at DIFFERENT rates — exercises the Exchange
--      restatement split (migration 059): Supplier's base_amount in the
--      PUR voucher is forced to balance against Accrual, and the residual
--      (a real loss here: EUR strengthens between GRN and Bill) posts as
--      its own separate EXC voucher, both lines natively in base currency.
-- ============================================================

BEGIN;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_client_id       uuid := '00000000-0000-0000-0054-000000000001';
  v_company_id      uuid := '00000000-0000-0000-0054-000000000002';
  v_loc_id          uuid := '00000000-0000-0000-0054-000000000003';
  v_user_id         uuid := '00000000-0000-0000-0054-000000000004';
  v_base_ccy_id     uuid := '00000000-0000-0000-0054-000000000005';
  v_eur_ccy_id      uuid;  -- read back post-trigger-seed, see below
  v_supplier_id     uuid := '00000000-0000-0000-0054-000000000007';
  v_stock_acc_id    uuid := '00000000-0000-0000-0054-000000000008';
  v_accrual_acc_id  uuid := '00000000-0000-0000-0054-000000000009';
  v_input_vat_acc_id uuid := '00000000-0000-0000-0054-000000000010';
  v_fx_acc_id       uuid := '00000000-0000-0000-0054-000000000011';
  v_product_id      uuid := '00000000-0000-0000-0054-000000000012';
  v_product2_id     uuid := '00000000-0000-0000-0054-000000000013';
  v_fy_id           uuid := '00000000-0000-0000-0054-000000000014';
  v_tax_id          uuid := '00000000-0000-0000-0054-000000000015';
  v_tax_rate_id     uuid := '00000000-0000-0000-0054-000000000016';
  v_tax_group_id    uuid := '00000000-0000-0000-0054-000000000017';
  v_tax_member_id   uuid := '00000000-0000-0000-0054-000000000018';
  v_stock_link_type uuid; v_accrual_link_type uuid; v_fx_link_type uuid;
BEGIN
  INSERT INTO ric_clients (id, client_name, is_active, is_deleted, created_at)
  VALUES (v_client_id, 'TEST054', true, false, now()) ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_companies (id, client_id, company_name, base_currency, local_currency, is_active, is_deleted, created_at)
  VALUES (v_company_id, v_client_id, 'TEST054 CO', 'USD', 'USD', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO ric_locations (id, client_id, company_id, location_name, location_short, is_active, is_deleted, created_at)
  VALUES (v_loc_id, v_client_id, v_company_id, 'Test054 Loc', 'T54', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_users (id, client_id, company_id, username, full_name, password_hash, is_active, is_deleted, created_at)
  VALUES (v_user_id, v_client_id, v_company_id, 'test054', 'Test User', 'x', true, false, now())
  ON CONFLICT (id) DO NOTHING;

  -- ric_companies has an AFTER INSERT trigger (trg_seed_company_currencies,
  -- migration 007) that auto-seeds every world currency — including USD and
  -- EUR — for the new company. Explicitly inserting them here would collide
  -- on the real unique constraint (client_id, company_id, currency_id),
  -- which an ON CONFLICT (id) target doesn't catch. Read back the
  -- trigger-seeded ids instead of inserting our own.
  SELECT id INTO v_base_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'USD';
  SELECT id INTO v_eur_ccy_id FROM rim_currencies
  WHERE client_id = v_client_id AND company_id = v_company_id AND currency_id = 'EUR';

  -- v_eur_ccy_id is referenced by later, separate DO blocks (PL/pgSQL
  -- variables don't survive across DO blocks) — persist it via set_config,
  -- same trick already used for v_grn_no/v_invoice_no.
  PERFORM set_config('pgtap.v_eur_ccy_054', v_eur_ccy_id::text, false);

  -- Supplier account has NO account_currency_id configured, so the
  -- party-amount shortcut in fn_approve_purchase_invoice falls back to
  -- party_rate=1 / party_currency=invoice currency — same shortcut the GRN
  -- test (038) relies on for its Stock account, avoiding the need for a
  -- rim_exchange_rates fixture entirely.
  -- accounting_std is NOT NULL with no default (CHECK IN ('INDIAN','OHADA'))
  -- — arbitrary for this test, OHADA matches the project's DRC/Zambia target.
  INSERT INTO rim_accounts (id, client_id, company_id, account_code, account_name, account_nature, accounting_std, posting_allowed, is_active, is_deleted, created_at)
  VALUES
    (v_supplier_id,      v_client_id, v_company_id, '5054', 'Test054 Supplier',   'Supplier', 'OHADA', true, true, false, now()),
    (v_stock_acc_id,     v_client_id, v_company_id, '1354', 'Stock Account',      'General',  'OHADA', true, true, false, now()),
    (v_accrual_acc_id,   v_client_id, v_company_id, '2254', 'Purchase Accrual',   'General',  'OHADA', true, true, false, now()),
    (v_input_vat_acc_id, v_client_id, v_company_id, '1454', 'Input VAT',          'General',  'OHADA', true, true, false, now()),
    (v_fx_acc_id,        v_client_id, v_company_id, '7754', 'Exchange Gain/Loss', 'General',  'OHADA', true, true, false, now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_products (id, client_id, company_id, product_code, product_name, cost_currency_id, created_by)
  VALUES
    (v_product_id,  v_client_id, v_company_id, 'PINV-001', 'Purchase Invoice Test Item A', v_base_ccy_id, v_user_id),
    (v_product2_id, v_client_id, v_company_id, 'PINV-002', 'Purchase Invoice Test Item B', v_base_ccy_id, v_user_id)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO rim_financial_years (id, client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed)
  VALUES (v_fy_id, v_client_id, v_company_id, 'FY TEST054', '2020-01-01', '2030-12-31', true, false)
  ON CONFLICT (id) DO NOTHING;

  -- Tax: 16% VAT, one-member group, own dedicated Input VAT account (unlike
  -- 038's fixture shortcut of reusing the accrual account) — this test's
  -- whole point is exercising real VAT recognition at Bill time.
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

  -- Account Link Setup: COMPANY-level defaults for STOCK/ACCRUAL/FX.
  -- (Input VAT is NOT resolved via fn_resolve_account_link — the function
  -- reads rim_taxes.gl_input_account_id directly — so no link-setup row for
  -- INPUT_VAT_ACCOUNT is needed even though that link type exists.)
  SELECT id INTO v_stock_link_type   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
  SELECT id INTO v_accrual_link_type FROM rim_account_link_types WHERE link_key = 'PURCHASE_ACCRUAL_ACCOUNT';
  SELECT id INTO v_fx_link_type      FROM rim_account_link_types WHERE link_key = 'EXCHANGE_GAIN_LOSS_ACCOUNT';

  INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_accrual_link_type, 'COMPANY'),
    (v_client_id, v_company_id, v_fx_link_type, 'COMPANY')
  ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

  INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
  VALUES
    (v_client_id, v_company_id, v_stock_link_type, NULL, v_stock_acc_id),
    (v_client_id, v_company_id, v_accrual_link_type, NULL, v_accrual_acc_id),
    (v_client_id, v_company_id, v_fx_link_type, NULL, v_fx_acc_id)
  ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;

-- ══════════════════════════════════════════════════════════════════════════════
-- Scenario A: GRN and Bill at the SAME rate (rate_to_base=2 both times) —
-- taxable_amount/tax_amount on the bill exactly match the GRN's own
-- estimate, so this is the "clean" GR/IR clearing path with zero FX gap.
-- 10 units @ 100 EUR = gross 1000 EUR, 16% VAT = 160 EUR estimated/real.
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0054-000000000001',
      'company_id', '00000000-0000-0000-0054-000000000002',
      'location_id', '00000000-0000-0000-0054-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-01',
      'supplier_id', '00000000-0000-0000-0054-000000000007',
      'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_eur_ccy_054'),
      'rate_to_base', 2, 'rate_to_local', 2
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0054-000000000012',
        'qty_pack', 10, 'qty_loose', 0, 'base_qty', 10, 'rate', 100,
        'gross_amount', 1000, 'tax_group_id', '00000000-0000-0000-0054-000000000017',
        'tax_amount', 160, 'final_amount', 1160, 'charge_amount', 0, 'landed_amount', 1160
      )
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0054-000000000004'
  );
  PERFORM set_config('pgtap.v_grn_a_054', v_grn_no, false);

  PERFORM fn_approve_grn(
    '00000000-0000-0000-0054-000000000001', '00000000-0000-0000-0054-000000000002',
    v_grn_no, '2026-06-01'::date, '00000000-0000-0000-0054-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_invoice_no text;
BEGIN
  v_invoice_no := fn_save_purchase_invoice(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0054-000000000001',
      'company_id', '00000000-0000-0000-0054-000000000002',
      'location_id', '00000000-0000-0000-0054-000000000003',
      'invoice_no', NULL, 'invoice_date', '2026-06-05',
      'supplier_id', '00000000-0000-0000-0054-000000000007',
      'supplier_invoice_no', 'SUPP-INV-A1', 'supplier_invoice_date', '2026-06-04',
      'invoice_currency_id', current_setting('pgtap.v_eur_ccy_054'),
      'rate_to_base', 2, 'rate_to_local', 2,
      'taxable_amount', 1000, 'tax_amount', 160, 'invoice_total', 1160
    ),
    jsonb_build_array(jsonb_build_object('grn_no', current_setting('pgtap.v_grn_a_054'), 'grn_date', '2026-06-01')),
    '00000000-0000-0000-0054-000000000004'
  );
  PERFORM set_config('pgtap.v_invoice_a_054', v_invoice_no, false);
END;
$$ LANGUAGE plpgsql;

SELECT plan(18);

SELECT ok(
  (SELECT billed_invoice_no FROM rih_grn_headers
   WHERE client_id = '00000000-0000-0000-0054-000000000001' AND grn_no = current_setting('pgtap.v_grn_a_054'))
    = current_setting('pgtap.v_invoice_a_054'),
  'ok 1 — fn_save_purchase_invoice reserves the GRN (billed_invoice_no set) at DRAFT save, not just Approve'
);

SELECT ok(
  (SELECT status FROM rih_purchase_invoices
   WHERE client_id = '00000000-0000-0000-0054-000000000001' AND invoice_no = current_setting('pgtap.v_invoice_a_054')) = 'DRAFT',
  'ok 2 — Purchase Bill status is DRAFT after fn_save_purchase_invoice, before approval'
);

DO $$
BEGIN
  PERFORM fn_approve_purchase_invoice(
    '00000000-0000-0000-0054-000000000001', '00000000-0000-0000-0054-000000000002',
    current_setting('pgtap.v_invoice_a_054'), '2026-06-05'::date,
    '00000000-0000-0000-0054-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

SELECT ok(
  (SELECT status FROM rih_purchase_invoices
   WHERE client_id = '00000000-0000-0000-0054-000000000001' AND invoice_no = current_setting('pgtap.v_invoice_a_054')) = 'APPROVED',
  'ok 3 — Purchase Bill status is APPROVED after fn_approve_purchase_invoice'
);

SELECT ok(
  (SELECT posted_voucher_no FROM rih_purchase_invoices
   WHERE client_id = '00000000-0000-0000-0054-000000000001' AND invoice_no = current_setting('pgtap.v_invoice_a_054')) IS NOT NULL,
  'ok 4 — posted_voucher_no is recorded on the bill header'
);

SELECT ok(
  (SELECT voucher_type_code FROM rih_finance_headers
   WHERE client_id = '00000000-0000-0000-0054-000000000001'
     AND trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))) = 'PUR',
  'ok 5 — migration 055: the voucher posts as PUR (Purchase Voucher), not the generic JV every other auto-posting used before'
);

SELECT ok(
  (SELECT source_doc_type FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))) = 'PURCHASE_INVOICE'
  AND
  (SELECT source_doc_no FROM rih_finance_headers
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))) = current_setting('pgtap.v_invoice_a_054'),
  'ok 6 — header tags source_doc_type=PURCHASE_INVOICE / source_doc_no=invoice_no for traceability'
);

SELECT ok(
  (SELECT count(*) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND is_deleted = false) = 3,
  'ok 7 — exactly 3 finance lines (Accrual clearing Dr, Input VAT Dr, Supplier Cr) — zero FX gap since GRN and Bill share the same rate'
);

SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'ACCRUAL_CLEARING') = 1000
  AND
  (SELECT base_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'ACCRUAL_CLEARING') = 2000,
  'ok 8 — DR Purchase Accrual replicates the GRN''s own ACCRUAL line exactly: trans_amount=1000, base_amount=2000'
);

SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'INPUT_VAT') = 160
  AND
  (SELECT base_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'INPUT_VAT') = 320
  AND
  (SELECT account_id FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'INPUT_VAT') = '00000000-0000-0000-0054-000000000010',
  'ok 9 — DR Input VAT posts the REAL 160 (base 320) to the tax''s own dedicated gl_input_account_id, not the accrual account'
);

SELECT ok(
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'SUPPLIER') = 1160
  AND
  (SELECT trans_nature FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'SUPPLIER') = 'CR'
  AND
  (SELECT inv_bill_no FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))
     AND source_line_type = 'SUPPLIER') = 'SUPP-INV-A1',
  'ok 10 — CR Supplier = 1160 (taxable+tax), tagged inv_bill_no = the SUPPLIER''s own invoice number (rides the pending-bills mechanism)'
);

SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_a_054'))) = 0,
  'ok 11 — the posted voucher balances exactly (Dr Accrual 2000 + Dr VAT 320 = Cr Supplier 2320)'
);

-- ══════════════════════════════════════════════════════════════════════════════
-- Scenario B: GRN rate (2) differs from the Bill's own rate (2.2) — EUR
-- strengthened against the base currency (USD) between GRN and Bill, so the
-- real payable (booked at the new rate) is MORE than the provisional accrual
-- (booked at the old rate) — a genuine Exchange LOSS, which must post as a
-- DEBIT (loss = expense = debit-normal), even though this function's own
-- inline comment describes the polarity backwards (comment-only mistake,
-- the code's CASE expression is correct — this test pins the actual,
-- correct behavior). 5 units @ 40 EUR = 200 EUR, no tax (keeps the VAT
-- block out of scope for this scenario).
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_grn_no text;
BEGIN
  v_grn_no := fn_save_grn(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0054-000000000001',
      'company_id', '00000000-0000-0000-0054-000000000002',
      'location_id', '00000000-0000-0000-0054-000000000003',
      'grn_no', NULL, 'grn_date', '2026-06-10',
      'supplier_id', '00000000-0000-0000-0054-000000000007',
      'receipt_mode', 'DIRECT',
      'grn_currency_id', current_setting('pgtap.v_eur_ccy_054'),
      'rate_to_base', 2, 'rate_to_local', 2
    ),
    jsonb_build_array(
      jsonb_build_object(
        'serial_no', 1, 'product_id', '00000000-0000-0000-0054-000000000013',
        'qty_pack', 5, 'qty_loose', 0, 'base_qty', 5, 'rate', 40,
        'gross_amount', 200, 'tax_amount', 0, 'final_amount', 200, 'charge_amount', 0, 'landed_amount', 200
      )
    ),
    '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
    '00000000-0000-0000-0054-000000000004'
  );
  PERFORM set_config('pgtap.v_grn_b_054', v_grn_no, false);

  PERFORM fn_approve_grn(
    '00000000-0000-0000-0054-000000000001', '00000000-0000-0000-0054-000000000002',
    v_grn_no, '2026-06-10'::date, '00000000-0000-0000-0054-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
  v_invoice_no text;
BEGIN
  v_invoice_no := fn_save_purchase_invoice(
    jsonb_build_object(
      'client_id', '00000000-0000-0000-0054-000000000001',
      'company_id', '00000000-0000-0000-0054-000000000002',
      'location_id', '00000000-0000-0000-0054-000000000003',
      'invoice_no', NULL, 'invoice_date', '2026-06-15',
      'supplier_id', '00000000-0000-0000-0054-000000000007',
      'supplier_invoice_no', 'SUPP-INV-B1', 'supplier_invoice_date', '2026-06-14',
      'invoice_currency_id', current_setting('pgtap.v_eur_ccy_054'),
      'rate_to_base', 2.2, 'rate_to_local', 2.2,
      'taxable_amount', 200, 'tax_amount', 0, 'invoice_total', 200
    ),
    jsonb_build_array(jsonb_build_object('grn_no', current_setting('pgtap.v_grn_b_054'), 'grn_date', '2026-06-10')),
    '00000000-0000-0000-0054-000000000004'
  );
  PERFORM set_config('pgtap.v_invoice_b_054', v_invoice_no, false);

  PERFORM fn_approve_purchase_invoice(
    '00000000-0000-0000-0054-000000000001', '00000000-0000-0000-0054-000000000002',
    v_invoice_no, '2026-06-15'::date,
    '00000000-0000-0000-0054-000000000004'
  );
END;
$$ LANGUAGE plpgsql;

-- Migration 059: the PUR voucher (posted_voucher_no) and the Exchange
-- restatement now live in TWO SEPARATE, independently-balanced vouchers —
-- every voucher posted through fn_post_voucher must balance on its own,
-- so a single voucher can no longer carry an FX-driven imbalance.

SELECT ok(
  (SELECT count(*) FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_b_054'))
     AND is_deleted = false) = 2,
  'ok 12 — PUR voucher has exactly 2 lines (Accrual clearing Dr, Supplier Cr) — no VAT line since tax_amount=0, no Exchange line here anymore'
);

SELECT ok(
  (SELECT base_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_b_054'))
     AND source_line_type = 'ACCRUAL_CLEARING') = 400
  AND
  (SELECT base_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_b_054'))
     AND source_line_type = 'SUPPLIER') = 400
  AND
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_b_054'))
     AND source_line_type = 'SUPPLIER') = 200,
  'ok 13 — Supplier''s base_amount is FORCED to match Accrual''s 400 so the PUR voucher balances on its own; trans_amount stays the real 200 EUR invoice amount unaffected'
);

SELECT ok(
  (SELECT count(*) FROM rih_finance_headers
   WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
     AND voucher_type_code = 'EXC') = 1,
  'ok 14 — migration 059: a SEPARATE EXC (Exchange Voucher) header was posted for this bill, distinct from the PUR voucher'
);

SELECT ok(
  (SELECT count(*) FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
                        AND voucher_type_code = 'EXC')
     AND is_deleted = false) = 2,
  'ok 15 — the EXC voucher has exactly 2 lines (Exchange Loss Dr, Supplier Cr)'
);

SELECT ok(
  (SELECT account_id FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
                        AND voucher_type_code = 'EXC')
     AND source_line_type = 'EXCHANGE_DIFF' AND trans_nature = 'DR') = '00000000-0000-0000-0054-000000000011'
  AND
  (SELECT trans_amount FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
                        AND voucher_type_code = 'EXC')
     AND source_line_type = 'EXCHANGE_DIFF' AND trans_nature = 'DR') = 40
  AND
  (SELECT trans_currency FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
                        AND voucher_type_code = 'EXC')
     AND source_line_type = 'EXCHANGE_DIFF' AND trans_nature = 'DR') = 'USD',
  'ok 16 — Exchange Loss posts DR 40, natively in the company base currency (USD) — accrual 400 < true payable 440 = a real loss when the EUR strengthened'
);

SELECT ok(
  (SELECT account_id FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
                        AND voucher_type_code = 'EXC')
     AND source_line_type = 'EXCHANGE_DIFF' AND trans_nature = 'CR') = '00000000-0000-0000-0054-000000000007'
  AND
  (SELECT inv_bill_no FROM rid_finance_lines
   WHERE trans_no = (SELECT trans_no FROM rih_finance_headers
                      WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
                        AND voucher_type_code = 'EXC')
     AND source_line_type = 'EXCHANGE_DIFF' AND trans_nature = 'CR') IS NULL,
  'ok 17 — Exchange restatement''s CR lands on the Supplier account itself, with NO inv_bill_no — invisible to party-currency pending-bills reconciliation, since the party is still owed the same real amount regardless of base-currency movement'
);

SELECT ok(
  (SELECT sum(CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END) FROM rid_finance_lines
   WHERE trans_no IN (
     (SELECT posted_voucher_no FROM rih_purchase_invoices WHERE invoice_no = current_setting('pgtap.v_invoice_b_054')),
     (SELECT trans_no FROM rih_finance_headers
      WHERE source_doc_type = 'PURCHASE_INVOICE' AND source_doc_no = current_setting('pgtap.v_invoice_b_054')
        AND voucher_type_code = 'EXC')
   )) = 0,
  'ok 18 — PUR (Dr Accrual 400 = Cr Supplier 400) and EXC (Dr Exchange Loss 40 = Cr Supplier 40) each balance independently, and together the Supplier''s total credit reaches the true 440'
);

SELECT * FROM finish();
ROLLBACK;
