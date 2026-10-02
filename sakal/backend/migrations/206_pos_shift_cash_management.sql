-- ============================================================================
-- Migration 206: POS Shift & Cash Management — open/close a till shift,
-- denomination-based cash-up with variance, and cash-in/out/payout/drop.
-- ============================================================================
-- Design reference: docs/pos/04_shift_cash_management.md. Depends on
-- migration 205 (ric_pos_terminals, the PIN login chain) having already run.
--
-- IMPORTANT, HONEST SCOPE NOTE: the expected-cash formula in
-- fn_close_pos_shift below currently sums ONLY opening float + this shift's
-- own cash-in/out/payout/drop movements — it does NOT yet add cash sales,
-- because the Sales screen (rih_sales_invoices.pos_shift_id,
-- rid_pos_tender_lines) has not been built yet in this build order (see
-- docs/pos/10_phase_plan.md's recommended sequence: terminals/access/shift
-- BEFORE New Sale). Once New Sale ships, this function gets ONE additive
-- change (sum rid_pos_tender_lines for CASH tender lines on this shift's
-- invoices into the formula) — the table/column shapes here are already
-- designed to make that a small change, not a redesign.
-- ============================================================================

-- ── A. rim_currency_denominations — global per-currency defaults, company-editable
CREATE TABLE IF NOT EXISTS rim_currency_denominations (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID REFERENCES ric_clients(id),   -- NULL = global default row, available to every client
    company_id     UUID REFERENCES ric_companies(id), -- NULL alongside client_id for the same reason
    currency_id    TEXT NOT NULL,                     -- rim_currencies.currency_id (ISO code), not a FK — currencies are seeded per-company, this table's global rows predate any company existing
    denomination_value NUMERIC(18,4) NOT NULL,
    sort_order     SMALLINT NOT NULL DEFAULT 0,
    is_active      BOOLEAN NOT NULL DEFAULT true
);
-- Plain multi-column index (NULLs index fine in a btree) — a lookup is
-- always "this client+company's own rows OR the global NULL/NULL rows",
-- handled in the query itself, not the index.
CREATE INDEX IF NOT EXISTS idx_rim_currency_denominations_lookup
    ON rim_currency_denominations (client_id, company_id, currency_id);

-- Global defaults for the two currencies already in real use (USD, CDF) —
-- additive seed data, never assumed to be the only currencies a company
-- will ever need; a company can add its own client_id/company_id-scoped
-- rows for any other currency via the POS Setup screen later.
INSERT INTO rim_currency_denominations (currency_id, denomination_value, sort_order)
SELECT * FROM (VALUES
    ('USD', 100, 0), ('USD', 50, 1), ('USD', 20, 2), ('USD', 10, 3), ('USD', 5, 4), ('USD', 1, 5),
    ('CDF', 20000, 0), ('CDF', 10000, 1), ('CDF', 5000, 2), ('CDF', 1000, 3), ('CDF', 500, 4), ('CDF', 200, 5), ('CDF', 100, 6), ('CDF', 50, 7)
) AS v(currency_id, denomination_value, sort_order)
WHERE NOT EXISTS (SELECT 1 FROM rim_currency_denominations WHERE client_id IS NULL AND company_id IS NULL);

