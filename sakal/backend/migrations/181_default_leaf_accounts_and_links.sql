-- ============================================================
-- Migration 181: default leaf accounts + Account Link Setup, per standard
-- ============================================================
-- Part of the "new-tenant bare-minimum starter kit" initiative. Today a
-- freshly-seeded Chart of Accounts (fn_seed_chart_of_accounts) gives a
-- company only GROUP nodes for Stock/Cost-of-Sales/Purchase-Accrual (e.g.
-- OHADA's '3600 Merchandise', INDIAN/ZAMBIA's '1130 Inventory') -- no
-- actual posting-allowed LEAF account exists yet, and rim_account_link_
-- setup/rim_account_link_defaults (032) have zero rows for any company in
-- any migration. Confirmed via grep of fn_approve_grn/fn_approve_sales_
-- invoice: exactly 4 link types (STOCK_ACCOUNT, PURCHASE_ACCRUAL_ACCOUNT,
-- SALES_ACCOUNT, COST_OF_SALES_ACCOUNT) are required before either
-- function will even run -- backend/scripts/seed_qa_master_data.sql's own
-- header comment confirms this is exactly the manual step it had to work
-- around by hand for the QA tenant. This function automates that same
-- work for every real tenant.
--
-- fn_seed_default_leaf_accounts_and_links(client_id, company_id, std):
--   1. Creates one posting-allowed leaf account each for Stock, Cost of
--      Sales, and Purchase Accrual (GR/IR) under whichever group each
--      standard's own COA tree already provides for that role (via
--      fn_next_account_code, same technique the QA script already uses
--      by hand) -- or reuses one if it somehow already exists (idempotent
--      on re-run). Sales Account is NOT created new -- every standard's
--      tree already has a posting-allowed leaf for it (OHADA '7010 Sales
--      of Goods', INDIAN/ZAMBIA '4110 Product Sales') so this just looks
--      it up.
--   2. Wires rim_account_link_setup (COMPANY granularity) + rim_account_
--      link_defaults for exactly those 4 link types -- the other 9 link
--      types (Stock Adjustment, Depreciation, Sales Discount, Stock in
--      Transit, Exchange Gain/Loss, Plant Stock x2, Stock Account FG,
--      Stock Consumption) stay unset, same as today, since a brand-new
--      tenant won't reach those modules on day one -- "bare minimum," not
--      "everything."
--
-- Called from fn_complete_accounting_setup (see the follow-up migration
-- that adds it) right after fn_seed_chart_of_accounts succeeds -- never
-- called standalone from the registration path, since it depends on the
-- COA tree already existing.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_seed_default_leaf_accounts_and_links(
    p_client_id  UUID,
    p_company_id UUID,
    p_std        TEXT
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_stock_parent_code   TEXT;
    v_cos_parent_code     TEXT;
    v_accrual_parent_code TEXT;
    v_sales_code          TEXT;

    v_stock_parent_id   UUID;
    v_cos_parent_id     UUID;
    v_accrual_parent_id UUID;

    v_stock_id   UUID;
    v_cos_id     UUID;
    v_accrual_id UUID;
    v_sales_id   UUID;

    v_stock_link_type_id   UUID;
    v_accrual_link_type_id UUID;
    v_sales_link_type_id   UUID;
    v_cos_link_type_id     UUID;
BEGIN
    IF p_std = 'OHADA' THEN
        v_stock_parent_code := '3600'; v_cos_parent_code := '6100';
        v_accrual_parent_code := '4000'; v_sales_code := '7010';
    ELSIF p_std IN ('INDIAN', 'ZAMBIA') THEN
        v_stock_parent_code := '1130'; v_cos_parent_code := '5100';
        v_accrual_parent_code := '2100'; v_sales_code := '4110';
    ELSE
        RAISE EXCEPTION 'UNKNOWN_ACCOUNTING_STANDARD'
            USING DETAIL = format('No default leaf-account mapping for accounting standard %s.', p_std);
    END IF;

    SELECT id INTO v_stock_parent_id FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND account_code = v_stock_parent_code;
    SELECT id INTO v_cos_parent_id FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND account_code = v_cos_parent_code;
    SELECT id INTO v_accrual_parent_id FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND account_code = v_accrual_parent_code;
    SELECT id INTO v_sales_id FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id AND account_code = v_sales_code;

    IF v_stock_parent_id IS NULL OR v_cos_parent_id IS NULL OR v_accrual_parent_id IS NULL OR v_sales_id IS NULL THEN
        RAISE EXCEPTION 'COA_NOT_SEEDED'
            USING DETAIL = 'Chart of Accounts must be seeded (fn_seed_chart_of_accounts) before default leaf accounts can be created.';
    END IF;

    -- ── 1. Stock Account leaf ────────────────────────────────────────────
    SELECT id INTO v_stock_id FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id = v_stock_parent_id AND account_name = 'Stock Account';
    IF v_stock_id IS NULL THEN
        INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
        VALUES (p_client_id, p_company_id, fn_next_account_code(p_client_id, p_company_id, v_stock_parent_id),
                'Stock Account', v_stock_parent_id, true, 'General', false, p_std)
        RETURNING id INTO v_stock_id;
    END IF;

    -- ── 2. Cost of Sales leaf ─────────────────────────────────────────────
    SELECT id INTO v_cos_id FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id = v_cos_parent_id AND account_name = 'Cost of Sales';
    IF v_cos_id IS NULL THEN
        INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
        VALUES (p_client_id, p_company_id, fn_next_account_code(p_client_id, p_company_id, v_cos_parent_id),
                'Cost of Sales', v_cos_parent_id, true, 'General', false, p_std)
        RETURNING id INTO v_cos_id;
    END IF;

    -- ── 3. Purchase Accrual (GR/IR) leaf ─────────────────────────────────
    SELECT id INTO v_accrual_id FROM rim_accounts
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id = v_accrual_parent_id AND account_name = 'Purchase Accrual (GR/IR)';
    IF v_accrual_id IS NULL THEN
        INSERT INTO rim_accounts (client_id, company_id, account_code, account_name, parent_id, posting_allowed, account_nature, is_system_fixed, accounting_std)
        VALUES (p_client_id, p_company_id, fn_next_account_code(p_client_id, p_company_id, v_accrual_parent_id),
                'Purchase Accrual (GR/IR)', v_accrual_parent_id, true, 'General', false, p_std)
        RETURNING id INTO v_accrual_id;
    END IF;

    -- ── 4. Wire Account Link Setup + Defaults, COMPANY granularity ───────
    SELECT id INTO v_stock_link_type_id   FROM rim_account_link_types WHERE link_key = 'STOCK_ACCOUNT';
    SELECT id INTO v_accrual_link_type_id FROM rim_account_link_types WHERE link_key = 'PURCHASE_ACCRUAL_ACCOUNT';
    SELECT id INTO v_sales_link_type_id   FROM rim_account_link_types WHERE link_key = 'SALES_ACCOUNT';
    SELECT id INTO v_cos_link_type_id     FROM rim_account_link_types WHERE link_key = 'COST_OF_SALES_ACCOUNT';

    INSERT INTO rim_account_link_setup (client_id, company_id, link_type_id, link_type)
    VALUES
        (p_client_id, p_company_id, v_stock_link_type_id,   'COMPANY'),
        (p_client_id, p_company_id, v_accrual_link_type_id, 'COMPANY'),
        (p_client_id, p_company_id, v_sales_link_type_id,   'COMPANY'),
        (p_client_id, p_company_id, v_cos_link_type_id,     'COMPANY')
    ON CONFLICT (client_id, company_id, link_type_id) DO NOTHING;

    -- uq_account_link_defaults_company is a partial UNIQUE INDEX (WHERE
    -- link_key_id IS NULL), not a named table CONSTRAINT -- "ON CONFLICT
    -- ON CONSTRAINT" only works for real constraints, so the conflict
    -- target must be spelled out with the matching WHERE clause instead
    -- (confirmed live: "ON CONFLICT ON CONSTRAINT" raised "constraint ...
    -- does not exist" even though the index itself exists).
    INSERT INTO rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id, account_id)
    VALUES
        (p_client_id, p_company_id, v_stock_link_type_id,   NULL, v_stock_id),
        (p_client_id, p_company_id, v_accrual_link_type_id, NULL, v_accrual_id),
        (p_client_id, p_company_id, v_sales_link_type_id,   NULL, v_sales_id),
        (p_client_id, p_company_id, v_cos_link_type_id,     NULL, v_cos_id)
    ON CONFLICT (client_id, company_id, link_type_id) WHERE link_key_id IS NULL DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_seed_default_leaf_accounts_and_links(UUID, UUID, TEXT) TO authenticated;
