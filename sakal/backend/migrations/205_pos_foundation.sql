-- ============================================================================
-- Migration 205: POS Foundation — terminals, devices, PIN-only till login,
-- per-terminal user access, and the handful of POS-specific company settings
-- (idle lock, weighted-barcode parsing, PIN policy, minimum selling price).
-- ============================================================================
-- Design reference: sakal/docs/pos/ (full requirements + data model). This is
-- the FIRST slice of the recommended build order in docs/pos/10_phase_plan.md
-- — terminals/devices/access must exist before a shift, a sale, or anything
-- else POS-specific can be built on top of it.
--
-- Nothing here duplicates an existing mechanism:
--   - A "store" IS a SAKAL location (ric_locations) — no new concept there.
--   - Sales/stock/tax/discount/currency/offline all reuse Quick Invoice's
--     existing engine unchanged (rih_sales_invoices etc.) — see
--     docs/pos/00_index.md's "already built" table.
--   - Negative-stock behavior needs ZERO new code: fn_post_stock_movement
--     (036/060) already checks BOTH rim_products.flags->>'allow_negative_stock'
--     (item-level) AND ric_locations.is_negative_stock_allowed (location-
--     level) before letting an outward movement go negative, and a batch/
--     serial-tracked product can never go negative regardless of either flag.
--     A POS sale calls the exact same fn_approve_sales_invoice ->
--     fn_post_stock_movement path Quick Invoice already uses, so "Negative
--     Stock Allowed = Yes" at the shop and/or the product already lets a POS
--     invoice complete with no stock on hand — confirmed by reading the live
--     function bodies, not assumed.
--
-- PIN-only till login (no username/password UI on the till at all — user-
-- specified): full username/password sign-in still exists in SAKAL exactly
-- as today (fn_login, unchanged) and is how a device gets provisioned/bound
-- in the first place, on the back-office admin screen — never on the till.
-- Once bound, a device remembers its own client/company/location/terminal in
-- secure storage, and every cashier login after that is a bare PIN against
-- fn_pos_pin_login below. See docs/pos/06_access_security.md §4 for the full
-- design discussion (why PIN uniqueness is checked at SET time rather than a
-- DB constraint, why lockout is device-scoped rather than user-scoped, why
-- the PIN-matching candidate set is always narrowed to the current terminal).
-- ============================================================================

-- ── A. Company-level POS settings (additive columns only) ──────────────────
-- Every one of these exists so nothing POS-specific is hardcoded — a future
-- client with different hardware, a different till-sharing policy, or a
-- different weighted-barcode convention never needs a code change, only a
-- different value in this row.
ALTER TABLE ric_companies
    ADD COLUMN IF NOT EXISTS pos_idle_lock_minutes INTEGER NOT NULL DEFAULT 3,
    ADD COLUMN IF NOT EXISTS pos_allow_concurrent_sessions BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS pos_pin_length INTEGER NOT NULL DEFAULT 4
        CHECK (pos_pin_length BETWEEN 4 AND 8),
    ADD COLUMN IF NOT EXISTS pos_pin_max_attempts INTEGER NOT NULL DEFAULT 5,
    ADD COLUMN IF NOT EXISTS pos_pin_lockout_minutes INTEGER NOT NULL DEFAULT 15,
    -- Weighted-barcode parsing (the common supermarket convention embeds a
    -- product code + weight/price into one barcode). Stored as a prefix
    -- RANGE (e.g. '20'..'29'), not a single value — the real-world GS1-style
    -- convention this mirrors is always a range, and a single-prefix design
    -- would have been a hardcoded assumption we'd have had to walk back the
    -- first time a client needed two digits' worth of prefixes.
    ADD COLUMN IF NOT EXISTS weighted_barcode_prefix_from TEXT,
    ADD COLUMN IF NOT EXISTS weighted_barcode_prefix_to TEXT,
    ADD COLUMN IF NOT EXISTS weighted_barcode_format TEXT
        CHECK (weighted_barcode_format IN ('WEIGHT_EMBEDDED','PRICE_EMBEDDED')),
    ADD COLUMN IF NOT EXISTS pos_require_denomination_count BOOLEAN NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS pos_allow_change_in_foreign_currency BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS pos_require_opening_approval BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS pos_offline_grace_hours INTEGER NOT NULL DEFAULT 24;

COMMENT ON COLUMN ric_companies.pos_idle_lock_minutes IS
    'Minutes of no till interaction before the POS app re-locks to a PIN check (session/cart untouched). See docs/pos/06_access_security.md.';
