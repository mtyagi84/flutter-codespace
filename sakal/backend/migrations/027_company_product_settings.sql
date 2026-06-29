-- ============================================================
-- Migration 027: Company Product Coding Settings
-- ============================================================
-- Adds enable_barcode + enable_part_number to ric_companies.
-- These are setup-time decisions — locked once products exist.
--
-- Objects:
--   ALTER TABLE ric_companies            → add two boolean columns
--   fn_lock_company_product_settings()  → trigger: block changes when products exist
--   trg_lock_company_product_settings   → BEFORE UPDATE trigger on ric_companies
--   fn_get_company_settings(UUID)       → RPC: called on company switch to refresh session
--   fn_login (updated)                  → now returns enable_barcode + enable_part_number
-- ============================================================

-- ── Add columns ───────────────────────────────────────────────────────────────
ALTER TABLE ric_companies
  ADD COLUMN IF NOT EXISTS enable_barcode     BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS enable_part_number BOOLEAN NOT NULL DEFAULT false;

-- ── Lock trigger ─────────────────────────────────────────────────────────────
-- Fires BEFORE UPDATE on ric_companies.
-- Blocks changes to the two product coding flags if any products already exist
-- for this company. App-level UI shows them as read-only before sending the
-- PATCH — this trigger is the DB backstop (prevents direct API bypass).
CREATE OR REPLACE FUNCTION fn_lock_company_product_settings()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.enable_barcode     IS DISTINCT FROM OLD.enable_barcode OR
      NEW.enable_part_number IS DISTINCT FROM OLD.enable_part_number) THEN
    IF EXISTS (
      SELECT 1 FROM rim_products
      WHERE company_id = OLD.id AND is_deleted = false
      LIMIT 1
    ) THEN
      RAISE EXCEPTION 'PRODUCT_SETTINGS_LOCKED'
        USING DETAIL = 'Barcode and Part Number settings cannot be changed after products have been created.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lock_company_product_settings ON ric_companies;
CREATE TRIGGER trg_lock_company_product_settings
  BEFORE UPDATE ON ric_companies
  FOR EACH ROW EXECUTE FUNCTION fn_lock_company_product_settings();

-- ── fn_get_company_settings ───────────────────────────────────────────────────
-- Called by Flutter on every company switch (parallel with fn_get_user_menu).
-- Returns only the company settings the session needs — keeps the call lightweight.
CREATE OR REPLACE FUNCTION fn_get_company_settings(p_company_id UUID)
RETURNS JSON LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT json_build_object(
    'enable_barcode',     enable_barcode,
    'enable_part_number', enable_part_number
  )
  FROM ric_companies
  WHERE id = p_company_id;
$$;

GRANT EXECUTE ON FUNCTION fn_get_company_settings(UUID) TO authenticated;

-- ── Update fn_login ───────────────────────────────────────────────────────────
-- Now fetches full ric_companies row so enable_barcode + enable_part_number
-- can be included in the login response and stored in the Flutter session.
CREATE OR REPLACE FUNCTION fn_login(
    p_client_no text,
    p_username  text,
    p_password  text
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_client   ric_clients%rowtype;
    v_company  ric_companies%rowtype;
    v_user     rim_users%rowtype;
    v_token    text;
    v_secret   text;
BEGIN
    SELECT * INTO v_client FROM ric_clients
    WHERE client_no = upper(trim(p_client_no)) AND is_deleted = false AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_CREDENTIALS'; END IF;

    IF v_client.license_status = 'EXPIRED' THEN RAISE EXCEPTION 'LICENSE_EXPIRED'; END IF;
    IF v_client.license_status = 'TRIAL' AND v_client.trial_end_date < current_date THEN
        UPDATE ric_clients SET license_status = 'EXPIRED' WHERE id = v_client.id;
        RAISE EXCEPTION 'TRIAL_EXPIRED';
    END IF;

    SELECT * INTO v_user FROM rim_users
    WHERE client_id = v_client.id AND username = lower(trim(p_username)) AND is_deleted = false;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_CREDENTIALS'; END IF;
    IF NOT v_user.is_active THEN RAISE EXCEPTION 'ACCOUNT_INACTIVE'; END IF;
    IF v_user.locked_until IS NOT NULL AND v_user.locked_until > now() THEN RAISE EXCEPTION 'ACCOUNT_LOCKED'; END IF;

    IF v_user.password_hash != crypt(p_password, v_user.password_hash) THEN
        UPDATE rim_users SET failed_attempts = failed_attempts + 1,
            locked_until = CASE WHEN failed_attempts + 1 >= 5 THEN now() + interval '30 minutes' ELSE locked_until END
        WHERE id = v_user.id;
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    UPDATE rim_users SET failed_attempts = 0, locked_until = null, last_login_at = now() WHERE id = v_user.id;
    SELECT * INTO v_company FROM ric_companies WHERE id = v_user.company_id;

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
        'user_id',          v_user.id,
        'client_id',        v_user.client_id,
        'client_no',        v_client.client_no,
        'company_id',       v_user.company_id,
        'company_name',     coalesce(v_company.company_name, ''),
        'location_id',      v_user.default_location_id,
        'full_name',        v_user.full_name,
        'username',         v_user.username,
        'must_change',      v_user.must_change_password,
        'access_token',     v_token,
        'enable_barcode',     coalesce(v_company.enable_barcode,     false),
        'enable_part_number', coalesce(v_company.enable_part_number, false)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_login(text, text, text) TO anon;
