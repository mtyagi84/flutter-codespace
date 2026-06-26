-- ============================================================
-- fn_login
-- Verifies credentials using bcrypt. Handles account lockout.
-- Returns session data + signed JWT (access_token) on success.
-- PostgREST: POST /rest/v1/rpc/fn_login  (callable by anon role)
--
-- JWT signed with extensions.sign() from pgjwt extension.
-- Enable pgjwt first: Supabase Dashboard → Database → Extensions → pgjwt
-- ============================================================

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

    -- Find user within this client
    SELECT * INTO v_user
    FROM rim_users
    WHERE client_id  = v_client.id
      AND username   = lower(trim(p_username))
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

    -- Generate JWT using pgjwt extension (extensions.sign — no SET search_path needed)
    -- Requires pgjwt enabled: Supabase Dashboard → Database → Extensions → pgjwt
    -- Falls back gracefully if pgjwt not yet enabled (login still works, just no JWT)
    BEGIN
        v_secret := coalesce(
            current_setting('app.jwt_secret', true),
            current_setting('app.settings.jwt_secret', true)
        );
        IF v_secret IS NOT NULL THEN
            v_token := extensions.sign(
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
        v_token := null; -- pgjwt not enabled; login still works
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
