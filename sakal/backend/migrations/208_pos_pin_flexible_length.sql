-- ============================================================================
-- Migration 208: PIN length is flexible, not a fixed company-wide exact
-- length — user-specified ("PIN can be any digit [count]") after testing
-- found the exact-4-digit requirement too rigid.
-- ============================================================================
-- fn_set_user_pin (205) required length(p_new_pin) = ric_companies.pos_pin_length
-- exactly (default 4). Relaxed to: digits only, between 1 and 10 characters
-- — a generous sanity bound (protects the PIN pad UI and the bcrypt call
-- from an absurd input), not a fixed count. `ric_companies.pos_pin_length`
-- stays as-is (still usable later as a UI hint for how many dots to show by
-- default), it's just no longer enforced as an exact match server-side.
--
-- Reproduced verbatim from 205 (the only migration that has ever defined
-- this function) with exactly this one change, per CLAUDE.md's "check
-- latest signature" rule — fn_set_user_pin has no other callers/migrations
-- to reconcile against.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_set_user_pin(
    p_client_id  UUID,
    p_company_id UUID,
    p_user_id    UUID,
    p_new_pin    TEXT
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_other RECORD;
BEGIN
    IF p_new_pin !~ '^[0-9]+$' OR length(p_new_pin) < 1 OR length(p_new_pin) > 10 THEN
        RAISE EXCEPTION 'INVALID_PIN_FORMAT'
            USING DETAIL = 'PIN must be 1 to 10 digits.';
    END IF;

    FOR v_other IN
        SELECT pin_hash FROM rim_users
         WHERE client_id = p_client_id AND company_id = p_company_id
           AND id <> p_user_id AND is_active = true AND is_deleted = false
           AND pin_hash IS NOT NULL
    LOOP
        IF crypt(p_new_pin, v_other.pin_hash) = v_other.pin_hash THEN
            RAISE EXCEPTION 'PIN_ALREADY_IN_USE'
                USING DETAIL = 'Another active user in this company already has this PIN. Choose a different one.';
        END IF;
    END LOOP;

    UPDATE rim_users SET pin_hash = crypt(p_new_pin, gen_salt('bf')), updated_at = now()
     WHERE id = p_user_id;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_set_user_pin(uuid, uuid, uuid, text) TO authenticated;
