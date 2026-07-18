-- ============================================================
-- Migration 091: Number-format settings — grouping style + per-currency
-- rate/price decimal precision
-- ============================================================
-- User-raised requirement: this app deals in multi-currency (a DRC/Zambia
-- company buys in USD/EUR but sells in CDF/ZMW) and a real gap surfaced
-- while reviewing the Sales Invoice redesign — numbers show as plain
-- ".toStringAsFixed(2)" everywhere, with no grouping separator, and no way
-- to configure it. Researched how Odoo/SAP solve this (see
-- project_redesign_widgets_implementation memory for the full writeup) —
-- confirmed this is genuinely TWO independent settings, not one:
--
-- 1. GROUPING STYLE (this migration's ric_companies.number_format) —
--    company-level, cosmetic, applies to every number shown anywhere:
--    INTERNATIONAL (115,356.00) vs INDIAN (1,15,356.00) digit grouping.
-- 2. RATE/PRICE DECIMAL PRECISION (this migration's
--    rim_currencies.rate_decimal_places) — how many decimals a UNIT
--    PRICE/RATE in that specific currency is entered/shown with (a USD
--    unit cost may need 4-5dp when converted from a bulk purchase; CDF
--    only needs 2). Per-currency, not a single global number.
--
-- Deliberately NOT built here (out of scope for this pass, flagged not
-- hidden): a THIRD axis — calculated TOTALS (Gross/Tax/Grand Total, any
-- report subtotal) always round to a FIXED 2 decimal places regardless of
-- which currency or rate precision produced them, matching universal
-- accounting practice — this is a pure Flutter-side formatting rule
-- (AppNumberFormat.amount()), no schema needed for it.
--
-- Also NOT built here: validating/truncating what a user TYPES into a
-- live Rate field to the currency's own rate_decimal_places, and no
-- master-screen UI to edit rate_decimal_places yet (admin sets it via SQL
-- for now) — both flagged as real follow-ups in
-- project_redesign_widgets_implementation memory, not silently dropped.
-- ============================================================

ALTER TABLE ric_companies
  ADD COLUMN IF NOT EXISTS number_format TEXT NOT NULL DEFAULT 'INTERNATIONAL'
    CHECK (number_format IN ('INTERNATIONAL', 'INDIAN'));

ALTER TABLE rim_currencies
  ADD COLUMN IF NOT EXISTS rate_decimal_places INT NOT NULL DEFAULT 2
    CHECK (rate_decimal_places BETWEEN 0 AND 6);

-- ── fn_get_company_settings — now also returns number_format ───────────────
CREATE OR REPLACE FUNCTION fn_get_company_settings(p_company_id UUID)
RETURNS JSON LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT json_build_object(
    'enable_barcode',     enable_barcode,
    'enable_part_number', enable_part_number,
    'qty_entry_mode',     qty_entry_mode,
    'number_format',      number_format
  )
  FROM ric_companies
  WHERE id = p_company_id;
$$;

GRANT EXECUTE ON FUNCTION fn_get_company_settings(UUID) TO authenticated;

-- ── fn_login — now also returns number_format ───────────────────────────────
-- Reproduced verbatim from 034 with exactly one addition (number_format in
-- the final json_build_object) — CREATE OR REPLACE on an unchanged
-- parameter list is safe to re-run.
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
        'qty_entry_mode',     coalesce(v_company.qty_entry_mode,     'PACK_AND_LOOSE'),
        'number_format',      coalesce(v_company.number_format,      'INTERNATIONAL')
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_login(text, text, text) TO anon;
