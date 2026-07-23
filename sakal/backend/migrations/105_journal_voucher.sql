-- ============================================================
-- Migration 105: Journal Voucher (Finance)
-- ============================================================
-- Plan written first in sakal/docs/screens/journal_voucher.md — read
-- that for the full requirement doc. This migration builds it as
-- designed there.
--
-- No new tables — a Journal Voucher is just another voucher_type_code
-- ('JV', already seeded 035_period_close_backdated_control.sql:179)
-- row in the EXISTING rih_finance_headers/rid_finance_lines, posted
-- through the EXISTING fn_save_finance_voucher/fn_post_finance_voucher
-- (050/058) with zero changes to either — confirmed by re-reading both:
-- neither has any special-casing of serial_no=1 as a cash/bank line,
-- and the DR=CR balance check already sums base_amount (multi-currency
-- safe). All bill-linkage/Cash-Bank-exclusion/multi-column-picker logic
-- lives entirely in the Flutter screen's own payload construction —
-- never in these shared functions, which every other voucher type and
-- every auto-posting module also calls.
--
-- Two real backend pieces in this migration:
--   1. fn_check_backdate_allowed gets a new p_reference_date param —
--      fixes a real bug (compares against CURRENT_DATE at Approve time,
--      not the document's own creation date, so a same-day-created
--      draft approved a day later can falsely trip as backdated).
--      Backward compatible via DEFAULT — but per this project's own
--      documented gotcha (CLAUDE.md "Migration idempotency" section),
--      appending a parameter via plain CREATE OR REPLACE does NOT
--      replace the old signature, it silently creates a second
--      overload. Explicit DROP FUNCTION first, same fix pattern
--      already used once for fn_compute_stock_count_variance/
--      fn_post_stock_movement in migration 080.
--   2. fn_reverse_journal_voucher (new) — one-click reversal of an
--      APPROVED JV, first real consumer of the dormant
--      reversal_of_trans_no column. Deliberately simple scope: flips
--      every line's Dr/Cr, posts is_on_account=true (a pure GL
--      correction), does NOT propagate inv_bill_no on any line — if
--      the original JV created or settled a bill (§7 of the plan), the
--      reversal does not attempt to auto-undo that bill-linkage effect.
--      Getting a partial/incorrect auto-reversal of bill settlement
--      wrong would be worse than a documented, simple limitation; a
--      bill-related correction is a deliberate separate follow-up
--      action for the user to take, not something inferred silently.
-- ============================================================


-- ── fn_check_backdate_allowed — new p_reference_date param ──────────────
-- Explicit DROP first: the old 4-arg signature must not survive as a
-- silent duplicate overload alongside the new 5-arg one.
DROP FUNCTION IF EXISTS fn_check_backdate_allowed(UUID, UUID, TEXT, DATE);

CREATE OR REPLACE FUNCTION fn_check_backdate_allowed(
    p_client_id        UUID,
    p_company_id       UUID,
    p_transaction_type TEXT,
    p_trans_date       DATE,
    p_reference_date   DATE DEFAULT CURRENT_DATE
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_ctrl ric_backdated_entry_control%ROWTYPE;
BEGIN
    SELECT * INTO v_ctrl FROM ric_backdated_entry_control
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND transaction_type = p_transaction_type AND is_active = true;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Future-date check is unaffected by the reference-date fix — "is this
    -- date in the future" is always relative to real-world today, not the
    -- document's own creation date, so this deliberately keeps using
    -- CURRENT_DATE regardless of what p_reference_date was passed.
    IF NOT v_ctrl.allow_future_date AND p_trans_date > current_date THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('%s transactions cannot be dated in the future.', p_transaction_type);
    END IF;

    -- Backdate check: "how many days in the past is this" is measured
    -- from the caller-supplied reference date (the document's own
    -- created_at, when the caller has one), defaulting to CURRENT_DATE
    -- for every existing call site that doesn't pass this new param —
    -- zero behavior change for them.
    IF v_ctrl.max_backdate_days IS NOT NULL
       AND p_trans_date < (p_reference_date - v_ctrl.max_backdate_days) THEN
        RAISE EXCEPTION 'BACKDATE_NOT_ALLOWED'
            USING DETAIL = format('%s transactions cannot be dated more than %s day(s) back.',
                                   p_transaction_type, v_ctrl.max_backdate_days);
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_check_backdate_allowed(UUID, UUID, TEXT, DATE, DATE) TO authenticated;


-- ── fn_post_finance_voucher — now calls the backdate check with the ─────
-- voucher's own created_at as the reference date. This one change fixes
-- the "saved today, approved tomorrow" false-positive for all five
-- manually-entered voucher types (CRV/BRV/CPV/BPV/JV) at once, since
-- they all post through this same function. Signature is UNCHANGED
-- (still 6 params) so a plain CREATE OR REPLACE is safe here — no DROP
-- needed, per this project's own "safe when signature unchanged" rule.
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

    -- NEW: backdate check, reference-dated to when this voucher was
    -- actually created — never blocks approving a same-day-created
    -- voucher just because "today" moved on since it was saved.
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'FINANCE_VOUCHER', p_trans_date, v_header.created_at::date);

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


