-- ============================================================
-- Migration 104: Cash Receipt (Cash Collection against pending invoices)
-- ============================================================
-- Plan written first in sakal/docs/screens/cash_receipt.md — read that
-- for the full requirement doc, including the user's own worked FX
-- example this migration's pgTAP test reproduces exactly. This
-- migration builds it as designed there, no scope changes beyond the
-- two the user requested at approval time: table prefix renamed from
-- rid_sales_receipt to rid_cash_receipt (and rih_ to match), and the
-- pending-bill picker showing three currency columns (handled in the
-- Flutter layer, not schema).
--
-- Reuses the existing SL-RCP menu placeholder ("Cash Receipt",
-- approve_allowed=false, route /sales/receipts) — no menu seed needed
-- here, confirmed already present since the very first menu seed.
--
-- Settlement mechanic is 100% reused, zero new SQL: v_pending_bills
-- (020) + fn_save_finance_voucher/fn_post_finance_voucher (050/058),
-- called DIRECTLY (never fn_post_voucher, which hardcodes
-- is_on_account=true). Posting a CRV with one CR line per bill
-- (account_id = that bill's own account_id, inv_bill_no/date = that
-- bill's own voucher trans_no/trans_date) drives
-- fn_post_finance_voucher's existing settlement loop automatically.
--
-- Two CRV vouchers, never one mixed-currency voucher: a voucher's
-- trans_currency is locked from its own line 1 (Cash/Bank account) —
-- if the user enters cash in BOTH local and base currency, this
-- receipt posts CRV-LOCAL and CRV-BASE as two independent, individually
-- balanced vouchers (exact precedent: fn_approve_sales_invoice's own
-- cash-collection code, migrations 089/090).
--
-- Waterfall split: the user enters a SINGLE "Apply" amount per invoice
-- line, in LOCAL currency (confirmed design). fn_approve_cash_receipt
-- funds each line from the local cash pool first, then the base pool
-- for any remainder — a single line can straddle both pools, producing
-- two settlement fragments (one per voucher) against the SAME bill.
--
-- FX gain/loss — computed PER RECEIPT, not deferred to full clearing,
-- per the user's own worked example (confirmed correct during
-- planning): for every settlement fragment, compare the bill's
-- proportional ORIGINAL booked base value (bill.base_amount * this
-- fragment's share of the bill's ORIGINAL total party_amount) against
-- the fragment's own ACTUAL base value (its own trans_currency->base
-- conversion at TODAY's rate). Net every fragment's diff together; if
-- material, post a separate EXC voucher (reused as-is from migration
-- 059) DR/CR Exchange Gain/Loss vs the customer, natively in base
-- currency, no inv_bill_no on the customer line (pure GL valuation
-- adjustment, invisible to v_pending_bills — same reasoning as Purchase
-- Bill's EXC voucher).
--
-- fn_resolve_account_link CANNOT be reused for EXCHANGE_GAIN_LOSS_
-- ACCOUNT here — verified by reading 032_account_link_setup.sql: its
-- cache table rim_account_links has product_id NOT NULL, an
-- architectural requirement. A cash receipt has no product at all.
-- fn_resolve_company_account_link (new, this migration) queries
-- rim_account_link_setup/rim_account_link_defaults directly for the
-- COMPANY granularity only — this link type is "always configured at
-- COMPANY granularity in practice" per the Purchase Bill precedent, so
-- this is the correct semantic, not a workaround.
--
-- Offline-first: fn_save_cash_receipt/fn_approve_cash_receipt are plain
-- synchronous RPCs with no awareness of offline queuing — that lives
-- entirely in the Flutter layer (SyncEngine.enqueue for Save, Approve
-- always online-only, surfaced via the unified Pending Approvals
-- screen). No schema impact here.
-- ============================================================


-- ── New voucher type: CREC (numbering only) ──────────────────────────────
-- GL posting reuses the existing CRV (settlement) and EXC (FX
-- adjustment, already seeded by migration 059) codes — the "numbering
-- code != posting code" rule (PINV/PUR, MREQ+MISS/MIC, SDEL/COS).
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('CREC', 'Cash Receipt', 'RECEIPT', 'DR', 'YEARLY', 'CREC/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ============================================================
-- rih_cash_receipt_headers
-- ============================================================
CREATE TABLE IF NOT EXISTS rih_cash_receipt_headers (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    location_id           UUID          NOT NULL REFERENCES ric_locations(id),
    receipt_no            TEXT          NOT NULL,
    receipt_date          DATE          NOT NULL,
    customer_id           UUID          NOT NULL REFERENCES rim_accounts(id),
    -- Cash entered by the cashier, split into the two pools this
    -- screen's prefilled cash accounts (ric_user_quick_invoice_setup)
    -- represent — never both zero.
    local_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,
    remarks               TEXT,
    status                TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    -- GL trace — whichever of these actually posted at Approve time.
    crv_local_voucher_no  TEXT,
    crv_local_voucher_date DATE,
    crv_base_voucher_no   TEXT,
    crv_base_voucher_date DATE,
    exc_voucher_no        TEXT,          -- NULL if no FX adjustment was needed
    exc_voucher_date      DATE,
    approved_by           UUID          REFERENCES rim_users(id),
    approved_at           TIMESTAMPTZ,
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    CONSTRAINT chk_rih_cr_amount CHECK (local_amount > 0 OR base_amount > 0),
    CONSTRAINT uq_rih_cash_receipt_headers UNIQUE (client_id, company_id, receipt_no, receipt_date)
);

CREATE INDEX IF NOT EXISTS idx_rih_cr_tenant   ON rih_cash_receipt_headers (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rih_cr_customer ON rih_cash_receipt_headers (customer_id);
CREATE INDEX IF NOT EXISTS idx_rih_cr_status   ON rih_cash_receipt_headers (client_id, company_id, location_id, status);
CREATE INDEX IF NOT EXISTS idx_rih_cr_date     ON rih_cash_receipt_headers (client_id, company_id, receipt_date DESC);

DROP TRIGGER IF EXISTS trg_rih_cash_receipt_headers_updated_at ON rih_cash_receipt_headers;
CREATE TRIGGER trg_rih_cash_receipt_headers_updated_at
    BEFORE UPDATE ON rih_cash_receipt_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_cash_receipt_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_cash_receipt_headers" ON rih_cash_receipt_headers;
CREATE POLICY "auth_rw_cash_receipt_headers" ON rih_cash_receipt_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_cash_receipt_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_cash_receipt_headers TO authenticated;


-- ============================================================
-- rid_cash_receipt_lines — one row per invoice this receipt applies to
-- ============================================================
CREATE TABLE IF NOT EXISTS rid_cash_receipt_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    receipt_no            TEXT          NOT NULL,
    receipt_date          DATE          NOT NULL,
    serial_no             SMALLINT      NOT NULL,
    -- The bill's own voucher trans_no/trans_date (from v_pending_bills)
    -- — NEVER the invoice_no. This is what fn_post_finance_voucher's
    -- settlement lookup joins against.
    inv_bill_no           TEXT          NOT NULL,
    inv_bill_date         DATE          NOT NULL,
    bill_currency         TEXT          NOT NULL,   -- snapshot of that bill's party_currency, display only
    applied_amount_local  NUMERIC(18,4) NOT NULL CHECK (applied_amount_local > 0),
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rid_cr_lines UNIQUE (client_id, company_id, receipt_no, receipt_date, serial_no),
    CONSTRAINT rid_cr_lines_header_fk
        FOREIGN KEY (client_id, company_id, receipt_no, receipt_date)
        REFERENCES  rih_cash_receipt_headers (client_id, company_id, receipt_no, receipt_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_cr_lines_header ON rid_cash_receipt_lines (client_id, company_id, receipt_no, receipt_date);

ALTER TABLE rid_cash_receipt_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_cash_receipt_lines" ON rid_cash_receipt_lines;
CREATE POLICY "auth_rw_cash_receipt_lines" ON rid_cash_receipt_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_cash_receipt_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_cash_receipt_lines TO authenticated;


-- ============================================================
-- v_customers_with_pending_bills — fills a real gap (research finding):
-- no existing query answers "which customers have pending invoices" —
-- every current v_pending_bills consumer (Finance Voucher) picks the
-- party FIRST, then loads bills. This view lets the Cash Receipt
-- screen's customer picker filter correctly from the start.
-- ============================================================
CREATE OR REPLACE VIEW v_customers_with_pending_bills AS
SELECT DISTINCT b.client_id, b.company_id, b.location_id, b.account_id
FROM v_pending_bills b
JOIN rim_accounts a ON a.id = b.account_id
WHERE a.account_nature = 'Customer';

GRANT SELECT ON v_customers_with_pending_bills TO anon, authenticated, service_role;


-- ============================================================
-- fn_resolve_company_account_link — direct COMPANY-granularity lookup,
-- for link types with no natural product/category/location anchor
-- (e.g. EXCHANGE_GAIN_LOSS_ACCOUNT on a pure customer receipt).
-- fn_resolve_account_link cannot be reused here: its cache table
-- rim_account_links has product_id NOT NULL, an architectural
-- requirement this document has nothing to satisfy it with. Returns
-- NULL if not configured, or configured at any granularity other than
-- COMPANY (that would mean this link type needs a per-item resolution
-- this function deliberately doesn't attempt) — callers must treat
-- NULL as a hard error, same convention as fn_resolve_account_link.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_resolve_company_account_link(
    p_client_id  UUID,
    p_company_id UUID,
    p_link_key   TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_link_type_id UUID;
    v_granularity  TEXT;
    v_account_id   UUID;
BEGIN
    SELECT id INTO v_link_type_id FROM rim_account_link_types
    WHERE link_key = p_link_key AND is_active = true AND is_deleted = false;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT link_type INTO v_granularity FROM rim_account_link_setup
    WHERE client_id = p_client_id AND company_id = p_company_id AND link_type_id = v_link_type_id;

    IF NOT FOUND OR v_granularity != 'COMPANY' THEN
        RETURN NULL;
    END IF;

    SELECT account_id INTO v_account_id FROM rim_account_link_defaults
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND link_type_id = v_link_type_id AND link_key_id IS NULL AND is_deleted = false;

    RETURN v_account_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_resolve_company_account_link(UUID, UUID, TEXT) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_cash_receipt — DRAFT-only
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_cash_receipt(
    p_header  JSONB,  -- {client_id, company_id, location_id, receipt_no, receipt_date, customer_id, local_amount, base_amount, remarks}
    p_lines   JSONB,  -- [{inv_bill_no, inv_bill_date, bill_currency, applied_amount_local}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_location_id    UUID;
    v_receipt_no     TEXT;
    v_receipt_date   DATE;
    v_customer_id    UUID;
    v_local_amount   NUMERIC;
    v_base_amount    NUMERIC;
    v_is_new         BOOLEAN;
    v_old_status     TEXT;
    v_line           JSONB;
    v_serial         INTEGER := 0;
    v_lines_total    NUMERIC := 0;
    v_base_ccy       TEXT;
    v_local_ccy      TEXT;
    v_rate           NUMERIC;
    v_expected_total NUMERIC;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_receipt_no   := nullif(trim(p_header->>'receipt_no'), '');
    v_receipt_date := (p_header->>'receipt_date')::date;
    v_customer_id  := (p_header->>'customer_id')::uuid;
    v_local_amount := coalesce((p_header->>'local_amount')::numeric, 0);
    v_base_amount  := coalesce((p_header->>'base_amount')::numeric, 0);
    v_is_new       := v_receipt_no IS NULL;

    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Select a customer.';
    END IF;
    IF v_local_amount <= 0 AND v_base_amount <= 0 THEN
        RAISE EXCEPTION 'Enter a cash amount received, in local and/or base currency.';
    END IF;
    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Apply the receipt against at least one pending invoice.';
    END IF;

    -- Every applied line must be positive — zero-amount lines never
    -- reach the database, defense in depth alongside the Flutter-side
    -- guard, same precedent as every other module's zero-qty check.
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        IF coalesce((v_line->>'applied_amount_local')::numeric, 0) <= 0 THEN
            RAISE EXCEPTION 'RECEIPT_LINE_AMOUNT_ZERO'
                USING DETAIL = format('Invoice %s has a zero (or missing) applied amount — every applied line must be positive.', v_line->>'inv_bill_no');
        END IF;
        v_lines_total := v_lines_total + (v_line->>'applied_amount_local')::numeric;
    END LOOP;

    -- Sum-matches-header validation — best-effort at save time (the
    -- Flutter screen already gates Save on this); the authoritative
    -- math happens at Approve using approve-time rates.
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = v_company_id;
    v_rate := fn_get_exchange_rate(v_company_id, v_location_id, v_base_ccy, v_local_ccy, v_receipt_date);
    v_expected_total := v_local_amount + v_base_amount * v_rate;

    IF abs(v_lines_total - v_expected_total) > 0.01 THEN
        RAISE EXCEPTION 'RECEIPT_AMOUNT_MISMATCH'
            USING DETAIL = format('Applied amounts total %s but the header total is %s (Local %s + Base %s @ %s) — they must match.',
                                   v_lines_total, v_expected_total, v_local_amount, v_base_amount, v_rate);
    END IF;

    IF v_is_new THEN
        v_receipt_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'CREC');
    ELSE
        SELECT status INTO v_old_status FROM rih_cash_receipt_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND receipt_no = v_receipt_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status IS NULL THEN
            RAISE EXCEPTION 'Cash Receipt % not found.', v_receipt_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Cash Receipt % is % and cannot be edited.', v_receipt_no, v_old_status;
        END IF;

        DELETE FROM rid_cash_receipt_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND receipt_no = v_receipt_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_cash_receipt_headers (
            client_id, company_id, location_id, receipt_no, receipt_date,
            customer_id, local_amount, base_amount, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_receipt_no, v_receipt_date,
            v_customer_id, v_local_amount, v_base_amount, nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_cash_receipt_headers SET
            location_id  = v_location_id,
            receipt_date = v_receipt_date,
            customer_id  = v_customer_id,
            local_amount = v_local_amount,
            base_amount  = v_base_amount,
            remarks      = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND receipt_no = v_receipt_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_serial := v_serial + 1;
        INSERT INTO rid_cash_receipt_lines (
            client_id, company_id, receipt_no, receipt_date, serial_no,
            inv_bill_no, inv_bill_date, bill_currency, applied_amount_local,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_receipt_no, v_receipt_date, v_serial,
            v_line->>'inv_bill_no', (v_line->>'inv_bill_date')::date,
            v_line->>'bill_currency', (v_line->>'applied_amount_local')::numeric,
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_receipt_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_cash_receipt(JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_cash_receipt
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_cash_receipt(
    p_client_id    UUID,
    p_company_id   UUID,
    p_receipt_no   TEXT,
    p_receipt_date DATE,
    p_approved_by  UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header                     rih_cash_receipt_headers%ROWTYPE;
    v_base_ccy                   TEXT;
    v_local_ccy                  TEXT;
    v_local_to_base_rate         NUMERIC;
    v_base_to_local_rate         NUMERIC;
    v_local_cash_account         UUID;
    v_base_cash_account          UUID;
    v_line                       RECORD;
    v_bill                       rid_finance_lines%ROWTYPE;
    v_party_rate                 NUMERIC;
    v_party_amount_line          NUMERIC;
    v_live_balance                NUMERIC;
    v_proportional_base_line     NUMERIC;
    v_remaining_local             NUMERIC;
    v_remaining_base_local_equiv  NUMERIC;
    v_local_portion               NUMERIC;
    v_base_portion                NUMERIC;
    v_local_fragments             JSONB := '[]'::jsonb;
    v_base_fragments              JSONB := '[]'::jsonb;
    v_frag                        JSONB;
    v_crv_local_lines             JSONB;
    v_crv_base_lines              JSONB;
    v_serial                      INTEGER;
    v_trans_amt                   NUMERIC;
    v_base_amt                    NUMERIC;
    v_crv_local_no                TEXT;
    v_crv_local_date              DATE;
    v_crv_base_no                 TEXT;
    v_crv_base_date               DATE;
    v_net_fx_diff                 NUMERIC := 0;
    v_exc_lines                   JSONB;
    v_exc_voucher_no              TEXT;
    v_exc_voucher_date            DATE;
    v_fx_account                  UUID;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_cash_receipt_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cash Receipt % dated % not found', p_receipt_no, p_receipt_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Cash Receipt % is % and cannot be approved again', p_receipt_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks. Future-date lock is a
    --    HARD rule, not a company-configurable opt-in — belt-and-
    --    suspenders pair (soft config check + unconditional guard),
    --    same as Sales Delivery/Material Issue.
    PERFORM fn_check_period_open(p_company_id, p_receipt_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'CASH_RECEIPT', p_receipt_date);

    IF p_receipt_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Receipt date %s is in the future — a Cash Receipt cannot be dated ahead of today.', p_receipt_date);
    END IF;

    -- 3. Resolve currencies, rates, cash accounts (from the CREATOR —
    --    cash sits in that cashier's drawer, same reasoning already
    --    established for Quick Invoice).
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_local_to_base_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_receipt_date);
    v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_receipt_date);

    v_local_cash_account := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
    v_base_cash_account  := fn_quick_cash_account_base(p_client_id, p_company_id, v_header.created_by);

    IF v_header.local_amount > 0 AND v_local_cash_account IS NULL THEN
        RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
            USING DETAIL = 'The user who created this receipt has no Quick Invoice Setup (Local Cash Account) — cannot collect cash.';
    END IF;
    IF v_header.base_amount > 0 AND v_base_cash_account IS NULL THEN
        RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
            USING DETAIL = 'The user who created this receipt has no Quick Invoice Setup (Base Cash Account) — cannot collect cash.';
    END IF;

    -- 4. Per line — lock+re-validate each bill (one row per statement,
    --    over a pre-sorted key list, never ORDER BY ... FOR UPDATE),
    --    compute settlement amounts, and waterfall-split this line's
    --    applied_amount_local across the local pool (first) then the
    --    base pool (remainder) into "fragments" — a single bill can
    --    straddle both pools.
    v_remaining_local            := v_header.local_amount;
    v_remaining_base_local_equiv := v_header.base_amount * v_base_to_local_rate;

    FOR v_line IN
        SELECT * FROM rid_cash_receipt_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date AND is_deleted = false
        ORDER BY inv_bill_no, inv_bill_date
    LOOP
        SELECT * INTO v_bill FROM rid_finance_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id
          AND trans_no = v_line.inv_bill_no AND trans_date = v_line.inv_bill_date
          AND account_id = v_header.customer_id AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PENDING_BILL_NOT_FOUND'
                USING DETAIL = format('Invoice/bill %s dated %s was not found for this customer at this location — it may have been reassigned since this receipt was saved.', v_line.inv_bill_no, v_line.inv_bill_date);
        END IF;

        -- Convert this line's LOCAL-currency applied amount into the
        -- bill's own party currency, fresh at approve time (never trust
        -- save-time values) — this is what actually settles the bill.
        v_party_rate        := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_bill.party_currency, p_receipt_date);
        v_party_amount_line := v_line.applied_amount_local * v_party_rate;

        v_live_balance := v_bill.party_amount - v_bill.settled_amount;
        IF v_party_amount_line > v_live_balance + 0.01 THEN
            RAISE EXCEPTION 'RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE'
                USING DETAIL = format('Invoice %s: remaining balance is %s %s but this receipt applies %s %s — it may have been partly settled by another receipt since this one was saved.',
                                       v_line.inv_bill_no, v_live_balance, v_bill.party_currency, v_party_amount_line, v_bill.party_currency);
        END IF;

        -- Proportional ORIGINAL base share — uses the bill's ORIGINAL
        -- total party_amount (never the remaining balance), which fixes
        -- the "per party-currency-unit" originally-booked rate,
        -- consistent across however many receipts eventually clear this
        -- one bill over time.
        v_proportional_base_line := v_bill.base_amount * (v_party_amount_line / NULLIF(v_bill.party_amount, 0));

        v_local_portion := LEAST(v_line.applied_amount_local, GREATEST(v_remaining_local, 0));
        v_base_portion  := v_line.applied_amount_local - v_local_portion;

        IF v_base_portion > v_remaining_base_local_equiv + 0.01 THEN
            RAISE EXCEPTION 'RECEIPT_AMOUNT_MISMATCH'
                USING DETAIL = 'Applied amounts exceed the cash pools entered on this receipt — save the receipt again to re-validate.';
        END IF;

        v_remaining_local            := v_remaining_local - v_local_portion;
        v_remaining_base_local_equiv := v_remaining_base_local_equiv - v_base_portion;

        IF v_local_portion > 0.0001 THEN
            v_local_fragments := v_local_fragments || jsonb_build_array(jsonb_build_object(
                'inv_bill_no', v_line.inv_bill_no, 'inv_bill_date', v_line.inv_bill_date,
                'party_currency', v_bill.party_currency,
                'local_equiv', v_local_portion,
                'party_amount', v_party_amount_line * (v_local_portion / v_line.applied_amount_local),
                'proportional_original_base', v_proportional_base_line * (v_local_portion / v_line.applied_amount_local)
            ));
        END IF;
        IF v_base_portion > 0.0001 THEN
            v_base_fragments := v_base_fragments || jsonb_build_array(jsonb_build_object(
                'inv_bill_no', v_line.inv_bill_no, 'inv_bill_date', v_line.inv_bill_date,
                'party_currency', v_bill.party_currency,
                'local_equiv', v_base_portion,
                'party_amount', v_party_amount_line * (v_base_portion / v_line.applied_amount_local),
                'proportional_original_base', v_proportional_base_line * (v_base_portion / v_line.applied_amount_local)
            ));
        END IF;
    END LOOP;

    -- 5. Build + post CRV-LOCAL, if any fragments were funded from the
    --    local pool. Line 1 = Cash DR; lines 2+ = one Customer CR per
    --    fragment, account_id/inv_bill_no/inv_bill_date taken EXACTLY
    --    from the bill's own row — never re-derived, or
    --    fn_post_finance_voucher's settlement lookup silently fails to
    --    find a match.
    IF jsonb_array_length(v_local_fragments) > 0 THEN
        v_trans_amt := 0;
        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_local_fragments) LOOP
            v_trans_amt := v_trans_amt + (v_frag->>'local_equiv')::numeric;
        END LOOP;

        v_serial := 1;
        v_crv_local_lines := jsonb_build_array(jsonb_build_object(
            'serial_no', v_serial, 'account_id', v_local_cash_account, 'trans_nature', 'DR',
            'trans_amount', v_trans_amt, 'trans_currency', v_local_ccy,
            'base_amount', v_trans_amt * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
            'local_amount', v_trans_amt, 'local_rate', 1,
            'party_amount', v_trans_amt, 'party_currency', v_local_ccy, 'party_rate', 1
        ));

        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_local_fragments) LOOP
            v_serial := v_serial + 1;
            v_crv_local_lines := v_crv_local_lines || jsonb_build_array(jsonb_build_object(
                'serial_no', v_serial, 'account_id', v_header.customer_id, 'trans_nature', 'CR',
                'trans_amount', (v_frag->>'local_equiv')::numeric, 'trans_currency', v_local_ccy,
                'base_amount', (v_frag->>'local_equiv')::numeric * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                'local_amount', (v_frag->>'local_equiv')::numeric, 'local_rate', 1,
                'party_amount', (v_frag->>'party_amount')::numeric, 'party_currency', v_frag->>'party_currency',
                'party_rate', CASE WHEN (v_frag->>'local_equiv')::numeric = 0 THEN 1 ELSE (v_frag->>'party_amount')::numeric / (v_frag->>'local_equiv')::numeric END,
                'inv_bill_no', v_frag->>'inv_bill_no', 'inv_bill_date', v_frag->>'inv_bill_date'
            ));

            v_net_fx_diff := v_net_fx_diff + (
                (v_frag->>'local_equiv')::numeric * v_local_to_base_rate - (v_frag->>'proportional_original_base')::numeric
            );
        END LOOP;

        v_crv_local_no := fn_save_finance_voucher(
            jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_receipt_date,
                'voucher_type_code', 'CRV', 'payment_mode_code', 'CASH', 'is_on_account', false,
                'remarks', format('Cash Collection %s', p_receipt_no)
            ),
            v_crv_local_lines, p_approved_by
        );
        PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_crv_local_no, p_receipt_date, p_approved_by);
        v_crv_local_date := p_receipt_date;
    END IF;

    -- 6. Build + post CRV-BASE identically, if any fragments were
    --    funded from the base pool. A fragment's actual base-currency
    --    trans_amount is its local-equivalent portion divided by the
    --    SAME base->local rate that produced that local-equivalent
    --    value in step 4 — the precise algebraic inverse, not a fresh
    --    (and potentially non-reciprocal-by-rounding) lookup.
    IF jsonb_array_length(v_base_fragments) > 0 THEN
        v_trans_amt := 0;
        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_base_fragments) LOOP
            v_trans_amt := v_trans_amt + (v_frag->>'local_equiv')::numeric / v_base_to_local_rate;
        END LOOP;

        v_serial := 1;
        v_crv_base_lines := jsonb_build_array(jsonb_build_object(
            'serial_no', v_serial, 'account_id', v_base_cash_account, 'trans_nature', 'DR',
            'trans_amount', v_trans_amt, 'trans_currency', v_base_ccy,
            'base_amount', v_trans_amt, 'base_rate', 1,
            'local_amount', v_trans_amt * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
            'party_amount', v_trans_amt, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_base_fragments) LOOP
            v_serial   := v_serial + 1;
            v_base_amt := (v_frag->>'local_equiv')::numeric / v_base_to_local_rate;
            v_crv_base_lines := v_crv_base_lines || jsonb_build_array(jsonb_build_object(
                'serial_no', v_serial, 'account_id', v_header.customer_id, 'trans_nature', 'CR',
                'trans_amount', v_base_amt, 'trans_currency', v_base_ccy,
                'base_amount', v_base_amt, 'base_rate', 1,
                'local_amount', v_base_amt * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', (v_frag->>'party_amount')::numeric, 'party_currency', v_frag->>'party_currency',
                'party_rate', CASE WHEN v_base_amt = 0 THEN 1 ELSE (v_frag->>'party_amount')::numeric / v_base_amt END,
                'inv_bill_no', v_frag->>'inv_bill_no', 'inv_bill_date', v_frag->>'inv_bill_date'
            ));

            v_net_fx_diff := v_net_fx_diff + (v_base_amt - (v_frag->>'proportional_original_base')::numeric);
        END LOOP;

        v_crv_base_no := fn_save_finance_voucher(
            jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_receipt_date,
                'voucher_type_code', 'CRV', 'payment_mode_code', 'CASH', 'is_on_account', false,
                'remarks', format('Cash Collection %s', p_receipt_no)
            ),
            v_crv_base_lines, p_approved_by
        );
        PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_crv_base_no, p_receipt_date, p_approved_by);
        v_crv_base_date := p_receipt_date;
    END IF;

    -- 7. FX gain/loss — company-level EXCHANGE_GAIN_LOSS_ACCOUNT, no
    --    product anchor exists for this document. Both lines natively
    --    in base currency (mirrors Purchase Bill's EXC pattern exactly)
    --    — no inv_bill_no on the customer line, pure GL valuation
    --    adjustment, invisible to v_pending_bills.
    IF abs(v_net_fx_diff) > 0.0001 THEN
        v_fx_account := fn_resolve_company_account_link(p_client_id, p_company_id, 'EXCHANGE_GAIN_LOSS_ACCOUNT');
        IF v_fx_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = 'No Exchange Gain/Loss Account configured at Company level — cannot post the currency revaluation on this receipt.';
        END IF;

        IF v_net_fx_diff < 0 THEN
            -- Collected less base value than proportionally booked: LOSS
            v_exc_lines := jsonb_build_array(
                jsonb_build_object('account_id', v_fx_account, 'trans_nature', 'DR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1),
                jsonb_build_object('account_id', v_header.customer_id, 'trans_nature', 'CR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1)
            );
        ELSE
            -- Collected more base value than proportionally booked: GAIN
            v_exc_lines := jsonb_build_array(
                jsonb_build_object('account_id', v_header.customer_id, 'trans_nature', 'DR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1),
                jsonb_build_object('account_id', v_fx_account, 'trans_nature', 'CR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1)
            );
        END IF;

        SELECT trans_no, trans_date INTO v_exc_voucher_no, v_exc_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'EXC', p_receipt_date,
            v_exc_lines, 'CASH_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
        );
    END IF;

    -- 8. Mark receipt approved.
    UPDATE rih_cash_receipt_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        crv_local_voucher_no = v_crv_local_no,   crv_local_voucher_date = v_crv_local_date,
        crv_base_voucher_no  = v_crv_base_no,    crv_base_voucher_date  = v_crv_base_date,
        exc_voucher_no       = v_exc_voucher_no, exc_voucher_date       = v_exc_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_cash_receipt(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
