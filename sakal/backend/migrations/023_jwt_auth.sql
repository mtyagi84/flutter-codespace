-- ============================================================
-- Migration 023: JWT Authentication
-- ============================================================
-- BEFORE running this migration, set the JWT secret in the DB.
-- Get your secret: Supabase Dashboard → Project Settings → API → JWT Secret
-- Then run (once, in Supabase SQL editor):
--   ALTER DATABASE postgres SET "app.jwt_secret" = 'PASTE-SECRET-HERE';
--
-- Self-hosted: set the same value in postgresql.conf:
--   app.jwt_secret = 'same-secret'
-- and in postgrest.conf:
--   jwt-secret = "same-secret"
-- ============================================================

-- pgjwt extension (provides the sign() function for JWT generation)
-- Supabase: creates in 'extensions' schema
-- Self-hosted: install postgresql-{ver}-pgjwt first, then uncomment:
--   CREATE EXTENSION IF NOT EXISTS pgjwt;
CREATE EXTENSION IF NOT EXISTS pgjwt;

-- ── Updated fn_login: returns access_token in response ───────────────────────
-- SET search_path = public, extensions  makes sign() resolve in both
-- Supabase (extensions.sign) and self-hosted (public.sign) without code change.
CREATE OR REPLACE FUNCTION fn_login(
    p_client_no text,
    p_username  text,
    p_password  text
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_client       ric_clients%rowtype;
    v_user         rim_users%rowtype;
    v_company_name text;
    v_token        text;
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

    -- Success — reset lockout and record login
    UPDATE rim_users
    SET failed_attempts = 0,
        locked_until    = null,
        last_login_at   = now()
    WHERE id = v_user.id;

    SELECT company_name INTO v_company_name
    FROM ric_companies
    WHERE id = v_user.company_id;

    -- Generate JWT (8-hour expiry)
    -- sign() resolved via search_path = public, extensions
    -- app.jwt_secret must match jwt-secret in postgrest.conf
    v_token := sign(
        json_build_object(
            'role',       'authenticated',
            'user_id',    v_user.id::text,
            'client_id',  v_user.client_id::text,
            'company_id', v_user.company_id::text,
            'iat',        extract(epoch FROM now())::integer,
            'exp',        extract(epoch FROM (now() + interval '8 hours'))::integer
        )::json,
        current_setting('app.jwt_secret')
    );

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

-- anon role can call fn_login (user is not authenticated yet at this point)
GRANT EXECUTE ON FUNCTION fn_login(text, text, text) TO anon;


-- ── Fix rim_common_masters: proper JWT-based tenant isolation ─────────────────

-- Remove the interim policies from migration 022
DROP POLICY IF EXISTS "read_types"    ON rim_common_master_types;
DROP POLICY IF EXISTS "read_masters"  ON rim_common_masters;
DROP POLICY IF EXISTS "write_masters" ON rim_common_masters;

-- Enable RLS (may already be enabled if 022 policies ran; IF NOT ENABLED is safe)
ALTER TABLE rim_common_master_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE rim_common_masters      ENABLE ROW LEVEL SECURITY;

-- rim_common_master_types: system-seeded, any authenticated user can read
CREATE POLICY "auth_read_types" ON rim_common_master_types
    FOR SELECT TO authenticated USING (true);

-- rim_common_masters: full tenant isolation via JWT claims
CREATE POLICY "auth_rw_masters" ON rim_common_masters
    FOR ALL TO authenticated
    USING (
        client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
    )
    WITH CHECK (
        client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
        AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
    );

-- Strip anon from data tables — only authenticated (JWT holder) can access
REVOKE ALL ON rim_common_master_types FROM anon;
REVOKE ALL ON rim_common_masters       FROM anon;
GRANT SELECT               ON rim_common_master_types TO authenticated;
GRANT SELECT, INSERT, UPDATE ON rim_common_masters    TO authenticated;