-- ── fn_reverse_journal_voucher — one-click reversal ──────────────────────
-- Only consumer of rih_finance_headers.reversal_of_trans_no to date
-- (column has existed, dormant, since 019_finance_vouchers.sql).
-- Posted at CURRENT_DATE (when the correction is actually being made),
-- not the original voucher's own date — matches this app's convention
-- elsewhere of dating a correction at the time of the correction, not
-- backdating it to match what it corrects.
CREATE OR REPLACE FUNCTION fn_reverse_journal_voucher(
    p_client_id   UUID,
    p_company_id  UUID,
    p_trans_no    TEXT,
    p_trans_date  DATE,
    p_user_id     UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_header       rih_finance_headers%ROWTYPE;
    v_line         rid_finance_lines%ROWTYPE;
    v_lines        JSONB := '[]'::jsonb;
    v_serial       INTEGER := 0;
    v_new_trans_no TEXT;
BEGIN
    SELECT * INTO v_header FROM rih_finance_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND trans_no = p_trans_no AND trans_date = p_trans_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher % dated % not found', p_trans_no, p_trans_date;
    END IF;
    IF NOT v_header.is_posted THEN
        RAISE EXCEPTION 'NOT_POSTED' USING DETAIL = 'Only a posted voucher can be reversed.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM rih_finance_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND reversal_of_trans_no = p_trans_no AND is_deleted = false
    ) THEN
        RAISE EXCEPTION 'ALREADY_REVERSED'
            USING DETAIL = format('Voucher %s has already been reversed.', p_trans_no);
    END IF;

    PERFORM fn_check_period_open(p_company_id, CURRENT_DATE);

    FOR v_line IN
        SELECT * FROM rid_finance_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND trans_no = p_trans_no AND trans_date = p_trans_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        v_serial := v_serial + 1;
        -- Deliberately NOT carrying inv_bill_no/inv_bill_date forward —
        -- see migration header comment. This is a pure GL correction.
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'serial_no',      v_serial,
            'account_id',     v_line.account_id,
            'trans_nature',   CASE WHEN v_line.trans_nature = 'DR' THEN 'CR' ELSE 'DR' END,
            'trans_amount',   v_line.trans_amount,  'trans_currency', v_line.trans_currency,
            'base_amount',    v_line.base_amount,   'base_rate',      v_line.base_rate,
            'local_amount',   v_line.local_amount,  'local_rate',     v_line.local_rate,
            'party_amount',   v_line.party_amount,  'party_currency', v_line.party_currency, 'party_rate', v_line.party_rate,
            'line_remarks',   v_line.line_remarks
        ));
    END LOOP;

    IF jsonb_array_length(v_lines) = 0 THEN
        RAISE EXCEPTION 'Voucher % has no lines to reverse.', p_trans_no;
    END IF;

    v_new_trans_no := fn_save_finance_voucher(
        jsonb_build_object(
            'client_id',         p_client_id,
            'company_id',        p_company_id,
            'location_id',       v_header.location_id,
            'trans_no',          NULL,
            'trans_date',        CURRENT_DATE,
            'voucher_type_code', v_header.voucher_type_code,
            'is_on_account',     true,
            'remarks',           format('Reversal of %s dated %s', p_trans_no, p_trans_date)
        ),
        v_lines,
        p_user_id
    );

    PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_new_trans_no, CURRENT_DATE, p_user_id);

    UPDATE rih_finance_headers SET
        reversal_of_trans_no = p_trans_no,
        updated_at = now(), updated_by = p_user_id
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND trans_no = v_new_trans_no AND trans_date = CURRENT_DATE;

    RETURN v_new_trans_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_reverse_journal_voucher(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