COMMENT ON COLUMN ric_companies.weighted_barcode_prefix_from IS
    'Inclusive start of the barcode-prefix range (as text, e.g. ''20'') this company uses to encode a weighted/priced-in-store item. NULL = weighted-barcode parsing disabled.';

-- ── B. PIN credential on the user (same hashing convention as password_hash) ─
ALTER TABLE rim_users
    ADD COLUMN IF NOT EXISTS pin_hash TEXT;

COMMENT ON COLUMN rim_users.pin_hash IS
    'bcrypt hash of this user''s POS till PIN (never stored/logged in plain text, same convention as password_hash). Uniqueness within a company is enforced at SET time by fn_set_user_pin, not by a DB constraint on this column — see docs/pos/06_access_security.md §4 for why a unique index on a salted hash cannot do that.';

-- ── C. Minimum selling price floor (master data, one nullable column) ──────
ALTER TABLE rim_products
    ADD COLUMN IF NOT EXISTS min_selling_price NUMERIC(18,4);

COMMENT ON COLUMN rim_products.min_selling_price IS
    'Base-currency floor no discount/override may cross, checked server-side at save time. NULL = no floor configured for this product. See docs/pos/02_pricing_promotions_loyalty.md.';

-- ── D. ric_pos_terminals — the logical checkout counter ────────────────────
CREATE TABLE IF NOT EXISTS ric_pos_terminals (
    id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                    UUID NOT NULL REFERENCES ric_clients(id),
    company_id                   UUID NOT NULL REFERENCES ric_companies(id),
    location_id                  UUID NOT NULL REFERENCES ric_locations(id),
    terminal_code                TEXT NOT NULL,
    terminal_name                TEXT NOT NULL,
    receipt_paper_profile        TEXT NOT NULL DEFAULT 'RECEIPT_80MM'
        CHECK (receipt_paper_profile IN ('RECEIPT_58MM','RECEIPT_80MM')),
    -- Fallback drawer accounts for a shared-till environment where several
    -- cashiers rotate through one physical register. A cashier's own
    -- ric_user_quick_invoice_setup cash accounts (if configured) still win
    -- for an individual walk-up sale — this is only the terminal's default.
    default_cash_account_local_id UUID REFERENCES rim_accounts(id),
    default_cash_account_base_id  UUID REFERENCES rim_accounts(id),
    is_active                    BOOLEAN NOT NULL DEFAULT true,
    is_deleted                   BOOLEAN NOT NULL DEFAULT false,
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                   UUID REFERENCES rim_users(id),
    updated_at                   TIMESTAMPTZ,
    updated_by                   UUID REFERENCES rim_users(id),
    CONSTRAINT uq_pos_terminal_code UNIQUE (client_id, company_id, location_id, terminal_code)
);

DROP TRIGGER IF EXISTS trg_ric_pos_terminals_updated_at ON ric_pos_terminals;
CREATE TRIGGER trg_ric_pos_terminals_updated_at
    BEFORE UPDATE ON ric_pos_terminals
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

DROP POLICY IF EXISTS "auth_rw_ric_pos_terminals" ON ric_pos_terminals;
CREATE POLICY "auth_rw_ric_pos_terminals" ON ric_pos_terminals
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE ric_pos_terminals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ric_pos_terminals FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_pos_terminals TO authenticated;

-- ── E. ric_pos_devices — physical hardware registration/binding ───────────
CREATE TABLE IF NOT EXISTS ric_pos_devices (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            UUID NOT NULL REFERENCES ric_clients(id),
    company_id           UUID NOT NULL REFERENCES ric_companies(id),
    location_id          UUID NOT NULL REFERENCES ric_locations(id),
    device_uid           TEXT NOT NULL,
    device_name          TEXT,
    platform             TEXT CHECK (platform IN ('WEB','ANDROID','WINDOWS','IOS')),
    bound_terminal_id    UUID REFERENCES ric_pos_terminals(id),
    app_version          TEXT,
    last_seen_at         TIMESTAMPTZ,
    last_sync_at         TIMESTAMPTZ,
    -- PIN-login lockout is DEVICE-scoped, not user-scoped — a failed PIN
    -- attempt carries no username, so there is no specific user record to
    -- lock. See docs/pos/06_access_security.md §4.
    failed_pin_attempts  INTEGER NOT NULL DEFAULT 0,
    pin_locked_until     TIMESTAMPTZ,
    is_blocked           BOOLEAN NOT NULL DEFAULT false,
    is_active            BOOLEAN NOT NULL DEFAULT true,
    is_deleted           BOOLEAN NOT NULL DEFAULT false,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID REFERENCES rim_users(id),
    updated_at           TIMESTAMPTZ,
    updated_by           UUID REFERENCES rim_users(id),
    CONSTRAINT uq_pos_device_uid UNIQUE (client_id, company_id, device_uid)
);

