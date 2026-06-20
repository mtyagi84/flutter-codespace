-- ============================================================
-- seed_dummy_invoices.sql
--
-- Inserts 5 posted Sales Invoice Vouchers (SIV) so that the
-- Finance Voucher Entry screen's "Against Bill" mode has bills
-- to display in v_pending_bills.
--
-- HOW TO USE
--   1. Fill in the three parameter values at the top of the DO block.
--   2. Paste into Supabase SQL editor and run.
--   3. The script auto-discovers customer and revenue accounts that
--      already exist for your company — nothing is hard-coded.
--
-- REQUIREMENTS
--   Migrations 001-021 must be applied.
--   At least 2 Customer accounts must exist in rim_accounts.
--   At least 1 non-Cash/Bank/Party account must exist (revenue/expense).
-- ============================================================

DO $$
DECLARE
    -- ──────────────────────────────────────────────────────────
    -- ① FILL THESE THREE VALUES IN BEFORE RUNNING
    -- ──────────────────────────────────────────────────────────
    p_client_id   uuid := 'YOUR-CLIENT-UUID';
    p_company_id  uuid := 'YOUR-COMPANY-UUID';
    p_location_id uuid := 'YOUR-LOCATION-UUID';
    -- ──────────────────────────────────────────────────────────

    -- Auto-discovered at runtime
    v_base_currency  text;
    v_local_currency text;
    v_user_id        uuid;

    -- Up to 3 customers, 1 revenue account
    v_cust   uuid[];
    v_cust_currency text[];
    v_rev_id uuid;

    -- Per-invoice vars
    v_trans_no   text;
    v_trans_date date;
    v_amount     numeric;
    v_cust_id    uuid;
    v_cust_curr  text;
    v_rev_nature text;  -- DR on invoice = customer is owed
