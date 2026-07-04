-- ============================================================
-- Migration 047: fn_post_voucher — assign serial_no before insert
-- ============================================================
-- Bug reported live: approving a GRN failed with
-- "null value in column "serial_no" of relation "rid_finance_lines"
-- violates not-null constraint".
--
-- Root cause: fn_save_finance_voucher (021_composite_trans_key.sql) inserts
-- serial_no straight from the JSON payload with NO coalesce/default —
-- (v_line->>'serial_no')::integer — because manual voucher entry
-- (Finance Voucher screen) always assigns it client-side per line. But
-- fn_post_voucher's own line-object contract (its own comment: "[{account_id,
-- trans_nature, trans_amount, ...}, ...]") never included serial_no, and
-- every caller (fn_approve_grn today; future Purchase Invoice/Sales
-- Invoice/Payment auto-postings) builds lines from that contract. So this
-- was never a GRN-specific bug — every future auto-posting caller would hit
-- the identical NOT NULL violation the first time it exercised this path.
--
-- Fix belongs in the shared engine, not in every caller: fn_post_voucher
-- now assigns 1-based serial_no to each line (in array order) before handing
-- them to fn_save_finance_voucher, exactly like manual entry already does.
-- Callers' line objects are unchanged.
--
-- New migration, not an edit to 037 — 037 may already be deployed.
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

    -- NEW: fn_save_finance_voucher requires serial_no on every line with no
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

    UPDATE rih_finance_headers SET
        source_doc_type = p_source_doc_type,
        source_doc_no   = p_source_doc_no,
        source_doc_date = p_source_doc_date,
        posting_source  = 'AUTO'
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND trans_no    = v_trans_no
      AND trans_date  = p_trans_date;

    PERFORM fn_post_finance_voucher(p_client_id, p_company_id, p_location_id, v_trans_no, p_trans_date, p_user_id);

    RETURN QUERY SELECT v_trans_no, p_trans_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_post_voucher(UUID, UUID, UUID, TEXT, DATE, JSONB, TEXT, TEXT, DATE, UUID) TO authenticated;
