-- Migration 237: VAT/Tax Return Summary and Withholding Tax Summary both
-- returned a raw 404 on their group-summary RPC call, never loading.
--
-- Found live 2026-10-31 during the Phase 2 Finance Reports browser-E2E
-- pass: direct network capture showed the request
-- `/rpc/fn_vat_tax_summary_group_summary?p_trans_date_from=...&p_trans_date_to=...`
-- (and the same for `fn_wht_summary_group_summary`) returning HTTP 404.
--
-- Exact same root cause and fix shape as migration 233/234's Day Book
-- Register / Cheque Register incident: `ric_report_filters`'s `date_range`
-- filter has `param_target='trans_date'` (correct — both reports' MAIN
-- grid queries filter `v_vat_tax_lines`/`v_withholding_tax_lines` directly
-- by their own real `trans_date` column, confirmed via
-- information_schema), but each report's GROUP-SUMMARY function (migration
-- 165) declared its date parameters as plain `p_date_from`/`p_date_to`
-- instead of `p_trans_date_from`/`p_trans_date_to` — so PostgREST's
-- parameter-name matching for the group-summary RPC call fails silently
-- with a 404.
--
-- Fix (same shape as 234, NOT 233 — this is the Cheque Register case, not
-- the Day Book case): the filter's `param_target` stays `'trans_date'`
-- (changing it would break the main grid's working column-filter query,
-- exactly the mistake 233 made and 234 had to correct). Instead, rename
-- each function's own IN parameters to match what the filter actually
-- sends. Postgres disallows renaming an IN parameter via
-- `CREATE OR REPLACE` alone, so each function is dropped and recreated.

DROP FUNCTION IF EXISTS fn_vat_tax_summary_group_summary(uuid, uuid, date, date, uuid, uuid);

CREATE FUNCTION fn_vat_tax_summary_group_summary(
    p_client_id uuid, p_company_id uuid,
    p_trans_date_from date DEFAULT NULL::date, p_trans_date_to date DEFAULT NULL::date,
    p_tax_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid
) RETURNS TABLE(tax_id uuid, tax_code text, tax_name text, output_tax_amount numeric, input_tax_amount numeric, net_payable numeric, row_count bigint)
LANGUAGE sql STABLE
AS $$
    SELECT tax_id, MIN(tax_code), MIN(tax_name),
           COALESCE(SUM(output_tax_signed), 0), COALESCE(SUM(input_tax_signed), 0),
           COALESCE(SUM(output_tax_signed), 0) - COALESCE(SUM(input_tax_signed), 0),
           COUNT(*)
    FROM v_vat_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_tax_id          IS NULL OR tax_id = p_tax_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id)
    GROUP BY tax_id;
$$;
GRANT EXECUTE ON FUNCTION fn_vat_tax_summary_group_summary(uuid, uuid, date, date, uuid, uuid) TO authenticated;

DROP FUNCTION IF EXISTS fn_wht_summary_group_summary(uuid, uuid, date, date, uuid);

CREATE FUNCTION fn_wht_summary_group_summary(
    p_client_id uuid, p_company_id uuid,
    p_trans_date_from date DEFAULT NULL::date, p_trans_date_to date DEFAULT NULL::date,
    p_supplier_id uuid DEFAULT NULL::uuid
) RETURNS TABLE(supplier_id uuid, supplier_name text, gross_amount numeric, wht_amount numeric, row_count bigint)
LANGUAGE sql STABLE
AS $$
    SELECT supplier_id, MIN(supplier_name), COALESCE(SUM(gross_amount), 0), COALESCE(SUM(wht_amount), 0), COUNT(*)
    FROM v_withholding_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_supplier_id     IS NULL OR supplier_id = p_supplier_id)
    GROUP BY supplier_id;
$$;
GRANT EXECUTE ON FUNCTION fn_wht_summary_group_summary(uuid, uuid, date, date, uuid) TO authenticated;

-- Same bug, same fix, on each report's TOTALS function (totals_source_object)
-- — these are separate RPC calls from the group-summary ones above and were
-- found to carry the identical p_date_from/p_date_to naming defect.

DROP FUNCTION IF EXISTS fn_vat_tax_summary_totals(uuid, uuid, date, date, uuid, uuid);

CREATE FUNCTION fn_vat_tax_summary_totals(
    p_client_id uuid, p_company_id uuid,
    p_trans_date_from date DEFAULT NULL::date, p_trans_date_to date DEFAULT NULL::date,
    p_tax_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid
) RETURNS TABLE(output_tax_amount numeric, input_tax_amount numeric, net_payable numeric, row_count bigint)
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(output_tax_signed), 0), COALESCE(SUM(input_tax_signed), 0),
           COALESCE(SUM(output_tax_signed), 0) - COALESCE(SUM(input_tax_signed), 0), COUNT(*)
    FROM v_vat_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_tax_id          IS NULL OR tax_id = p_tax_id)
      AND (p_location_id     IS NULL OR location_id = p_location_id);
$$;
GRANT EXECUTE ON FUNCTION fn_vat_tax_summary_totals(uuid, uuid, date, date, uuid, uuid) TO authenticated;

DROP FUNCTION IF EXISTS fn_wht_summary_totals(uuid, uuid, date, date, uuid);

CREATE FUNCTION fn_wht_summary_totals(
    p_client_id uuid, p_company_id uuid,
    p_trans_date_from date DEFAULT NULL::date, p_trans_date_to date DEFAULT NULL::date,
    p_supplier_id uuid DEFAULT NULL::uuid
) RETURNS TABLE(gross_amount numeric, wht_amount numeric, row_count bigint)
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(gross_amount), 0), COALESCE(SUM(wht_amount), 0), COUNT(*)
    FROM v_withholding_tax_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_trans_date_from IS NULL OR trans_date >= p_trans_date_from)
      AND (p_trans_date_to   IS NULL OR trans_date <= p_trans_date_to)
      AND (p_supplier_id     IS NULL OR supplier_id = p_supplier_id);
$$;
GRANT EXECUTE ON FUNCTION fn_wht_summary_totals(uuid, uuid, date, date, uuid) TO authenticated;
