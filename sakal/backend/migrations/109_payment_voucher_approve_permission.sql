-- ============================================================
-- 109_payment_voucher_approve_permission.sql
--
-- Follow-up to migration 108. That migration deliberately left
-- Payment/Receipt Voucher (CRV/BRV/CPV/BPV, finance_voucher_entry_screen.dart)
-- out of the new fn_check_approve_permission wiring, because grepping the
-- backend found no seeded feature_code/screen_name row for it anywhere.
--
-- The user confirmed the row DOES exist in their live database — it was
-- created manually, outside of any migration, which is why grepping
-- backend/migrations and backend/functions never found it:
--   feature_code='FN-PRV', feature_name='Payment/Receipt Voucher',
--   screen_name='/finance/voucher-list' (matches RouteNames.voucherList).
--
-- This migration:
-- 1. Backfills FN-PRV for any OTHER existing company that doesn't already
--    have it (ON CONFLICT DO UPDATE only touches group columns, same
--    shape as migration 107's own FN-EXP backfill — never overwrites the
--    user's existing feature_name/screen_name/serial_no for their company).
-- 2. Extends fn_post_finance_voucher and fn_reverse_voucher (both already
--    modified once in 108) to map CRV/BRV/CPV/BPV -> FN-PRV, closing the
--    gap 108 deliberately left open.
--
-- fn_seed_client_modules.sql (backend/functions/, not a numbered
-- migration — re-run directly, not run-once) is updated in the same
-- commit so brand-new companies get FN-PRV automatically going forward.
-- ============================================================

-- ── Backfill for existing companies ─────────────────────────────────────
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'FN-PRV', 'Payment/Receipt Voucher', '/finance/voucher-list',
    4, 'FN-TXN', 'Transactions', 0,
    true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'FN'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;

-- ════════════════════════════════════════════════════════════════════
-- fn_post_finance_voucher — full body reproduced verbatim from migration
-- 108 (its current live definition); only the new ELSIF branch for
-- CRV/BRV/CPV/BPV is new.
-- ════════════════════════════════════════════════════════════════════
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

    -- Server-side re-check of approve permission, resolved from the JWT
    -- (never the p_posted_by parameter) — see migration 108's own header
    -- comment for the full reasoning. FN-PRV covers Payment/Receipt
    -- Voucher (CRV/BRV/CPV/BPV) — added in 109 once its real feature_code
    -- was confirmed to exist (manually created, not seeded by any migration).
    IF v_header.voucher_type_code = 'JV' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-JRN');
    ELSIF v_header.voucher_type_code = 'CTR' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-CTR');
    ELSIF v_header.voucher_type_code IN ('CRV', 'BRV', 'CPV', 'BPV') THEN
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

-- ════════════════════════════════════════════════════════════════════
-- fn_reverse_voucher — full body reproduced verbatim from migration 108
-- (its current live definition); only the new ELSIF branch for
-- CRV/BRV/CPV/BPV is new.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_reverse_voucher(
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

    -- Server-side re-check of approve permission, resolved from the JWT
    -- (never the p_user_id parameter) — see migration 108's own header
    -- comment. Expense Voucher's own posted GL entry carries
    -- voucher_type_code 'EXP' (the posting code, not 'EXV' the
    -- document-numbering code). FN-PRV added in 109 for CRV/BRV/CPV/BPV.
    IF v_header.voucher_type_code = 'JV' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-JRN');
    ELSIF v_header.voucher_type_code = 'CTR' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-CTR');
    ELSIF v_header.voucher_type_code = 'EXP' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-EXP');
    ELSIF v_header.voucher_type_code IN ('CRV', 'BRV', 'CPV', 'BPV') THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-PRV');
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
        -- a reversal is a pure GL correction, never a new bill.
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'serial_no',      v_serial,
            'account_id',     v_line.account_id,
            'trans_nature',   CASE WHEN v_line.trans_nature = 'DR' THEN 'CR' ELSE 'DR' END,
            'trans_amount',   v_line.trans_amount,  'trans_currency', v_line.trans_currency,
            'base_amount',    v_line.base_amount,   'base_rate',      v_line.base_rate,
            'local_amount',   v_line.local_amount,  'local_rate',     v_line.local_rate,
            'party_amount',   v_line.party_amount,  'party_currency', v_line.party_currency,
            'party_rate',     v_line.party_rate,
            'line_remarks',   'Reversal of ' || p_trans_no
        ));
    END LOOP;

    v_new_trans_no := fn_save_finance_voucher(
        jsonb_build_object(
            'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
            'trans_no', null, 'trans_date', CURRENT_DATE,
            'voucher_type_code', v_header.voucher_type_code, 'is_on_account', v_header.is_on_account,
            'reversal_of_trans_no', p_trans_no,
            'remarks', 'Reversal of ' || p_trans_no
        ),
        v_lines,
        p_user_id
    );

    PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_new_trans_no, CURRENT_DATE, p_user_id);

    RETURN v_new_trans_no;
END;
$$;
