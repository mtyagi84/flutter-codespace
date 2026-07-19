-- ============================================================
-- Reverses a prior deliberate design decision (documented in 087's own
-- header comment: "Deliberately NO fn_check_period_open/
-- fn_check_backdate_allowed at Approve — this document never posts to
-- the books, same intentional deviation as Sales Quotation/Sales Price
-- Master"), per explicit user instruction during live testing (bug #17):
-- period-close and backdate/future-date control should apply to Sales
-- Order and Sales Quotation too, not just GL-posting documents.
--
-- Both fn_approve_sales_order and fn_approve_sales_quotation gain the
-- exact same two PERFORM calls, in the exact same position (immediately
-- after the header lock+status check, before any line-level validation)
-- as fn_approve_sales_invoice already uses (089_sales_invoice.sql:1094-
-- 1095) -- one shared convention across the whole Quotation->Order->
-- Invoice chain now, not two different behaviors.
--
-- Both functions' signatures are unchanged -- safe CREATE OR REPLACE.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_approve_sales_order(
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
    v_header         rih_sales_orders%ROWTYPE;
    v_line           RECORD;
    v_source_line    rid_sales_quotation_lines%ROWTYPE;
    v_remaining      NUMERIC;
    v_all_converted  BOOLEAN;
    v_any_converted  BOOLEAN;
BEGIN
    SELECT * INTO v_header FROM rih_sales_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % dated % not found', p_order_no, p_order_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Order % is % and cannot be approved again', p_order_no, v_header.status;
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_order_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_ORDER', p_order_date);

    FOR v_line IN
        SELECT * FROM rid_sales_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;
        IF v_line.rate < 0 THEN
            RAISE EXCEPTION 'LINE_RATE_INVALID'
                USING DETAIL = format('Line %s: rate cannot be negative.', v_line.serial_no);
        END IF;
    END LOOP;

    IF v_header.order_mode = 'AGAINST_QUOTATION' THEN
        FOR v_line IN
            SELECT * FROM rid_sales_order_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
            ORDER BY source_quotation_line_serial
        LOOP
            SELECT * INTO v_source_line FROM rid_sales_quotation_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
              AND serial_no = v_line.source_quotation_line_serial
            FOR UPDATE;

            v_remaining := v_source_line.base_qty - v_source_line.converted_qty;
            IF v_line.base_qty > v_remaining THEN
                RAISE EXCEPTION 'QUOTATION_QTY_EXCEEDED'
                    USING DETAIL = format('Quotation %s line %s: only %s remains unconverted (another order may have consumed it since this draft was saved).',
                        v_header.source_quotation_no, v_source_line.serial_no, v_remaining);
            END IF;

            UPDATE rid_sales_quotation_lines SET
                converted_qty = converted_qty + v_line.base_qty,
                updated_at = now(), updated_by = p_approved_by
            WHERE id = v_source_line.id;
        END LOOP;

        SELECT
            bool_and(converted_qty >= base_qty),
            bool_or(converted_qty > 0)
        INTO v_all_converted, v_any_converted
        FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
          AND is_deleted = false;

        UPDATE rih_sales_quotations SET
            status = CASE WHEN v_all_converted THEN 'CONVERTED'
                          WHEN v_any_converted  THEN 'PARTIALLY_CONVERTED'
                          ELSE status END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date;
    END IF;

    UPDATE rih_sales_orders SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_order(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_approve_sales_quotation — same two PERFORM calls added
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_approve_sales_quotation(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_approved_by    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_sales_quotations%ROWTYPE;
    v_line   RECORD;
BEGIN
    SELECT * INTO v_header FROM rih_sales_quotations
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Quotation % dated % not found', p_quotation_no, p_quotation_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Quotation % is % and cannot be approved again', p_quotation_no, v_header.status;
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_quotation_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_QUOTATION', p_quotation_date);

    FOR v_line IN
        SELECT * FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date AND is_deleted = false
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;
        IF v_line.rate < 0 THEN
            RAISE EXCEPTION 'LINE_RATE_INVALID'
                USING DETAIL = format('Line %s: rate cannot be negative.', v_line.serial_no);
        END IF;
    END LOOP;

    UPDATE rih_sales_quotations SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_quotation(UUID, UUID, TEXT, DATE, UUID) TO authenticated;

-- No ric_backdated_entry_control seed needed -- a missing row is already
-- fully permissive (fn_check_backdate_allowed's own documented "opt-in
-- control, not opt-out" behavior), same as every other transaction type
-- in this schema. No other module seeds a default row either.
