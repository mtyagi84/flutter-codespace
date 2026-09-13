-- ============================================================
-- Migration 182: minimum Tax Groups — DR Congo (OHADA) + Zambia
-- ============================================================
-- Part of the "new-tenant bare-minimum starter kit" initiative. Tax
-- tables (rim_taxes/rim_tax_rates/rim_tax_groups/rim_tax_group_members,
-- 025) have ZERO seeded rows anywhere in this schema for any real
-- company -- confirmed by grep, only pgTAP test-fixture files touch
-- them. Both DR Congo and Zambia are structurally simple, flat-VAT
-- countries (confirmed via web research, Sept 2026: both currently levy
-- 16% standard VAT, with a straightforward 0% zero-rated/exempt case) --
-- safe to auto-seed now.
--
-- India is DELIBERATELY skipped here (the function no-ops for
-- accounting_std = 'INDIAN') -- per the user's explicit choice, India
-- gets a REAL CGST+SGST (intra-state) vs IGST (inter-state) compound
-- setup, not a flattened single rate, but this schema has ZERO state/
-- province tracking anywhere yet (confirmed via grep: no state/
-- state_code column on ric_companies or rim_accounts), which dual-GST
-- fundamentally needs to pick the right tax group per transaction. That
-- needs its own schema + posting-logic design pass, scoped separately --
-- squeezing a flat placeholder in now would just be something to rip out
-- later, so this function does nothing for INDIAN until that follow-on
-- work lands.
--
-- Each seeded tax is a plain single-rate tax (calculation_type =
-- 'PERCENTAGE', never 'COMPOUND') resolved against whichever tax-role
-- account each standard's own Chart of Accounts (013/180) already
-- defines -- reused, never a new leaf invented just for tax:
--   OHADA:  one combined '4400 State & Taxes' account for both output
--           (sales) and input (purchase) legs -- OHADA's own COA doesn't
--           split these.
--   ZAMBIA: '2120 VAT Payable' (output) / '1140 VAT Recoverable' (input)
--           -- Zambia's own COA (180) does split these.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_seed_default_tax_setup(
    p_client_id  UUID,
    p_company_id UUID,
    p_std        TEXT
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_output_account_id UUID;
    v_input_account_id  UUID;
    v_std_tax_id   UUID;
    v_zero_tax_id  UUID;
    v_std_group_id UUID;
    v_zero_group_id UUID;
    v_std_tax_name   TEXT;
    v_zero_tax_name  TEXT;
    v_std_group_name TEXT;
    v_zero_group_name TEXT;