BEGIN

    -- ── Resolve company currencies ────────────────────────────
    SELECT base_currency, local_currency
    INTO   v_base_currency, v_local_currency
    FROM   ric_companies
    WHERE  id = p_company_id;

    IF v_base_currency IS NULL THEN
        RAISE EXCEPTION 'Company % not found or has no base_currency', p_company_id;
    END IF;

    -- ── Find a created_by user ────────────────────────────────
    SELECT id INTO v_user_id
    FROM   rim_users
    WHERE  is_deleted = false
    ORDER  BY created_at
    LIMIT  1;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No users found — cannot set created_by';
    END IF;

    -- ── Discover up to 3 customer accounts ───────────────────
    SELECT
        array_agg(a.id       ORDER BY a.account_name),
        array_agg(COALESCE(c.currency_id, v_base_currency) ORDER BY a.account_name)
    INTO v_cust, v_cust_currency
    FROM (
        SELECT a.id, a.account_name, a.account_currency_id
        FROM   rim_accounts a
        WHERE  a.company_id    = p_company_id
          AND  a.account_nature = 'Customer'
          AND  a.is_deleted     = false
          AND  a.is_active      = true
          AND  a.posting_allowed = true
        ORDER  BY a.account_name
        LIMIT  3
    ) a
    LEFT JOIN rim_currencies c ON c.currency_id = a.account_currency_id::text;

    IF v_cust IS NULL OR array_length(v_cust, 1) = 0 THEN
        RAISE EXCEPTION 'No Customer accounts found for company % — create at least one first', p_company_id;
    END IF;

    -- ── Discover a revenue / income account ──────────────────
    -- Prefer accounts whose nature looks like income/revenue/sales
    SELECT id INTO v_rev_id
    FROM   rim_accounts
    WHERE  company_id    = p_company_id
      AND  account_nature IN ('Income','Revenue','Sales','Other Income')
      AND  is_deleted     = false
      AND  is_active      = true
      AND  posting_allowed = true
    ORDER  BY account_name
    LIMIT  1;

    -- Fallback: any non-Cash/Bank/Customer/Supplier account
    IF v_rev_id IS NULL THEN
        SELECT id INTO v_rev_id
        FROM   rim_accounts
        WHERE  company_id    = p_company_id
          AND  account_nature NOT IN ('Cash','Bank','Customer','Supplier')
          AND  is_deleted     = false
          AND  is_active      = true
          AND  posting_allowed = true
        ORDER  BY account_name
        LIMIT  1;
    END IF;

    IF v_rev_id IS NULL THEN
        RAISE EXCEPTION 'No income/revenue account found — create one in Chart of Accounts first';
    END IF;

    -- ── Helper: insert one invoice ────────────────────────────
    -- Invoice double-entry:
    --   DR  Customer account  (receivable — who owes us)
    --   CR  Revenue account   (what we earned)
    -- inv_bill_no on the CUSTOMER line = the invoice's own trans_no.
    -- This makes it visible in v_pending_bills so it can be paid.

    -- ── Invoice 1 ─────────────────────────────────────────────
    v_trans_no   := 'SIV/HO/2026/00001';
    v_trans_date := '2026-04-10';
    v_amount     := 5000.00;
    v_cust_id    := v_cust[1];
    v_cust_curr  := v_cust_currency[1];

    INSERT INTO rih_finance_headers (
        client_id, company_id, location_id,
        trans_no, trans_date, voucher_type_code,
        is_on_account, is_posted, posted_at, posted_by,
        remarks, created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id,
        v_trans_no, v_trans_date, 'SIV',
        false, true, now(), v_user_id,
        'Dummy invoice 1', v_user_id, v_user_id
    ) ON CONFLICT ON CONSTRAINT uq_rih_finance_headers DO NOTHING;

    INSERT INTO rid_finance_lines (
        client_id, company_id, location_id, trans_no, trans_date,
        serial_no, account_id, trans_nature,
        trans_amount, trans_currency, base_amount, base_rate,
        local_amount, local_rate,
        party_amount, party_currency, party_rate,
        inv_bill_no, inv_bill_date, created_by, updated_by
    ) VALUES
    -- DR Customer (receivable — has inv_bill_no = self)
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      1, v_cust_id, 'DR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_cust_curr, 1,
      v_trans_no, v_trans_date, v_user_id, v_user_id ),
    -- CR Revenue
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      2, v_rev_id, 'CR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_base_currency, 1,
      NULL, NULL, v_user_id, v_user_id )
    ON CONFLICT ON CONSTRAINT uq_rid_finance_lines DO NOTHING;

    -- ── Invoice 2 ─────────────────────────────────────────────
    v_trans_no   := 'SIV/HO/2026/00002';
    v_trans_date := '2026-04-18';
    v_amount     := 12500.00;
    v_cust_id    := v_cust[1];
    v_cust_curr  := v_cust_currency[1];

    INSERT INTO rih_finance_headers (
        client_id, company_id, location_id,
        trans_no, trans_date, voucher_type_code,
        is_on_account, is_posted, posted_at, posted_by,
        remarks, created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id,
        v_trans_no, v_trans_date, 'SIV',
        false, true, now(), v_user_id,
        'Dummy invoice 2', v_user_id, v_user_id
    ) ON CONFLICT ON CONSTRAINT uq_rih_finance_headers DO NOTHING;

    INSERT INTO rid_finance_lines (
        client_id, company_id, location_id, trans_no, trans_date,
        serial_no, account_id, trans_nature,
        trans_amount, trans_currency, base_amount, base_rate,
        local_amount, local_rate,
        party_amount, party_currency, party_rate,
        inv_bill_no, inv_bill_date, created_by, updated_by
    ) VALUES
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      1, v_cust_id, 'DR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_cust_curr, 1,
      v_trans_no, v_trans_date, v_user_id, v_user_id ),
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      2, v_rev_id, 'CR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_base_currency, 1,
      NULL, NULL, v_user_id, v_user_id )
    ON CONFLICT ON CONSTRAINT uq_rid_finance_lines DO NOTHING;

    -- ── Invoice 3 — second customer (if exists) ───────────────
    v_trans_no   := 'SIV/HO/2026/00003';
    v_trans_date := '2026-05-02';
    v_amount     := 8750.00;
    v_cust_id    := COALESCE(v_cust[2], v_cust[1]);
    v_cust_curr  := COALESCE(v_cust_currency[2], v_cust_currency[1]);

    INSERT INTO rih_finance_headers (
        client_id, company_id, location_id,
        trans_no, trans_date, voucher_type_code,
        is_on_account, is_posted, posted_at, posted_by,
        remarks, created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id,
        v_trans_no, v_trans_date, 'SIV',
        false, true, now(), v_user_id,
        'Dummy invoice 3', v_user_id, v_user_id
    ) ON CONFLICT ON CONSTRAINT uq_rih_finance_headers DO NOTHING;

    INSERT INTO rid_finance_lines (
        client_id, company_id, location_id, trans_no, trans_date,
        serial_no, account_id, trans_nature,
        trans_amount, trans_currency, base_amount, base_rate,
        local_amount, local_rate,
        party_amount, party_currency, party_rate,
        inv_bill_no, inv_bill_date, created_by, updated_by
    ) VALUES
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      1, v_cust_id, 'DR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_cust_curr, 1,
      v_trans_no, v_trans_date, v_user_id, v_user_id ),
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      2, v_rev_id, 'CR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_base_currency, 1,
      NULL, NULL, v_user_id, v_user_id )
    ON CONFLICT ON CONSTRAINT uq_rid_finance_lines DO NOTHING;

    -- ── Invoice 4 — first customer, partially settled ─────────
    -- This invoice already has 2000 paid, leaving 6000 outstanding.
    -- Demonstrates the balance_amount column in v_pending_bills.
    v_trans_no   := 'SIV/HO/2026/00004';
    v_trans_date := '2026-05-15';
    v_amount     := 8000.00;
    v_cust_id    := v_cust[1];
    v_cust_curr  := v_cust_currency[1];

    INSERT INTO rih_finance_headers (
        client_id, company_id, location_id,
        trans_no, trans_date, voucher_type_code,
        is_on_account, is_posted, posted_at, posted_by,
        remarks, created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id,
        v_trans_no, v_trans_date, 'SIV',
        false, true, now(), v_user_id,
        'Dummy invoice 4 — partially settled', v_user_id, v_user_id
    ) ON CONFLICT ON CONSTRAINT uq_rih_finance_headers DO NOTHING;

    INSERT INTO rid_finance_lines (
        client_id, company_id, location_id, trans_no, trans_date,
        serial_no, account_id, trans_nature,
        trans_amount, trans_currency, base_amount, base_rate,
        local_amount, local_rate,
        party_amount, party_currency, party_rate,
        inv_bill_no, inv_bill_date,
        settled_amount,                  -- 2000 already paid
        created_by, updated_by
    ) VALUES
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      1, v_cust_id, 'DR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_cust_curr, 1,
      v_trans_no, v_trans_date,
      2000.00,
      v_user_id, v_user_id ),
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      2, v_rev_id, 'CR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_base_currency, 1,
      NULL, NULL,
      0,
      v_user_id, v_user_id )
    ON CONFLICT ON CONSTRAINT uq_rid_finance_lines DO NOTHING;

    -- Matching settlement record for the 2000 partial payment
    INSERT INTO rid_invoice_bill_settlement (
        client_id, company_id, location_id,
        trans_no, trans_date, voucher_type_code,
        account_id, inv_bill_no, inv_bill_date,
        settlement_no, was_balance, paid_amount, paid_amount_trans,
        created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id,
        'BRV/HO/2026/00099', '2026-05-20', 'BRV',
        v_cust_id, v_trans_no, v_trans_date,
        1, 8000.00, 2000.00, 2000.00,
        v_user_id, v_user_id
    ) ON CONFLICT DO NOTHING;

    -- ── Invoice 5 — third customer (or fallback to first) ─────
    v_trans_no   := 'SIV/HO/2026/00005';
    v_trans_date := '2026-06-01';
    v_amount     := 3200.00;
    v_cust_id    := COALESCE(v_cust[3], v_cust[2], v_cust[1]);
    v_cust_curr  := COALESCE(v_cust_currency[3], v_cust_currency[2], v_cust_currency[1]);

    INSERT INTO rih_finance_headers (
        client_id, company_id, location_id,
        trans_no, trans_date, voucher_type_code,
        is_on_account, is_posted, posted_at, posted_by,
        remarks, created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id,
        v_trans_no, v_trans_date, 'SIV',
        false, true, now(), v_user_id,
        'Dummy invoice 5', v_user_id, v_user_id
    ) ON CONFLICT ON CONSTRAINT uq_rih_finance_headers DO NOTHING;

    INSERT INTO rid_finance_lines (
        client_id, company_id, location_id, trans_no, trans_date,
        serial_no, account_id, trans_nature,
        trans_amount, trans_currency, base_amount, base_rate,
        local_amount, local_rate,
        party_amount, party_currency, party_rate,
        inv_bill_no, inv_bill_date, created_by, updated_by
    ) VALUES
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      1, v_cust_id, 'DR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_cust_curr, 1,
      v_trans_no, v_trans_date, v_user_id, v_user_id ),
    ( p_client_id, p_company_id, p_location_id, v_trans_no, v_trans_date,
      2, v_rev_id, 'CR',
      v_amount, v_base_currency, v_amount, 1,
      v_amount, 1,
      v_amount, v_base_currency, 1,
      NULL, NULL, v_user_id, v_user_id )
    ON CONFLICT ON CONSTRAINT uq_rid_finance_lines DO NOTHING;

    -- ── Summary ───────────────────────────────────────────────
    RAISE NOTICE '✓ Done. Invoices inserted for company %.', p_company_id;
    RAISE NOTICE '  Customers used: %', v_cust;
    RAISE NOTICE '  Revenue account: %', v_rev_id;
    RAISE NOTICE '  Base currency: %', v_base_currency;
    RAISE NOTICE '';
    RAISE NOTICE '  SIV/HO/2026/00001  % %   fully outstanding', v_amount, v_base_currency;
    RAISE NOTICE '  SIV/HO/2026/00002  12500  fully outstanding';
    RAISE NOTICE '  SIV/HO/2026/00003  8750   fully outstanding';
    RAISE NOTICE '  SIV/HO/2026/00004  8000   partially settled (2000 paid, 6000 outstanding)';
    RAISE NOTICE '  SIV/HO/2026/00005  3200   fully outstanding';

END;
$$;

-- ── Quick verification ────────────────────────────────────────
-- Run this separately after the DO block to confirm what was inserted:
--
-- SELECT trans_no, trans_date, account_id, party_amount, party_currency,
--        settled_amount, party_amount - settled_amount AS balance
-- FROM   rid_finance_lines
-- WHERE  inv_bill_no IS NOT NULL
-- ORDER  BY trans_no, serial_no;
