-- ============================================================
-- Migration 041: fn_approve_purchase_order gains period/backdate checks
-- ============================================================
-- Closes a standing-rule gap: CLAUDE.md's "Period / backdate checks" rule
-- requires fn_check_period_open + fn_check_backdate_allowed to be called by
-- every fn_approve_*/fn_post_* as its FIRST action (see fn_approve_grn in
-- 038, fn_post_stock_movement in 036, fn_post_voucher/fn_post_finance_voucher
-- in 037). fn_approve_purchase_order never got this — neither in 031 nor in
-- 040's rewrite — so a PO could be approved with a future-dated or
-- period-locked order_date with no check at all.
--
-- fn_check_backdate_allowed is opt-in per transaction_type (missing config
-- row = no restriction, per its own comment in 035), so this is safe to add
-- unconditionally — it only starts enforcing once/if an admin configures a
-- 'PURCHASE_ORDER' row in Backdated Entry Control.
--
-- Everything else in this function is unchanged from 040 — only the two new
-- PERFORM calls, placed first, right after the status check (same position
-- fn_approve_grn uses them).
-- ============================================================

CREATE OR REPLACE FUNCTION fn_approve_purchase_order(
    p_client_id   UUID,
    p_company_id  UUID,
    p_order_no    TEXT,
    p_order_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_purchase_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_header FROM rih_purchase_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Order % dated % not found', p_order_no, p_order_date;
    END IF;

    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Purchase Order % is % and cannot be approved again', p_order_no, v_header.status;
    END IF;

    -- NEW: period/backdate checks — closes the gap where a PO could be
    -- approved with a future-dated or period-locked order_date with no
    -- validation at all, unlike every other approve/post function.
    PERFORM fn_check_period_open(p_company_id, p_order_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'PURCHASE_ORDER', p_order_date);

    -- At least one line, and every line must be complete (qty/rate/UOM) —
    -- added in migration 040, unchanged here.
    IF NOT EXISTS (
        SELECT 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
    ) THEN
        RAISE EXCEPTION 'PO_NO_LINES'
            USING DETAIL = 'A Purchase Order needs at least one item line before it can be approved.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
          AND (base_qty <= 0 OR rate <= 0 OR uom_id IS NULL)
    ) THEN
        RAISE EXCEPTION 'PO_LINE_INCOMPLETE'
            USING DETAIL = 'Every line needs a quantity greater than zero, a rate greater than zero, and a UOM selected before the Purchase Order can be approved.';
    END IF;

    UPDATE rih_purchase_orders SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(),
        updated_by  = p_approved_by
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_purchase_order(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
