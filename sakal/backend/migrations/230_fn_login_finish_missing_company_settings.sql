-- ============================================================
-- Migration 230: fn_login_finish was missing every company-setting
-- field the app actually depends on
-- ============================================================
-- Real, serious regression found live 2026-10-19 while testing barcode
-- scanning on client SK-18538 — the Barcode field on Sales Quotation
-- silently never rendered at all, traced to `session.enableBarcode` being
-- false despite `ric_companies.enable_barcode = true` for that tenant.
-- Root cause: migration 226's `fn_login_finish` refactor (the shared core
-- BOTH `fn_login` and `fn_login_by_email` delegate to) only ever selected
-- `company_name` from `ric_companies` and returned a JSON object missing
-- `enable_barcode`, `enable_part_number`, `qty_entry_mode`,
-- `quick_invoice_dispatch_stock`, `quick_invoice_collect_cash`, and
-- `number_format` entirely — fields the ORIGINAL (pre-226) `fn_login`
-- always returned, confirmed via every one of these fields' own source
-- migrations (027 enable_barcode, 034 qty_entry_mode, 075 barcode/part
-- number retrofit, 088 quick_invoice_dispatch_stock/collect_cash, 091
-- number_format). The Flutter side's own `UserSession` construction
-- (login_screen.dart) silently defaults every one of these with `?? false`/
-- `?? true`/`?? 'PACK_AND_LOOSE'`/`?? 'INTERNATIONAL'` when the key is
-- missing — which is why this shipped invisibly for 4 days with no error,
-- exception, or crash anywhere: every session just silently ran as if
-- these company settings were all off/default, regardless of what the
-- company admin actually configured.
--
-- Impact: every login, via EITHER fn_login or fn_login_by_email, on EVERY
-- tenant, since migration 226 shipped (2026-10-15) — not specific to one
-- company or one user. Confirmed live before this fix: SK-18538's own
-- enable_barcode=true in the database, but the live fn_login_by_email
-- response for vineet@gmail.com was missing the key entirely.
--
-- Fix: reproduces fn_login_finish's CURRENT full live body verbatim (re-
-- fetched via pg_get_functiondef immediately before writing this, per this
-- project's own "always re-verify the live definition, never trust the
-- migration file alone" rule), adding exactly the missing SELECT (from
-- ric_companies, alongside the existing company_name fetch) and the
-- missing json_build_object entries — same column names confirmed live via
-- information_schema against ric_companies.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_login_finish(p_user rim_users, p_password text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_client       ric_clients%rowtype;
    v_company      ric_companies%rowtype;
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

    SELECT * INTO v_company
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
        'company_name', coalesce(v_company.company_name, ''),
        'location_id',  p_user.default_location_id,
        'full_name',    p_user.full_name,
        'username',     p_user.username,
        'must_change',  p_user.must_change_password,
        'is_first_login', v_is_first_login,
        'access_token', v_token,
        'enable_barcode',              coalesce(v_company.enable_barcode, false),
        'enable_part_number',          coalesce(v_company.enable_part_number, false),
        'qty_entry_mode',              coalesce(v_company.qty_entry_mode, 'PACK_AND_LOOSE'),
        'quick_invoice_dispatch_stock', coalesce(v_company.quick_invoice_dispatch_stock, true),
        'quick_invoice_collect_cash',   coalesce(v_company.quick_invoice_collect_cash, true),
        'number_format',               coalesce(v_company.number_format, 'INTERNATIONAL')
    );
END;
$function$;
