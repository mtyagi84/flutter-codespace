-- ============================================================
-- Migration 088: Quick Invoice — company config + per-user setup
-- ============================================================
-- First of three migrations building the Sales Invoice ("Quick Invoice")
-- module — see docs/screens/sales_invoice.md for the full requirement
-- document. This migration lays the config groundwork the other two
-- (089 core invoice, 090 manager review) depend on:
--
--   PART A — ric_companies.quick_invoice_dispatch_stock /
--            quick_invoice_collect_cash: company-wide toggles deciding
--            whether stock/cash move immediately at invoice save, or
--            are deferred to future dedicated screens. Freely editable,
--            no lock trigger (unlike enable_barcode/qty_entry_mode) —
--            toggling only changes behavior for FUTURE invoices; each
--            invoice snapshots the mode it was created under onto its
--            own header in migration 089, so a later flag change can
--            never reinterpret an existing invoice's history.
--   PART B — ric_user_quick_invoice_setup: per-user cash-sale defaults
--            (location, cash customer, two cash accounts, default sales
--            person). Same shape/RLS precedent as ric_user_sales_controls
--            (086/087). The "lock after first invoice" trigger is
--            deliberately deferred to migration 089 (once
--            rih_sales_invoices exists to check against) rather than
--            created here against a not-yet-existing table — a forward-
--            reference class of mistake caught live this same session
--            on the Sales Order/Payment Terms migration pair, not worth
--            repeating even though PL/pgSQL bodies aren't validated
--            against table existence at CREATE time (only at first
--            execution) the way a DDL FK constraint would be.
--   PART C — Menu seeds for the two new screens this module needs
--            beyond the already-placeholdered /sales/invoices (SL-INV,
--            seeded since migration 005 — confirmed via
--            fn_seed_client_modules.sql, no new seed needed for it):
--            Quick Invoice Setup (AD module, AD-SETG group, same
--            precedent as Payment Terms/AD-PAYTERM in 086) and Sales
--            Invoice — Manager Review (SL module, SL-TXN group,
--            positioned right after SL-INV, same "review screen sits
--            beside its parent transaction" precedent as Stock Count
--            Review/IN-CNR beside Stock Count/IN-CNT).
-- ============================================================


-- ============================================================
-- PART A: ric_companies flags
-- ============================================================

ALTER TABLE ric_companies
  ADD COLUMN IF NOT EXISTS quick_invoice_dispatch_stock BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS quick_invoice_collect_cash   BOOLEAN NOT NULL DEFAULT true;

-- ── fn_get_company_settings ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_get_company_settings(p_company_id UUID)
RETURNS JSON LANGUAGE sql STABLE SECURITY INVOKER AS $$
  SELECT json_build_object(
    'enable_barcode',                enable_barcode,
    'enable_part_number',            enable_part_number,
    'qty_entry_mode',                qty_entry_mode,
    'quick_invoice_dispatch_stock',  quick_invoice_dispatch_stock,
    'quick_invoice_collect_cash',    quick_invoice_collect_cash
  )
  FROM ric_companies
  WHERE id = p_company_id;
$$;

GRANT EXECUTE ON FUNCTION fn_get_company_settings(UUID) TO authenticated;

-- ── fn_login ───────────────────────────────────────────────────────────────
-- Same RETURNS json / same params as the latest prior redefinition
-- (034_company_qty_entry_mode.sql) — plain CREATE OR REPLACE is safe,
-- no DROP FUNCTION needed (shape unchanged).
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
        'enable_barcode',               coalesce(v_company.enable_barcode,               false),
        'enable_part_number',           coalesce(v_company.enable_part_number,           false),
        'qty_entry_mode',               coalesce(v_company.qty_entry_mode,               'PACK_AND_LOOSE'),
        'quick_invoice_dispatch_stock', coalesce(v_company.quick_invoice_dispatch_stock, true),
        'quick_invoice_collect_cash',   coalesce(v_company.quick_invoice_collect_cash,   true)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_login(text, text, text) TO anon;


-- ============================================================
-- PART B: ric_user_quick_invoice_setup
-- ============================================================
-- Per-user cash-sale defaults, same family/shape as
-- ric_user_sales_controls (087_sales_order.sql). A missing row simply
-- means that user has no Quick Invoice access yet (Flutter blocks
-- Cash-type sales for a user with no row — Credit-type sales don't need
-- one). Lock trigger lives in 089 (see header comment).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ric_user_quick_invoice_setup (
    id                      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id               UUID          NOT NULL REFERENCES ric_clients(id),
    company_id              UUID          NOT NULL REFERENCES ric_companies(id),
    user_id                 UUID          NOT NULL REFERENCES rim_users(id),
    location_id             UUID          NOT NULL REFERENCES ric_locations(id),
    cash_customer_id        UUID          NOT NULL REFERENCES rim_accounts(id),
    local_cash_account_id   UUID          NOT NULL REFERENCES rim_accounts(id),
    base_cash_account_id    UUID          NOT NULL REFERENCES rim_accounts(id),
    -- Prefill-only — never locked, never re-validated at invoice save.
    default_sales_person_id UUID          REFERENCES rim_users(id),
    is_active                BOOLEAN      NOT NULL DEFAULT true,
    is_deleted                BOOLEAN     NOT NULL DEFAULT false,
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by                UUID        REFERENCES rim_users(id),
    updated_at                TIMESTAMPTZ,
    updated_by                 UUID       REFERENCES rim_users(id),
    CONSTRAINT uq_user_quick_invoice_setup UNIQUE (client_id, company_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_quick_invoice_setup_tenant ON ric_user_quick_invoice_setup (client_id, company_id);

DROP TRIGGER IF EXISTS trg_ric_user_quick_invoice_setup_updated_at ON ric_user_quick_invoice_setup;
CREATE TRIGGER trg_ric_user_quick_invoice_setup_updated_at
    BEFORE UPDATE ON ric_user_quick_invoice_setup
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE ric_user_quick_invoice_setup ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_user_quick_invoice_setup" ON ric_user_quick_invoice_setup;
CREATE POLICY "auth_rw_user_quick_invoice_setup" ON ric_user_quick_invoice_setup
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_user_quick_invoice_setup FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_user_quick_invoice_setup TO authenticated;


-- ============================================================
-- PART C: Menu seeds
-- ============================================================

-- Future clients: fn_seed_client_modules.sql updated separately below
-- (this migration only backfills EXISTING companies).

-- Make room: shift SL-RET/SL-RCP down one to seat SL-INR right after SL-INV.
UPDATE ric_master_menus SET serial_no = serial_no + 1
WHERE feature_code IN ('SL-RET', 'SL-RCP')
  AND module_id IN (SELECT id FROM ric_system_modules WHERE module_code = 'SL');

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'SL-INR', 'Sales Invoice - Manager Review', '/sales/invoice-manager-review',
    3, 'SL-TXN', 'Transactions', 1,
    true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'SL'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'AD-QIS', 'Quick Invoice Setup', '/setup/quick-invoice-setup',
    6, 'AD-SETG', 'System Setup', 0,
    false, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'AD'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
