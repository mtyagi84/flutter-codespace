-- ============================================================
-- Migration 058: Voucher DR=CR balance check must sum base_amount,
-- not trans_amount
-- ============================================================
-- Found while running the Purchase Bill pgTAP test (054/055): Scenario B's
-- Exchange Gain/Loss line is deliberately posted in the company's BASE
-- currency (v_base_ccy) while every other line of the same voucher
-- (Accrual clearing, Input VAT, Supplier) is posted in the bill's own
-- invoice currency (e.g. EUR) — a genuinely mixed-currency voucher. Both
-- fn_post_voucher's pre-check and fn_post_finance_voucher's authoritative
-- check summed raw trans_amount across ALL lines regardless of each line's
-- own trans_currency — meaningless once two different currencies are mixed
-- in one voucher, since e.g. "200 EUR debit" and "40 USD debit" were being
-- added together as if they were the same unit. Real double-entry balance
-- is a statement about the company's books, which are kept in ONE currency
-- (base) — trans_currency/local_currency/party_currency are supplementary
-- tracking columns, not the system of record for whether a voucher
-- balances. base_amount is the one column guaranteed to be in a single
-- common currency across every line of a voucher, regardless of what
-- trans_currency each individual line uses — so it's the only column that
-- can correctly validate DR=CR when a voucher's lines span currencies.
--
-- This was invisible until now because every existing caller (manually-
-- entered Payment/Receipt/Journal vouchers, and GRN's own posting) happens
-- to keep every line of a voucher in the SAME trans_currency, so
-- trans_amount and base_amount summed to the same pass/fail result by
-- coincidence. Purchase Bill's Exchange Gain/Loss line is the first
-- deliberately mixed-currency voucher line in the codebase.
--
-- fn_save_finance_voucher does NOT perform a balance check at all (DRAFT
-- saves don't need to balance, only Approve/Post) — confirmed by reading
-- its current (050) definition — so only these two functions need fixing.
--
-- New migration, not edits to 037/048 — either may already be deployed.
-- ============================================================

-- ── fn_post_finance_voucher — authoritative check at Post time ──────────────
CREATE OR REPLACE FUNCTION fn_post_finance_voucher(
    p_client_id   uuid,
    p_company_id  uuid,
    p_location_id uuid,
    p_trans_no    text,
    p_trans_date  date,
    p_posted_by   uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_header        rih_finance_headers%rowtype;
    v_line          rid_finance_lines%rowtype;
    v_imbalance     numeric;
    v_was_balance   numeric;
    v_settle_no     integer;
    v_bad_account   text;
BEGIN
    -- Lock and load using composite key
    SELECT * INTO v_header FROM rih_finance_headers
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND trans_no    = p_trans_no
      AND trans_date  = p_trans_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher % dated % not found', p_trans_no, p_trans_date;
    END IF;

    IF v_header.is_posted THEN
        RAISE EXCEPTION 'Voucher % is already posted', p_trans_no;
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_trans_date);

    SELECT a.account_code INTO v_bad_account
    FROM rid_finance_lines l
    JOIN rim_accounts a ON a.id = l.account_id
    WHERE l.client_id   = p_client_id
      AND l.company_id  = p_company_id
      AND l.location_id = p_location_id
      AND l.trans_no    = p_trans_no
      AND l.trans_date  = p_trans_date
      AND l.is_deleted  = false
      AND a.posting_allowed = false
    LIMIT 1;

    IF v_bad_account IS NOT NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_POSTABLE'
            USING DETAIL = format('Account %s is a group/header account and cannot receive postings.', v_bad_account);
    END IF;

    -- FIX (058): balance on base_amount, not trans_amount — the only column
    -- guaranteed to be in one common currency across every line of a
    -- voucher, regardless of each line's own trans_currency.
    SELECT abs(sum(
        CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END
    ))
    INTO v_imbalance
    FROM rid_finance_lines
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND trans_no    = p_trans_no
      AND trans_date  = p_trans_date
      AND is_deleted  = false;

    IF coalesce(v_imbalance, 0) > 0.01 THEN
        RAISE EXCEPTION
            'Voucher % is not balanced — DR and CR totals do not match (difference: %)',
            p_trans_no, v_imbalance;
    END IF;

    -- Mark as posted
    UPDATE rih_finance_headers SET
        is_posted  = true,
        posted_at  = now(),
        posted_by  = p_posted_by,
        updated_at = now(),
        updated_by = p_posted_by
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND trans_no    = p_trans_no
      AND trans_date  = p_trans_date;

    -- Cheque register entry
    IF v_header.cheque_no IS NOT NULL THEN
        INSERT INTO rid_cheque_register (
            client_id, company_id, location_id,
            trans_no, trans_date,
            cheque_no, cheque_date,
            cheque_status, created_by, updated_by
        ) VALUES (
            p_client_id, p_company_id, p_location_id,
            p_trans_no, p_trans_date,
            v_header.cheque_no,
            COALESCE(v_header.cheque_date, v_header.trans_date),
            'ISSUED', p_posted_by, p_posted_by
        )
        ON CONFLICT DO NOTHING;
    END IF;

    -- Settlement records: Against Bill vouchers only
    IF NOT v_header.is_on_account THEN
        FOR v_line IN
            SELECT * FROM rid_finance_lines
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND trans_no    = p_trans_no
              AND trans_date  = p_trans_date
              AND is_deleted  = false
              AND inv_bill_no IS NOT NULL
        LOOP
            SELECT coalesce(party_amount - settled_amount, 0)
            INTO v_was_balance
            FROM rid_finance_lines
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND trans_no    = v_line.inv_bill_no
              AND trans_date  = v_line.inv_bill_date
              AND account_id  = v_line.account_id
              AND is_deleted  = false
            LIMIT 1;

            SELECT coalesce(max(settlement_no), 0) + 1
            INTO v_settle_no
            FROM rid_invoice_bill_settlement
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND account_id  = v_line.account_id
              AND inv_bill_no = v_line.inv_bill_no
              AND is_deleted  = false;

            INSERT INTO rid_invoice_bill_settlement (
                client_id, company_id, location_id,
                trans_no, trans_date, voucher_type_code,
                account_id, inv_bill_no, inv_bill_date,
                settlement_no, was_balance, paid_amount, paid_amount_trans,
                created_by, updated_by
            ) VALUES (
                p_client_id, p_company_id, p_location_id,
                p_trans_no, p_trans_date, v_header.voucher_type_code,
                v_line.account_id, v_line.inv_bill_no, v_line.inv_bill_date,
                v_settle_no,
                coalesce(v_was_balance, 0),
                v_line.party_amount,
                v_line.trans_amount,
                p_posted_by, p_posted_by
            );

            UPDATE rid_finance_lines SET
                settled_amount = settled_amount + v_line.party_amount,
                updated_at     = now(),
                updated_by     = p_posted_by
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND trans_no    = v_line.inv_bill_no
              AND trans_date  = v_line.inv_bill_date
              AND account_id  = v_line.account_id
              AND is_deleted  = false;
        END LOOP;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_post_finance_voucher(UUID, UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── fn_post_voucher — earlier, clearer pre-check for auto-posting callers ───
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

    -- FIX (058): balance on base_amount, not trans_amount — see
    -- fn_post_finance_voucher's own fix in this same migration for the full
    -- reasoning (a voucher's lines can legitimately span currencies, e.g.
    -- Purchase Bill's Exchange Gain/Loss line posts in base currency while
    -- every other line posts in the bill's own currency).
    SELECT abs(sum(
        CASE WHEN (l->>'trans_nature') = 'DR' THEN (l->>'base_amount')::numeric
             ELSE -(l->>'base_amount')::numeric END
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
