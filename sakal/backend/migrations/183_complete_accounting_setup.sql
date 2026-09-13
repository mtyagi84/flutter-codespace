-- ============================================================
-- Migration 183: fn_complete_accounting_setup — one RPC for the whole
-- Accounting Setup flow (COA + default leaf accounts/links + default tax
-- setup + first Financial Year)
-- ============================================================
-- Part of the "new-tenant bare-minimum starter kit" initiative. Today
-- this whole flow is 3 separate Dio calls hand-rolled inside
-- accounting_setup_screen.dart's _save()/_createFirstFY() (a rim_
-- accounting_setup POST, an fn_seed_chart_of_accounts RPC, an
-- rim_financial_years POST) -- and it only ever runs as a SEPARATE,
-- later, manual step after registration. The user asked for Financial
-- Year start date (and, by extension, the whole accounting setup) to be
-- asked in the registration WIZARD itself.
--
-- This function is that whole flow, callable in ONE RPC, reusable from
-- BOTH places:
--   - The registration wizard (register_screen.dart), called right after
--     fn_register_client, in the SAME pre-login flow -- this function is
--     SECURITY DEFINER for exactly the same reason fn_register_client
--     itself is: the caller has no JWT/session yet at that point, so RLS
--     (which reads client_id/company_id from request.jwt.claims) would
--     otherwise block every INSERT.
--   - accounting_setup_screen.dart, kept as a fallback for any tenant
--     that skips the wizard step (or a pre-migration company that never
--     got it) -- unchanged from the caller's point of view except now a
--     single RPC replaces 3 separate calls.
--
-- Composes fn_seed_chart_of_accounts (013/180), the new
-- fn_seed_default_leaf_accounts_and_links (181), and the new
-- fn_seed_default_tax_setup (182) -- then creates the first Financial
-- Year using the exact same "if the FY start month is still ahead of
-- today, use last year's start" rule as _fyStartForYear() in
-- accounting_setup_screen.dart, reproduced in SQL so both call sites
-- compute an identical result.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_complete_accounting_setup(
    p_client_id       UUID,
    p_company_id      UUID,
    p_accounting_std  TEXT,
    p_fy_start_month  INTEGER,
    p_fy_start_day    INTEGER DEFAULT 1,
    p_user_id         UUID DEFAULT NULL
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_today       DATE := CURRENT_DATE;
    v_candidate   DATE;
    v_fy_start    DATE;
    v_fy_end      DATE;
    v_fy_name     TEXT;
    v_fy_id       UUID;
BEGIN
    IF EXISTS (
        SELECT 1 FROM rim_accounting_setup
        WHERE client_id = p_client_id AND company_id = p_company_id AND is_coa_seeded = true
    ) THEN
        RAISE EXCEPTION 'ACCOUNTING_ALREADY_SETUP'
            USING DETAIL = 'Chart of Accounts is already seeded for this company and cannot be changed.';
    END IF;

    INSERT INTO rim_accounting_setup (client_id, company_id, accounting_std, fy_start_month, fy_start_day, created_by, updated_by)
    VALUES (p_client_id, p_company_id, p_accounting_std, p_fy_start_month, p_fy_start_day, p_user_id, p_user_id)
    ON CONFLICT (client_id, company_id) DO UPDATE
        SET accounting_std = EXCLUDED.accounting_std,
            fy_start_month = EXCLUDED.fy_start_month,
            fy_start_day   = EXCLUDED.fy_start_day,
            updated_by     = EXCLUDED.updated_by,
            updated_at     = now();

    PERFORM fn_seed_chart_of_accounts(p_client_id, p_company_id, p_accounting_std);
    PERFORM fn_seed_default_leaf_accounts_and_links(p_client_id, p_company_id, p_accounting_std);
    PERFORM fn_seed_default_tax_setup(p_client_id, p_company_id, p_accounting_std);

    -- Same rule as accounting_setup_screen.dart's _fyStartForYear(): if
    -- this year's FY-start-month candidate is still in the future, the
    -- current, still-open FY actually started last year instead.
    v_candidate := make_date(EXTRACT(YEAR FROM v_today)::int, p_fy_start_month, p_fy_start_day);
    IF v_candidate > v_today THEN
        v_fy_start := make_date(EXTRACT(YEAR FROM v_today)::int - 1, p_fy_start_month, p_fy_start_day);
    ELSE
        v_fy_start := v_candidate;
    END IF;
    v_fy_end := (v_fy_start + INTERVAL '1 year' - INTERVAL '1 day')::date;

    v_fy_name := CASE
        WHEN EXTRACT(YEAR FROM v_fy_start) = EXTRACT(YEAR FROM v_fy_end)
            THEN 'FY ' || EXTRACT(YEAR FROM v_fy_start)::text
        ELSE 'FY ' || EXTRACT(YEAR FROM v_fy_start)::text || '-' || to_char(v_fy_end, 'YY')
    END;

    INSERT INTO rim_financial_years (client_id, company_id, fy_name, fy_start_date, fy_end_date, is_active, is_closed, created_by, updated_by)
    VALUES (p_client_id, p_company_id, v_fy_name, v_fy_start, v_fy_end, true, false, p_user_id, p_user_id)
    ON CONFLICT (client_id, company_id, fy_start_date) DO NOTHING;

    SELECT id INTO v_fy_id FROM rim_financial_years
    WHERE client_id = p_client_id AND company_id = p_company_id AND fy_start_date = v_fy_start;

    RETURN json_build_object(
        'accounting_std', p_accounting_std,
        'fy_id',          v_fy_id,
        'fy_name',        v_fy_name,
        'fy_start_date',  v_fy_start,
        'fy_end_date',    v_fy_end
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_complete_accounting_setup(UUID, UUID, TEXT, INTEGER, INTEGER, UUID) TO authenticated;
