-- ============================================================
-- Migration 048: fn_post_voucher — qualify trans_no/trans_date
-- ============================================================
-- Bug reported live: approving a Direct GRN failed with "column reference
-- ... is ambiguous — It could refer to either a PL/pgSQL variable or a
-- table column." right after 047 fixed the earlier serial_no bug — this
-- one was always latent in fn_post_voucher (037), just masked because
-- execution never got past the serial_no NOT NULL error to reach it.
--
-- Root cause: fn_post_voucher declares RETURNS TABLE (trans_no text,
-- trans_date date) — those OUT-parameter names are implicitly PL/pgSQL
-- variables for the whole function body, exactly like DECLAREd variables.
-- Its own closing UPDATE statement then does:
--     UPDATE rih_finance_headers SET ...
--     WHERE ... AND trans_no = v_trans_no AND trans_date = p_trans_date;
-- rih_finance_headers has columns named trans_no/trans_date too, so the
-- bare references in the WHERE clause are genuinely ambiguous to Postgres
-- — it cannot tell whether "trans_no" means the OUT-parameter variable or
-- the table column.
--
-- Fix: qualify both with the table name. No other bare reference to
-- trans_no/trans_date exists elsewhere in the function body (checked) —
-- everywhere else already uses the v_/p_-prefixed local variables.
-- Audited every other RETURNS TABLE function in the backend for the same
-- footgun (012, 016, 024, 036) — none of them are PL/pgSQL functions with
-- a bare column reference matching an OUT-parameter name, so this was
-- isolated to fn_post_voucher.
--
-- New migration, not an edit to 037/047 — either may already be deployed.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_post_voucher(
    p_client_id       uuid,
    p_company_id      uuid,
    p_location_id     uuid,
    p_voucher_type_code text,
    p_trans_date      date,
    p_lines           jsonb,          -- [{account_id, trans_nature, trans_amount, trans_currency, base_amount, base_rate, local_amount, local_rate, party_amount, party_currency, party_rate, line_remarks}, ...]
    p_source_doc_type text,
    p_source_doc_no   text,
    p_source_doc_date date,
    p_user_id         uuid
)
RETURNS TABLE (trans_no text, trans_date date)
LANGUAGE plpgsql
AS $$
DECLARE
    v_header            jsonb;
    v_lines_with_serial jsonb;
    v_trans_no          text;
    v_imbalance         numeric;
BEGIN
    PERFORM fn_check_period_open(p_company_id, p_trans_date);

    -- Pre-check DR=CR here too, before the draft is even created — a clearer
    -- "posting imbalance from <source module>" error than one surfacing three
    -- calls deep inside fn_post_finance_voucher for a bug in the caller's math.
    SELECT abs(sum(
        CASE WHEN (l->>'trans_nature') = 'DR' THEN (l->>'trans_amount')::numeric
             ELSE -(l->>'trans_amount')::numeric END
    ))
    INTO v_imbalance
    FROM jsonb_array_elements(p_lines) AS l;

    IF coalesce(v_imbalance, 0) > 0.01 THEN
        RAISE EXCEPTION 'VOUCHER_POSTING_IMBALANCE'
            USING DETAIL = format('%s posting for %s dated %s is not balanced (difference: %s).',
                                   p_source_doc_type, p_source_doc_no, p_trans_date, v_imbalance);
    END IF;

    -- fn_save_finance_voucher requires serial_no on every line with no
    -- default (manual entry always supplies it) — assign it here, 1-based in
    -- array order, so every fn_post_voucher caller is insulated from that
    -- requirement.
    SELECT jsonb_agg(elem.value || jsonb_build_object('serial_no', elem.ordinality))
    INTO v_lines_with_serial
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS elem(value, ordinality);

    v_header := jsonb_build_object(
        'client_id',          p_client_id,
        'company_id',         p_company_id,
        'location_id',        p_location_id,
        'trans_no',           NULL,
        'trans_date',         p_trans_date,
        'voucher_type_code',  p_voucher_type_code,
        'is_on_account',      true
    );

    v_trans_no := fn_save_finance_voucher(v_header, v_lines_with_serial, p_user_id);

    -- NEW: qualified with the table name — trans_no/trans_date are also
    -- this function's OUT-parameter names (RETURNS TABLE above), so the
    -- bare column names here were ambiguous to Postgres.
    UPDATE rih_finance_headers SET
        source_doc_type = p_source_doc_type,
        source_doc_no   = p_source_doc_no,
        source_doc_date = p_source_doc_date,
        posting_source  = 'AUTO'
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND rih_finance_headers.trans_no   = v_trans_no
      AND rih_finance_headers.trans_date = p_trans_date;

    PERFORM fn_post_finance_voucher(p_client_id, p_company_id, p_location_id, v_trans_no, p_trans_date, p_user_id);

    RETURN QUERY SELECT v_trans_no, p_trans_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_post_voucher(UUID, UUID, UUID, TEXT, DATE, JSONB, TEXT, TEXT, DATE, UUID) TO authenticated;
