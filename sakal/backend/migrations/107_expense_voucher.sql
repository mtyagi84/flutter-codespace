-- ============================================================
-- 107_expense_voucher.sql — Expense Voucher (Finance)
--
-- Creates a Supplier bill for a SERVICE (electricity, water, internet,
-- ...) with no GRN, no goods receipt — the accrual-accounting use case
-- of recognizing an expense in the period it belongs to even though it
-- is entered/paid later. Modeled on Odoo's Vendor Bill: each line is
-- Account + Amount (always an implicit debit, no manual Dr/Cr) plus an
-- OPTIONAL Tax Group; the engine expands that group automatically at
-- Approve time by checking each member tax's own rim_tax_types.
-- is_withholding flag — a normal (VAT-type) tax ADDS to the payable
-- (posts to that tax's gl_input_account_id), a WITHHOLDING-type tax
-- SUBTRACTS from it (posts to that tax's gl_expense_account_id). This
-- is the FIRST real consumer of is_withholding anywhere in this schema
-- (025_tax_master.sql) — seeded, fully designed, never wired to any
-- posting function until now, same situation as reversal_of_trans_no
-- before Journal Voucher or EXCHANGE_GAIN_LOSS_ACCOUNT before Contra
-- Voucher.
--
-- Structurally closer to Purchase Bill than to Journal/Contra Voucher:
-- this is a real source document (own header+line tables, own
-- fn_save_*/fn_approve_* pair) because tax computation must be
-- authoritative on the backend, not client-computed like JV/Contra's
-- fully generic lines. fn_approve_expense_voucher composes the SAME
-- fn_post_voucher entry point Purchase Bill/GRN already use — never
-- writes to rih_finance_headers/rid_finance_lines directly.
--
-- Supplier is always serial_no=1 in the posted voucher (mirroring
-- Payment/Receipt Voucher's own "line 1 is the fixed/anchor line"
-- convention) even though the user enters expense lines first and the
-- Supplier's own net payable is only known once every line (and its
-- tax) has been totalled — achieved by prepending the Supplier line to
-- the array fn_post_voucher receives, since it assigns serial_no in
-- array order.
--
-- Bill-linkage is MANDATORY here (inv_bill_no/inv_bill_date on the
-- Supplier line always come from the header's own bill_no/bill_date),
-- unlike Journal Voucher's opt-in per-line auto-tagging — creating a
-- payable is this document's entire purpose, not an inferred
-- side-effect. Balance is guaranteed by construction: the Supplier
-- line's base_amount is FORCED to (expense+VAT total − withholding
-- total), never independently re-derived via multiplication, same
-- technique 059_purchase_invoice_exchange_voucher_split.sql already
-- uses for its own PUR voucher — avoids a floating-point mismatch
-- ever tripping fn_post_voucher's own VOUCHER_POSTING_IMBALANCE check.
-- ============================================================


-- ── 1. rim_voucher_types — allow 'EXPENSE' as a voucher_nature ──────────
-- Current list (confirmed live, migration 106): RECEIPT|PAYMENT|JOURNAL|
-- DEBIT_NOTE|CREDIT_NOTE|STOCK|PURCHASE|SALES|CONTRA. Extends from THIS
-- list, not the original 017 one — the exact mistake caught live during
-- Contra Voucher's own build.
ALTER TABLE rim_voucher_types DROP CONSTRAINT IF EXISTS rim_voucher_types_nature_check;
ALTER TABLE rim_voucher_types ADD CONSTRAINT rim_voucher_types_nature_check
    CHECK (voucher_nature IN ('RECEIPT','PAYMENT','JOURNAL','DEBIT_NOTE','CREDIT_NOTE','STOCK','PURCHASE','SALES','CONTRA','EXPENSE'));

-- Two codes, same split rationale as Purchase Bill's PINV(numbering)/
-- PUR(posting) and Material Issue's MREQ+MISS(numbering)/MIC(posting):
-- EXV numbers the source DOCUMENT (fn_save_expense_voucher's own
-- fn_next_trans_no call); EXP is the separate GL POSTING code
-- (fn_approve_expense_voucher's fn_post_voucher call). Reusing one code
-- for both would make Approve silently consume/skip numbers from the
-- document's own numbering sequence, since ril_trans_no_seq keys its
-- counter on (company, location, voucher_type_code) alone.
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('EXV', 'Expense Voucher', 'EXPENSE', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('EXP', 'Expense Posting',  'EXPENSE', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 2. rim_accounts — default tax group per account ──────────────────────
-- User-specified (built now, not deferred): picking an Expense account
-- on this screen auto-suggests its usual Tax Group. Nullable — most
-- accounts have no default; General/Employee/Tax-natured expense
-- accounts are the realistic users of this.
ALTER TABLE rim_accounts ADD COLUMN IF NOT EXISTS default_tax_group_id UUID REFERENCES rim_tax_groups(id);


-- ── 3. rih_expense_voucher_headers ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_expense_voucher_headers (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    location_id         UUID          NOT NULL REFERENCES ric_locations(id),
    trans_no            TEXT          NOT NULL,
    trans_date          DATE          NOT NULL,
    supplier_id         UUID          NOT NULL REFERENCES rim_accounts(id),
    currency_id         UUID          NOT NULL REFERENCES rim_currencies(id),
    rate_to_base        NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local       NUMERIC(18,8) NOT NULL DEFAULT 1,
    -- The supplier's own paper bill — duplicate prevention lives on this
    -- pair, not on our internal trans_no (same convention as Purchase
    -- Bill's supplier_invoice_no/date).
    bill_no             TEXT          NOT NULL,
    bill_date           DATE          NOT NULL,
    remarks             TEXT,
    status              TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by         UUID          REFERENCES rim_users(id),
    approved_at         TIMESTAMPTZ,
    posted_voucher_no   TEXT,
    posted_voucher_date DATE,
    is_deleted          BOOLEAN       NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          UUID          REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, trans_no, trans_date),
    UNIQUE (client_id, company_id, supplier_id, bill_no)
);

CREATE INDEX IF NOT EXISTS idx_expense_voucher_headers_supplier ON rih_expense_voucher_headers (client_id, company_id, supplier_id);
CREATE INDEX IF NOT EXISTS idx_expense_voucher_headers_status   ON rih_expense_voucher_headers (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_expense_voucher_headers_updated_at ON rih_expense_voucher_headers;
CREATE TRIGGER trg_rih_expense_voucher_headers_updated_at
    BEFORE UPDATE ON rih_expense_voucher_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_expense_voucher_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_expense_voucher_headers" ON rih_expense_voucher_headers;
CREATE POLICY "auth_rw_expense_voucher_headers" ON rih_expense_voucher_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_expense_voucher_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_expense_voucher_headers TO authenticated;


-- ── 4. rid_expense_voucher_lines ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rid_expense_voucher_lines (
    id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID          NOT NULL,
    company_id     UUID          NOT NULL,
    trans_no       TEXT          NOT NULL,
    trans_date     DATE          NOT NULL,
    serial_no      INTEGER       NOT NULL,
    account_id     UUID          NOT NULL REFERENCES rim_accounts(id),
    amount         NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_group_id   UUID          REFERENCES rim_tax_groups(id),
    line_remarks   TEXT,
    is_deleted     BOOLEAN       NOT NULL DEFAULT false,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by     UUID          REFERENCES rim_users(id),
    updated_at     TIMESTAMPTZ,
    updated_by     UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, trans_no, trans_date, serial_no),
    FOREIGN KEY (client_id, company_id, trans_no, trans_date)
        REFERENCES rih_expense_voucher_headers (client_id, company_id, trans_no, trans_date)
);

CREATE INDEX IF NOT EXISTS idx_expense_voucher_lines_account ON rid_expense_voucher_lines (account_id);

ALTER TABLE rid_expense_voucher_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_expense_voucher_lines" ON rid_expense_voucher_lines;
CREATE POLICY "auth_rw_expense_voucher_lines" ON rid_expense_voucher_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_expense_voucher_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_expense_voucher_lines TO authenticated;


-- ── 5. fn_save_expense_voucher ───────────────────────────────────────────
-- DRAFT-only, blocks edits once APPROVED — same immutability rule every
-- fn_save_* in this schema enforces. Lines: delete-then-reinsert on
-- every save, same shape as GRN/PO's own child-row handling.
CREATE OR REPLACE FUNCTION fn_save_expense_voucher(
    p_header  JSONB,
    p_lines   JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id   UUID   := (p_header->>'client_id')::uuid;
    v_company_id  UUID   := (p_header->>'company_id')::uuid;
    v_location_id UUID   := (p_header->>'location_id')::uuid;
    v_trans_no    TEXT   := nullif(trim(p_header->>'trans_no'), '');
    v_trans_date  DATE   := (p_header->>'trans_date')::date;
    v_is_new      BOOLEAN := nullif(trim(p_header->>'trans_no'), '') IS NULL;
    v_old_status  TEXT;
    v_old_trans_date DATE;
    v_line        JSONB;
    v_serial      INTEGER := 0;
BEGIN
    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one expense line.';
    END IF;

    IF v_is_new THEN
        v_trans_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'EXV');
    ELSE
        -- Capture the OLD trans_date before anything changes — the lines'
        -- own FK is keyed on (trans_no, trans_date), so if the user edited
        -- the voucher date on this draft, deleting/re-pointing must use the
        -- date the existing lines were actually saved under, not the new
        -- one, or the header UPDATE below would violate the FK outright
        -- (child rows still referencing the old composite key). Same fix
        -- GRN's own fn_save_grn already applies (v_old_grn_date).
        SELECT status, trans_date INTO v_old_status, v_old_trans_date FROM rih_expense_voucher_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND trans_no = v_trans_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Expense Voucher % not found.', v_trans_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Expense Voucher % is % and cannot be edited.', v_trans_no, v_old_status;
        END IF;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_expense_voucher_headers (
            client_id, company_id, location_id, trans_no, trans_date,
            supplier_id, currency_id, rate_to_base, rate_to_local,
            bill_no, bill_date, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_trans_no, v_trans_date,
            (p_header->>'supplier_id')::uuid, (p_header->>'currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1), coalesce((p_header->>'rate_to_local')::numeric, 1),
            p_header->>'bill_no', (p_header->>'bill_date')::date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        -- Delete the OLD lines (keyed on the OLD date) BEFORE the header's
        -- own trans_date changes underneath them — see the capture comment
        -- above for why this order is required, not just tidy.
        DELETE FROM rid_expense_voucher_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND trans_no = v_trans_no AND trans_date = v_old_trans_date;

        UPDATE rih_expense_voucher_headers SET
            location_id   = v_location_id,
            trans_date    = v_trans_date,
            supplier_id   = (p_header->>'supplier_id')::uuid,
            currency_id   = (p_header->>'currency_id')::uuid,
            rate_to_base  = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local = coalesce((p_header->>'rate_to_local')::numeric, 1),
            bill_no       = p_header->>'bill_no',
            bill_date     = (p_header->>'bill_date')::date,
            remarks       = nullif(p_header->>'remarks', ''),
            updated_at    = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND trans_no = v_trans_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_serial := v_serial + 1;
        INSERT INTO rid_expense_voucher_lines (
            client_id, company_id, trans_no, trans_date, serial_no,
            account_id, amount, tax_group_id, line_remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_trans_no, v_trans_date, v_serial,
            (v_line->>'account_id')::uuid, coalesce((v_line->>'amount')::numeric, 0),
            nullif(v_line->>'tax_group_id', '')::uuid, nullif(v_line->>'line_remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_trans_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_expense_voucher(JSONB, JSONB, UUID) TO authenticated;


-- ── 6. fn_approve_expense_voucher ────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_expense_voucher(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID,
    p_trans_no    TEXT,
    p_trans_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header         rih_expense_voucher_headers%ROWTYPE;
    v_line           RECORD;
    v_tax_row        RECORD;
    v_currency_ccy   TEXT;
    v_base_ccy       TEXT;
    v_local_ccy      TEXT;
    v_account_ccy    TEXT;
    v_party_rate     NUMERIC;
    v_party_ccy      TEXT;
    v_rate           NUMERIC;
    v_tax_amt        NUMERIC;
    v_other_lines    JSONB := '[]'::jsonb;
    v_voucher_lines  JSONB;
    v_dr_total_trans NUMERIC := 0;
    v_dr_total_base  NUMERIC := 0;
    v_wht_total_trans NUMERIC := 0;
    v_wht_total_base  NUMERIC := 0;
    v_net_trans      NUMERIC;
    v_net_base       NUMERIC;
    v_voucher_result RECORD;
BEGIN
    -- 1. Lock header, validate status.
    SELECT * INTO v_header FROM rih_expense_voucher_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND trans_no = p_trans_no AND trans_date = p_trans_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expense Voucher % dated % not found', p_trans_no, p_trans_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Expense Voucher % is % and cannot be approved again', p_trans_no, v_header.status;
    END IF;

    -- 2. Period + backdate checks (5-arg form — compares against this
    --    document's own creation date, not live CURRENT_DATE, same fix
    --    Journal Voucher's own backdate check got in migration 105).
    PERFORM fn_check_period_open(p_company_id, p_trans_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'EXPENSE_VOUCHER', p_trans_date, v_header.created_at::date);

    SELECT currency_id INTO v_currency_ccy FROM rim_currencies WHERE id = v_header.currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- 3. Loop expense lines — each is always an implicit DEBIT (no manual
    --    Dr/Cr, per the user's own final direction), with an optional Tax
    --    Group expanded into further lines.
    FOR v_line IN
        SELECT * FROM rid_expense_voucher_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND trans_no = p_trans_no AND trans_date = p_trans_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        SELECT c.currency_id INTO v_account_ccy
        FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
        WHERE a.id = v_line.account_id;
        IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
            v_party_rate := 1; v_party_ccy := v_currency_ccy;
        ELSIF v_account_ccy = v_base_ccy THEN
            v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
        ELSIF v_account_ccy = v_local_ccy THEN
            v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
            v_party_ccy := v_account_ccy;
        END IF;

        v_other_lines := v_other_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_line.account_id, 'trans_nature', 'DR',
            'trans_amount', v_line.amount, 'trans_currency', v_currency_ccy,
            'base_amount', v_line.amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_line.amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_line.amount * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'line_remarks', v_line.line_remarks, 'source_line_type', 'EXPENSE', 'source_line_no', v_line.serial_no
        ));
        v_dr_total_trans := v_dr_total_trans + v_line.amount;
        v_dr_total_base  := v_dr_total_base  + (v_line.amount * v_header.rate_to_base);

        -- Tax Group expansion — a normal (VAT-type) member ADDS to the
        -- payable, a WITHHOLDING-type member SUBTRACTS from it. First real
        -- consumer of rim_tax_types.is_withholding anywhere in this schema.
        IF v_line.tax_group_id IS NOT NULL THEN
            FOR v_tax_row IN
                SELECT t.id AS tax_id, t.tax_code, t.tax_name,
                       t.gl_input_account_id, t.gl_expense_account_id,
                       tt.is_withholding
                FROM rim_tax_group_members tgm
                JOIN rim_taxes t      ON t.id = tgm.tax_id
                JOIN rim_tax_types tt ON tt.tax_type_code = t.tax_type_code
                WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                  AND tgm.tax_group_id = v_line.tax_group_id
                ORDER BY tgm.sequence_no
            LOOP
                v_rate := fn_get_active_tax_rate(v_tax_row.tax_id, p_trans_date);
                IF v_rate IS NULL THEN
                    RAISE EXCEPTION 'TAX_RATE_NOT_CONFIGURED'
                        USING DETAIL = format('Tax [%s] %s has no active rate for %s.', v_tax_row.tax_code, v_tax_row.tax_name, p_trans_date);
                END IF;
                v_tax_amt := v_line.amount * v_rate / 100;
                IF v_tax_amt = 0 THEN
                    CONTINUE;
                END IF;

                IF NOT v_tax_row.is_withholding THEN
                    IF v_tax_row.gl_input_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Tax [%s] %s has no Input GL account configured.', v_tax_row.tax_code, v_tax_row.tax_name);
                    END IF;

                    SELECT c.currency_id INTO v_account_ccy
                    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
                    WHERE a.id = v_tax_row.gl_input_account_id;
                    IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
                        v_party_rate := 1; v_party_ccy := v_currency_ccy;
                    ELSIF v_account_ccy = v_base_ccy THEN
                        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
                    ELSIF v_account_ccy = v_local_ccy THEN
                        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
                    ELSE
                        v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
                        v_party_ccy := v_account_ccy;
                    END IF;

                    v_other_lines := v_other_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'DR',
                        'trans_amount', v_tax_amt, 'trans_currency', v_currency_ccy,
                        'base_amount', v_tax_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_tax_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_tax_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
                        'source_line_type', 'INPUT_VAT', 'source_line_no', v_line.serial_no
                    ));
                    v_dr_total_trans := v_dr_total_trans + v_tax_amt;
                    v_dr_total_base  := v_dr_total_base  + (v_tax_amt * v_header.rate_to_base);
                ELSE
                    IF v_tax_row.gl_expense_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Withholding tax [%s] %s has no GL account configured.', v_tax_row.tax_code, v_tax_row.tax_name);
                    END IF;

                    SELECT c.currency_id INTO v_account_ccy
                    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
                    WHERE a.id = v_tax_row.gl_expense_account_id;
                    IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
                        v_party_rate := 1; v_party_ccy := v_currency_ccy;
                    ELSIF v_account_ccy = v_base_ccy THEN
                        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
                    ELSIF v_account_ccy = v_local_ccy THEN
                        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
                    ELSE
                        v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
                        v_party_ccy := v_account_ccy;
                    END IF;

                    v_other_lines := v_other_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_expense_account_id, 'trans_nature', 'CR',
                        'trans_amount', v_tax_amt, 'trans_currency', v_currency_ccy,
                        'base_amount', v_tax_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_tax_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_tax_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
                        'source_line_type', 'WITHHOLDING', 'source_line_no', v_line.serial_no
                    ));
                    v_wht_total_trans := v_wht_total_trans + v_tax_amt;
                    v_wht_total_base  := v_wht_total_base  + (v_tax_amt * v_header.rate_to_base);
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    -- 4. Supplier CR line — net = expense+VAT total minus withholding
    --    total. base_amount is FORCED to the literal accumulated figure
    --    (never re-derived via trans_amount * rate_to_base independently)
    --    so fn_post_voucher's own DR=CR check can never fail on a
    --    floating-point rounding mismatch — same technique 059 uses for
    --    its own PUR voucher.
    v_net_trans := v_dr_total_trans - v_wht_total_trans;
    v_net_base  := v_dr_total_base  - v_wht_total_base;

    IF v_net_base <= 0 THEN
        RAISE EXCEPTION 'EXPENSE_NET_NOT_POSITIVE'
            USING DETAIL = 'The Debit total must exceed the Credit total — this document creates a payable, so the supplier must end up owed a positive amount.';
    END IF;

    SELECT c.currency_id INTO v_account_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.supplier_id;
    IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
        v_party_rate := 1; v_party_ccy := v_currency_ccy;
    ELSIF v_account_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_account_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
        v_party_ccy := v_account_ccy;
    END IF;

    -- Supplier is prepended first — fn_post_voucher assigns serial_no in
    -- array order, so this guarantees Supplier = serial_no 1, matching
    -- Payment/Receipt Voucher's own "line 1 is the fixed/anchor line"
    -- convention, even though it's computed last.
    v_voucher_lines := jsonb_build_array(jsonb_build_object(
        'account_id', v_header.supplier_id, 'trans_nature', 'CR',
        'trans_amount', v_net_trans, 'trans_currency', v_currency_ccy,
        'base_amount', v_net_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_net_trans * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_net_trans * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', v_header.bill_no, 'inv_bill_date', v_header.bill_date,
        'source_line_type', 'SUPPLIER'
    )) || v_other_lines;

    -- 5. Post — fn_post_voucher composes fn_save_finance_voucher +
    --    fn_post_finance_voucher, tags source_doc_type/no/date, and
    --    re-validates DR=CR on base_amount itself. Posts under 'EXP'
    --    (the posting code), never 'EXV' (the document's own numbering
    --    code) — see the rim_voucher_types seed comment above.
    SELECT * INTO v_voucher_result FROM fn_post_voucher(
        p_client_id, p_company_id, p_location_id, 'EXP', p_trans_date,
        v_voucher_lines, 'EXPENSE_VOUCHER', p_trans_no, p_trans_date, p_approved_by
    );

    -- 6. Mark approved, store GL traceability.
    UPDATE rih_expense_voucher_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_voucher_result.trans_no,
        posted_voucher_date = v_voucher_result.trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_expense_voucher(UUID, UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── 7. Menu seed for EXISTING clients ────────────────────────────────
-- fn_seed_client_modules.sql (backend/functions/) updated for FUTURE
-- clients — must be re-run manually in the Supabase SQL editor. This
-- backfills every already-existing company, same shape as 092/095/106.
--
-- IMPORTANT: adding this row alone does not grant any existing user
-- access — re-run fn_grant_admin_access(user_id, client_id, company_id)
-- for whichever user(s) should see this screen.
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'FN-EXP', 'Expense Voucher', '/finance/expense-vouchers',
    2, 'FN-TXN', 'Transactions', 0,
    true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'FN'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
