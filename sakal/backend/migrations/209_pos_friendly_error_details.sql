-- ============================================================================
-- Migration 209: friendly error messages across POS — user-reported real bug
-- (a raw code like "INVALID_CREDENTIALS" shown as the entire error text on
-- the Device Setup screen), audited across every POS backend function.
-- ============================================================================
-- Root cause confirmed by reading `ErrorPresenter.format`
-- (lib/core/errors/error_presenter.dart) directly: it returns
-- `data['message']` verbatim whenever present — and `DioClient`'s own
-- interceptor only OVERWRITES `message` with `details` when a `details`
-- value exists (CLAUDE.md's "PostgREST Error details Field" rule). A bare
-- `RAISE EXCEPTION 'SOME_CODE';` with no `USING DETAIL` has nothing to
-- promote, so the raw code is exactly what reaches the screen. Confirmed
-- this is the cause and not something to fix in Flutter, since
-- `ErrorPresenter.format` is already working exactly as documented.
--
-- Two different fixes, matching how this app already splits this concern:
-- 1. `fn_login`/`fn_pos_pin_login` are pre-auth, maximally-generic, shared
--    functions — this app's own established convention (see
--    `login_screen.dart`'s own `_friendlyError`) is to translate their
--    bare codes client-side, NOT add USING DETAIL to fn_login itself
--    (it's shared by every login surface in the app, back-office included).
--    Fixed in `pos_device_setup_screen.dart`/`pos_pin_login_screen.dart`
--    (same commit as this migration), not here.
-- 2. Every OTHER POS-specific function (this migration) gets a proper
--    `USING DETAIL` on every bare RAISE EXCEPTION, matching how the rest of
--    this schema already handles every other module's exceptions — so
--    `ErrorPresenter.format` keeps working for POS with zero Flutter-side
--    per-code mapping needed, same as Sales/Finance/Purchase/Inventory.
--
-- Reproduced verbatim from migration 206 (the only migration that has ever
-- defined these three functions) with ONLY the four bare RAISE EXCEPTION
-- statements gaining a USING DETAIL — nothing else changed, confirmed by
-- diff against 206 before deploying.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_open_pos_shift(
    p_client_id      UUID,
    p_company_id     UUID,
    p_terminal_id    UUID,
    p_cashier_id     UUID,
    p_opening_notes  TEXT,
    p_opening_floats JSONB   -- [{"currency_id": "USD", "amount": 100.00}, ...]
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_location_id UUID;
    v_shift_id    UUID;
    v_shift_no    TEXT;
    v_float       JSONB;
BEGIN
    SELECT location_id INTO v_location_id FROM ric_pos_terminals WHERE id = p_terminal_id;
    IF v_location_id IS NULL THEN
        RAISE EXCEPTION 'TERMINAL_NOT_FOUND'
            USING DETAIL = 'This terminal could not be found. It may have been removed — ask an admin to check POS Setup.';
    END IF;

    PERFORM fn_check_period_open(p_company_id, current_date);

    v_shift_no := fn_next_trans_no(p_client_id, p_company_id, v_location_id, 'SFT');

    -- The partial unique index (uq_pos_shift_one_open_per_terminal) is the
    -- real guard against two concurrently-open shifts on one terminal; this
    -- INSERT simply surfaces that as a normal exception if it fires.
    INSERT INTO rih_pos_shifts (client_id, company_id, location_id, terminal_id, shift_no, cashier_id, opening_notes)
    VALUES (p_client_id, p_company_id, v_location_id, p_terminal_id, v_shift_no, p_cashier_id, p_opening_notes)
    RETURNING id INTO v_shift_id;

    FOR v_float IN SELECT * FROM jsonb_array_elements(coalesce(p_opening_floats, '[]'::jsonb))
    LOOP
        INSERT INTO rih_pos_shift_opening_float (client_id, company_id, shift_id, currency_id, opening_amount)
        VALUES (p_client_id, p_company_id, v_shift_id, v_float->>'currency_id', (v_float->>'amount')::numeric);
    END LOOP;

    RETURN v_shift_no;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'SHIFT_ALREADY_OPEN'
            USING DETAIL = 'This terminal already has an open shift. Close it before opening a new one.';
END;
$$;
GRANT EXECUTE ON FUNCTION fn_open_pos_shift(uuid, uuid, uuid, uuid, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION fn_save_pos_cash_movement(
    p_client_id     UUID,
    p_company_id    UUID,
    p_shift_id      UUID,
    p_movement_type TEXT,
    p_amount        NUMERIC,
    p_currency_id   TEXT,
    p_cash_account_id UUID,
    p_counter_account_id UUID,
    p_reason_id     UUID,
    p_reference_no  TEXT,
    p_created_by    UUID
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_shift        rih_pos_shifts%rowtype;
    v_company      ric_companies%rowtype;
    v_direction    TEXT;
    v_payout_no    TEXT;
    v_voucher_no   TEXT;
    v_voucher_date DATE := current_date;
    v_base_rate    NUMERIC;
    v_local_rate   NUMERIC;
    v_lines        JSONB;
    v_dr_account   UUID;
    v_cr_account   UUID;
BEGIN
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'POS-PAYOUT');
    PERFORM fn_check_period_open(p_company_id, v_voucher_date);

    SELECT * INTO v_shift FROM rih_pos_shifts WHERE id = p_shift_id;
    IF v_shift.status <> 'OPEN' THEN
        RAISE EXCEPTION 'SHIFT_NOT_OPEN'
            USING DETAIL = 'This shift is no longer open — refresh the Shift & Cash screen and try again.';
    END IF;
    SELECT * INTO v_company FROM ric_companies WHERE id = p_company_id;

    -- Every movement type needs a real counter account for the journal's
    -- other leg (Safe/Bank for CASH_IN/OUT/DROP, an expense account for
    -- PAYOUT) — rid_finance_lines.account_id is NOT NULL, so a missing one
    -- here must fail with a friendly message rather than a raw DB error.
    IF p_counter_account_id IS NULL THEN
        RAISE EXCEPTION 'COUNTER_ACCOUNT_REQUIRED'
            USING DETAIL = format('A %s needs an account for its other side.', p_movement_type);
    END IF;

    v_direction := CASE WHEN p_movement_type = 'CASH_IN' THEN 'IN' ELSE 'OUT' END;
    v_payout_no := fn_next_trans_no(p_client_id, p_company_id, v_shift.location_id, 'PAY');

    -- Always-multiply convention (CLAUDE.md's multicurrency rule): both legs
    -- share the same trans_currency (a plain two-leg internal journal, same
    -- shape as Material Issue's own self-referential MIC lines), so one rate
    -- lookup per base/local covers both.
    v_base_rate  := CASE WHEN p_currency_id = v_company.base_currency  THEN 1 ELSE fn_get_exchange_rate(p_company_id, v_shift.location_id, p_currency_id, v_company.base_currency,  v_voucher_date) END;
    v_local_rate := CASE WHEN p_currency_id = v_company.local_currency THEN 1 ELSE fn_get_exchange_rate(p_company_id, v_shift.location_id, p_currency_id, v_company.local_currency, v_voucher_date) END;

    v_dr_account := CASE WHEN v_direction = 'IN' THEN p_cash_account_id ELSE p_counter_account_id END;
    v_cr_account := CASE WHEN v_direction = 'IN' THEN p_counter_account_id ELSE p_cash_account_id END;

    v_lines := jsonb_build_array(
        jsonb_build_object(
            'account_id', v_dr_account, 'trans_nature', 'DR', 'trans_amount', p_amount, 'trans_currency', p_currency_id,
            'base_amount', p_amount * v_base_rate, 'base_rate', v_base_rate,
            'local_amount', p_amount * v_local_rate, 'local_rate', v_local_rate,
            'party_amount', p_amount, 'party_currency', p_currency_id, 'party_rate', 1,
            'line_remarks', format('POS %s — %s', p_movement_type, v_payout_no)
        ),
        jsonb_build_object(
            'account_id', v_cr_account, 'trans_nature', 'CR', 'trans_amount', p_amount, 'trans_currency', p_currency_id,
            'base_amount', p_amount * v_base_rate, 'base_rate', v_base_rate,
            'local_amount', p_amount * v_local_rate, 'local_rate', v_local_rate,
            'party_amount', p_amount, 'party_currency', p_currency_id, 'party_rate', 1,
            'line_remarks', format('POS %s — %s', p_movement_type, v_payout_no)
        )
    );

    SELECT trans_no INTO v_voucher_no FROM fn_post_voucher(
        p_client_id, p_company_id, v_shift.location_id, 'JV', v_voucher_date, v_lines,
        'POS_CASH_MOVEMENT', v_payout_no, v_voucher_date, p_created_by
    );

    INSERT INTO rih_pos_payouts (client_id, company_id, shift_id, payout_no, movement_type, direction, amount, currency_id, reason_id, gl_account_id, reference_no, voucher_no, voucher_date, created_by)
    VALUES (p_client_id, p_company_id, p_shift_id, v_payout_no, p_movement_type, v_direction, p_amount, p_currency_id, p_reason_id, p_counter_account_id, p_reference_no, v_voucher_no, v_voucher_date, p_created_by);

    RETURN v_payout_no;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_save_pos_cash_movement(uuid, uuid, uuid, text, numeric, text, uuid, uuid, uuid, text, uuid) TO authenticated;

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
BEGIN
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'POS-SHIFT');

    SELECT * INTO v_shift FROM rih_pos_shifts WHERE id = p_shift_id;
    IF v_shift.status <> 'OPEN' THEN
        RAISE EXCEPTION 'SHIFT_NOT_OPEN'
            USING DETAIL = 'This shift is already closed.';
    END IF;
    PERFORM fn_check_period_open(p_company_id, current_date);

    -- One pass per currency this shift ever touched (opening float, any
    -- movement, or a closing count) — expected vs counted compared per
    -- currency, never mixed.
    FOR v_row IN
        SELECT currency_id FROM (
            SELECT currency_id FROM rih_pos_shift_opening_float WHERE shift_id = p_shift_id
            UNION
            SELECT currency_id FROM rih_pos_payouts WHERE shift_id = p_shift_id AND is_deleted = false
            UNION
            SELECT currency_id FROM rid_pos_shift_denomination_counts WHERE shift_id = p_shift_id AND count_stage = 'CLOSING'
        ) c
    LOOP
        SELECT coalesce(sum(opening_amount), 0) INTO v_expected
          FROM rih_pos_shift_opening_float WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id;

        v_expected := v_expected
            + (SELECT coalesce(sum(amount), 0) FROM rih_pos_payouts WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id AND direction = 'IN'  AND is_deleted = false)
            - (SELECT coalesce(sum(amount), 0) FROM rih_pos_payouts WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id AND direction = 'OUT' AND is_deleted = false);
        -- TODO once New Sale ships: + SUM(rid_pos_tender_lines.tender_amount)
        -- for CASH tender lines, this currency, on this shift's invoices.

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

    -- Variance-approval threshold is intentionally NOT enforced yet — DEC-07
    -- in docs/pos/11_open_decisions.md is still an open number the user
    -- hasn't confirmed. For now a variance reason is mandatory (enforced
    -- above) but approval is optional; once DEC-07 is answered this gets a
    -- real `pos_cash_variance_threshold` column + a hard block here, the
    -- same shape as every other threshold check in this schema.

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
GRANT EXECUTE ON FUNCTION fn_close_pos_shift(uuid, uuid, uuid, text, text, uuid) TO authenticated;
