-- ============================================================================
-- seed_qa_master_data.sql
--
-- One-time setup of a dedicated "QA Automation" tenant inside the SAME
-- Supabase project used by production, for the E2E test automation plan
-- (see the approved plan: dedicated QA tenant + integration_test pilot,
-- GRN -> Sales Invoice -> Stock Ledger + Trial Balance, multi-currency).
--
-- This is a one-time maintenance script, not a numbered migration — it does
-- not change the schema, only data. It reuses fn_register_client (the exact
-- RPC the app's own real signup flow calls) so the QA tenant is created
-- through the same code path a real customer goes through — no bespoke
-- client/company/user creation logic duplicated here.
--
-- WHAT THIS CREATES:
--   1. Client + Company (base_currency=USD, local_currency=CDF — mirrors
--      the real tenant's currency pair, the exact pair that surfaced the
--      SELLING/MID exchange-rate bug this session) + one Location + one
--      admin user, all via fn_register_client (same as a real signup).
--   2. Chart of Accounts (INDIAN standard) via fn_seed_chart_of_accounts —
--      the same function the real Accounting Setup screen calls.
--   3. An active Financial Year covering today's date (fn_check_period_open
--      requires one; fn_register_client/fn_seed_client_modules don't create
--      one — confirmed by reading both).
--   4. Four leaf GL accounts fn_next_account_code-style (Customer, Supplier,
--      Stock, Cost of Sales) under the CoA's own group nodes, since the
--      seeded 1120/2110/1130/5100 groups are posting_allowed=FALSE by
--      design (real leaf ledgers are meant to be created under them).
--   5. Account Link Setup (COMPANY-level) for the four link types
--      fn_approve_grn and fn_approve_sales_invoice actually require
--      (STOCK_ACCOUNT, PURCHASE_ACCRUAL_ACCOUNT, SALES_ACCOUNT,
--      COST_OF_SALES_ACCOUNT — confirmed via direct grep of both functions'
--      CURRENT bodies, not assumed) — without this, GRN/Sales Invoice
--      Approve fails with ACCOUNT_LINK_NOT_CONFIGURED.
--   6. One UOM common-master value ('PCS'), one Item Category, one Product
--      (tracking_type='NONE' — batch/serial explicitly deferred to a later
--      pilot per the plan's own effort/risk callouts).
--   7. One Customer and one Supplier (plain rim_accounts rows, account_nature
--      Customer/Supplier, under the CoA leaves created in step 4).
--   8. One rim_exchange_rates row (USD -> CDF) — fn_get_exchange_rate only
--      ever queries the from_currency=base_currency direction (confirmed),
--      so a single row covers both directions of the pilot's Sales Invoice.
--
-- WHAT THIS DELIBERATELY DOES NOT SET UP (out of scope for the pilot, per
-- the approved plan's own effort/risk callouts):
--   - No tax setup — confirmed neither fn_approve_grn nor
--     fn_approve_sales_invoice requires a tax_group_id when tax_amount=0.
--   - No batch/serial/FEFO — tracking_type='NONE' on the seeded product.
--   - No Purchase Order — GRN is entered DIRECT (no PO), which the app
--     supports natively; keeps the pilot's setup surface smaller.
--
-- HOW TO USE:
--   1. Edit the CUSTOMIZE block in Section 0 below — pick a unique email
--      (fn_register_client rejects a duplicate), a username, and a real
--      password you'll actually use to log in as this QA user later.
--   2. Run the ENTIRE script as one batch in the Supabase SQL editor. It
--      prints the generated client_id/company_id/location_id/product_id/
--      customer_id/supplier_id and the username you chose at the end via
--      RAISE NOTICE — copy those into your test-config (never commit them
--      to git; sakal/integration_test/support/test_tenant_config.dart reads
--      them via --dart-define or a gitignored local env file, per the plan).
--   3. This is NOT safely re-runnable as-is — fn_register_client rejects a
--      duplicate email, so re-running with the SAME email fails loudly at
--      Section 1 rather than silently creating a second tenant. To create
--      a fresh QA tenant, change the email (and username, since it's also
--      unique per company but you likely want a fresh one anyway).
-- ============================================================================

DO $$
DECLARE
    -- ── 0. CUSTOMIZE before running ─────────────────────────────────────
    v_business_name  TEXT := 'QA Automation Co';
    v_email          TEXT := 'qa-automation@sakal-test.local';  -- must be unique
    v_username       TEXT := 'qa_admin';
    v_password       TEXT := 'CHANGE-ME-Str0ngPassword!';       -- pick a real one
    v_base_currency  TEXT := 'USD';
    v_local_currency TEXT := 'CDF';
    -- USD->CDF rates: same magnitude as the real tenant's own rates this
    -- session (2800/2850/2825), for continuity — not load-bearing, just
    -- realistic. exchange_rate is what every Sales/Purchase/Inventory
    -- conversion actually uses (per migration 179); buying/selling are
    -- stored but unused by any current calculation.
    v_buying_rate    NUMERIC := 2800;
    v_selling_rate   NUMERIC := 2850;
    v_exchange_rate  NUMERIC := 2825;

    -- ── working variables ────────────────────────────────────────────────
    v_result         JSON;
    v_client_id      UUID;
    v_client_no      TEXT;   -- fn_login needs THIS, not client_id (SK-XXXXX format)
    v_company_id     UUID;
    v_location_id    UUID;
    v_user_id        UUID;

    v_group_1120     UUID;  -- Trade Receivables (Customer group)
    v_group_2110     UUID;  -- Trade Payables (Supplier group)
    v_group_1130     UUID;  -- Inventory group
    v_group_5100     UUID;  -- Cost Of Goods Sold group
    v_group_4110     UUID;  -- Product Sales (already posting_allowed=TRUE)
    v_group_2100     UUID;  -- Current Liabilities (parent for Purchase Accrual leaf)

    v_customer_acct  UUID;
    v_supplier_acct  UUID;
    v_stock_acct     UUID;
    v_cogs_acct      UUID;
    v_accrual_acct   UUID;

    v_unit_id        UUID;  -- rim_common_masters row for UOM 'PCS'
    v_category_id    UUID;
    v_product_id     UUID;
    v_customer_id    UUID;  -- rim_accounts id for the Customer party
    v_supplier_id    UUID;  -- rim_accounts id for the Supplier party
BEGIN
    -- ── 1. Client + Company + Location + Admin user ─────────────────────
    -- Same RPC the app's real Registration screen calls — no bespoke
    -- creation logic here.
    v_result := fn_register_client(
        p_business_name  => v_business_name,
        p_country        => 'DR Congo',
        p_contact_name   => 'QA Automation',
        p_email          => v_email,
        p_phone          => '+000000000',
        p_company_name   => v_business_name,
        p_company_short  => 'QAAUTO',
        p_base_currency  => v_base_currency,
        p_local_currency => v_local_currency,
        p_location_name  => 'QA Head Office',
        p_location_short => 'QAHO',
        p_location_type  => 'HEAD_OFFICE',
        p_admin_name     => 'QA Admin',
        p_username       => v_username,
        p_password       => v_password
    );

    v_client_id   := (v_result->>'client_id')::UUID;
    v_client_no   := v_result->>'client_no';
    v_company_id  := (v_result->>'company_id')::UUID;
    v_location_id := (v_result->>'location_id')::UUID;

    -- fn_register_client's own JSON return doesn't include the user id —
    -- look it up by the (company-scoped-unique) username it just created.
    SELECT id INTO v_user_id
    FROM rim_users
    WHERE company_id = v_company_id AND username = lower(trim(v_username));

    -- ── 2. Chart of Accounts (INDIAN standard) ──────────────────────────
    -- Same function the real Accounting Setup screen calls on first save.
    INSERT INTO rim_accounting_setup (client_id, company_id, accounting_std, fy_start_month, fy_start_day, created_by)
    VALUES (v_client_id, v_company_id, 'INDIAN', 1, 1, v_user_id);

    PERFORM fn_seed_chart_of_accounts(v_client_id, v_company_id, 'INDIAN');

    -- ── 3. Active Financial Year covering today ─────────────────────────
    -- fn_check_period_open (the mandatory first check in every fn_approve_*)
    -- needs one; neither fn_register_client nor fn_seed_client_modules
    -- creates it.
    INSERT INTO rim_financial_years (client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, created_by)
    VALUES (
        v_client_id, v_company_id, 'FY ' || EXTRACT(YEAR FROM CURRENT_DATE)::TEXT,
        DATE_TRUNC('year', CURRENT_DATE)::DATE,
        (DATE_TRUNC('year', CURRENT_DATE) + INTERVAL '1 year - 1 day')::DATE,
        TRUE, v_user_id
    );

    -- ── 4. Leaf GL accounts under the seeded group nodes ────────────────
    -- 1120/2110/1130/5100 are posting_allowed=FALSE group nodes by design
    -- (see 013_chart_of_accounts.sql's own comment) — real leaf ledgers are
    -- meant to be created under them, same as the real Chart of Accounts
    -- screen does via fn_next_account_code.
    SELECT id INTO v_group_1120 FROM rim_accounts WHERE company_id = v_company_id AND account_code = '1120';
    SELECT id INTO v_group_2110 FROM rim_accounts WHERE company_id = v_company_id AND account_code = '2110';
    SELECT id INTO v_group_1130 FROM rim_accounts WHERE company_id = v_company_id AND account_code = '1130';
    SELECT id INTO v_group_5100 FROM rim_accounts WHERE company_id = v_company_id AND account_code = '5100';
    SELECT id INTO v_group_4110 FROM rim_accounts WHERE company_id = v_company_id AND account_code = '4110';
    SELECT id INTO v_group_2100 FROM rim_accounts WHERE company_id = v_company_id AND account_code = '2100';

    INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
    VALUES (v_client_id, v_company_id, fn_next_account_code(v_client_id, v_company_id, v_group_1120), 'QA Test Customer', v_group_1120, TRUE, 'Customer', FALSE, 'INDIAN')
    RETURNING id INTO v_customer_acct;

    INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
    VALUES (v_client_id, v_company_id, fn_next_account_code(v_client_id, v_company_id, v_group_2110), 'QA Test Supplier', v_group_2110, TRUE, 'Supplier', FALSE, 'INDIAN')
    RETURNING id INTO v_supplier_acct;

    INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
    VALUES (v_client_id, v_company_id, fn_next_account_code(v_client_id, v_company_id, v_group_1130), 'QA Stock Account', v_group_1130, TRUE, 'General', FALSE, 'INDIAN')
    RETURNING id INTO v_stock_acct;

    INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
    VALUES (v_client_id, v_company_id, fn_next_account_code(v_client_id, v_company_id, v_group_5100), 'QA Cost of Sales', v_group_5100, TRUE, 'General', FALSE, 'INDIAN')
    RETURNING id INTO v_cogs_acct;

    INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
    VALUES (v_client_id, v_company_id, fn_next_account_code(v_client_id, v_company_id, v_group_2100), 'QA Purchase Accrual (GR/IR)', v_group_2100, TRUE, 'General', FALSE, 'INDIAN')
    RETURNING id INTO v_accrual_acct;

    -- ── 5. Account Link Setup (COMPANY granularity) ─────────────────────
    -- The four link types fn_approve_grn/fn_approve_sales_invoice's CURRENT
    -- bodies actually require (confirmed via grep, not assumed) —
    -- STOCK_ACCOUNT, PURCHASE_ACCRUAL_ACCOUNT, SALES_ACCOUNT,
    -- COST_OF_SALES_ACCOUNT. SALES_ACCOUNT maps straight to the already
    -- posting_allowed 4110 'Product Sales' leaf — no new account needed.
    INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
    SELECT v_client_id, v_company_id, id, 'COMPANY' FROM rim_account_link_types
    WHERE link_key IN ('STOCK_ACCOUNT', 'PURCHASE_ACCRUAL_ACCOUNT', 'SALES_ACCOUNT', 'COST_OF_SALES_ACCOUNT');

    INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
    SELECT v_client_id, v_company_id, id, NULL, v_stock_acct FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
    INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
    SELECT v_client_id, v_company_id, id, NULL, v_accrual_acct FROM rim_account_link_types WHERE link_key = 'PURCHASE_ACCRUAL_ACCOUNT';
    INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
    SELECT v_client_id, v_company_id, id, NULL, v_group_4110 FROM rim_account_link_types WHERE link_key = 'SALES_ACCOUNT';
    INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
    SELECT v_client_id, v_company_id, id, NULL, v_cogs_acct FROM rim_account_link_types WHERE link_key = 'COST_OF_SALES_ACCOUNT';

    -- ── 6. UOM + Category + Product ──────────────────────────────────────
    INSERT INTO rim_common_masters (client_id, company_id, type_id, description, short_name, created_by)
    SELECT v_client_id, v_company_id, id, 'Pieces', 'PCS', v_user_id
    FROM rim_common_master_types WHERE type_key = 'UNIT'
    RETURNING id INTO v_unit_id;

    INSERT INTO rim_item_categories (client_id, company_id, level_no, category_name, created_by)
    VALUES (v_client_id, v_company_id, 1, 'QA Test Category', v_user_id)
    RETURNING id INTO v_category_id;

    INSERT INTO rim_products (
        client_id, company_id, product_code, product_name, product_nature,
        category_id, base_uom_id, tracking_type, created_by
    ) VALUES (
        v_client_id, v_company_id, 'QA-PROD-001', 'QA Test Product', 'TRADING',
        v_category_id, v_unit_id, 'NONE', v_user_id
    ) RETURNING id INTO v_product_id;

    -- ── 7. Customer + Supplier parties ──────────────────────────────────
    -- The Chart of Accounts leaves created in step 4 already have
    -- account_nature='Customer'/'Supplier' — that IS the party record; no
    -- separate customer/supplier table exists in this schema.
    v_customer_id := v_customer_acct;
    v_supplier_id := v_supplier_acct;

    -- ── 8. Exchange rate: USD -> CDF ─────────────────────────────────────
    -- fn_get_exchange_rate only ever queries from_currency=base_currency
    -- rows (confirmed) — a single row covers both conversion directions.
    INSERT INTO rim_exchange_rates (
        client_id, company_id, location_id, rate_date,
        from_currency, to_currency, buying_rate, selling_rate, exchange_rate,
        source, created_by
    ) VALUES (
        v_client_id, v_company_id, v_location_id, CURRENT_DATE,
        v_base_currency, v_local_currency, v_buying_rate, v_selling_rate, v_exchange_rate,
        'MANUAL', v_user_id
    );

    -- ── Done — print everything the test harness needs ──────────────────
    RAISE NOTICE '=== QA TENANT SEEDED ===';
    RAISE NOTICE 'client_id:   %', v_client_id;
    RAISE NOTICE 'client_no:   % (this is what fn_login''s p_client_no expects, NOT client_id)', v_client_no;
    RAISE NOTICE 'company_id:  %', v_company_id;
    RAISE NOTICE 'location_id: %', v_location_id;
    RAISE NOTICE 'username:    %', lower(trim(v_username));
    RAISE NOTICE 'product_id:  % (code QA-PROD-001)', v_product_id;
    RAISE NOTICE 'customer_id: % (rim_accounts row)', v_customer_id;
    RAISE NOTICE 'supplier_id: % (rim_accounts row)', v_supplier_id;
    RAISE NOTICE 'Password is whatever you set in v_password above -- not printed here.';
END $$;