REVOKE ALL ON rim_currency_denominations FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_currency_denominations TO authenticated;
DROP POLICY IF EXISTS "auth_rw_rim_currency_denominations" ON rim_currency_denominations;
-- Readable by anyone authenticated (global rows have no client/company to
-- scope against); writable only to rows actually owned by the caller's own
-- tenant — a global (NULL/NULL) row is never editable by a client.
CREATE POLICY "auth_rw_rim_currency_denominations" ON rim_currency_denominations
    FOR ALL TO authenticated
    USING (client_id IS NULL OR (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
                              AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid))
    WITH CHECK (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
            AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rim_currency_denominations ENABLE ROW LEVEL SECURITY;

-- ── B. rih_pos_shifts ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_pos_shifts (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            UUID NOT NULL REFERENCES ric_clients(id),
    company_id           UUID NOT NULL REFERENCES ric_companies(id),
    location_id          UUID NOT NULL REFERENCES ric_locations(id),
    terminal_id          UUID NOT NULL REFERENCES ric_pos_terminals(id),
    shift_no             TEXT NOT NULL,
    cashier_id           UUID NOT NULL REFERENCES rim_users(id),
    opened_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at            TIMESTAMPTZ,
    status               TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CASH_UP_PENDING','CLOSED')),
    opening_notes        TEXT,
    closing_notes        TEXT,
    variance_reason      TEXT,
    variance_approved_by UUID REFERENCES rim_users(id),
    variance_approved_at TIMESTAMPTZ,
    opening_approved_by  UUID REFERENCES rim_users(id),
    is_deleted           BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT uq_pos_shift_no UNIQUE (client_id, company_id, location_id, shift_no)
);
-- At most one OPEN shift per terminal at a time — the real concurrency
-- guard (an app-level check is UX only, this is what's actually authoritative).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_shift_one_open_per_terminal
    ON rih_pos_shifts (terminal_id) WHERE status = 'OPEN' AND is_deleted = false;

DROP POLICY IF EXISTS "auth_rw_rih_pos_shifts" ON rih_pos_shifts;
CREATE POLICY "auth_rw_rih_pos_shifts" ON rih_pos_shifts
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rih_pos_shifts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rih_pos_shifts FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_pos_shifts TO authenticated;

-- rih_sales_invoices.pos_shift_id is added here, NOT in a future Sales
-- migration, so this column exists from the moment shifts do — the future
-- Sales migration only needs to START populating it, never ALTER for it.
ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS pos_shift_id UUID REFERENCES rih_pos_shifts(id);
-- Likewise the HELD status this column's sibling design doc calls for —
-- additive to the existing CHECK, every current caller unaffected since
-- nothing sets 'HELD' until the POS New Sale screen exists.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'rih_sales_invoices_status_check'
          AND pg_get_constraintdef(oid) NOT LIKE '%HELD%'
    ) THEN
        ALTER TABLE rih_sales_invoices DROP CONSTRAINT rih_sales_invoices_status_check;
        ALTER TABLE rih_sales_invoices ADD CONSTRAINT rih_sales_invoices_status_check
            CHECK (status IN ('DRAFT','APPROVED','CANCELLED','HELD'));
    END IF;
END $$;

-- ── C. rih_pos_shift_opening_float — one row per currency the shift opened with
CREATE TABLE IF NOT EXISTS rih_pos_shift_opening_float (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID NOT NULL REFERENCES ric_clients(id),
    company_id     UUID NOT NULL REFERENCES ric_companies(id),
    shift_id       UUID NOT NULL REFERENCES rih_pos_shifts(id),
    currency_id    TEXT NOT NULL,
    opening_amount NUMERIC(18,4) NOT NULL,
    CONSTRAINT uq_pos_shift_opening_float UNIQUE (shift_id, currency_id)
);
DROP POLICY IF EXISTS "auth_rw_rih_pos_shift_opening_float" ON rih_pos_shift_opening_float;
CREATE POLICY "auth_rw_rih_pos_shift_opening_float" ON rih_pos_shift_opening_float
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rih_pos_shift_opening_float ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rih_pos_shift_opening_float FROM anon;
GRANT SELECT, INSERT ON rih_pos_shift_opening_float TO authenticated;

-- ── D. rid_pos_shift_denomination_counts — same shape used at open AND close
CREATE TABLE IF NOT EXISTS rid_pos_shift_denomination_counts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID NOT NULL REFERENCES ric_clients(id),
    company_id          UUID NOT NULL REFERENCES ric_companies(id),
    shift_id            UUID NOT NULL REFERENCES rih_pos_shifts(id),
    count_stage         TEXT NOT NULL CHECK (count_stage IN ('OPENING','CLOSING')),
    currency_id         TEXT NOT NULL,
    denomination_value  NUMERIC(18,4) NOT NULL,
    count               INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT uq_pos_shift_denom_count UNIQUE (shift_id, count_stage, currency_id, denomination_value)
);
DROP POLICY IF EXISTS "auth_rw_rid_pos_shift_denomination_counts" ON rid_pos_shift_denomination_counts;
CREATE POLICY "auth_rw_rid_pos_shift_denomination_counts" ON rid_pos_shift_denomination_counts
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rid_pos_shift_denomination_counts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rid_pos_shift_denomination_counts FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_pos_shift_denomination_counts TO authenticated;

