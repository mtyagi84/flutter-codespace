-- ============================================================
-- Migration 082: fix fn_update_sales_quotation_status's format() bug
-- ============================================================
-- 081's INVALID_STATUS_TRANSITION branch used bare `%` inside format(),
-- confusing PL/pgSQL's native RAISE-substitution syntax (where bare % is
-- correct, e.g. every other RAISE EXCEPTION 'msg %', arg in this schema)
-- with the format() FUNCTION's own placeholder syntax (%s/%I/%L — a bare
-- % is invalid there). format() tried to parse the space after the first
-- bare % as a type specifier and threw 22023 "unrecognized format() type
-- specifier ' '" instead of ever raising INVALID_STATUS_TRANSITION.
-- Caught live by pgTAP test 20 in 081_sales_quotation_test.sql.
-- Same signature, so CREATE OR REPLACE is safe — no DROP FUNCTION needed.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_update_sales_quotation_status(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_new_status     TEXT,
    p_user_id        UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_status TEXT;
    v_allowed        BOOLEAN := false;
BEGIN
    SELECT status INTO v_current_status FROM rih_sales_quotations
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Quotation % dated % not found', p_quotation_no, p_quotation_date;
    END IF;

    v_allowed := (v_current_status = 'APPROVED' AND p_new_status = 'SENT')
              OR (v_current_status = 'SENT'     AND p_new_status IN ('ACCEPTED', 'REJECTED'));

    IF NOT v_allowed THEN
        RAISE EXCEPTION 'INVALID_STATUS_TRANSITION'
            USING DETAIL = format('Sales Quotation %s cannot move from %s to %s.', p_quotation_no, v_current_status, p_new_status);
    END IF;

    UPDATE rih_sales_quotations SET
        status = p_new_status,
        updated_at = now(), updated_by = p_user_id
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_update_sales_quotation_status(UUID, UUID, TEXT, DATE, TEXT, UUID) TO authenticated;
