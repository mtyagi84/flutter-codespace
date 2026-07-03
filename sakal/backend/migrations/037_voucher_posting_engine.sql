-- ============================================================
-- Migration 037: Shared Voucher Posting Engine + gap fixes
-- ============================================================
-- Third of four foundational migrations before GRN (035-038).
--
-- fn_post_voucher is the one entry point every future auto-posting module
-- (GRN, later Purchase Invoice / Sales Invoice / Payment auto-postings)
-- calls — nobody writes to rih_finance_headers/rid_finance_lines directly.
-- It is a thin wrapper composing the EXISTING, already-tested
-- fn_save_finance_voucher + fn_post_finance_voucher (021) — their
-- INSERT/UPDATE branches are NOT touched, so manual voucher entry has zero
-- regression risk from this migration.
--
-- Two real gaps found during design review are also fixed here, in
-- fn_post_finance_voucher itself (CREATE OR REPLACE, additive only):
--   1. Nothing today validates a voucher's trans_date against an open
--      financial year / period lock — even for manual entry.
--   2. Nothing today validates that a line's account has posting_allowed
--      = true — a voucher could post to a non-leaf/group account.
--
-- Objects:
--   rih_finance_headers          → ALTER: + source_doc_type/no/date, posting_source
--   fn_post_finance_voucher      → CREATE OR REPLACE: + period check, + posting_allowed check
--   fn_post_voucher(...)         → new shared entry point
-- ============================================================

-- ── rih_finance_headers — traceability + auto-vs-manual marker ──────────────
ALTER TABLE rih_finance_headers
    ADD COLUMN IF NOT EXISTS source_doc_type TEXT,
    ADD COLUMN IF NOT EXISTS source_doc_no   TEXT,
    ADD COLUMN IF NOT EXISTS source_doc_date DATE,
    ADD COLUMN IF NOT EXISTS posting_source  TEXT NOT NULL DEFAULT 'MANUAL'
        CHECK (posting_source IN ('MANUAL', 'AUTO'));

CREATE INDEX IF NOT EXISTS idx_finance_headers_source
    ON rih_finance_headers (source_doc_type, source_doc_no, source_doc_date);

-- ── fn_post_finance_voucher — additive gap fixes ─────────────────────────────
-- Identical to the 021 version except for the two blocks marked "NEW" below.
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

    -- NEW: period/FY check — closes the gap where nothing validated trans_date
    -- against an open financial year or an active period lock, even manually.
    PERFORM fn_check_period_open(p_company_id, p_trans_date);

    -- NEW: every line must post to a leaf account (posting_allowed = true) —
    -- closes the gap where posting to a group/non-postable account had no error.
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

    -- Validate DR = CR (allow 0.01 rounding tolerance)
    SELECT abs(sum(
        CASE WHEN trans_nature = 'DR' THEN trans_amount ELSE -trans_amount END
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
            -- cheque_date NOT NULL in schema; fall back to trans_date if user omitted it
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
            -- Original invoice line: inv_bill_no = invoice trans_no,
            --                        inv_bill_date = invoice trans_date
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

            -- Update running settled_amount on the original invoice line
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

-- ── fn_post_voucher — the shared entry point every future auto-posting module calls ──
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
    v_header      jsonb;
    v_trans_no    text;
    v_imbalance   numeric;
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

    v_header := jsonb_build_object(
        'client_id',          p_client_id,
        'company_id',         p_company_id,
        'location_id',        p_location_id,
        'trans_no',           NULL,
        'trans_date',         p_trans_date,
        'voucher_type_code',  p_voucher_type_code,
        'is_on_account',      true
    );

    v_trans_no := fn_save_finance_voucher(v_header, p_lines, p_user_id);

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