BEGIN
    IF p_std = 'INDIAN' THEN
        -- Deliberate no-op -- see this migration's own header comment.
        RETURN;
    ELSIF p_std = 'OHADA' THEN
        SELECT id INTO v_output_account_id FROM rim_accounts
            WHERE client_id = p_client_id AND company_id = p_company_id AND account_code = '4400';
        v_input_account_id := v_output_account_id;
        v_std_tax_name    := 'TVA Standard 16%';
        v_zero_tax_name   := 'TVA Exonere / Export 0%';
        v_std_group_name  := 'TVA Standard 16%';
        v_zero_group_name := 'Exonere / Export 0%';
    ELSIF p_std = 'ZAMBIA' THEN
        SELECT id INTO v_output_account_id FROM rim_accounts
            WHERE client_id = p_client_id AND company_id = p_company_id AND account_code = '2120';
        SELECT id INTO v_input_account_id FROM rim_accounts
            WHERE client_id = p_client_id AND company_id = p_company_id AND account_code = '1140';
        v_std_tax_name    := 'VAT Standard 16%';
        v_zero_tax_name   := 'VAT Zero-Rated / Exempt 0%';
        v_std_group_name  := 'VAT Standard 16%';
        v_zero_group_name := 'Zero-Rated / Exempt 0%';
    ELSE
        RAISE EXCEPTION 'UNKNOWN_ACCOUNTING_STANDARD'
            USING DETAIL = format('No default tax setup exists for accounting standard %s.', p_std);
    END IF;

    IF v_output_account_id IS NULL OR v_input_account_id IS NULL THEN
        RAISE EXCEPTION 'COA_NOT_SEEDED'
            USING DETAIL = 'Chart of Accounts must be seeded before default tax setup can resolve its GL accounts.';
    END IF;

    -- ── Standard-rate tax + rate + group ─────────────────────────────────
    INSERT INTO rim_taxes (client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, calculation_type, gl_output_account_id, gl_input_account_id, sort_order)
    VALUES (p_client_id, p_company_id, 'VAT_STD', v_std_tax_name, 'VAT', 'BOTH', 'PERCENTAGE', v_output_account_id, v_input_account_id, 1)
    ON CONFLICT (client_id, company_id, tax_code) DO NOTHING;
    SELECT id INTO v_std_tax_id FROM rim_taxes WHERE client_id = p_client_id AND company_id = p_company_id AND tax_code = 'VAT_STD';

    INSERT INTO rim_tax_rates (client_id, company_id, tax_id, rate_label, rate, effective_from, description)
    VALUES (p_client_id, p_company_id, v_std_tax_id, 'STANDARD', 16.0000, '2020-01-01', v_std_tax_name)
    ON CONFLICT (client_id, company_id, tax_id, rate_label, effective_from) DO NOTHING;

    INSERT INTO rim_tax_groups (client_id, company_id, group_code, group_name, applicable_on, sort_order)
    VALUES (p_client_id, p_company_id, 'VAT_STD_GRP', v_std_group_name, 'BOTH', 1)
    ON CONFLICT (client_id, company_id, group_code) DO NOTHING;
    SELECT id INTO v_std_group_id FROM rim_tax_groups WHERE client_id = p_client_id AND company_id = p_company_id AND group_code = 'VAT_STD_GRP';

    INSERT INTO rim_tax_group_members (client_id, company_id, tax_group_id, tax_id, sequence_no)
    VALUES (p_client_id, p_company_id, v_std_group_id, v_std_tax_id, 1)
    ON CONFLICT (client_id, company_id, tax_group_id, tax_id) DO NOTHING;

    -- ── Zero-rated / exempt tax + rate + group ───────────────────────────
    INSERT INTO rim_taxes (client_id, company_id, tax_code, tax_name, tax_type_code, applicable_on, calculation_type, gl_output_account_id, gl_input_account_id, sort_order)
    VALUES (p_client_id, p_company_id, 'VAT_ZERO', v_zero_tax_name, 'VAT', 'BOTH', 'PERCENTAGE', v_output_account_id, v_input_account_id, 2)
    ON CONFLICT (client_id, company_id, tax_code) DO NOTHING;
    SELECT id INTO v_zero_tax_id FROM rim_taxes WHERE client_id = p_client_id AND company_id = p_company_id AND tax_code = 'VAT_ZERO';

    INSERT INTO rim_tax_rates (client_id, company_id, tax_id, rate_label, rate, effective_from, description)
    VALUES (p_client_id, p_company_id, v_zero_tax_id, 'ZERO', 0.0000, '2020-01-01', v_zero_tax_name)
    ON CONFLICT (client_id, company_id, tax_id, rate_label, effective_from) DO NOTHING;

    INSERT INTO rim_tax_groups (client_id, company_id, group_code, group_name, applicable_on, sort_order)
    VALUES (p_client_id, p_company_id, 'VAT_ZERO_GRP', v_zero_group_name, 'BOTH', 2)
    ON CONFLICT (client_id, company_id, group_code) DO NOTHING;
    SELECT id INTO v_zero_group_id FROM rim_tax_groups WHERE client_id = p_client_id AND company_id = p_company_id AND group_code = 'VAT_ZERO_GRP';

    INSERT INTO rim_tax_group_members (client_id, company_id, tax_group_id, tax_id, sequence_no)
    VALUES (p_client_id, p_company_id, v_zero_group_id, v_zero_tax_id, 1)
    ON CONFLICT (client_id, company_id, tax_group_id, tax_id) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_seed_default_tax_setup(UUID, UUID, TEXT) TO authenticated;