DROP TRIGGER IF EXISTS trg_ric_pos_devices_updated_at ON ric_pos_devices;
CREATE TRIGGER trg_ric_pos_devices_updated_at
    BEFORE UPDATE ON ric_pos_devices
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

DROP POLICY IF EXISTS "auth_rw_ric_pos_devices" ON ric_pos_devices;
CREATE POLICY "auth_rw_ric_pos_devices" ON ric_pos_devices
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE ric_pos_devices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ric_pos_devices FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_pos_devices TO authenticated;

-- ── F. ric_user_pos_terminal_access — mirrors ric_user_location_access's own
-- shape, one level down (store access is a prerequisite, terminal access is
-- the narrower, POS-specific layer on top of it).
CREATE TABLE IF NOT EXISTS ric_user_pos_terminal_access (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id    UUID NOT NULL REFERENCES ric_clients(id),
    company_id   UUID NOT NULL REFERENCES ric_companies(id),
    user_id      UUID NOT NULL REFERENCES rim_users(id),
    terminal_id  UUID NOT NULL REFERENCES ric_pos_terminals(id),
    access_type  TEXT NOT NULL DEFAULT 'PERMANENT'
        CHECK (access_type IN ('PERMANENT','TEMPORARY','SHIFT_BASED')),
    valid_from   TIMESTAMPTZ,
    valid_to     TIMESTAMPTZ,
    is_active    BOOLEAN NOT NULL DEFAULT true,
    is_deleted   BOOLEAN NOT NULL DEFAULT false,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID REFERENCES rim_users(id),
    CONSTRAINT uq_user_pos_terminal UNIQUE (client_id, company_id, user_id, terminal_id)
);

DROP POLICY IF EXISTS "auth_rw_ric_user_pos_terminal_access" ON ric_user_pos_terminal_access;
CREATE POLICY "auth_rw_ric_user_pos_terminal_access" ON ric_user_pos_terminal_access
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE ric_user_pos_terminal_access ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ric_user_pos_terminal_access FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_user_pos_terminal_access TO authenticated;

-- A missing row here always means NO access (never "unrestricted" the way
-- v_user_accessible_locations treats a missing location-access row) — a
-- till is a money-handling context, not a visibility filter. Enforced in
-- fn_pos_pin_login's own candidate-set query below, not by a view.