-- ── E. rih_pos_payouts — cash-in/out/payout/drop, one table, movement_type distinguishes
CREATE TABLE IF NOT EXISTS rih_pos_payouts (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID NOT NULL REFERENCES ric_clients(id),
    company_id     UUID NOT NULL REFERENCES ric_companies(id),
    shift_id       UUID NOT NULL REFERENCES rih_pos_shifts(id),
    payout_no      TEXT NOT NULL,
    movement_type  TEXT NOT NULL CHECK (movement_type IN ('CASH_IN','CASH_OUT','PAYOUT','CASH_DROP')),
    direction      TEXT NOT NULL CHECK (direction IN ('IN','OUT')),
    amount         NUMERIC(18,4) NOT NULL CHECK (amount > 0),
    currency_id    TEXT NOT NULL,
    reason_id      UUID REFERENCES rim_common_masters(id),
    gl_account_id  UUID REFERENCES rim_accounts(id),   -- required for PAYOUT (an expense); NULL for CASH_IN/OUT/DROP
    reference_no   TEXT,
    voucher_no     TEXT,   -- the JV this movement posted under, once posted
    voucher_date   DATE,
    created_by     UUID NOT NULL REFERENCES rim_users(id),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_by    UUID REFERENCES rim_users(id),       -- NULL until an above-threshold PAYOUT clears approval
    is_deleted     BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT uq_pos_payout_no UNIQUE (client_id, company_id, payout_no)
);
DROP POLICY IF EXISTS "auth_rw_rih_pos_payouts" ON rih_pos_payouts;
CREATE POLICY "auth_rw_rih_pos_payouts" ON rih_pos_payouts
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rih_pos_payouts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rih_pos_payouts FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_pos_payouts TO authenticated;

