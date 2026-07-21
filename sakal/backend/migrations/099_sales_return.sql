-- ============================================================
-- Migration 099: Sales Return
-- ============================================================
-- Plan written first in sakal/docs/screens/sales_return.md — read that for
-- the full requirement doc. This migration builds it as designed there,
-- no scope changes.
--
-- "Return" and "reverse" are ONE feature, same as Purchase Return (061) —
-- reason is a free-text audit label, never a branch in the code.
--
-- Unlike Purchase Return (which can span multiple GRNs, some billed, some
-- not, needing a header-confirmed total apportioned back down across
-- lines), Sales Return references exactly ONE already-APPROVED invoice
-- whose own line-level rate/tax_group/amounts are already fixed and
-- trustworthy — there's no external document to reconcile a confirmed
-- total against, so every line's own stored gross_amount/tax_amount/
-- final_amount posts directly, no apportionment-from-header-total
-- indirection needed. That invoice CAN be the source of many separate
-- Sales Return documents over time (cumulative-qty capped, same mechanism
-- as Purchase Return's v_already_returned pattern, scoped per invoice
-- line instead of per-GRN-line).
--
-- Three possible vouchers per approval, all tagged
-- source_doc_type='SALES_RETURN'/source_doc_no=return_no:
--   CRN  (Credit Note, always) — per line: DR SALES_RETURNS_ACCOUNT (new
--        contra-revenue link type) + DR the tax's own gl_output_account_id
--        (reversed from the invoice's CR); per charge: reversed direction
--        from the original (ADD reversed -> DR, DEDUCT reversed -> CR) +
--        its own tax leg reversed the same way; one aggregate CR Customer
--        line, self-tagged inv_bill_no (corrected post-hoc to the CRN's
--        own trans_no, same trick fn_approve_sales_invoice uses) so the
--        refund below (or any future manual settlement) can settle
--        directly against it via the existing Against-Bill mechanism.
--   COS  (reused type, JOURNAL nature) — only when the source invoice's
--        stock_dispatch_mode was IMMEDIATE. Unit cost is the ORIGINAL
--        invoice's own historical per-unit COGS (read back from that
--        invoice's already-posted COS voucher's own STOCK line via
--        source_line_type/source_line_no), never a fresh current-average
--        lookup — this is what keeps this return's Stock-DR/COGS-CR
--        symmetric with what the invoice itself reversed. First INWARD
--        fn_post_stock_movement caller in this schema supplying a
--        historical rather than current cost.
--   CPV  (reused type) — the cash refund, only when the source invoice was
--        CASH + actually collected (cash_collection_mode='IMMEDIATE').
--        Posted via fn_save_finance_voucher + fn_post_finance_voucher
--        DIRECTLY (never fn_post_voucher, which hardcodes
--        is_on_account=true) — same reasoning Sales Invoice's own CRV
--        collection uses. Capped cumulative per invoice, per currency leg
--        (local/base), against what that invoice actually collected minus
--        what prior approved Sales Returns against it already refunded —
--        mirrors the qty-cap pattern, applied to cash instead of quantity.
--        Settles directly against the CRN's own bill (inv_bill_no), DR
--        Customer / CR Cash account (from the RETURN's own created_by's
--        Quick Invoice Setup — whoever is at the till processing the
--        refund right now, not necessarily the original cashier).
--
-- Batch/serial: no new tables — reuses rid_transaction_line_batches/
-- rid_transaction_line_serials (source_doc_type='SALES_RETURN'), same as
-- every prior module. Candidates (Flutter-side) are scoped to exactly what
-- the specific invoice line sold (source_doc_type='SALES_INVOICE',
-- source_doc_no=invoice_no, line_serial=<that line's serial>) minus
-- whatever a prior approved Sales Return already consumed — same idiom as
-- Purchase Return's GRN-line-scoped candidates. Mandatory allocation is a
-- Flutter-side rule only (backend has no proactive tracking_type check),
-- matching the existing, documented Purchase Return precedent exactly —
-- not a new gap introduced here.
--
-- Online-only, no offline support (v1) — approving a return needs a live,
-- cross-device "how much of this invoice line has already been returned"
-- check, same reasoning as Sales Invoice's own AGAINST_QUOTATION/
-- AGAINST_ORDER modes.
--
-- DRAFT / APPROVED only, no CANCELLED — same as Purchase Return, matches
-- the Immutability principle (once approved, no clean "un-return" path).
--
-- Naming: no `source_` prefix anywhere. The header stores the one-and-
-- only invoice_no/invoice_date this return is against; a line only needs
-- invoice_line_serial (which line of that invoice), never a repeated
-- source_invoice_no/source_invoice_date per line the way Purchase Return's
-- source_grn_no needs one (Purchase Return can reference MULTIPLE GRNs per
-- return; Sales Return can't).
-- ============================================================


-- ── New voucher types ────────────────────────────────────────────────────
-- SRET numbers the return document itself (fn_next_trans_no), never the
-- ledger voucher — same numbering-code-vs-posting-code split as every
-- other module (PINV/PUR, MREQ+MISS/MIC, ADJ/ADJV). CRN is the new GL
-- posting code; COS and CPV are REUSED as-is, no new type needed for them.
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('SRET', 'Sales Return', 'SALES', NULL, 'YEARLY', 'SRET/{LOC}/{YYYY}/{SEQ5}', true),
    ('CRN',  'Credit Note',  'SALES', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;

-- ── New account-link type: Sales Returns contra-revenue account ─────────
-- Mirrors PURCHASE_RETURNS_ACCOUNT's precedent (061) — deliberately NOT
-- the plain SALES_ACCOUNT, so Gross Sales and Sales Returns report as
-- separate P&L lines (standard practice), not netted invisibly together.
INSERT INTO rim_account_link_types (link_key, link_name, sort_order) VALUES
    ('SALES_RETURNS_ACCOUNT', 'Sales Returns Account', 151)
ON CONFLICT (link_key) DO NOTHING;


-- ============================================================
-- rih_sales_return_headers
-- ============================================================
CREATE TABLE IF NOT EXISTS rih_sales_return_headers (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL REFERENCES ric_clients(id),
    company_id             UUID          NOT NULL REFERENCES ric_companies(id),
    location_id            UUID          NOT NULL REFERENCES ric_locations(id),
    return_no              TEXT          NOT NULL,
    return_date            DATE          NOT NULL,
    invoice_no              TEXT         NOT NULL,
    invoice_date            DATE         NOT NULL,
    customer_id              UUID        NOT NULL REFERENCES rim_accounts(id),
    return_currency_id        UUID       REFERENCES rim_currencies(id),
    rate_to_base                NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local                 NUMERIC(18,8) NOT NULL DEFAULT 1,
    taxable_amount                  NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount                        NUMERIC(18,4) NOT NULL DEFAULT 0,
    charges_amount                      NUMERIC(18,4) NOT NULL DEFAULT 0,
    return_total                          NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- User-confirmed refund request, defaulted client-side proportionally
    -- to how the original invoice split local/base collection. Validated
    -- (never silently clamped) against the remaining-collected pool at
    -- Approve — see fn_approve_sales_return.
    refund_amount_local                     NUMERIC(18,4) NOT NULL DEFAULT 0,
    refund_amount_base                        NUMERIC(18,4) NOT NULL DEFAULT 0,
    reason                                      TEXT,  -- free text label only, never branches logic
    remarks                                       TEXT,
    status                                          TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by                                       UUID REFERENCES rim_users(id),
    approved_at                                         TIMESTAMPTZ,
    credit_note_voucher_no                                TEXT,
    credit_note_voucher_date                                DATE,
    cos_voucher_no                                            TEXT,
    cos_voucher_date                                            DATE,
    refund_voucher_no_local                                       TEXT,
    refund_voucher_date_local                                       DATE,
    refund_voucher_no_base                                            TEXT,
    refund_voucher_date_base                                            DATE,
    is_deleted             BOOLEAN       NOT NULL DEFAULT false,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by               UUID        REFERENCES rim_users(id),
    updated_at                TIMESTAMPTZ,
    updated_by                  UUID     REFERENCES rim_users(id),
    CONSTRAINT uq_rih_sales_return_headers UNIQUE (client_id, company_id, return_no, return_date)
);

CREATE INDEX IF NOT EXISTS idx_rih_sr_tenant    ON rih_sales_return_headers (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rih_sr_invoice   ON rih_sales_return_headers (client_id, company_id, invoice_no, invoice_date);
CREATE INDEX IF NOT EXISTS idx_rih_sr_customer  ON rih_sales_return_headers (customer_id);
CREATE INDEX IF NOT EXISTS idx_rih_sr_status    ON rih_sales_return_headers (client_id, company_id, location_id, status);
CREATE INDEX IF NOT EXISTS idx_rih_sr_date      ON rih_sales_return_headers (client_id, company_id, return_date DESC);

DROP TRIGGER IF EXISTS trg_rih_sales_return_headers_updated_at ON rih_sales_return_headers;
CREATE TRIGGER trg_rih_sales_return_headers_updated_at
    BEFORE UPDATE ON rih_sales_return_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_sales_return_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sales_return_headers" ON rih_sales_return_headers;
CREATE POLICY "auth_rw_sales_return_headers" ON rih_sales_return_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_sales_return_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_sales_return_headers TO authenticated;


-- ============================================================
-- rid_sales_return_lines
-- ============================================================
CREATE TABLE IF NOT EXISTS rid_sales_return_lines (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL,
    company_id             UUID          NOT NULL,
    return_no              TEXT          NOT NULL,
    return_date            DATE          NOT NULL,
    serial_no              INTEGER       NOT NULL,
    invoice_line_serial    INTEGER       NOT NULL,
    product_id             UUID          NOT NULL REFERENCES rim_products(id),
    -- Carried forward from the invoice line's own saved barcode column —
    -- this is a consolidation document (lines copied from a prior
    -- document), never a freshly scanned value. No showBarcode gating
    -- needed since there's no scan UI here to gate.
    barcode                TEXT,
    uom_id                 UUID,
    uom_conversion_factor  NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack               NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose              NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty               NUMERIC(18,4) NOT NULL DEFAULT 0,   -- the RETURN quantity
    rate                   NUMERIC(18,4) NOT NULL DEFAULT 0,   -- inherited from the invoice line, read-only
    tax_group_id           UUID          REFERENCES rim_tax_groups(id),
    gross_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount             NUMERIC(18,4) NOT NULL DEFAULT 0,
    final_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,
    charge_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
    landed_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_deleted             BOOLEAN       NOT NULL DEFAULT false,
    created_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by             UUID          REFERENCES rim_users(id),
    updated_at             TIMESTAMPTZ,
    updated_by             UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rid_sr_lines UNIQUE (client_id, company_id, return_no, return_date, serial_no),
    CONSTRAINT rid_sr_lines_header_fk
        FOREIGN KEY (client_id, company_id, return_no, return_date)
        REFERENCES  rih_sales_return_headers (client_id, company_id, return_no, return_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_sr_lines_header  ON rid_sales_return_lines (client_id, company_id, return_no, return_date);
CREATE INDEX IF NOT EXISTS idx_rid_sr_lines_product ON rid_sales_return_lines (product_id);

ALTER TABLE rid_sales_return_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sr_lines" ON rid_sales_return_lines;
CREATE POLICY "auth_rw_sr_lines" ON rid_sales_return_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_return_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_return_lines TO authenticated;


-- ============================================================
-- rid_sales_return_charges — mirrors rid_sales_invoice_charges' shape.
-- Carried forward PROPORTIONALLY from the source invoice's own charges
-- (if any) as read-only defaults — nothing left to legitimately choose,
-- same rule Sales Invoice itself established for its AGAINST_QUOTATION/
-- AGAINST_ORDER modes. invoice_charge_serial traces which invoice charge
-- this was apportioned from.
-- ============================================================
CREATE TABLE IF NOT EXISTS rid_sales_return_charges (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    return_no             TEXT          NOT NULL,
    return_date           DATE          NOT NULL,
    serial_no             INTEGER       NOT NULL,
    invoice_charge_serial INTEGER,
    charge_id             UUID          NOT NULL REFERENCES rim_additional_charges(id),
    charge_name           TEXT          NOT NULL,
    is_taxable            BOOLEAN       NOT NULL DEFAULT false,
    tax_id                UUID          REFERENCES rim_taxes(id),
    nature                TEXT          NOT NULL DEFAULT 'ADD' CHECK (nature IN ('ADD','DEDUCT')),
    gl_account_id         UUID          REFERENCES rim_accounts(id),
    amount                NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rid_sr_charges UNIQUE (client_id, company_id, return_no, return_date, serial_no),
    CONSTRAINT rid_sr_charges_header_fk
        FOREIGN KEY (client_id, company_id, return_no, return_date)
        REFERENCES  rih_sales_return_headers (client_id, company_id, return_no, return_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_sr_charges_header ON rid_sales_return_charges (client_id, company_id, return_no, return_date);

ALTER TABLE rid_sales_return_charges ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sr_charges" ON rid_sales_return_charges;
CREATE POLICY "auth_rw_sr_charges" ON rid_sales_return_charges
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_return_charges FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_return_charges TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_sales_return — DRAFT-only, mirrors fn_save_purchase_return's shape
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_sales_return(
    p_header  JSONB,  -- {client_id, company_id, return_no, return_date, invoice_no, invoice_date, taxable_amount, tax_amount, charges_amount, return_total, refund_amount_local, refund_amount_base, reason, remarks}
    p_lines   JSONB,  -- [{serial_no, invoice_line_serial, product_id, barcode, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate, tax_group_id, gross_amount, tax_amount, final_amount, charge_amount, landed_amount}, ...]
    p_batches JSONB,  -- [{line_serial, batch_no, expiry_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials JSONB,  -- [{line_serial, serial_no}, ...]
    p_charges JSONB,  -- [{serial_no, invoice_charge_serial, charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id, amount, tax_amount}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     UUID;
    v_company_id    UUID;
    v_return_no     TEXT;
    v_return_date   DATE;
    v_invoice_no    TEXT;
    v_invoice_date  DATE;
    v_old_status    TEXT;
    v_is_new        BOOLEAN;
    v_invoice       rih_sales_invoices%ROWTYPE;
    v_line          JSONB;
    v_charge        JSONB;
    v_batch         JSONB;
    v_charges_total NUMERIC := 0;
    v_line_qty      NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_return_no    := nullif(trim(p_header->>'return_no'), '');
    v_return_date  := (p_header->>'return_date')::date;
    v_invoice_no   := p_header->>'invoice_no';
    v_invoice_date := (p_header->>'invoice_date')::date;
    v_is_new       := v_return_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Return.';
    END IF;

    -- Lock and validate the source invoice — must exist and be APPROVED.
    -- location_id/customer_id/currency/rate are all inherited from HERE,
    -- server-side, never trusted from the client — nothing left for the
    -- client to legitimately choose about a document already fixed by an
    -- approved invoice.
    SELECT * INTO v_invoice FROM rih_sales_invoices
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND invoice_no = v_invoice_no AND invoice_date = v_invoice_date
      AND is_deleted = false
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % not found.', v_invoice_no;
    END IF;
    IF v_invoice.status != 'APPROVED' THEN
        RAISE EXCEPTION 'Sales Invoice % is % — only APPROVED invoices can be returned against.', v_invoice.invoice_no, v_invoice.status;
    END IF;

    IF v_is_new THEN
        v_return_no := fn_next_trans_no(v_client_id, v_company_id, v_invoice.location_id, 'SRET');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_sales_return_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Sales Return % is % and cannot be edited.', v_return_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_RETURN' AND source_doc_no = v_return_no AND source_doc_date = v_return_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_RETURN' AND source_doc_no = v_return_no AND source_doc_date = v_return_date;
        DELETE FROM rid_sales_return_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
        DELETE FROM rid_sales_return_charges
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_sales_return_headers (
            client_id, company_id, location_id, return_no, return_date,
            invoice_no, invoice_date, customer_id,
            return_currency_id, rate_to_base, rate_to_local,
            taxable_amount, tax_amount, charges_amount, return_total,
            refund_amount_local, refund_amount_base,
            reason, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_invoice.location_id, v_return_no, v_return_date,
            v_invoice.invoice_no, v_invoice.invoice_date, v_invoice.customer_id,
            v_invoice.invoice_currency_id, v_invoice.rate_to_base, v_invoice.rate_to_local,
            coalesce((p_header->>'taxable_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'return_total')::numeric, 0),
            coalesce((p_header->>'refund_amount_local')::numeric, 0),
            coalesce((p_header->>'refund_amount_base')::numeric, 0),
            nullif(p_header->>'reason', ''), nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_sales_return_headers SET
            location_id          = v_invoice.location_id,
            return_date          = v_return_date,
            invoice_no           = v_invoice.invoice_no,
            invoice_date         = v_invoice.invoice_date,
            customer_id          = v_invoice.customer_id,
            return_currency_id   = v_invoice.invoice_currency_id,
            rate_to_base         = v_invoice.rate_to_base,
            rate_to_local        = v_invoice.rate_to_local,
            taxable_amount       = coalesce((p_header->>'taxable_amount')::numeric, 0),
            tax_amount           = coalesce((p_header->>'tax_amount')::numeric, 0),
            charges_amount       = coalesce((p_header->>'charges_amount')::numeric, 0),
            return_total         = coalesce((p_header->>'return_total')::numeric, 0),
            refund_amount_local  = coalesce((p_header->>'refund_amount_local')::numeric, 0),
            refund_amount_base   = coalesce((p_header->>'refund_amount_base')::numeric, 0),
            reason               = nullif(p_header->>'reason', ''),
            remarks              = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_sales_return_lines (
            client_id, company_id, return_no, return_date, serial_no,
            invoice_line_serial, product_id, barcode,
            uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate,
            tax_group_id, gross_amount, tax_amount, final_amount,
            charge_amount, landed_amount,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_line->>'serial_no')::integer,
            (v_line->>'invoice_line_serial')::integer, (v_line->>'product_id')::uuid, nullif(v_line->>'barcode', ''),
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0), coalesce((v_line->>'rate')::numeric, 0),
            nullif(v_line->>'tax_group_id', '')::uuid,
            coalesce((v_line->>'gross_amount')::numeric, 0), coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            coalesce((v_line->>'charge_amount')::numeric, 0), coalesce((v_line->>'landed_amount')::numeric, 0),
            p_user_id, p_user_id
        );

        -- Batch children for this line, if any — same BATCH_QTY_MISMATCH
        -- rule as fn_save_grn/fn_save_purchase_return.
        v_line_qty := coalesce((v_line->>'base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'SALES_RETURN', v_return_no, v_return_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the return quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'SALES_RETURN', v_return_no, v_return_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(coalesce(p_charges, '[]'::jsonb))
    LOOP
        INSERT INTO rid_sales_return_charges (
            client_id, company_id, return_no, return_date, serial_no, invoice_charge_serial,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount, tax_amount, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_charge->>'serial_no')::integer,
            nullif(v_charge->>'invoice_charge_serial', '')::integer,
            (v_charge->>'charge_id')::uuid, v_charge->>'charge_name',
            coalesce((v_charge->>'is_taxable')::boolean, false), nullif(v_charge->>'tax_id', '')::uuid,
            coalesce(v_charge->>'nature', 'ADD'), nullif(v_charge->>'gl_account_id', '')::uuid,
            coalesce((v_charge->>'amount')::numeric, 0), coalesce((v_charge->>'tax_amount')::numeric, 0),
            p_user_id, p_user_id
        );
        v_charges_total := v_charges_total + coalesce((v_charge->>'amount')::numeric, 0);
    END LOOP;

    UPDATE rih_sales_return_headers SET charges_amount = v_charges_total
    WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;

    RETURN v_return_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_sales_return(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_sales_return
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_sales_return(
    p_client_id   UUID,
    p_company_id  UUID,
    p_return_no   TEXT,
    p_return_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_sales_return_headers%ROWTYPE;
    v_invoice            rih_sales_invoices%ROWTYPE;
    v_return_ccy         TEXT;
    v_base_ccy           TEXT;
    v_local_ccy          TEXT;
    v_line               RECORD;
    v_tax_line           RECORD;
    v_charge_row         rid_sales_return_charges%ROWTYPE;
    v_charge_amount      NUMERIC;
    v_charge_tax_account UUID;
    v_charge_dir         TEXT;
    v_returns_account    UUID;
    v_stock_account      UUID;
    v_cos_account        UUID;
    v_customer_ccy       TEXT;
    v_party_rate         NUMERIC;
    v_party_ccy          TEXT;
    v_crn_lines          JSONB := '[]'::jsonb;
    v_cos_lines          JSONB := '[]'::jsonb;
    v_crn_result         RECORD;
    v_cos_voucher_no     TEXT;
    v_cos_voucher_date   DATE;
    v_already_returned   NUMERIC;
    v_invoice_line_qty   NUMERIC;
    v_customer_cr_total  NUMERIC := 0;
    v_batch              rid_transaction_line_batches%ROWTYPE;
    v_serial_row         rid_transaction_line_serials%ROWTYPE;
    v_has_batches        BOOLEAN;
    v_has_serials        BOOLEAN;
    v_orig_line_base_qty NUMERIC;
    v_orig_line_cost     NUMERIC;
    v_unit_cost          NUMERIC;
    v_unit_cost_specific NUMERIC;
    v_line_cost_total    NUMERIC;
    v_base_to_local_rate NUMERIC;
    v_local_to_base_rate NUMERIC;
    v_already_refunded_local NUMERIC;
    v_already_refunded_base  NUMERIC;
    v_remaining_local    NUMERIC;
    v_remaining_base     NUMERIC;
    v_cash_account_local UUID;
    v_cash_account_base  UUID;
    v_receipt_party_rate NUMERIC;
    v_receipt_party_ccy  TEXT;
    v_receipt_header     JSONB;
    v_receipt_lines      JSONB;
    v_receipt_no         TEXT;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_sales_return_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND return_no = p_return_no AND return_date = p_return_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Return % dated % not found', p_return_no, p_return_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Return % is % and cannot be approved again', p_return_no, v_header.status;
    END IF;

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_return_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_RETURN', p_return_date);

    -- 3. Lock the source invoice
    SELECT * INTO v_invoice FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % not found', v_header.invoice_no;
    END IF;

    SELECT currency_id INTO v_return_ccy FROM rim_currencies WHERE id = v_header.return_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- Customer's own currency shortcut — same idiom fn_approve_sales_invoice
    -- uses for its Customer DR line, reused here for the Customer CR line.
    SELECT c.currency_id INTO v_customer_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.customer_id;
    IF v_customer_ccy IS NULL OR v_customer_ccy = v_return_ccy THEN
        v_party_rate := 1; v_party_ccy := v_return_ccy;
    ELSIF v_customer_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_customer_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_return_ccy, v_customer_ccy, p_return_date);
        v_party_ccy := v_customer_ccy;
    END IF;

    -- 4. Per-line: cap check + Sales-Returns-contra DR + tax DR (reversed
    --    from the invoice's own CR — each line's own stored figures are
    --    used directly, no header-total apportionment needed, see this
    --    migration's header comment for why).
    FOR v_line IN
        SELECT * FROM rid_sales_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT base_qty INTO v_invoice_line_qty
        FROM rid_sales_invoice_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND serial_no = v_line.invoice_line_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'INVOICE_LINE_NOT_FOUND'
                USING DETAIL = format('Invoice %s has no line %s.', v_header.invoice_no, v_line.invoice_line_serial);
        END IF;

        -- Cumulative cap: every OTHER already-APPROVED Sales Return
        -- against this same invoice line (this return itself is still
        -- DRAFT during this check, naturally excluded) — a line can be
        -- partially returned across several separate Sales Return
        -- documents over time.
        SELECT coalesce(sum(rl.base_qty), 0) INTO v_already_returned
        FROM rid_sales_return_lines rl
        JOIN rih_sales_return_headers rh
          ON rh.client_id = rl.client_id AND rh.company_id = rl.company_id
         AND rh.return_no = rl.return_no AND rh.return_date = rl.return_date
        WHERE rl.client_id = p_client_id AND rl.company_id = p_company_id
          AND rh.invoice_no = v_header.invoice_no AND rh.invoice_date = v_header.invoice_date
          AND rl.invoice_line_serial = v_line.invoice_line_serial
          AND rl.is_deleted = false AND rh.status = 'APPROVED';

        IF v_already_returned + v_line.base_qty > v_invoice_line_qty THEN
            RAISE EXCEPTION 'RETURN_QTY_EXCEEDS_INVOICED'
                USING DETAIL = format(
                    'Invoice %s line %s: already returned %s of %s invoiced, this return adds %s more.',
                    v_header.invoice_no, v_line.invoice_line_serial,
                    v_already_returned, v_invoice_line_qty, v_line.base_qty);
        END IF;

        v_returns_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'SALES_RETURNS_ACCOUNT');
        IF v_returns_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Sales Returns Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_returns_account, 'trans_nature', 'DR',
            'trans_amount', v_line.final_amount - v_line.tax_amount, 'trans_currency', v_return_ccy,
            'base_amount', (v_line.final_amount - v_line.tax_amount) * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', (v_line.final_amount - v_line.tax_amount) * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_line.final_amount - v_line.tax_amount, 'party_currency', v_return_ccy, 'party_rate', 1,
            'source_line_type', 'SALES_RETURN', 'source_line_no', v_line.serial_no
        ));
        v_customer_cr_total := v_customer_cr_total + v_line.final_amount;

        IF v_line.tax_amount > 0 THEN
            IF v_line.tax_group_id IS NULL THEN
                RAISE EXCEPTION 'LINE_TAX_GROUP_MISSING'
                    USING DETAIL = format('Line %s: has a tax amount but no tax group.', v_line.serial_no);
            END IF;

            FOR v_tax_line IN
                SELECT t.gl_output_account_id AS tax_account,
                       v_line.tax_amount * (coalesce(r.tax_rate, 0) / NULLIF(sum(coalesce(r.tax_rate, 0)) OVER (), 0)) AS tax_portion
                FROM rim_tax_group_members gm
                JOIN rim_taxes t ON t.id = gm.tax_id
                JOIN LATERAL (SELECT fn_get_active_tax_rate(gm.tax_id, p_return_date) AS tax_rate) r ON true
                WHERE gm.tax_group_id = v_line.tax_group_id
            LOOP
                IF v_tax_line.tax_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('Line %s: a tax in its tax group has no Output GL account configured.', v_line.serial_no);
                END IF;

                v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_tax_line.tax_account, 'trans_nature', 'DR',
                    'trans_amount', v_tax_line.tax_portion, 'trans_currency', v_return_ccy,
                    'base_amount', v_tax_line.tax_portion * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_tax_line.tax_portion * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_tax_line.tax_portion, 'party_currency', v_return_ccy, 'party_rate', 1,
                    'source_line_type', 'SALES_RETURN_TAX', 'source_line_no', v_line.serial_no
                ));
            END LOOP;
        END IF;
    END LOOP;

    -- 5. Charges — reversed direction from the invoice's own posting
    --    (ADD reversed -> DR, DEDUCT reversed -> CR), straight to the
    --    charge's own gl_account_id, trusted as stored (same idiom
    --    fn_approve_sales_invoice uses for its own charge tax_amount).
    FOR v_charge_row IN
        SELECT * FROM rid_sales_return_charges
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        IF v_charge_row.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge_row.charge_name);
        END IF;

        v_charge_amount := v_charge_row.amount;
        v_charge_dir := CASE WHEN v_charge_row.nature = 'DEDUCT' THEN 'CR' ELSE 'DR' END;

        v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_charge_row.gl_account_id, 'trans_nature', v_charge_dir,
            'trans_amount', v_charge_amount, 'trans_currency', v_return_ccy,
            'base_amount', v_charge_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_charge_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_charge_amount, 'party_currency', v_return_ccy, 'party_rate', 1,
            'source_line_type', 'SALES_RETURN_CHARGE', 'source_line_no', v_charge_row.serial_no
        ));
        v_customer_cr_total := v_customer_cr_total + (CASE WHEN v_charge_row.nature = 'DEDUCT' THEN -1 ELSE 1 END) * v_charge_amount;

        IF v_charge_row.is_taxable AND coalesce(v_charge_row.tax_amount, 0) > 0 THEN
            IF v_charge_row.tax_id IS NULL THEN
                RAISE EXCEPTION 'LINE_TAX_GROUP_MISSING'
                    USING DETAIL = format('Charge %s has a tax amount but no tax configured.', v_charge_row.charge_name);
            END IF;
            SELECT gl_output_account_id INTO v_charge_tax_account FROM rim_taxes WHERE id = v_charge_row.tax_id;
            IF v_charge_tax_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('Charge %s: its tax has no Output GL account configured.', v_charge_row.charge_name);
            END IF;

            v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge_tax_account, 'trans_nature', v_charge_dir,
                'trans_amount', v_charge_row.tax_amount, 'trans_currency', v_return_ccy,
                'base_amount', v_charge_row.tax_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                'local_amount', v_charge_row.tax_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                'party_amount', v_charge_row.tax_amount, 'party_currency', v_return_ccy, 'party_rate', 1,
                'source_line_type', 'SALES_RETURN_CHARGE_TAX', 'source_line_no', v_charge_row.serial_no
            ));
            v_customer_cr_total := v_customer_cr_total + (CASE WHEN v_charge_row.nature = 'DEDUCT' THEN -1 ELSE 1 END) * v_charge_row.tax_amount;
        END IF;
    END LOOP;

    -- 6. Customer CR — one aggregate line, self-tagged inv_bill_no
    --    (corrected below once the real trans_no is known) so the refund
    --    below (or any future manual settlement) can settle directly
    --    against this bill via the existing Against-Bill mechanism.
    v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_header.customer_id, 'trans_nature', 'CR',
        'trans_amount', v_customer_cr_total, 'trans_currency', v_return_ccy,
        'base_amount', v_customer_cr_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_customer_cr_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_customer_cr_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', p_return_no, 'inv_bill_date', p_return_date,
        'source_line_type', 'CUSTOMER', 'source_line_no', 0
    ));

    SELECT * INTO v_crn_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'CRN', p_return_date,
        v_crn_lines, 'SALES_RETURN', p_return_no, p_return_date, p_approved_by
    );

    UPDATE rid_finance_lines SET
        inv_bill_no   = v_crn_result.trans_no,
        inv_bill_date = v_crn_result.trans_date
    WHERE client_id       = p_client_id
      AND company_id      = p_company_id
      AND location_id     = v_header.location_id
      AND trans_no        = v_crn_result.trans_no
      AND trans_date      = v_crn_result.trans_date
      AND source_line_type = 'CUSTOMER' AND source_line_no = 0;

    -- 7. Stock + Cost of Sales reversal — only if the source invoice
    --    actually dispatched stock. Unit cost is the ORIGINAL invoice's
    --    own historical per-unit COGS, read back from its already-posted
    --    COS voucher — never a fresh current-average lookup, to keep this
    --    reversal symmetric with what the invoice itself posted.
    IF v_invoice.stock_dispatch_mode = 'IMMEDIATE' THEN
        v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_return_date);

        FOR v_line IN
            SELECT * FROM rid_sales_return_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
            ORDER BY product_id
        LOOP
            v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
            v_cos_account   := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'COST_OF_SALES_ACCOUNT');
            IF v_stock_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Stock Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;
            IF v_cos_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Cost of Sales Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;

            -- Historical unit cost: original invoice line's own posted
            -- COS voucher STOCK line (base_amount) divided by that line's
            -- own original base_qty. source_doc_type/no/date live on
            -- rih_finance_headers (migration 037), NOT on rid_finance_lines
            -- itself (which only carries source_line_type/source_line_no,
            -- migration 050) — a join is required, not a direct filter.
            SELECT fl.base_amount INTO v_orig_line_cost
            FROM rid_finance_lines fl
            JOIN rih_finance_headers fh
              ON fh.client_id = fl.client_id AND fh.company_id = fl.company_id
             AND fh.location_id = fl.location_id AND fh.trans_no = fl.trans_no AND fh.trans_date = fl.trans_date
            WHERE fl.client_id = p_client_id AND fl.company_id = p_company_id
              AND fh.source_doc_type = 'SALES_INVOICE' AND fh.source_doc_no = v_header.invoice_no AND fh.source_doc_date = v_header.invoice_date
              AND fl.source_line_type = 'STOCK' AND fl.source_line_no = v_line.invoice_line_serial;

            SELECT base_qty INTO v_orig_line_base_qty
            FROM rid_sales_invoice_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
              AND serial_no = v_line.invoice_line_serial;

            IF v_orig_line_cost IS NULL OR coalesce(v_orig_line_base_qty, 0) = 0 THEN
                RAISE EXCEPTION 'ORIGINAL_COST_NOT_FOUND'
                    USING DETAIL = format('Line %s: could not find the original invoice line''s posted cost to reverse against.', v_line.serial_no);
            END IF;
            v_unit_cost := v_orig_line_cost / v_orig_line_base_qty;

            -- p_unit_cost_specific has no historical equivalent to read
            -- back (the invoice's own OUTWARD movement never needed a cost
            -- at all, let alone a specific-currency one) — it only feeds
            -- rim_product_location's own specific-currency weighted
            -- average (a secondary reporting field, never part of the GL
            -- amounts above, which use v_unit_cost/v_line_cost_total
            -- exclusively), so the CURRENT average is an acceptable
            -- approximation here, unlike the base cost which must be
            -- historical for Stock-DR/COGS-CR symmetry.
            SELECT cost_price_specific INTO v_unit_cost_specific
            FROM rim_product_location
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND location_id = v_header.location_id AND product_id = v_line.product_id
            FOR UPDATE;
            v_unit_cost_specific := coalesce(v_unit_cost_specific, v_unit_cost);

            v_has_batches := EXISTS (
                SELECT 1 FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                  AND line_serial = v_line.serial_no
            );
            v_has_serials := EXISTS (
                SELECT 1 FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                  AND line_serial = v_line.serial_no
            );

            v_line_cost_total := 0;

            IF v_has_batches THEN
                FOR v_batch IN
                    SELECT * FROM rid_transaction_line_batches
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_return_date, 'SALES_RETURN', v_batch.base_qty,
                        v_unit_cost, v_unit_cost_specific, v_batch.batch_no, v_batch.expiry_date, NULL,
                        'SALES_RETURN', p_return_no, p_return_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_batch.base_qty * v_unit_cost;
                END LOOP;
            ELSIF v_has_serials THEN
                FOR v_serial_row IN
                    SELECT * FROM rid_transaction_line_serials
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_return_date, 'SALES_RETURN', 1,
                        v_unit_cost, v_unit_cost_specific, NULL, NULL, v_serial_row.serial_no,
                        'SALES_RETURN', p_return_no, p_return_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_unit_cost;
                END LOOP;
            ELSE
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_return_date, 'SALES_RETURN', v_line.base_qty,
                    v_unit_cost, v_unit_cost_specific, NULL, NULL, NULL,
                    'SALES_RETURN', p_return_no, p_return_date, p_approved_by
                );
                v_line_cost_total := v_line.base_qty * v_unit_cost;
            END IF;

            -- Reverse of the invoice's own DR COGS / CR Stock: here
            -- DR Stock / CR COGS. Base currency throughout, party
            -- self-referential (same convention as every other purely-
            -- internal voucher, e.g. Material Issue's MIC lines).
            v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'DR',
                'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
                'base_amount', v_line_cost_total, 'base_rate', 1,
                'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK', 'source_line_no', v_line.serial_no
            ));
            v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_cos_account, 'trans_nature', 'CR',
                'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
                'base_amount', v_line_cost_total, 'base_rate', 1,
                'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'COGS', 'source_line_no', v_line.serial_no
            ));
        END LOOP;

        SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'COS', p_return_date,
            v_cos_lines, 'SALES_RETURN', p_return_no, p_return_date, p_approved_by
        );
    END IF;

    -- 8. Cash refund — only when the source invoice was CASH and actually
    --    collected. Capped cumulative per invoice, per currency leg,
    --    against what that invoice actually collected minus what prior
    --    approved Sales Returns against it already refunded. A confirmed
    --    header amount exceeding the remaining pool is a hard error, never
    --    a silent clamp.
    IF v_invoice.sale_type = 'CASH' AND v_invoice.cash_collection_mode = 'IMMEDIATE' THEN
        SELECT coalesce(sum(refund_amount_local), 0), coalesce(sum(refund_amount_base), 0)
        INTO v_already_refunded_local, v_already_refunded_base
        FROM rih_sales_return_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND is_deleted = false AND status = 'APPROVED';

        v_remaining_local := coalesce(v_invoice.collected_amount_local, 0) - v_already_refunded_local;
        v_remaining_base  := coalesce(v_invoice.collected_amount_base, 0)  - v_already_refunded_base;

        IF v_header.refund_amount_local > v_remaining_local + 0.0001 OR v_header.refund_amount_base > v_remaining_base + 0.0001 THEN
            RAISE EXCEPTION 'REFUND_EXCEEDS_COLLECTED'
                USING DETAIL = format(
                    'Requested refund (local %s, base %s) exceeds what remains collected on invoice %s (local %s, base %s remaining).',
                    v_header.refund_amount_local, v_header.refund_amount_base, v_header.invoice_no, v_remaining_local, v_remaining_base);
        END IF;

        IF v_header.refund_amount_local > 0 THEN
            v_cash_account_local := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
            IF v_cash_account_local IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user processing this return has no Quick Invoice Setup (Local Cash Account) — cannot refund cash.';
            END IF;

            IF v_customer_ccy IS NULL OR v_customer_ccy = v_local_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_local_ccy;
            ELSIF v_customer_ccy = v_base_ccy THEN
                v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_return_date));
                v_receipt_party_rate := v_local_to_base_rate; v_receipt_party_ccy := v_base_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_customer_ccy, p_return_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_return_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_return_date,
                'voucher_type_code', 'CPV', 'is_on_account', false,
                'remarks', format('Refund against Sales Return %s', p_return_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_header.customer_id,
                    'trans_nature', 'DR', 'trans_amount', v_header.refund_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.refund_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.refund_amount_local, 'local_rate', 1,
                    'party_amount', v_header.refund_amount_local * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_crn_result.trans_no, 'inv_bill_date', v_crn_result.trans_date
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_cash_account_local,
                    'trans_nature', 'CR', 'trans_amount', v_header.refund_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.refund_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.refund_amount_local, 'local_rate', 1,
                    'party_amount', v_header.refund_amount_local, 'party_currency', v_local_ccy, 'party_rate', 1
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_return_date, p_approved_by);
            UPDATE rih_sales_return_headers SET refund_voucher_no_local = v_receipt_no, refund_voucher_date_local = p_return_date WHERE id = v_header.id;
        END IF;

        IF v_header.refund_amount_base > 0 THEN
            v_cash_account_base := fn_quick_cash_account_base(p_client_id, p_company_id, v_header.created_by);
            IF v_cash_account_base IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user processing this return has no Quick Invoice Setup (Base Cash Account) — cannot refund cash.';
            END IF;

            IF v_customer_ccy IS NULL OR v_customer_ccy = v_base_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_base_ccy;
            ELSIF v_customer_ccy = v_local_ccy THEN
                v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_return_date));
                v_receipt_party_rate := v_base_to_local_rate; v_receipt_party_ccy := v_local_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_customer_ccy, p_return_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_return_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_return_date,
                'voucher_type_code', 'CPV', 'is_on_account', false,
                'remarks', format('Refund against Sales Return %s', p_return_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_header.customer_id,
                    'trans_nature', 'DR', 'trans_amount', v_header.refund_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.refund_amount_base, 'base_rate', 1,
                    'local_amount', v_header.refund_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.refund_amount_base * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_crn_result.trans_no, 'inv_bill_date', v_crn_result.trans_date
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_cash_account_base,
                    'trans_nature', 'CR', 'trans_amount', v_header.refund_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.refund_amount_base, 'base_rate', 1,
                    'local_amount', v_header.refund_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.refund_amount_base, 'party_currency', v_base_ccy, 'party_rate', 1
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_return_date, p_approved_by);
            UPDATE rih_sales_return_headers SET refund_voucher_no_base = v_receipt_no, refund_voucher_date_base = p_return_date WHERE id = v_header.id;
        END IF;
    END IF;

    -- 9. Mark the return approved.
    UPDATE rih_sales_return_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        credit_note_voucher_no   = v_crn_result.trans_no,
        credit_note_voucher_date = v_crn_result.trans_date,
        cos_voucher_no   = v_cos_voucher_no,
        cos_voucher_date = v_cos_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_return(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
