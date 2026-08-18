-- ============================================================
-- Migration 136: rim_accounts.party_category — TEXT free-text → real LOV
-- ============================================================
-- rim_accounts.party_category (013) has been plain TEXT since day one,
-- deliberately: migration 094's own comment says converting it to a real
-- FK "would ripple into" fn_convert_prospect_to_customer (087/096),
-- Sales Order's own prospect-capture flow, which was out of scope there.
-- User-specified this session: fix it properly now — "let us not keep it
-- an open text field" — across every place that writes it, not just the
-- new Customer/Supplier Ageing report's own filter (which is what
-- surfaced the gap in the first place; see plan_party_ageing_reports.md).
--
-- Full blast radius, confirmed by direct code investigation, not
-- guessed: customer_master_screen.dart and supplier_master_screen.dart
-- already source a dropdown from rim_common_masters (type_key
-- 'CUSTOMER_CATEGORY'/'SUPPLIER_CATEGORY', seeded by 094) but bind
-- `value: c['description']` — they write the description STRING into
-- party_category, not an id. chart_of_accounts_screen.dart is a plain
-- TextField that doesn't consume the LOV at all.
-- prospect_conversion_dialog.dart (Sales Order's prospect->customer
-- wizard) is a plain TextFormField with zero rim_common_masters wiring
-- — this is the exact screen 094 named as the reason party_category
-- stayed TEXT, and per this session's own Q&A it gets the same LOV
-- treatment too, for full consistency (no free-text path survives
-- anywhere this column is written).
--
-- No backfill: confirmed acceptable this session ("we are still in dev
-- env") — the user is resetting the existing party_category text values
-- themselves. The OLD column is deliberately NOT dropped here — user
-- correction: "I told you I will reset it" meant they'd clear the data
-- on their own terms, not that this migration should structurally drop
-- the column. party_category stays in place, untouched, unused by the
-- app going forward (every screen below is repointed at the new
-- party_category_id FK column instead) — dropping it is left as a
-- separate, later decision for the user to make explicitly if/when
-- they want it gone.
-- ============================================================

ALTER TABLE rim_accounts
    ADD COLUMN IF NOT EXISTS party_category_id UUID REFERENCES rim_common_masters(id);


-- ------------------------------------------------------------
-- fn_convert_prospect_to_customer — re-issued to write the new FK
-- column instead of the old TEXT one.
--
-- Signature unchanged (same params, same RETURNS UUID) — safe
-- CREATE OR REPLACE, no DROP FUNCTION needed (same note 096's own
-- header already made about this exact function). Full current body
-- reproduced verbatim from 096 (its own live definition — 096 is the
-- latest migration touching this function, confirmed by grepping every
-- migration for it), not truncated, per this project's standing rule
-- that editing a shared function from a stale copy is a real, previously
-- -caught mistake class. The ONLY change from 096's body is the
-- party_category handling: p_account's own JSONB key is renamed
-- 'party_category_id' (a UUID, not free text) and it's cast/written
-- into the new party_category_id column.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_convert_prospect_to_customer(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_account        JSONB,   -- {account_name, account_currency_id, party_type, contact_person, phone, email,
                               --  address_line1, address_line2, city_id, country_id, tax_id, party_category_id,
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

    -- Reads the company's own chosen standard instead of a hardcoded
    -- literal. Falls back to 'OHADA' only if onboarding was somehow
    -- skipped (rim_accounting_setup has no row yet) — matches the same
    -- fallback the Flutter-side accountingStdProvider uses.
    SELECT accounting_std INTO v_accounting_std FROM rim_accounting_setup
    WHERE client_id = p_client_id AND company_id = p_company_id
    LIMIT 1;
    v_accounting_std := coalesce(v_accounting_std, 'OHADA');

    v_account_code := fn_next_account_code(p_client_id, p_company_id, v_group_id);

    INSERT INTO rim_accounts (
        client_id, company_id, parent_id, account_code, account_name,
        account_nature, posting_allowed, is_system_fixed, accounting_std,
        account_currency_id, party_type, contact_person, phone, email,
        address_line1, address_line2, city_id, country_id, tax_id, party_category_id,
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
        (nullif(p_account->>'party_category_id', ''))::uuid,
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