-- ── G. fn_pos_register_device — idempotent, callable pre-auth (anon) ──────
-- A device generates its own stable device_uid once (client-side, secure
-- storage) and calls this on first run. Registering does NOT bind it to a
-- terminal — that's a separate, explicit admin action (fn_bind_pos_device).
CREATE OR REPLACE FUNCTION fn_pos_register_device(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID,
    p_device_uid  TEXT,
    p_device_name TEXT,
    p_platform    TEXT
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO ric_pos_devices (client_id, company_id, location_id, device_uid, device_name, platform, last_seen_at)
    VALUES (p_client_id, p_company_id, p_location_id, p_device_uid, p_device_name, p_platform, now())
    ON CONFLICT (client_id, company_id, device_uid)
    DO UPDATE SET device_name = excluded.device_name, platform = excluded.platform, last_seen_at = now()
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_pos_register_device(uuid, uuid, uuid, text, text, text) TO anon;

-- ── H. fn_bind_pos_device — explicit admin action, authenticated only ─────
CREATE OR REPLACE FUNCTION fn_bind_pos_device(
    p_device_id   UUID,
    p_terminal_id UUID
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE ric_pos_devices SET bound_terminal_id = p_terminal_id, updated_at = now()
     WHERE id = p_device_id;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_bind_pos_device(uuid, uuid) TO authenticated;

-- ── I. fn_set_user_pin — collision-checked, never stores a PIN in plain text
-- Called rarely (onboarding, manager-driven reset), never at login, so an
-- O(active-users-in-company) loop of bcrypt comparisons here is cheap.
CREATE OR REPLACE FUNCTION fn_set_user_pin(
    p_client_id  UUID,
    p_company_id UUID,
    p_user_id    UUID,
    p_new_pin    TEXT
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_expected_len INTEGER;
    v_other        RECORD;
BEGIN
    SELECT pos_pin_length INTO v_expected_len FROM ric_companies WHERE id = p_company_id;

    IF p_new_pin !~ '^[0-9]+$' OR length(p_new_pin) <> v_expected_len THEN
        RAISE EXCEPTION 'INVALID_PIN_FORMAT'
            USING DETAIL = format('PIN must be exactly %s digits.', v_expected_len);
    END IF;

    FOR v_other IN
        SELECT pin_hash FROM rim_users
         WHERE client_id = p_client_id AND company_id = p_company_id
           AND id <> p_user_id AND is_active = true AND is_deleted = false
           AND pin_hash IS NOT NULL
    LOOP
        IF crypt(p_new_pin, v_other.pin_hash) = v_other.pin_hash THEN
            RAISE EXCEPTION 'PIN_ALREADY_IN_USE'
                USING DETAIL = 'Another active user in this company already has this PIN. Choose a different one.';
        END IF;
    END LOOP;

    UPDATE rim_users SET pin_hash = crypt(p_new_pin, gen_salt('bf')), updated_at = now()
     WHERE id = p_user_id;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_set_user_pin(uuid, uuid, uuid, text) TO authenticated;

-- ── J. fn_pos_pin_login — the till's everyday sign-in, callable pre-auth ──
-- Mirrors fn_login's own validation + JWT shape, with the candidate set
-- narrowed to users who already have ric_user_pos_terminal_access for THIS
-- terminal (never the whole company) so matching stays fast regardless of
-- company size. Device-scoped lockout per docs/pos/06_access_security.md §4.
CREATE OR REPLACE FUNCTION fn_pos_pin_login(
    p_device_uid TEXT,
    p_pin        TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_device       ric_pos_devices%rowtype;
    v_terminal     ric_pos_terminals%rowtype;
    v_company      ric_companies%rowtype;
    v_candidate    RECORD;
    v_user         rim_users%rowtype;
    v_matched      BOOLEAN := false;
    v_company_name TEXT;
    v_token        TEXT;
    v_secret       TEXT;
BEGIN
    SELECT * INTO v_device FROM ric_pos_devices WHERE device_uid = p_device_uid AND is_deleted = false;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_REGISTERED';
    END IF;
    IF v_device.is_blocked THEN
        RAISE EXCEPTION 'DEVICE_BLOCKED';
    END IF;
    IF v_device.bound_terminal_id IS NULL THEN
        RAISE EXCEPTION 'DEVICE_NOT_BOUND';
    END IF;
    IF v_device.pin_locked_until IS NOT NULL AND v_device.pin_locked_until > now() THEN
        RAISE EXCEPTION 'PIN_LOCKED'
            USING DETAIL = format('Too many incorrect PINs on this till. Try again after %s.', v_device.pin_locked_until);
    END IF;

    SELECT * INTO v_terminal FROM ric_pos_terminals WHERE id = v_device.bound_terminal_id;
    SELECT * INTO v_company  FROM ric_companies     WHERE id = v_device.company_id;

    -- Candidate set: only users with active, date-effective terminal access
    -- for THIS terminal. A missing/expired row = not a candidate at all
    -- (never "unrestricted").
    FOR v_candidate IN
        SELECT u.* FROM rim_users u
        JOIN ric_user_pos_terminal_access a
          ON a.user_id = u.id AND a.client_id = v_device.client_id AND a.company_id = v_device.company_id
        WHERE a.terminal_id = v_terminal.id
          AND a.is_active = true AND a.is_deleted = false
          AND (a.access_type = 'PERMANENT' OR now() BETWEEN coalesce(a.valid_from, now()) AND coalesce(a.valid_to, now()))
          AND u.is_active = true AND u.is_deleted = false
          AND u.pin_hash IS NOT NULL
          AND (u.locked_until IS NULL OR u.locked_until < now())
    LOOP
        IF crypt(p_pin, v_candidate.pin_hash) = v_candidate.pin_hash THEN
            v_user := v_candidate;
            v_matched := true;
            EXIT;
        END IF;
    END LOOP;

    v_device.last_seen_at := now();

    IF NOT v_matched THEN
        UPDATE ric_pos_devices
           SET failed_pin_attempts = failed_pin_attempts + 1,
               pin_locked_until = CASE
                   WHEN failed_pin_attempts + 1 >= v_company.pos_pin_max_attempts
                   THEN now() + (v_company.pos_pin_lockout_minutes || ' minutes')::interval
                   ELSE pin_locked_until
               END,
               last_seen_at = now()
         WHERE id = v_device.id;
        RAISE EXCEPTION 'INVALID_PIN';
    END IF;

    UPDATE ric_pos_devices SET failed_pin_attempts = 0, pin_locked_until = NULL, last_seen_at = now()
     WHERE id = v_device.id;

    SELECT company_name INTO v_company_name FROM ric_companies WHERE id = v_user.company_id;

    BEGIN
        v_secret := coalesce(
            current_setting('app.jwt_secret', true),
            (SELECT value FROM _sakal_config WHERE key = 'jwt_secret')
        );
        IF v_secret IS NOT NULL THEN
            v_token := sign(
                json_build_object(
                    'role',        'authenticated',
                    'user_id',     v_user.id::text,
                    'client_id',   v_user.client_id::text,
                    'company_id',  v_user.company_id::text,
                    -- POS-specific claims so a later RPC can scope itself to
                    -- this terminal/device without an extra lookup.
                    'pos_terminal_id', v_terminal.id::text,
                    'pos_device_id',   v_device.id::text,
                    'iat', extract(epoch FROM now())::integer,
                    'exp', extract(epoch FROM (now() + interval '8 hours'))::integer
                )::json,
                v_secret
            );
        END IF;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'JWT sign error (access_token will be null): %', SQLERRM;
        v_token := null;
    END;

    RETURN json_build_object(
        'user_id',       v_user.id,
        'client_id',     v_user.client_id,
        'company_id',    v_user.company_id,
        'company_name',  coalesce(v_company_name, ''),
        'location_id',   v_terminal.location_id,
        'full_name',     v_user.full_name,
        'username',      v_user.username,
        'pos_terminal_id', v_terminal.id,
        'pos_terminal_name', v_terminal.terminal_name,
        'pos_device_id', v_device.id,
        'access_token',  v_token
    );
END;
$$;
GRANT EXECUTE ON FUNCTION fn_pos_pin_login(text, text) TO anon;

-- ── K. Menu seed — new POS module, two groups ──────────────────────────────
-- "Point of Sale" (the till screens every cashier uses) and "POS Setup"
-- (admin-only configuration: terminals, devices, schemes, loyalty, reasons).
-- Added for existing companies here; fn_seed_client_modules.sql gets the
-- same rows so future clients receive it automatically (separate, manual
-- re-run in the Supabase SQL editor per this project's standing convention
-- for that file — it is not a migration and does not auto-apply).
INSERT INTO ric_system_modules (client_id, company_id, module_code, module_name, serial_no)
SELECT c.client_id, c.id, 'POS', 'Point of Sale', 5
FROM ric_companies c
ON CONFLICT (client_id, company_id, module_code) DO NOTHING;

INSERT INTO ric_master_menus (client_id, company_id, module_id, feature_code, feature_name, screen_name, group_code, group_name, group_serial_no, serial_no, approve_allowed)
SELECT m.client_id, m.company_id, m.id, v.feature_code, v.feature_name, v.screen_name, v.group_code, v.group_name, v.group_serial_no, v.serial_no, v.approve_allowed
FROM ric_system_modules m
CROSS JOIN (VALUES
    ('POS-SALE',      'New Sale',            '/pos/sale',          'POS-OPS',   'Point of Sale', 1, 1, false),
    ('POS-HOLD',      'Held Sales',          '/pos/hold',          'POS-OPS',   'Point of Sale', 1, 2, false),
    ('POS-RETURN',    'POS Return',          '/pos/return',        'POS-OPS',   'Point of Sale', 1, 3, true),
    ('POS-PRICECHK',  'Price Check',         '/pos/price-check',   'POS-OPS',   'Point of Sale', 1, 4, false),
    ('POS-SHIFT',     'Shift &amp; Cash',    '/pos/shift',         'POS-OPS',   'Point of Sale', 1, 5, true),
    ('POS-PAYOUT',    'Cash In/Out/Payout',  '/pos/payout',        'POS-OPS',   'Point of Sale', 1, 6, true),
    ('POS-APPROVALS', 'Manager Review',      '/pos/approvals',     'POS-OPS',   'Point of Sale', 1, 7, false),
    ('POS-SETUP',     'POS Setup',           '/pos/admin',         'POS-SETUP', 'POS Setup',     2, 1, false),
    ('POS-REPORTS',   'POS Reports',         '/pos/reports',       'POS-SETUP', 'POS Setup',     2, 2, false),
    -- Not a separate screen — a sub-permission checked within POS-RETURN
    -- itself (screen_name is NOT NULL on ric_master_menus, so this points at
    -- the same screen it gates rather than a nonexistent route).
    ('SL-RET-NOREF',  'Return Without Receipt', '/pos/return',     'POS-OPS',   'Point of Sale', 1, 8, true)
) AS v(feature_code, feature_name, screen_name, group_code, group_name, group_serial_no, serial_no, approve_allowed)
WHERE m.module_code = 'POS'
ON CONFLICT (client_id, company_id, feature_code) DO NOTHING;
