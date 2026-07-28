-- ============================================================
-- 111_finance_voucher_auto_post_permission_fix.sql
--
-- Real regression found live while building/testing migration 110
-- (Purchase-module approve-permission rollout): fn_post_finance_voucher
-- (migration 108) added
--   IF v_header.voucher_type_code = 'JV' THEN
--       PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-JRN');
--   ELSIF v_header.voucher_type_code = 'CTR' THEN
--       PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-CTR');
--   END IF;
-- unconditionally — with no way to distinguish a human directly approving
-- a hand-entered Journal/Contra Voucher from an AUTO-posted 'JV' voucher
-- triggered internally by another module's own approve function.
--
-- fn_approve_grn posts its GR/IR accrual via
--   fn_post_voucher(..., 'JV', ..., 'GRN', p_grn_no, p_grn_date, ...)
-- and fn_approve_purchase_return posts its unbilled-GRN reversal the same
-- way with source_doc_type='PURCHASE_RETURN'. fn_post_voucher composes
-- fn_save_finance_voucher + fn_post_finance_voucher (037/047/048/058) — so
-- BOTH of these already call straight into the now-JWT-gated
-- fn_post_finance_voucher. Since migration 108 shipped, approving a GRN or
-- an unbilled Purchase Return has silently ALSO required the acting user
-- to hold Journal Voucher (FN-JRN) approve permission — a pure internal
-- implementation detail (which voucher_type_code the accrual happens to
-- post under) leaking into an unrelated module's own permission model.
-- Caught live via migration 110's own pgTAP suite: a user granted PR-GRN
-- (but not FN-JRN, correctly — GRN approval has nothing to do with the
-- Journal Voucher screen) failed to approve a GRN, silently, inside the
-- test's own EXCEPTION WHEN OTHERS handler.
--
-- Fix: fn_post_voucher already stamps source_doc_type ('GRN',
-- 'PURCHASE_RETURN', ...) onto the header BEFORE calling
-- fn_post_finance_voucher (see 058's fn_post_voucher body) — so
-- fn_post_finance_voucher can tell the two cases apart. A voucher entered
-- directly via the Journal/Contra Voucher screen never sets
-- source_doc_type (fn_save_finance_voucher is called directly there, with
-- no source_doc_type key in the header payload), so
-- v_header.source_doc_type IS NULL reliably means "a human is approving
-- this JV/CTR directly" — the only case where FN-JRN/FN-CTR should be
-- checked here at all. An auto-posted voucher's OWN calling module
-- (fn_approve_grn -> PR-GRN, fn_approve_purchase_return -> PR-RET, etc.)
-- already enforces its own permission check before ever reaching
-- fn_post_voucher, so no coverage is lost — this removes a redundant,
-- wrongly-scoped second check, not the only check.
--
-- New migration, not an edit to 108 — that migration is already run/
-- shipped (pushed 00a9d82). Reproducing fn_post_finance_voucher's complete
-- current body verbatim (as it stands after 108), with ONLY the IF
-- condition changed to add "AND v_header.source_doc_type IS NULL".
-- ============================================================

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

    -- FIX (111): only re-check FN-JRN/FN-CTR approve permission when this
    -- voucher was entered DIRECTLY via the Journal/Contra Voucher screen
    -- (source_doc_type IS NULL in that case — fn_save_finance_voucher is
    -- called with no source_doc_type key). A voucher auto-posted by another
    -- module (fn_post_voucher always stamps source_doc_type = 'GRN' /
    -- 'PURCHASE_RETURN' / etc. before calling this function) is already
    -- gated by that module's OWN approve-permission check one level up
    -- (PR-GRN, PR-RET, ...) — checking FN-JRN/FN-CTR again here as well
    -- was a real regression: it silently required a GRN/Purchase Return
    -- approver to ALSO hold unrelated Journal Voucher permission, purely
    -- because the accrual happens to post under voucher_type_code='JV'.
    IF v_header.voucher_type_code = 'JV' AND v_header.source_doc_type IS NULL THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-JRN');
    ELSIF v_header.voucher_type_code = 'CTR' AND v_header.source_doc_type IS NULL THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-CTR');
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_trans_date);

    -- Backdate check, reference-dated to when this voucher was actually
    -- created — never blocks approving a same-day-created voucher just
    -- because "today" moved on since it was saved.
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
