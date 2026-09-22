-- ============================================================
-- Migration 204: fix Change Password (wrong table name) + Login
-- (case-sensitive username lookup)
-- ============================================================
-- Two real, live bugs reported by the user and confirmed by direct code
-- read, unrelated to each other:
--
-- A. fn_change_password.sql operated on `ric_users`, a table that has
--    never existed in this schema (the real table is `rim_users`) --
--    every single call to /rpc/fn_change_password failed outright with
--    "relation ric_users does not exist" before any password logic ever
--    ran. Confirmed via a full repo grep: the only two occurrences of
--    "ric_users" anywhere in this codebase were this function's own
--    SELECT and UPDATE. Change Password has been 100% broken for every
--    user since this function was first written -- a plain typo, not a
--    logic bug.
--
-- B. fn_login.sql's user lookup normalized the INPUT username
--    (`lower(trim(p_username))`) but compared it against the RAW,
--    un-normalized `username` column -- `WHERE username =
--    lower(trim(p_username))`. Since neither the Users screen's own
--    Add-User dialog nor fn_create_user ever lowercases a username at
--    creation time, any username containing an uppercase letter (e.g.
--    "Admin") is stored mixed-case but every login attempt normalizes
--    the typed value to lowercase first -- so the comparison can never
--    match, and login always fails with INVALID_CREDENTIALS regardless
--    of a correct password. This explains both a brand-new user created
--    with an uppercase username never being able to log in, AND an
--    existing working user's login breaking the moment their username
--    is renamed (via the app or directly in the database) to anything
--    containing an uppercase letter.
--
-- Fixed by comparing both sides case-insensitively (`lower(username) =
-- lower(trim(p_username))`) rather than requiring every past/future
-- write path to remember to lowercase -- more robust, since it can never
-- drift out of sync with a write path someone forgets to update.
--
-- Also hardens the uniqueness guarantee to match: confirmed live (no
-- existing client currently has two users whose usernames differ only
-- by case) that it's safe to replace the old case-SENSITIVE unique
-- index with a case-INSENSITIVE one, so two users like "admin" and
-- "Admin" can never coexist for the same client going forward (which
-- would otherwise be genuinely ambiguous to log in as, now that lookup
-- itself is case-insensitive).
-- ============================================================

-- ── A. fn_change_password ────────────────────────────────────────────────
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
      FROM rim_users
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
    UPDATE rim_users
       SET password_hash = crypt(p_new_password, gen_salt('bf')),
           updated_at    = now()
     WHERE id = p_user_id;
END;
$$;

-- ── B. fn_login ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_login(
    p_client_no text,
    p_username  text,
    p_password  text
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_client       ric_clients%rowtype;
    v_user         rim_users%rowtype;
    v_company_name text;
    v_token        text;
    v_secret       text;
BEGIN
    -- Find and validate client
    SELECT * INTO v_client
    FROM ric_clients
    WHERE client_no  = upper(trim(p_client_no))
      AND is_deleted = false
      AND is_active  = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    IF v_client.license_status = 'EXPIRED' THEN
        RAISE EXCEPTION 'LICENSE_EXPIRED';
    END IF;

    IF v_client.license_status = 'TRIAL'
       AND v_client.trial_end_date < current_date THEN
        UPDATE ric_clients SET license_status = 'EXPIRED' WHERE id = v_client.id;
        RAISE EXCEPTION 'TRIAL_EXPIRED';
    END IF;

    -- Find user within this client. Case-insensitive on BOTH sides
    -- (see this migration's own header comment) -- neither the Users
    -- screen nor fn_create_user ever lowercases username at write time,
    -- so comparing only a normalized input against a raw column value
    -- silently rejected any mixed-case username.
    SELECT * INTO v_user
    FROM rim_users
    WHERE client_id  = v_client.id
      AND lower(username) = lower(trim(p_username))
      AND is_deleted = false;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    IF NOT v_user.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE';
    END IF;

    IF v_user.locked_until IS NOT NULL AND v_user.locked_until > now() THEN
        RAISE EXCEPTION 'ACCOUNT_LOCKED';
    END IF;

    -- Verify bcrypt password
    IF v_user.password_hash != crypt(p_password, v_user.password_hash) THEN
        UPDATE rim_users
        SET failed_attempts = failed_attempts + 1,
            locked_until = CASE
                WHEN failed_attempts + 1 >= 5
                THEN now() + interval '30 minutes'
                ELSE locked_until
            END
        WHERE id = v_user.id;
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    -- Success — reset lockout counters and record login time
    UPDATE rim_users
    SET failed_attempts = 0,
        locked_until    = null,
        last_login_at   = now()
    WHERE id = v_user.id;

    SELECT company_name INTO v_company_name
    FROM ric_companies
    WHERE id = v_user.company_id;

    -- Generate JWT using sign() from pgjwt (public schema on Supabase).
    -- Secret: postgresql.conf app.jwt_secret (self-hosted) OR _sakal_config table (Supabase).
    -- Falls back gracefully — login still works even if secret not configured.
    BEGIN
        v_secret := coalesce(
            current_setting('app.jwt_secret', true),
            (SELECT value FROM _sakal_config WHERE key = 'jwt_secret')
        );
        IF v_secret IS NOT NULL THEN
            v_token := sign(
                json_build_object(
                    'role',       'authenticated',
                    'user_id',    v_user.id::text,
                    'client_id',  v_user.client_id::text,
                    'company_id', v_user.company_id::text,
                    'iat',        extract(epoch FROM now())::integer,
                    'exp',        extract(epoch FROM (now() + interval '8 hours'))::integer
                )::json,
                v_secret
            );
        END IF;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'JWT sign error (access_token will be null): %', SQLERRM;
        v_token := null;
    END;

    RETURN json_build_object(
        'user_id',      v_user.id,
        'client_id',    v_user.client_id,
        'client_no',    v_client.client_no,
        'company_id',   v_user.company_id,
        'company_name', coalesce(v_company_name, ''),
        'location_id',  v_user.default_location_id,
        'full_name',    v_user.full_name,
        'username',     v_user.username,
        'must_change',  v_user.must_change_password,
        'access_token', v_token
    );
END;
$$;

-- ── C. Harden the uniqueness guarantee to match the new case-insensitive
-- lookup — confirmed live (query run before writing this migration) that
-- no client currently has two users whose usernames differ only by case,
-- so this is safe to apply now.
DROP INDEX IF EXISTS uq_users_client_username;
CREATE UNIQUE INDEX uq_users_client_username ON rim_users (client_id, lower(username));
