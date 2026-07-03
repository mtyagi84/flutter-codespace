-- ============================================================
-- Migration 034: Company Quantity Entry Mode
-- ============================================================
-- Adds qty_entry_mode to ric_companies — controls whether Purchase Order
-- (and future GRN/Sales/Transfer) line entry shows both Pack + Loose qty
-- fields, or just Pack. Discussed during PO design (migration 031) but
-- never implemented — see project_purchase_order_design memory.
--
-- Not locked once transactions exist: unlike enable_barcode/enable_part_number
-- (migration 027), this is a display preference only — rid_purchase_order_lines
-- always stores qty_pack + qty_loose regardless of this setting, so toggling
-- it never corrupts existing data.
--
-- Objects:
--   ALTER TABLE ric_companies      → add qty_entry_mode
--   fn_get_company_settings (upd)  → now returns qty_entry_mode
--   fn_login (upd)                 → now returns qty_entry_mode
-- ============================================================

ALTER TABLE ric_companies
  ADD COLUMN IF NOT EXISTS qty_entry_mode TEXT NOT NULL DEFAULT 'PACK_AND_LOOSE'
    CHECK (qty_entry_mode IN ('PACK_ONLY', 'PACK_AND_LOOSE'));

-- ── fn_get_company_settings ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_get_company_settings(p_company_id UUID)
RETURNS JSON LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT json_build_object(
    'enable_barcode',     enable_barcode,
    'enable_part_number', enable_part_number,
    'qty_entry_mode',     qty_entry_mode
  )
  FROM ric_companies
  WHERE id = p_company_id;
$$;

GRANT EXECUTE ON FUNCTION fn_get_company_settings(UUID) TO authenticated;

-- ── Update fn_login ───────────────────────────────────────────────────────────
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
        'enable_part_number', coalesce(v_company.enable_part_number, false),
        'qty_entry_mode',     coalesce(v_company.qty_entry_mode,     'PACK_AND_LOOSE')
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_login(text, text, text) TO anon;
