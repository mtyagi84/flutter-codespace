-- ============================================================
-- 113_finance_voucher_prv_branch_restore.sql
--
-- URGENT correctness fix: migration 111 (this same session, already
-- shipped as e09d3f8) reproduced fn_post_finance_voucher's body from
-- migration 108's own definition to add the source_doc_type IS NULL
-- guard — but 108 was NOT the latest definition. Migration 109 had
-- ALREADY extended this same function with a third branch:
--     ELSIF v_header.voucher_type_code IN ('CRV','BRV','CPV','BPV') THEN
--         PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-PRV');
-- 111's CREATE OR REPLACE, built from the stale (108) body, silently
-- DROPPED this branch. Since 111 shipped, posting/approving ANY Payment
-- or Receipt Voucher (CRV/BRV/CPV/BPV) has performed NO server-side
-- approve-permission check at all — the exact security gap 109 was
-- built to close, silently reopened by 111's own incomplete base.
--
-- Root cause, for the record: "read the CURRENT complete body before
-- CREATE OR REPLACE" was followed, but the definition was read from the
-- wrong migration file (108, not 109) — grepping for the LAST file that
-- touches a function (see feedback_check_latest_function_signature) was
-- skipped for fn_post_finance_voucher specifically, because 111 was
-- built as a reactive same-session fix under time pressure rather than
-- through the normal "grep every migration for the current definition"
-- discipline used everywhere else this session.
--
-- Fix: reproduce the COMPLETE, correct body from migration 109 (its own
-- live definition, confirmed via grep as the latest before this file)
-- verbatim, restoring the CRV/BRV/CPV/BPV branch. While already touching
-- every branch, proactively extend the same "AND v_header.source_doc_type
-- IS NULL" guard from 111 to the CRV/BRV/CPV/BPV branch too — migration
-- 114 (Sales approve-permission rollout, next) needs this: Sales
-- Invoice's own fn_approve_sales_invoice composes a CRV settlement
-- voucher directly via fn_save_finance_voucher + fn_post_finance_voucher
-- (never through fn_post_voucher) whenever a cash sale collects payment
-- immediately. Without this guard, approving a cash Sales Invoice would
-- silently ALSO require the approver to hold unrelated Payment/Receipt
-- Voucher (FN-PRV) permission — the identical bug class already fixed
-- twice this session (GRN/JV in 111, Stock Count Review/Stock Adjustment
-- proactively in 112). Migration 114 tags that composed voucher's header
-- with source_doc_type='SALES_INVOICE' (mirroring fn_post_voucher's own
-- convention, and adding real traceability that voucher never had) so
-- this guard correctly exempts it while still requiring FN-PRV for any
-- voucher entered directly via the Payment/Receipt Voucher screen
-- (source_doc_type stays NULL there, same as JV/CTR's own direct-entry
-- case).
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

    -- RESTORED (113): the CRV/BRV/CPV/BPV branch, dropped by migration
    -- 111's incomplete base. All three branches now additionally gated
    -- "AND v_header.source_doc_type IS NULL" — see this migration's own
    -- header comment for the full reasoning (proactive extension ahead
    -- of migration 114's Sales Invoice composition).
    IF v_header.voucher_type_code = 'JV' AND v_header.source_doc_type IS NULL THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-JRN');
    ELSIF v_header.voucher_type_code = 'CTR' AND v_header.source_doc_type IS NULL THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-CTR');
    ELSIF v_header.voucher_type_code IN ('CRV', 'BRV', 'CPV', 'BPV') AND v_header.source_doc_type IS NULL THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-PRV');
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
