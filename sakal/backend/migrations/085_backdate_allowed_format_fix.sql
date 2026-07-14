-- ============================================================
-- Migration 085: fn_check_backdate_allowed — fix format() vs RAISE
-- substitution mixup (bare % where format() needs %s)
-- ============================================================
-- Bug caught live by CI, the first time this function's error paths have
-- ever actually been exercised end to end: both DETAIL messages used a
-- bare `%` (the RAISE EXCEPTION substitution placeholder) inside a
-- format() call, which requires `%s`/`%I`/`%L` instead — format() treats
-- every `%` as the start of its own placeholder syntax, so a bare `%`
-- followed by a space is an invalid specifier and raises
-- `22023: unrecognized format() type specifier " "` instead of the
-- intended named exception (FUTURE_DATE_NOT_ALLOWED / BACKDATE_NOT_ALLOWED).
-- Same class of bug already documented and fixed once before in migration
-- 082 (fn_update_sales_quotation_status) — this is the same mistake
-- recurring in an older, previously-untested function.
--
-- Same signature as 035's version — CREATE OR REPLACE replaces in place,
-- no DROP FUNCTION needed.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_check_backdate_allowed(
    p_client_id       UUID,
    p_company_id      UUID,
    p_transaction_type TEXT,
    p_trans_date      DATE
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

    IF NOT v_ctrl.allow_future_date AND p_trans_date > current_date THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('%s transactions cannot be dated in the future.', p_transaction_type);
    END IF;

    IF v_ctrl.max_backdate_days IS NOT NULL
       AND p_trans_date < (current_date - v_ctrl.max_backdate_days) THEN
        RAISE EXCEPTION 'BACKDATE_NOT_ALLOWED'
            USING DETAIL = format('%s transactions cannot be dated more than %s day(s) back.',
                                   p_transaction_type, v_ctrl.max_backdate_days);
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_check_backdate_allowed(UUID, UUID, TEXT, DATE) TO authenticated;
