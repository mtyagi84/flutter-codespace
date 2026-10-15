-- ============================================================================
-- Migration 226: email-based login (additive — Client ID path unchanged)
-- ============================================================================
-- User-requested (registration-wizard overhaul, 2026-10-15): let a user sign
-- in with just their email + password, without having to remember/type a
-- Client ID. Explicitly NOT a replacement — fn_login(client_no, username,
-- password) is kept fully intact for anyone who still wants/needs it
-- (shared logins, an admin juggling multiple clients, etc.). Confirmed live
-- before writing this: only 13 active users today, 3 with no email, zero
-- duplicates — safe to add a global unique index immediately in this
-- environment; a real production tenant would need the same check (and any
-- cleanup) before this ships there.
--
-- Live `fn_login` re-verified directly via pg_get_functiondef immediately
-- before writing this migration (not trusted from the 225 file alone) —
-- confirmed it already includes 225's own first-login detection, which this
-- refactor preserves inside the new shared core.
--
-- Design: extract the common "verify password, handle lockout, check
-- license, detect first login, issue JWT" logic — previously only inside
-- fn_login — into a new fn_login_finish(p_user rim_users, p_password text)
-- taking an ALREADY-RESOLVED user row. Both fn_login (resolves the user by
-- client_no+username) and the new fn_login_by_email (resolves the user by
-- email alone, now unambiguous thanks to the new unique index) delegate to
-- it. Avoids duplicating the lockout/bcrypt/JWT logic in two places — this
-- project's own established "shared engine, never duplicate" principle.
--
-- One deliberate, minor behavior difference from the old single fn_login:
-- client license-validity checks (LICENSE_EXPIRED/TRIAL_EXPIRED) now happen
-- AFTER the user is resolved (inside fn_login_finish) rather than before —
-- unavoidable since fn_login_by_email doesn't know which client it's
-- dealing with until the user row is found. A real user on an expired-
-- license client still correctly gets LICENSE_EXPIRED; only the error for a
-- NONEXISTENT username/email against such a client changes from
-- LICENSE_EXPIRED to INVALID_CREDENTIALS — arguably more correct (never
-- reveals license status for credentials that don't exist), not a
-- regression worth preserving byte-exact.
-- ============================================================================

-- Global, case-insensitive uniqueness on rim_users.email. Partial index —
-- NULL/blank emails (pre-existing users created before this feature) and
-- soft-deleted rows are excluded, matching this project's own established
-- convention for exactly this situation (see uq_users_client_username's own
-- case-insensitive tightening, migration 204).
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email
    ON rim_users (lower(email))
    WHERE email IS NOT NULL AND email <> '' AND is_deleted = false;

CREATE OR REPLACE FUNCTION fn_login_finish(p_user rim_users, p_password text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client       ric_clients%rowtype;
    v_company_name text;
    v_token        text;
    v_secret       text;
    v_is_first_login boolean;
BEGIN
    SELECT * INTO v_client
    FROM ric_clients
    WHERE id = p_user.client_id
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

    IF NOT p_user.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE';
    END IF;

    IF p_user.locked_until IS NOT NULL AND p_user.locked_until > now() THEN
        RAISE EXCEPTION 'ACCOUNT_LOCKED';
    END IF;

    -- Verify bcrypt password
    IF p_user.password_hash != crypt(p_password, p_user.password_hash) THEN
        UPDATE rim_users
        SET failed_attempts = failed_attempts + 1,
            locked_until = CASE
                WHEN failed_attempts + 1 >= 5
                THEN now() + interval '30 minutes'
                ELSE locked_until
            END
        WHERE id = p_user.id;
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    -- Success — reset lockout counters and record login time
    UPDATE rim_users
    SET failed_attempts = 0,
        locked_until    = null,
        last_login_at   = now()
    WHERE id = p_user.id;

    -- First-login detection (225) — atomically claim it per COMPANY.
    UPDATE ric_companies
    SET first_login_at = now()
    WHERE id = p_user.company_id AND first_login_at IS NULL;
    v_is_first_login := FOUND;

    SELECT company_name INTO v_company_name
    FROM ric_companies
    WHERE id = p_user.company_id;

    BEGIN
        v_secret := coalesce(
            current_setting('app.jwt_secret', true),
            (SELECT value FROM _sakal_config WHERE key = 'jwt_secret')
        );
        IF v_secret IS NOT NULL THEN
            v_token := sign(
                json_build_object(
                    'role',       'authenticated',
                    'user_id',    p_user.id::text,
                    'client_id',  p_user.client_id::text,
                    'company_id', p_user.company_id::text,
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
        'user_id',      p_user.id,
        'client_id',    p_user.client_id,
        'client_no',    v_client.client_no,
        'company_id',   p_user.company_id,
        'company_name', coalesce(v_company_name, ''),
        'location_id',  p_user.default_location_id,
        'full_name',    p_user.full_name,
        'username',     p_user.username,
        'must_change',  p_user.must_change_password,
        'is_first_login', v_is_first_login,
        'access_token', v_token
    );
END;
$function$;

GRANT EXECUTE ON FUNCTION fn_login_finish(rim_users, text) TO authenticated, anon;

CREATE OR REPLACE FUNCTION fn_login(p_client_no text, p_username text, p_password text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client_id uuid;
    v_user      rim_users%rowtype;
BEGIN
    SELECT id INTO v_client_id
    FROM ric_clients
    WHERE client_no  = upper(trim(p_client_no))
      AND is_deleted = false
      AND is_active  = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    -- Case-insensitive on both sides — see fn_login_finish's own callers'
    -- shared history (neither the Users screen nor fn_create_user ever
    -- lowercases username at write time).
    SELECT * INTO v_user
    FROM rim_users
    WHERE client_id  = v_client_id
      AND lower(username) = lower(trim(p_username))
      AND is_deleted = false;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    RETURN fn_login_finish(v_user, p_password);
END;
$function$;

CREATE OR REPLACE FUNCTION fn_login_by_email(p_email text, p_password text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_user rim_users%rowtype;
BEGIN
    SELECT * INTO v_user
    FROM rim_users
    WHERE lower(email) = lower(trim(p_email))
      AND is_deleted    = false;

    -- A not-found email returns the same generic invalid-credentials
    -- response fn_login already uses for a wrong client/username combo —
    -- never reveals whether an email exists.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    RETURN fn_login_finish(v_user, p_password);
END;
$function$;

GRANT EXECUTE ON FUNCTION fn_login(text, text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION fn_login_by_email(text, text) TO authenticated, anon;
