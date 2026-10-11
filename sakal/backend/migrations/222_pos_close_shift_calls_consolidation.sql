-- ============================================================================
-- Migration 222: fn_close_pos_shift now calls fn_consolidate_pos_shift_finance
-- ============================================================================
-- Reproduced verbatim from migration 220 (the latest definition) per
-- CLAUDE.md's "Check Latest Function Signature" rule, adding exactly one
-- call — right before the shift is marked CLOSED, inside the SAME
-- transaction, so a close either consolidates+closes together or neither
-- happens at all. fn_consolidate_pos_shift_finance itself is a no-op
-- (returns immediately) when this shift has no deferred cash sales, so
-- closing a shift that never used the deferred path (or has none left to
-- consolidate) behaves exactly as before.
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
    v_local_ccy TEXT;
    v_cash_sales NUMERIC;
BEGIN
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'POS-SHIFT');

    SELECT * INTO v_shift FROM rih_pos_shifts WHERE id = p_shift_id;
    IF v_shift.status <> 'OPEN' THEN
        RAISE EXCEPTION 'SHIFT_NOT_OPEN'
            USING DETAIL = 'This shift is already closed.';
    END IF;
    PERFORM fn_check_period_open(p_company_id, current_date);

    SELECT local_currency INTO v_local_ccy FROM ric_companies WHERE id = p_company_id;

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

    -- NEW (222): consolidate this shift's deferred cash-sale GL before
    -- marking it closed — see fn_consolidate_pos_shift_finance's own
    -- header comment (migration 221). A no-op if there's nothing deferred.
    PERFORM fn_consolidate_pos_shift_finance(p_client_id, p_company_id, p_shift_id, p_approved_by);

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
