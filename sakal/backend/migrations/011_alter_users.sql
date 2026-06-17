-- ============================================================
-- 011_alter_users.sql
-- Add identity + preference columns to rim_users.
-- Add fn_create_user and fn_admin_set_password RPCs.
-- ============================================================

ALTER TABLE rim_users
  ADD COLUMN IF NOT EXISTS salutation    text
      CHECK (salutation IN ('Mr', 'Mrs', 'Ms', 'Dr', 'Prof')),
  ADD COLUMN IF NOT EXISTS photo_url     text,
  ADD COLUMN IF NOT EXISTS language_code text NOT NULL DEFAULT 'en',
  ADD COLUMN IF NOT EXISTS theme         text NOT NULL DEFAULT 'light'
      CHECK (theme IN ('light', 'dark'));


-- ── fn_create_user ────────────────────────────────────────────────────────────
-- Creates a new user with bcrypt password hashing (server-side).
-- Call via PostgREST: POST /rpc/fn_create_user
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_create_user(
    p_client_id             uuid,
    p_company_id            uuid,
    p_location_id           uuid    DEFAULT NULL,
    p_username              text    DEFAULT NULL,
    p_full_name             text    DEFAULT NULL,
    p_salutation            text    DEFAULT NULL,
    p_email                 text    DEFAULT NULL,
    p_phone                 text    DEFAULT NULL,
    p_photo_url             text    DEFAULT NULL,
    p_language_code         text    DEFAULT 'en',
    p_theme                 text    DEFAULT 'light',
    p_password              text    DEFAULT 'Change@123',
    p_must_change_password  boolean DEFAULT true,
    p_created_by            uuid    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO rim_users (
        client_id, company_id, default_location_id,
        username, full_name, salutation,
        email, phone, photo_url,
        language_code, theme,
        password_hash, must_change_password,
        is_active, is_deleted,
        created_at, created_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id,
        p_username, p_full_name, p_salutation,
        p_email, p_phone, p_photo_url,
        p_language_code, p_theme,
        crypt(p_password, gen_salt('bf')), p_must_change_password,
        true, false,
        now(), p_created_by
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;


-- ── fn_admin_set_password ─────────────────────────────────────────────────────
-- Admin resets a user's password. Forces must_change_password = true.
-- Call via PostgREST: POST /rpc/fn_admin_set_password
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_admin_set_password(
    p_user_id       uuid,
    p_new_password  text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE rim_users
    SET password_hash        = crypt(p_new_password, gen_salt('bf')),
        must_change_password = true,
        updated_at           = now()
    WHERE id = p_user_id
      AND is_deleted = false;
END;
$$;