-- ── F. Voucher types for numbering (SFT = shift, PAY = cash movement) ──────
-- Both numbering-only — cash movements post real GL via the EXISTING 'JV'
-- voucher type (fn_post_voucher), never a bespoke posting code, since this
-- is a plain two-line journal entry with no tax/discount/stock complexity
-- (see CLAUDE.md's "Shared posting engines" rule).
INSERT INTO rim_voucher_types (voucher_type_code, type_description, voucher_nature, cash_bank_side, reset_frequency, trans_no_format, is_system)
VALUES
    ('SFT', 'POS Shift',         'JOURNAL', NULL, 'YEARLY', 'SFT/{LOC}/{YYYY}/{SEQ5}', true),
    ('PAY', 'POS Cash Movement', 'JOURNAL', NULL, 'YEARLY', 'PAY/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;

-- ── G. fn_open_pos_shift ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_open_pos_shift(
    p_client_id      UUID,
    p_company_id     UUID,
    p_terminal_id    UUID,
    p_cashier_id     UUID,
    p_opening_notes  TEXT,
    p_opening_floats JSONB   -- [{"currency_id": "USD", "amount": 100.00}, ...]
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_location_id UUID;
    v_shift_id    UUID;
    v_shift_no    TEXT;
    v_float       JSONB;
BEGIN
    SELECT location_id INTO v_location_id FROM ric_pos_terminals WHERE id = p_terminal_id;
    IF v_location_id IS NULL THEN
        RAISE EXCEPTION 'TERMINAL_NOT_FOUND';
    END IF;

    PERFORM fn_check_period_open(p_company_id, current_date);

    v_shift_no := fn_next_trans_no(p_client_id, p_company_id, v_location_id, 'SFT');

    -- The partial unique index (uq_pos_shift_one_open_per_terminal) is the
    -- real guard against two concurrently-open shifts on one terminal; this
    -- INSERT simply surfaces that as a normal exception if it fires.
    INSERT INTO rih_pos_shifts (client_id, company_id, location_id, terminal_id, shift_no, cashier_id, opening_notes)
    VALUES (p_client_id, p_company_id, v_location_id, p_terminal_id, v_shift_no, p_cashier_id, p_opening_notes)
    RETURNING id INTO v_shift_id;

    FOR v_float IN SELECT * FROM jsonb_array_elements(coalesce(p_opening_floats, '[]'::jsonb))
    LOOP
        INSERT INTO rih_pos_shift_opening_float (client_id, company_id, shift_id, currency_id, opening_amount)
        VALUES (p_client_id, p_company_id, v_shift_id, v_float->>'currency_id', (v_float->>'amount')::numeric);
    END LOOP;

    RETURN v_shift_no;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'SHIFT_ALREADY_OPEN'
            USING DETAIL = 'This terminal already has an open shift. Close it before opening a new one.';
END;
$$;
GRANT EXECUTE ON FUNCTION fn_open_pos_shift(uuid, uuid, uuid, uuid, text, jsonb) TO authenticated;

-- ── H. fn_save_pos_cash_movement — cash-in/out/payout/drop, posts GL via the
-- shared fn_post_voucher('JV', ...) engine immediately (see CLAUDE.md's
-- "Shared posting engines — never write directly to the ledger tables").
CREATE OR REPLACE FUNCTION fn_save_pos_cash_movement(
    p_client_id     UUID,
    p_company_id    UUID,
    p_shift_id      UUID,
    p_movement_type TEXT,
    p_amount        NUMERIC,
    p_currency_id   TEXT,
    p_cash_account_id UUID,   -- resolved client-side (terminal default or cashier's quick-invoice-setup account) — this function trusts it as the Dr/Cr cash leg, same "caller resolves, function posts" shape as every other voucher-composing function in this schema
    p_counter_account_id UUID, -- the expense account for PAYOUT, or the other side of the cash reclassification for CASH_IN/OUT/DROP
    p_reason_id     UUID,
    p_reference_no  TEXT,
    p_created_by    UUID
) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_shift        rih_pos_shifts%rowtype;
    v_company      ric_companies%rowtype;
    v_direction    TEXT;
    v_payout_no    TEXT;
    v_voucher_no   TEXT;
    v_voucher_date DATE := current_date;
    v_base_rate    NUMERIC;
    v_local_rate   NUMERIC;
    v_lines        JSONB;
    v_dr_account   UUID;
    v_cr_account   UUID;
BEGIN
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'POS-PAYOUT');
    PERFORM fn_check_period_open(p_company_id, v_voucher_date);

    SELECT * INTO v_shift FROM rih_pos_shifts WHERE id = p_shift_id;
    IF v_shift.status <> 'OPEN' THEN
        RAISE EXCEPTION 'SHIFT_NOT_OPEN';
    END IF;
    SELECT * INTO v_company FROM ric_companies WHERE id = p_company_id;

    -- Every movement type needs a real counter account for the journal's
    -- other leg (Safe/Bank for CASH_IN/OUT/DROP, an expense account for
    -- PAYOUT) — rid_finance_lines.account_id is NOT NULL, so a missing one
    -- here must fail with a friendly message rather than a raw DB error.
    IF p_counter_account_id IS NULL THEN
        RAISE EXCEPTION 'COUNTER_ACCOUNT_REQUIRED'
            USING DETAIL = format('A %s needs an account for its other side.', p_movement_type);
    END IF;

    v_direction := CASE WHEN p_movement_type = 'CASH_IN' THEN 'IN' ELSE 'OUT' END;
    v_payout_no := fn_next_trans_no(p_client_id, p_company_id, v_shift.location_id, 'PAY');

    -- Always-multiply convention (CLAUDE.md's multicurrency rule): both legs
    -- share the same trans_currency (a plain two-leg internal journal, same
    -- shape as Material Issue's own self-referential MIC lines), so one rate
    -- lookup per base/local covers both.
    v_base_rate  := CASE WHEN p_currency_id = v_company.base_currency  THEN 1 ELSE fn_get_exchange_rate(p_company_id, v_shift.location_id, p_currency_id, v_company.base_currency,  v_voucher_date) END;
    v_local_rate := CASE WHEN p_currency_id = v_company.local_currency THEN 1 ELSE fn_get_exchange_rate(p_company_id, v_shift.location_id, p_currency_id, v_company.local_currency, v_voucher_date) END;

    v_dr_account := CASE WHEN v_direction = 'IN' THEN p_cash_account_id ELSE p_counter_account_id END;
    v_cr_account := CASE WHEN v_direction = 'IN' THEN p_counter_account_id ELSE p_cash_account_id END;

    v_lines := jsonb_build_array(
        jsonb_build_object(
            'account_id', v_dr_account, 'trans_nature', 'DR', 'trans_amount', p_amount, 'trans_currency', p_currency_id,
            'base_amount', p_amount * v_base_rate, 'base_rate', v_base_rate,
            'local_amount', p_amount * v_local_rate, 'local_rate', v_local_rate,
            'party_amount', p_amount, 'party_currency', p_currency_id, 'party_rate', 1,
            'line_remarks', format('POS %s — %s', p_movement_type, v_payout_no)
        ),
        jsonb_build_object(
            'account_id', v_cr_account, 'trans_nature', 'CR', 'trans_amount', p_amount, 'trans_currency', p_currency_id,
            'base_amount', p_amount * v_base_rate, 'base_rate', v_base_rate,
            'local_amount', p_amount * v_local_rate, 'local_rate', v_local_rate,
            'party_amount', p_amount, 'party_currency', p_currency_id, 'party_rate', 1,
            'line_remarks', format('POS %s — %s', p_movement_type, v_payout_no)
        )
    );

    SELECT trans_no INTO v_voucher_no FROM fn_post_voucher(
        p_client_id, p_company_id, v_shift.location_id, 'JV', v_voucher_date, v_lines,
        'POS_CASH_MOVEMENT', v_payout_no, v_voucher_date, p_created_by
    );

    INSERT INTO rih_pos_payouts (client_id, company_id, shift_id, payout_no, movement_type, direction, amount, currency_id, reason_id, gl_account_id, reference_no, voucher_no, voucher_date, created_by)
    VALUES (p_client_id, p_company_id, p_shift_id, v_payout_no, p_movement_type, v_direction, p_amount, p_currency_id, p_reason_id, p_counter_account_id, p_reference_no, v_voucher_no, v_voucher_date, p_created_by);

    RETURN v_payout_no;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_save_pos_cash_movement(uuid, uuid, uuid, text, numeric, text, uuid, uuid, uuid, text, uuid) TO authenticated;

-- ── I. fn_close_pos_shift — freezes the shift; GL consolidation for CASH
-- SALES is added here once New Sale ships (see this file's header note).
CREATE OR REPLACE FUNCTION fn_close_pos_shift(
    p_client_id       UUID,
    p_company_id      UUID,
    p_shift_id        UUID,
    p_closing_notes   TEXT,
    p_variance_reason TEXT,
    p_approved_by     UUID   -- NULL unless a variance above the configured threshold needed sign-off
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_shift   rih_pos_shifts%rowtype;
    v_row     RECORD;
    v_expected NUMERIC;
    v_counted  NUMERIC;
    v_variance NUMERIC;
    v_any_variance BOOLEAN := false;
BEGIN
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'POS-SHIFT');

    SELECT * INTO v_shift FROM rih_pos_shifts WHERE id = p_shift_id;
    IF v_shift.status <> 'OPEN' THEN
        RAISE EXCEPTION 'SHIFT_NOT_OPEN';
    END IF;
    PERFORM fn_check_period_open(p_company_id, current_date);

    -- One pass per currency this shift ever touched (opening float, any
    -- movement, or a closing count) — expected vs counted compared per
    -- currency, never mixed.
    FOR v_row IN
        SELECT currency_id FROM (
            SELECT currency_id FROM rih_pos_shift_opening_float WHERE shift_id = p_shift_id
            UNION
            SELECT currency_id FROM rih_pos_payouts WHERE shift_id = p_shift_id AND is_deleted = false
            UNION
            SELECT currency_id FROM rid_pos_shift_denomination_counts WHERE shift_id = p_shift_id AND count_stage = 'CLOSING'
        ) c
    LOOP
        SELECT coalesce(sum(opening_amount), 0) INTO v_expected
          FROM rih_pos_shift_opening_float WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id;

        v_expected := v_expected
            + (SELECT coalesce(sum(amount), 0) FROM rih_pos_payouts WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id AND direction = 'IN'  AND is_deleted = false)
            - (SELECT coalesce(sum(amount), 0) FROM rih_pos_payouts WHERE shift_id = p_shift_id AND currency_id = v_row.currency_id AND direction = 'OUT' AND is_deleted = false);
        -- TODO once New Sale ships: + SUM(rid_pos_tender_lines.tender_amount)
        -- for CASH tender lines, this currency, on this shift's invoices.

        SELECT coalesce(sum(denomination_value * count), 0) INTO v_counted
          FROM rid_pos_shift_denomination_counts
         WHERE shift_id = p_shift_id AND count_stage = 'CLOSING' AND currency_id = v_row.currency_id;

        v_variance := v_counted - v_expected;
        IF abs(v_variance) > 0.01 THEN
            v_any_variance := true;
        END IF;
    END LOOP;

    IF v_any_variance AND (p_variance_reason IS NULL OR btrim(p_variance_reason) = '') THEN
        RAISE EXCEPTION 'VARIANCE_REASON_REQUIRED';
    END IF;

    -- Variance-approval threshold is intentionally NOT enforced yet — DEC-07
    -- in docs/pos/11_open_decisions.md is still an open number the user
    -- hasn't confirmed. For now a variance reason is mandatory (enforced
    -- above) but approval is optional; once DEC-07 is answered this gets a
    -- real `pos_cash_variance_threshold` column + a hard block here, the
    -- same shape as every other threshold check in this schema.

    UPDATE rih_pos_shifts
       SET status = 'CLOSED',
           closed_at = now(),
           closing_notes = p_closing_notes,
           variance_reason = CASE WHEN v_any_variance THEN p_variance_reason ELSE NULL END,
           variance_approved_by = p_approved_by,
           variance_approved_at = CASE WHEN p_approved_by IS NOT NULL THEN now() ELSE NULL END
     WHERE id = p_shift_id;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_close_pos_shift(uuid, uuid, uuid, text, text, uuid) TO authenticated;
