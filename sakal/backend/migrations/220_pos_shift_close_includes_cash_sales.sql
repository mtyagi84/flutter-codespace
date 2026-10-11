-- ============================================================================
-- Migration 220: shift-close expected-cash formula finally includes cash
-- sales — closes the "TODO once New Sale ships" gap (migration 206's
-- original comment), stale ever since New Sale actually shipped.
-- ============================================================================
-- Reproduced verbatim from migration 209 (the latest definition) per
-- CLAUDE.md's "Check Latest Function Signature" rule, with cash sales
-- folded into v_expected for each currency the shift touched:
--   - A non-split-tender cash sale has no rid_pos_tender_lines rows at
--     all; its own invoice_currency_id is always the company's LOCAL
--     currency (New Sale forces this for every cash sale), and
--     collected_amount_local already holds exactly what landed in the
--     drawer — counted once, only in the LOCAL-currency pass.
--   - A split-tender cash sale's CASH tender lines (rid_pos_tender_lines,
--     tender_type='CASH') carry their own native currency_id + amount —
--     counted once per currency, by that currency's own rows. A split-
--     tender sale's own collected_amount_local is deliberately NOT used
--     here (it's a local-currency-converted TOTAL across every tender
--     line regardless of currency — correct for the GL's own cash
--     settlement, wrong for a per-currency physical cash count).
-- Pure additive SELECT logic — no GL/voucher posting changed here at
-- all; this is purely the reconciliation formula.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_close_pos_shift(
    p_client_id       UUID,
    p_company_id      UUID,
    p_shift_id        UUID,
    p_closing_notes   TEXT,
    p_variance_reason TEXT,
    p_approved_by     UUID
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_shift   rih_pos_shifts%rowtype;
    v_row     RECORD;
    v_expected NUMERIC;
    v_counted  NUMERIC;
    v_variance NUMERIC;
    v_any_variance BOOLEAN := false;
    v_local_ccy TEXT; -- NEW (220)
    v_cash_sales NUMERIC; -- NEW (220)
BEGIN
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'POS-SHIFT');

    SELECT * INTO v_shift FROM rih_pos_shifts WHERE id = p_shift_id;
    IF v_shift.status <> 'OPEN' THEN
        RAISE EXCEPTION 'SHIFT_NOT_OPEN'
            USING DETAIL = 'This shift is already closed.';
    END IF;
    PERFORM fn_check_period_open(p_company_id, current_date);

    SELECT local_currency INTO v_local_ccy FROM ric_companies WHERE id = p_company_id; -- NEW (220)

    -- One pass per currency this shift ever touched (opening float, any
    -- movement, a closing count, OR a cash sale — NEW (220): the last of
    -- these was never included in this UNION before, so a shift with
    -- cash sales but no payouts/denomination count in some currency
    -- never even looped over it at all).
    FOR v_row IN
        SELECT currency_id FROM (
            SELECT currency_id FROM rih_pos_shift_opening_float WHERE shift_id = p_shift_id
            UNION
            SELECT currency_id FROM rih_pos_payouts WHERE shift_id = p_shift_id AND is_deleted = false
            UNION
            SELECT currency_id FROM rid_pos_shift_denomination_counts WHERE shift_id = p_shift_id AND count_stage = 'CLOSING'
            UNION
            SELECT t.currency_id FROM rid_pos_tender_lines t
            JOIN rih_sales_invoices si ON si.client_id = t.client_id AND si.company_id = t.company_id
              AND si.invoice_no = t.invoice_no AND si.invoice_date = t.invoice_date
            WHERE si.pos_shift_id = p_shift_id AND si.status = 'APPROVED' AND t.tender_type = 'CASH' AND t.is_deleted = false
            UNION
            SELECT v_local_ccy WHERE EXISTS (
                SELECT 1 FROM rih_sales_invoices si
                WHERE si.pos_shift_id = p_shift_id AND si.sale_type = 'CASH' AND si.status = 'APPROVED'
                  AND coalesce(si.collected_amount_local, 0) > 0
                  AND NOT EXISTS (
                      SELECT 1 FROM rid_pos_tender_lines t
                      WHERE t.client_id = si.client_id AND t.company_id = si.company_id
                        AND t.invoice_no = si.invoice_no AND t.invoice_date = si.invoice_date AND t.is_deleted = false
                  )
            )
        ) c
    LOOP
        SELECT coalesce(sum(opening_amount), 0) INTO v_expected
          FROM rih_pos_shift_opening_float WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id;

        v_expected := v_expected
            + (SELECT coalesce(sum(amount), 0) FROM rih_pos_payouts WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id AND direction = 'IN'  AND is_deleted = false)
            - (SELECT coalesce(sum(amount), 0) FROM rih_pos_payouts WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id AND direction = 'OUT' AND is_deleted = false);

        -- NEW (220): cash sales, this currency. Non-split sales (no
        -- tender lines) only ever contribute in the LOCAL currency;
        -- split-tender sales' own CASH tender lines contribute in
        -- whatever currency they were actually tendered in.
        v_cash_sales := 0;
        IF v_row.currency_id = v_local_ccy THEN
            v_cash_sales := v_cash_sales + coalesce((
                SELECT sum(si.collected_amount_local) FROM rih_sales_invoices si
                WHERE si.pos_shift_id = p_shift_id AND si.sale_type = 'CASH' AND si.status = 'APPROVED'
                  AND NOT EXISTS (
                      SELECT 1 FROM rid_pos_tender_lines t
                      WHERE t.client_id = si.client_id AND t.company_id = si.company_id
                        AND t.invoice_no = si.invoice_no AND t.invoice_date = si.invoice_date AND t.is_deleted = false
                  )
            ), 0);
        END IF;
        v_cash_sales := v_cash_sales + coalesce((
            SELECT sum(t.amount) FROM rid_pos_tender_lines t
            JOIN rih_sales_invoices si ON si.client_id = t.client_id AND si.company_id = t.company_id
              AND si.invoice_no = t.invoice_no AND si.invoice_date = t.invoice_date
            WHERE si.pos_shift_id = p_shift_id AND si.status = 'APPROVED'
              AND t.tender_type = 'CASH' AND t.currency_id = v_row.currency_id AND t.is_deleted = false
        ), 0);
        v_expected := v_expected + v_cash_sales;

        SELECT coalesce(sum(denomination_value * count), 0) INTO v_counted
          FROM rid_pos_shift_denomination_counts
         WHERE shift_id = p_shift_id AND count_stage = 'CLOSING' AND currency_id = v_row.currency_id;

        v_variance := v_counted - v_expected;
        IF abs(v_variance) > 0.01 THEN
            v_any_variance := true;
        END IF;
    END LOOP;

    IF v_any_variance AND (p_variance_reason IS NULL OR btrim(p_variance_reason) = '') THEN
        RAISE EXCEPTION 'VARIANCE_REASON_REQUIRED'
            USING DETAIL = 'The counted cash does not match the expected amount — enter a reason before closing this shift.';
    END IF;

    UPDATE rih_pos_shifts
       SET status = 'CLOSED',
           closed_at = now(),
           closing_notes = p_closing_notes,
           variance_reason = CASE WHEN v_any_variance THEN p_variance_reason ELSE NULL END,
           variance_approved_by = p_approved_by,
           variance_approved_at = CASE WHEN p_approved_by IS NOT NULL THEN now() ELSE NULL END
     WHERE id = p_shift_id;
END;
$$;
