-- ============================================================================
-- Migration 210: PIN-based discount override for POS
-- ============================================================================
-- New Sale's discount-override dialog still used fn_verify_discount_override
-- (username + password) — the one place a password was still typed on the
-- till outside Device Setup. User-specified: "we are already have PIN login
-- for POS", so a supervisor override should use a PIN too, not a password.
--
-- Deliberately NOT a variant of fn_pos_pin_login: this never logs the
-- supervisor in or changes the cashier's own session — it only verifies that
-- SOME active user in this company has this PIN AND is authorized for the
-- requested discount, exactly mirroring fn_verify_discount_override's own
-- "credentials + eligibility, nothing else changes" contract, just with a
-- PIN match instead of a username+password lookup.
--
-- A PIN is not a username — there's no single row to look up by PIN, so
-- this loops active users with a PIN set and bcrypt-compares each one,
-- identical in shape to fn_pos_pin_login's own device-login loop
-- (205_pos_foundation.sql) and fn_set_user_pin's uniqueness-check loop
-- (205/208). PIN uniqueness is already enforced at SET time per user
-- (fn_set_user_pin), so at most one active user should ever match.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_verify_pos_discount_override_pin(
    p_client_id                  UUID,
    p_company_id                 UUID,
    p_pin                        TEXT,
    p_requested_discount_percent NUMERIC
)
RETURNS TABLE (user_id UUID, full_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user         rim_users%ROWTYPE;
    v_matched      BOOLEAN := false;
    v_can_discount BOOLEAN;
    v_max_discount NUMERIC;
BEGIN
    FOR v_user IN
        SELECT * FROM rim_users
         WHERE client_id = p_client_id AND company_id = p_company_id
           AND is_active = true AND is_deleted = false
           AND pin_hash IS NOT NULL
    LOOP
        IF crypt(p_pin, v_user.pin_hash) = v_user.pin_hash THEN
            v_matched := true;
            EXIT;
        END IF;
    END LOOP;

    IF NOT v_matched THEN
        RAISE EXCEPTION 'INVALID_PIN'
            USING DETAIL = 'No active user matches this PIN.';
    END IF;

    SELECT can_give_discount, max_discount_percent INTO v_can_discount, v_max_discount
    FROM ric_user_sales_controls
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND ric_user_sales_controls.user_id = v_user.id AND is_deleted = false;

    IF NOT coalesce(v_can_discount, false)
       OR (v_max_discount IS NOT NULL AND p_requested_discount_percent > v_max_discount) THEN
        RAISE EXCEPTION 'DISCOUNT_NOT_AUTHORIZED'
            USING DETAIL = format('%s is not authorized to approve a %s%% discount.', v_user.full_name, p_requested_discount_percent);
    END IF;

    RETURN QUERY SELECT v_user.id, v_user.full_name;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_verify_pos_discount_override_pin(UUID, UUID, TEXT, NUMERIC) TO authenticated;
