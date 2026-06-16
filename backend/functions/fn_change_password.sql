-- fn_change_password
-- Verifies the user's current password, enforces rules, then updates the hash.
-- Called by the Flutter Change Password screen via PostgREST /rpc/fn_change_password.
--
-- Error codes surfaced to the client (caught by _friendly() in the Flutter screen):
--   INVALID_CREDENTIALS — user not found or inactive
--   WRONG_PASSWORD      — current password does not match
--   SAME_PASSWORD       — new password is identical to the current one
--   TOO_SHORT           — new password is shorter than 8 characters
--
-- Requires: pgcrypto extension (CREATE EXTENSION IF NOT EXISTS pgcrypto;)

CREATE OR REPLACE FUNCTION fn_change_password(
    p_user_id          UUID,
    p_current_password TEXT,
    p_new_password     TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_hash TEXT;
BEGIN
    -- Load current hash; reject if user is inactive/deleted
    SELECT password_hash
      INTO v_hash
      FROM ric_users
     WHERE id = p_user_id
       AND is_active  = true
       AND is_deleted = false;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CREDENTIALS'
            USING ERRCODE = 'P0001', HINT = 'User not found or inactive';
    END IF;

    -- Verify current password
    IF crypt(p_current_password, v_hash) <> v_hash THEN
        RAISE EXCEPTION 'WRONG_PASSWORD'
            USING ERRCODE = 'P0001', HINT = 'Current password does not match';
    END IF;

    -- Reject if new password is same as current
    IF crypt(p_new_password, v_hash) = v_hash THEN
        RAISE EXCEPTION 'SAME_PASSWORD'
            USING ERRCODE = 'P0001', HINT = 'New password must differ from current';
    END IF;

    -- Enforce minimum length
    IF length(p_new_password) < 8 THEN
        RAISE EXCEPTION 'TOO_SHORT'
            USING ERRCODE = 'P0001', HINT = 'Password must be at least 8 characters';
    END IF;

    -- Hash and save
    UPDATE ric_users
       SET password_hash = crypt(p_new_password, gen_salt('bf')),
           updated_at    = now()
     WHERE id = p_user_id;
END;
$$;

-- Grant execute to the PostgREST API role
-- GRANT EXECUTE ON FUNCTION fn_change_password(UUID, TEXT, TEXT) TO authenticator;
