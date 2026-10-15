-- ============================================================================
-- Migration 225: first-login detection for a brand-new admin
-- ============================================================================
-- User-requested (registration-wizard overhaul, 2026-10-15): a brand-new
-- admin's very first login should land on Company Setup instead of the
-- Dashboard, with a one-time informational popup pointing at the handful
-- of company-level settings worth reviewing before transacting (Product
-- Coding, Inter-Location Model, Quantity Entry Mode, Number Format,
-- Currency Decimal Places, Quick Invoice Setup) -- several of which lock
-- or become hard to change once real data exists (see company_screen.dart's
-- own `_hasProducts`/`_hasTransactions` lock logic). No new settings UI is
-- built here -- purely detection + an informational message, per direct
-- user correction during planning.
--
-- No existing flag anywhere on ric_companies or in fn_login's own response
-- indicated "has this company ever logged in before" (confirmed live via
-- this project's own exploration before writing this migration). Adding
-- one explicitly rather than inferring it from some other signal (e.g.
-- is_coa_seeded, which answers a different question -- Chart of Accounts
-- being seeded happens automatically during registration itself, not on
-- first login).
--
-- Live `fn_login` definition re-verified directly via pg_get_functiondef
-- immediately before writing this migration (not trusted from any
-- migration file) -- its current signature is exactly
-- fn_login(p_client_no text, p_username text, p_password text), matching
-- what's reproduced below.
-- ============================================================================

ALTER TABLE ric_companies ADD COLUMN IF NOT EXISTS first_login_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION fn_login(p_client_no text, p_username text, p_password text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client       ric_clients%rowtype;
    v_user         rim_users%rowtype;
    v_company_name text;
    v_token        text;
    v_secret       text;
    v_is_first_login boolean;
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

    -- First-login detection (NEW, 225): atomically claim the "first ever
    -- login" flag for this COMPANY (not user — a second admin user added
    -- later never re-triggers this, only the company's very first login
    -- does). UPDATE ... RETURNING tells us in one statement whether THIS
    -- call was the one that set it (v_is_first_login = true) versus it
    -- already being set by an earlier login (no rows match the
    -- `IS NULL` filter, v_is_first_login stays false) — avoids a
    -- check-then-set race between concurrent logins.
    UPDATE ric_companies
    SET first_login_at = now()
    WHERE id = v_user.company_id AND first_login_at IS NULL;
    v_is_first_login := FOUND;

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
        'is_first_login', v_is_first_login,
        'access_token', v_token
    );
END;
$function$;
