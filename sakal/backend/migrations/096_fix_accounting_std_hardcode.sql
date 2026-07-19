-- ============================================================
-- Fix: accounting_std hardcoded to 'OHADA' in fn_convert_prospect_to_customer
--
-- Real bug found in live testing: this function has always hardcoded
-- accounting_std='OHADA' on the new rim_accounts row it creates,
-- regardless of what the company actually chose at setup time
-- (rim_accounting_setup.accounting_std, set once via the Accounting
-- Setup screen — 'INDIAN' or 'OHADA'). A company running INDIAN got a
-- silently-wrong OHADA-tagged customer account on every prospect
-- conversion.
--
-- Same class of bug was independently hardcoded in three Flutter
-- screens (Customer Master, Supplier Master, Chart of Accounts) — those
-- are fixed in the same session by reading a new accountingStdProvider
-- (lib/core/providers/master_cache_providers.dart) instead of a literal.
-- This migration is the backend-side fix for the one place a real
-- rim_accounts row gets created entirely server-side.
--
-- Signature unchanged (same params, same RETURNS UUID) — safe
-- CREATE OR REPLACE, no DROP FUNCTION needed.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_convert_prospect_to_customer(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_account        JSONB,   -- {account_name, account_currency_id, party_type, contact_person, phone, email,
                               --  address_line1, address_line2, city_id, country_id, tax_id, party_category,
                               --  credit_limit, credit_days}
    p_notes          TEXT,
    p_user_id        UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_quotation      rih_sales_quotations%ROWTYPE;
    v_group_id       UUID;
    v_account_code   TEXT;
    v_new_id         UUID;
    v_accounting_std TEXT;
BEGIN
    SELECT * INTO v_quotation FROM rih_sales_quotations
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Quotation % dated % not found', p_quotation_no, p_quotation_date;
    END IF;
    IF v_quotation.customer_type != 'PROSPECT' THEN
        RAISE EXCEPTION 'ALREADY_A_CUSTOMER'
            USING DETAIL = format('Sales Quotation %s is already linked to a real customer.', p_quotation_no);
    END IF;

    SELECT id INTO v_group_id FROM rim_accounts
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND account_nature = 'Customer' AND posting_allowed = false AND is_deleted = false
    LIMIT 1;

    IF v_group_id IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_GROUP_NOT_CONFIGURED'
            USING DETAIL = 'No Customer group account exists yet — set up the Chart of Accounts Customer group first.';
    END IF;

    -- The real fix: read the company's own chosen standard instead of a
    -- hardcoded literal. Falls back to 'OHADA' only if onboarding was
    -- somehow skipped (rim_accounting_setup has no row yet) — matches
    -- the same fallback the Flutter-side accountingStdProvider uses.
    SELECT accounting_std INTO v_accounting_std FROM rim_accounting_setup
    WHERE client_id = p_client_id AND company_id = p_company_id
    LIMIT 1;
    v_accounting_std := coalesce(v_accounting_std, 'OHADA');

    v_account_code := fn_next_account_code(p_client_id, p_company_id, v_group_id);

    INSERT INTO rim_accounts (
        client_id, company_id, parent_id, account_code, account_name,
        account_nature, posting_allowed, is_system_fixed, accounting_std,
        account_currency_id, party_type, contact_person, phone, email,
        address_line1, address_line2, city_id, country_id, tax_id, party_category,
        credit_limit, credit_days, is_credit_blocked, created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, v_group_id, v_account_code,
        trim(p_account->>'account_name'),
        'Customer', true, false, v_accounting_std,
        (nullif(p_account->>'account_currency_id', ''))::uuid,
        nullif(p_account->>'party_type', ''),
        nullif(p_account->>'contact_person', ''),
        nullif(p_account->>'phone', ''),
        nullif(p_account->>'email', ''),
        nullif(p_account->>'address_line1', ''),
        nullif(p_account->>'address_line2', ''),
        (nullif(p_account->>'city_id', ''))::uuid,
        (nullif(p_account->>'country_id', ''))::uuid,
        nullif(p_account->>'tax_id', ''),
        nullif(p_account->>'party_category', ''),
        nullif(p_account->>'credit_limit', '')::numeric,
        coalesce(nullif(p_account->>'credit_days', '')::integer, 30),
        false,
        p_user_id, p_user_id
    ) RETURNING id INTO v_new_id;

    UPDATE rih_sales_quotations SET
        customer_type = 'CUSTOMER',
        customer_id   = v_new_id,
        updated_at = now(), updated_by = p_user_id
    WHERE id = v_quotation.id;

    INSERT INTO rih_prospect_conversions (
        client_id, company_id, source_quotation_no, source_quotation_date,
        new_customer_id, notes, converted_by
    ) VALUES (
        p_client_id, p_company_id, p_quotation_no, p_quotation_date,
        v_new_id, nullif(p_notes, ''), p_user_id
    );

    RETURN v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_convert_prospect_to_customer(UUID, UUID, TEXT, DATE, JSONB, TEXT, UUID) TO authenticated;
