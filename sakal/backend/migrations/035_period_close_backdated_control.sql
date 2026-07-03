-- ============================================================
-- Migration 035: Period Close + Backdated Entry Control
-- ============================================================
-- First of four foundational migrations before GRN (035-038).
-- Two independent controls on transaction dates:
--   1. Period Close (ric_period_locks)      — compliance-grade, company-wide,
--      e.g. "GST filed for January, lock it." Reopening is a logged,
--      permission-gated action, never a silent delete.
--   2. Backdated Entry Control (ric_backdated_entry_control) — a softer,
--      per-transaction-type operational guardrail ("how many days back can
--      a NEW entry normally be dated"), independent of Period Close.
--
-- Both checks are enforced only at Approve/Post time, never at Draft save —
-- matches the existing rule that DRAFT never affects books.
--
-- Objects:
--   ric_period_locks                    → table
--   ric_backdated_entry_control          → table
--   fn_check_period_open(company, date) → raises PERIOD_LOCKED / FY_CLOSED
--   fn_check_backdate_allowed(...)      → raises BACKDATE_NOT_ALLOWED / FUTURE_DATE_NOT_ALLOWED
--   rim_voucher_types                   → seed 'GRN' voucher type (needed by
--                                          fn_next_trans_no once migration 038 lands)
--   ric_master_menus                    → seed 'AD-PDC'/'AD-BDC' features
--                                          (backfill existing companies + seed function)
-- ============================================================

-- ── ric_period_locks ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ric_period_locks (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID        NOT NULL REFERENCES ric_clients(id),
    company_id          UUID        NOT NULL REFERENCES ric_companies(id),
    period_start_date   DATE        NOT NULL,
    period_end_date     DATE        NOT NULL,
    locked_by           UUID        REFERENCES rim_users(id),
    locked_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    reopened_by         UUID        REFERENCES rim_users(id),
    reopened_at         TIMESTAMPTZ,
    reopen_reason       TEXT,
    is_active           BOOLEAN     NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID        REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID        REFERENCES rim_users(id),
    CONSTRAINT chk_period_lock_dates CHECK (period_end_date >= period_start_date)
);

CREATE INDEX IF NOT EXISTS idx_period_locks_company_active
    ON ric_period_locks (client_id, company_id, is_active);

CREATE TRIGGER trg_ric_period_locks_updated_at
    BEFORE UPDATE ON ric_period_locks
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE ric_period_locks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_period_locks" ON ric_period_locks
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_period_locks FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_period_locks TO authenticated;

-- ── ric_backdated_entry_control ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ric_backdated_entry_control (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID        NOT NULL REFERENCES ric_clients(id),
    company_id          UUID        NOT NULL REFERENCES ric_companies(id),
    transaction_type    TEXT        NOT NULL,     -- 'GRN','SALES_INVOICE','PAYMENT_RECEIPT', etc.
    max_backdate_days   INTEGER,                  -- NULL = unlimited
    allow_future_date   BOOLEAN     NOT NULL DEFAULT false,
    is_active           BOOLEAN     NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID        REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID        REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, transaction_type)
);

CREATE TRIGGER trg_ric_backdated_entry_control_updated_at
    BEFORE UPDATE ON ric_backdated_entry_control
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE ric_backdated_entry_control ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_backdated_entry_control" ON ric_backdated_entry_control
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_backdated_entry_control FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_backdated_entry_control TO authenticated;

-- ── fn_check_period_open ─────────────────────────────────────────────────────
-- Raises if p_trans_date falls inside an active period lock, or outside an
-- open (active, not closed) financial year. Called by every posting/approval
-- function — fn_post_stock_movement (036), fn_post_voucher and
-- fn_post_finance_voucher (037), fn_approve_grn (038) — as their first action.
CREATE OR REPLACE FUNCTION fn_check_period_open(
    p_company_id UUID,
    p_trans_date DATE
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_locked BOOLEAN;
    v_fy     rim_financial_years%ROWTYPE;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM ric_period_locks
        WHERE company_id = p_company_id
          AND is_active = true
          AND p_trans_date BETWEEN period_start_date AND period_end_date
    ) INTO v_locked;

    IF v_locked THEN
        RAISE EXCEPTION 'PERIOD_LOCKED'
            USING DETAIL = format('Transaction date %s falls in a locked period.', p_trans_date);
    END IF;

    SELECT * INTO v_fy FROM rim_financial_years
    WHERE company_id = p_company_id
      AND p_trans_date BETWEEN fy_start_date AND fy_end_date
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'FY_CLOSED'
            USING DETAIL = format('Transaction date %s does not fall inside any financial year.', p_trans_date);
    END IF;

    IF v_fy.is_closed THEN
        RAISE EXCEPTION 'FY_CLOSED'
            USING DETAIL = format('Financial year "%s" is closed.', v_fy.fy_name);
    END IF;
END;
$$;

-- ── fn_check_backdate_allowed ────────────────────────────────────────────────
-- Softer, per-transaction-type check. Missing/inactive config row = unlimited
-- backdating, no future-date restriction (i.e. opt-in control, not opt-out).
CREATE OR REPLACE FUNCTION fn_check_backdate_allowed(
    p_client_id       UUID,
    p_company_id      UUID,
    p_transaction_type TEXT,
    p_trans_date      DATE
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_ctrl ric_backdated_entry_control%ROWTYPE;
BEGIN
    SELECT * INTO v_ctrl FROM ric_backdated_entry_control
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND transaction_type = p_transaction_type AND is_active = true;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF NOT v_ctrl.allow_future_date AND p_trans_date > current_date THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('% transactions cannot be dated in the future.', p_transaction_type);
    END IF;

    IF v_ctrl.max_backdate_days IS NOT NULL
       AND p_trans_date < (current_date - v_ctrl.max_backdate_days) THEN
        RAISE EXCEPTION 'BACKDATE_NOT_ALLOWED'
            USING DETAIL = format('% transactions cannot be dated more than %s day(s) back.',
                                   p_transaction_type, v_ctrl.max_backdate_days);
    END IF;
END;
$$;

-- ── Seed 'GRN' voucher type (needed by fn_next_trans_no in migration 038) ────
-- voucher_nature 'PURCHASE' already widened onto the CHECK constraint by
-- migration 031 for Purchase Order — GRN reuses it, not a new nature value.
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('GRN', 'Goods Receipt Note', 'PURCHASE', NULL, 'YEARLY', 'GRN/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;

GRANT EXECUTE ON FUNCTION fn_check_period_open(UUID, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_check_backdate_allowed(UUID, UUID, TEXT, DATE) TO authenticated;

-- ── Seed menu features: Period Close + Backdated Entry Control ──────────────
-- 'PR-GRN' ('Goods Receipt', '/purchase/grn') already exists in
-- fn_seed_client_modules.sql from initial scaffolding — GRN's own menu entry
-- needs no change here. These two are new, placed under AD / System Setup
-- alongside Company/Location/Currency Setup.
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    c.id, co.id, sm.id, x.feature_code, x.feature_name, x.screen_name,
    x.serial_no, 'AD-SETG', 'System Setup', 0,
    x.approve_allowed, false, false
FROM ric_companies co
JOIN ric_clients c ON c.id = co.client_id
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'AD'
CROSS JOIN (VALUES
    ('AD-PDC', 'Period Close',              '/setup/period-close',              3, true),
    ('AD-BDC', 'Backdated Entry Control',   '/setup/backdated-entry-control',   4, false)
) AS x(feature_code, feature_name, screen_name, serial_no, approve_allowed)
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
