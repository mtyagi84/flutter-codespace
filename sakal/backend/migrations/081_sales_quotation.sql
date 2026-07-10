-- ============================================================
-- Migration 081: Sales Quotation — first screen of the Sales module
-- ============================================================
-- Pure pre-commitment offer document — mirrors Purchase Order's role on
-- the sales side. NO stock reservation, NO GL posting, ever, at any
-- status. Real financial/stock effect only happens downstream once a
-- (not-yet-built) Sales Order and/or Sales Invoice consumes this
-- quotation's lines. See docs/screens/sales_quotation.md for the full
-- requirement document this migration implements.
--
-- Design decisions (see requirement doc for the "why"):
--   • quotation_no + quotation_date are the document identity (numbering
--     resets per period, same lesson as every other document here).
--   • LOCATION-SCOPED numbering (unlike PO, which is company-wide) —
--     reuses the existing fn_next_trans_no/ril_trans_no_seq machinery.
--     location_id lives on the header as a plain column (an input to
--     fn_next_trans_no's per-location sequence) but is deliberately NOT
--     part of the header's own composite identity — same shape as
--     rih_grn_headers/rih_material_requisition_headers, which key only on
--     (doc_no, doc_date) with no location_id on their line tables either.
--     Only Finance Vouchers (the earliest-built, heavier-weight module)
--     actually includes location_id in its composite key — that is NOT
--     the pattern to generalize from.
--   • Formal Approve step required (canApprove-gated) before Send/Print
--     — unlike some other pre-commitment documents, this module's own
--     decision.
--   • converted_qty on each line is a running total (mirrors PO's
--     qty_received) so ONE quotation can be partially converted into
--     multiple future Sales Orders/Invoices over time — not a
--     whole-document-only linkage.
--   • Deliberately NO fn_check_period_open/fn_check_backdate_allowed at
--     Approve — those protect the books, and this document never posts
--     to the books. Intentional deviation from the usual rule, not an
--     oversight.
--   • Charges reuse the existing shared rim_additional_charges master
--     (applicable_on IN ('SALES','BOTH')) — same master Purchase Order
--     already uses. Apportioned across lines by value (allocation_factor,
--     same formula as PO's landed cost) so each line carries a
--     charge_amount/landed_amount — but unlike PO this has NO costing
--     purpose (never touches inventory valuation), it exists purely so
--     the customer sees an all-inclusive per-item price.
--   • Prospect support: customer_type (CUSTOMER/PROSPECT) + nullable
--     customer_id + always-populated party_name/phone/email/address
--     snapshot columns — lets a quotation go out to someone with no
--     rim_accounts ledger yet. See the column comments on
--     rih_sales_quotations for the full reasoning.
-- ============================================================


-- ------------------------------------------------------------
-- rim_voucher_types — widen voucher_nature to allow SALES, seed 'SQ'.
-- Numbering is location-scoped, consumed by the existing fn_next_trans_no
-- (NOT fn_next_company_doc_no, which is PO's own company-wide scheme).
-- ------------------------------------------------------------
ALTER TABLE rim_voucher_types
    DROP CONSTRAINT IF EXISTS rim_voucher_types_nature_check;

ALTER TABLE rim_voucher_types
    ADD CONSTRAINT rim_voucher_types_nature_check
        CHECK (voucher_nature IN ('RECEIPT','PAYMENT','JOURNAL','DEBIT_NOTE','CREDIT_NOTE','STOCK','PURCHASE','SALES'));

INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('SQ', 'Sales Quotation', 'SALES', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- rih_sales_quotations
-- Unique key includes location_id — quotations are per-location, unlike
-- PO's company-wide identity.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rih_sales_quotations (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    location_id           UUID          NOT NULL REFERENCES ric_locations(id),
    quotation_no          TEXT          NOT NULL,
    quotation_date        DATE          NOT NULL,
    valid_until_date       DATE         NOT NULL,
    -- CUSTOMER = customer_id points at a real rim_accounts ledger row.
    -- PROSPECT = customer_id is NULL — quoting someone with no ledger yet
    -- (pre-sales). party_name/phone/email/address are ALWAYS populated
    -- regardless of type: for CUSTOMER they're an editable snapshot
    -- auto-filled from the account at selection time (same "default from
    -- master, editable per-document" pattern as PO's bill_to/ship_to); for
    -- PROSPECT they're typed directly. Printing and every future report
    -- reads these snapshot columns only — never needs to branch on type.
    -- A prospect only gets a real rim_accounts row at the point real
    -- business happens (future Sales Order/Invoice conversion forces it) —
    -- never at quoting time, so the accounting master never fills up with
    -- speculative/unconverted entities.
    customer_type          TEXT         NOT NULL DEFAULT 'CUSTOMER'
                           CHECK (customer_type IN ('CUSTOMER','PROSPECT')),
    customer_id            UUID         REFERENCES rim_accounts(id),
    party_name             TEXT         NOT NULL,
    party_phone            TEXT,
    party_email            TEXT,
    party_address          TEXT,
    sales_person_id          UUID       REFERENCES rim_users(id),
    quotation_currency_id     UUID      NOT NULL REFERENCES rim_currencies(id),
    rate_to_base               NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local                NUMERIC(18,8) NOT NULL DEFAULT 1,
    payment_terms                  TEXT,
    delivery_terms                   TEXT,
    -- Denormalized rollups for fast list-screen display — same rationale
    -- as rih_purchase_orders.
    gross_amount                       NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_amount                      NUMERIC(18,4) NOT NULL DEFAULT 0,
    charges_amount                         NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    grand_total                                NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- PARTIALLY_CONVERTED/CONVERTED are pre-declared now (nullable-cost
    -- placeholder, same convention as PO's indent_no/rfq_no/quotation_no)
    -- so the future Sales Order/Invoice conversion feature needs no new
    -- CHECK-constraint migration. EXPIRED is a computed display state in
    -- the UI (today > valid_until_date), never written to this column.
    status                                       TEXT NOT NULL DEFAULT 'DRAFT'
                         CHECK (status IN ('DRAFT','APPROVED','SENT','ACCEPTED','REJECTED','PARTIALLY_CONVERTED','CONVERTED')),
    approved_by            UUID          REFERENCES rim_users(id),
    approved_at            TIMESTAMPTZ,
    remarks                TEXT,
    is_active              BOOLEAN       NOT NULL DEFAULT true,
    is_deleted              BOOLEAN      NOT NULL DEFAULT false,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                UUID       REFERENCES rim_users(id),
    updated_at                  TIMESTAMPTZ,
    updated_by                   UUID    REFERENCES rim_users(id),
    CONSTRAINT uq_rih_sales_quotations UNIQUE (client_id, company_id, quotation_no, quotation_date),
    CONSTRAINT chk_sales_quotation_validity CHECK (valid_until_date >= quotation_date),
    CONSTRAINT chk_sales_quotation_customer_type CHECK (
        (customer_type = 'CUSTOMER' AND customer_id IS NOT NULL) OR
        (customer_type = 'PROSPECT' AND customer_id IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_rih_sq_tenant    ON rih_sales_quotations (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rih_sq_customer  ON rih_sales_quotations (customer_id);
CREATE INDEX IF NOT EXISTS idx_rih_sq_status    ON rih_sales_quotations (client_id, company_id, status);
CREATE INDEX IF NOT EXISTS idx_rih_sq_date      ON rih_sales_quotations (client_id, company_id, quotation_date DESC);

DROP TRIGGER IF EXISTS trg_rih_sales_quotations_updated_at ON rih_sales_quotations;
CREATE TRIGGER trg_rih_sales_quotations_updated_at
    BEFORE UPDATE ON rih_sales_quotations
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_sales_quotations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sales_quotations" ON rih_sales_quotations;
CREATE POLICY "auth_rw_sales_quotations" ON rih_sales_quotations
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_sales_quotations FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_sales_quotations TO authenticated;


-- ------------------------------------------------------------
-- rid_sales_quotation_lines
-- No location_id here — location_id lives only on the header as a plain
-- column (which location this quotation is FROM, and an input to
-- fn_next_trans_no's per-location sequence), it is deliberately NOT part
-- of the header's own composite identity. Same shape as GRN/Material
-- Requisition (rih_grn_headers/rih_material_requisition_headers both key
-- only on (doc_no, doc_date), and their line tables carry no location_id
-- at all) — NOT Finance Vouchers, whose older/heavier composite key does
-- include location_id. A line item is never itself "at a location" the
-- way a stock-ledger row is; it belongs to a document, and the document's
-- identity is just (quotation_no, quotation_date).
-- No batch/serial columns — a quotation has no stock allocation, so
-- there is nothing yet to attach a batch/serial to (deferred entirely
-- to Sales Order/Invoice, same as PO having no batch/serial entry).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rid_sales_quotation_lines (
    id                       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                UUID          NOT NULL REFERENCES ric_clients(id),
    company_id               UUID          NOT NULL REFERENCES ric_companies(id),
    quotation_no             TEXT          NOT NULL,
    quotation_date            DATE         NOT NULL,
    serial_no                 INTEGER      NOT NULL,
    product_id                UUID         NOT NULL REFERENCES rim_products(id),
    item_description           TEXT,
    -- What was actually scanned to select this line — audit only,
    -- rim_product_uom.barcode remains the source of truth
    barcode                     TEXT,
    uom_id                       UUID       NOT NULL REFERENCES rim_common_masters(id),
    -- Snapshotted at line-entry time, same rationale as PO's own line
    uom_conversion_factor         NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack                       NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose                       NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty                         NUMERIC(18,4) NOT NULL DEFAULT 0,
    rate                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    gross_amount                        NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_percent                     NUMERIC(6,2)  NOT NULL DEFAULT 0,
    discount_amount                       NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_group_id                           UUID          REFERENCES rim_tax_groups(id),
    tax_amount                              NUMERIC(18,4) NOT NULL DEFAULT 0,
    final_amount                             NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_amount                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    local_amount                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- This line's apportioned share of rid_sales_quotation_charges,
    -- computed the same way as rid_purchase_order_lines.charge_amount:
    -- sum(charge.allocation_factor * this line's taxable amount) across
    -- all quotation charges. Unlike PO this has no costing purpose — it
    -- exists purely so the customer can see an all-inclusive per-item
    -- price (unit price + their share of delivery/freight).
    charge_amount                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- final_amount + charge_amount — the all-inclusive price shown to the
    -- customer for this line.
    landed_amount                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- Running total consumed by a future Sales Order/Invoice conversion —
    -- mirrors rid_purchase_order_lines.qty_received exactly, enabling
    -- partial conversion of a single quotation over multiple documents.
    converted_qty                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    remarks                                     TEXT,
    is_deleted                                   BOOLEAN      NOT NULL DEFAULT false,
    created_at                                    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by                                     UUID        REFERENCES rim_users(id),
    updated_at                                      TIMESTAMPTZ,
    updated_by                                       UUID       REFERENCES rim_users(id),
    CONSTRAINT uq_rid_sq_lines UNIQUE (client_id, company_id, quotation_no, quotation_date, serial_no),
    CONSTRAINT rid_sq_lines_header_fk
        FOREIGN KEY (client_id, company_id, quotation_no, quotation_date)
        REFERENCES  rih_sales_quotations (client_id, company_id, quotation_no, quotation_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_sq_lines_header  ON rid_sales_quotation_lines (client_id, company_id, quotation_no, quotation_date);
CREATE INDEX IF NOT EXISTS idx_rid_sq_lines_product ON rid_sales_quotation_lines (product_id);

ALTER TABLE rid_sales_quotation_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sq_lines" ON rid_sales_quotation_lines;
CREATE POLICY "auth_rw_sq_lines" ON rid_sales_quotation_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_quotation_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_quotation_lines TO authenticated;


-- ------------------------------------------------------------
-- rid_sales_quotation_charges
-- is_taxable/tax_id/nature/gl_account_id/amount_or_percent frozen from
-- rim_additional_charges at entry time — type is locked, only
-- percent/amount are editable per transaction (same rule as PO charges).
-- gl_account_id is carried forward (not used by this module — never
-- posts GL) purely so a future Sales Invoice conversion doesn't need a
-- fresh master lookup to know which account this charge should credit.
-- allocation_factor = amount / (quotation value before charges) — computed
-- by the application, stored here so rid_sales_quotation_lines.charge_amount
-- doesn't need to be recomputed later, same pattern as rid_po_charge_lines.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rid_sales_quotation_charges (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    quotation_no          TEXT          NOT NULL,
    quotation_date         DATE         NOT NULL,
    serial_no               INTEGER     NOT NULL,
    charge_id                UUID        NOT NULL REFERENCES rim_additional_charges(id),
    charge_name                TEXT      NOT NULL,
    is_taxable                  BOOLEAN  NOT NULL DEFAULT false,
    tax_id                       UUID     REFERENCES rim_taxes(id),
    nature                        TEXT    NOT NULL DEFAULT 'ADD'
                             CHECK (nature IN ('ADD','DEDUCT')),
    gl_account_id                  UUID   REFERENCES rim_accounts(id),
    amount_or_percent               TEXT  NOT NULL DEFAULT 'AMOUNT'
                             CHECK (amount_or_percent IN ('AMOUNT','PERCENT')),
    percent                          NUMERIC(6,2),
    amount                            NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount                         NUMERIC(18,4) NOT NULL DEFAULT 0,
    allocation_factor                   NUMERIC(18,8),
    is_deleted                          BOOLEAN     NOT NULL DEFAULT false,
    created_at                           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                            UUID       REFERENCES rim_users(id),
    updated_at                             TIMESTAMPTZ,
    updated_by                              UUID      REFERENCES rim_users(id),
    CONSTRAINT uq_rid_sq_charge_lines UNIQUE (client_id, company_id, quotation_no, quotation_date, serial_no),
    CONSTRAINT rid_sq_charge_lines_header_fk
        FOREIGN KEY (client_id, company_id, quotation_no, quotation_date)
        REFERENCES  rih_sales_quotations (client_id, company_id, quotation_no, quotation_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_sq_charges_header ON rid_sales_quotation_charges (client_id, company_id, quotation_no, quotation_date);

ALTER TABLE rid_sales_quotation_charges ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sq_charge_lines" ON rid_sales_quotation_charges;
CREATE POLICY "auth_rw_sq_charge_lines" ON rid_sales_quotation_charges
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_quotation_charges FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_quotation_charges TO authenticated;


-- ============================================================
-- PG FUNCTIONS
-- ============================================================


-- ------------------------------------------------------------
-- fn_save_sales_quotation — DRAFT-only save.
-- Generates quotation_no on first save via the existing location-scoped
-- fn_next_trans_no (voucher type 'SQ'). Lines/charges are deleted and
-- re-inserted on every save — no audit value for unposted draft
-- revisions, same convention as every other draft-save function here.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_save_sales_quotation(
    p_header  JSONB,
    p_lines   JSONB,
    p_charges JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id        UUID;
    v_company_id       UUID;
    v_location_id      UUID;
    v_quotation_no     TEXT;
    v_quotation_date   DATE;
    v_old_quotation_date DATE;
    v_old_status       TEXT;
    v_is_new           BOOLEAN;
    v_line             JSONB;
    v_charge           JSONB;
BEGIN
    v_client_id      := (p_header->>'client_id')::uuid;
    v_company_id     := (p_header->>'company_id')::uuid;
    v_location_id    := (p_header->>'location_id')::uuid;
    v_quotation_no   := nullif(trim(p_header->>'quotation_no'), '');
    v_quotation_date := (p_header->>'quotation_date')::date;
    v_is_new         := v_quotation_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Quotation.';
    END IF;

    IF coalesce(p_header->>'customer_type', 'CUSTOMER') = 'CUSTOMER' AND nullif(p_header->>'customer_id', '') IS NULL THEN
        RAISE EXCEPTION 'Select a customer, or switch to Prospect and enter their details.';
    END IF;
    IF coalesce(p_header->>'customer_type', 'CUSTOMER') = 'PROSPECT' AND nullif(trim(p_header->>'party_name'), '') IS NULL THEN
        RAISE EXCEPTION 'Enter the prospect''s name.';
    END IF;

    IF v_is_new THEN
        v_quotation_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'SQ');
    ELSE
        SELECT quotation_date, status INTO v_old_quotation_date, v_old_status
        FROM   rih_sales_quotations
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  quotation_no = v_quotation_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Sales Quotation % not found', v_quotation_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Sales Quotation % is % and cannot be edited.', v_quotation_no, v_old_status;
        END IF;

        DELETE FROM rid_sales_quotation_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND quotation_no = v_quotation_no AND quotation_date = v_old_quotation_date;

        DELETE FROM rid_sales_quotation_charges
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND quotation_no = v_quotation_no AND quotation_date = v_old_quotation_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_sales_quotations (
            client_id, company_id, location_id, quotation_no, quotation_date, valid_until_date,
            customer_type, customer_id, party_name, party_phone, party_email, party_address,
            sales_person_id, quotation_currency_id, rate_to_base, rate_to_local,
            payment_terms, delivery_terms,
            gross_amount, discount_amount, charges_amount, tax_amount, grand_total,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_quotation_no, v_quotation_date,
            (p_header->>'valid_until_date')::date,
            coalesce(p_header->>'customer_type', 'CUSTOMER'),
            (nullif(p_header->>'customer_id', ''))::uuid,
            trim(p_header->>'party_name'),
            nullif(p_header->>'party_phone', ''), nullif(p_header->>'party_email', ''), nullif(p_header->>'party_address', ''),
            (nullif(p_header->>'sales_person_id', ''))::uuid,
            (p_header->>'quotation_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            nullif(p_header->>'payment_terms', ''), nullif(p_header->>'delivery_terms', ''),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_sales_quotations SET
            location_id            = v_location_id,
            quotation_date         = v_quotation_date,
            valid_until_date       = (p_header->>'valid_until_date')::date,
            customer_type          = coalesce(p_header->>'customer_type', 'CUSTOMER'),
            customer_id            = (nullif(p_header->>'customer_id', ''))::uuid,
            party_name             = trim(p_header->>'party_name'),
            party_phone            = nullif(p_header->>'party_phone', ''),
            party_email            = nullif(p_header->>'party_email', ''),
            party_address          = nullif(p_header->>'party_address', ''),
            sales_person_id        = (nullif(p_header->>'sales_person_id', ''))::uuid,
            quotation_currency_id  = (p_header->>'quotation_currency_id')::uuid,
            rate_to_base           = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local          = coalesce((p_header->>'rate_to_local')::numeric, 1),
            payment_terms          = nullif(p_header->>'payment_terms', ''),
            delivery_terms         = nullif(p_header->>'delivery_terms', ''),
            gross_amount            = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount          = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount            = coalesce((p_header->>'charges_amount')::numeric, 0),
            tax_amount                 = coalesce((p_header->>'tax_amount')::numeric, 0),
            grand_total                  = coalesce((p_header->>'grand_total')::numeric, 0),
            remarks                        = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND quotation_no = v_quotation_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_sales_quotation_lines (
            client_id, company_id, quotation_no, quotation_date, serial_no,
            product_id, item_description, barcode, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, gross_amount,
            discount_percent, discount_amount, tax_group_id, tax_amount,
            final_amount, base_amount, local_amount, charge_amount, landed_amount, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_quotation_no, v_quotation_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'item_description', ''),
            nullif(v_line->>'barcode', ''),
            (v_line->>'uom_id')::uuid,
            coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0),
            coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            coalesce((v_line->>'rate')::numeric, 0),
            coalesce((v_line->>'gross_amount')::numeric, 0),
            coalesce((v_line->>'discount_percent')::numeric, 0),
            coalesce((v_line->>'discount_amount')::numeric, 0),
            (nullif(v_line->>'tax_group_id', ''))::uuid,
            coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            coalesce((v_line->>'base_amount')::numeric, 0),
            coalesce((v_line->>'local_amount')::numeric, 0),
            coalesce((v_line->>'charge_amount')::numeric, 0),
            coalesce((v_line->>'landed_amount')::numeric, 0),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_sales_quotation_charges (
            client_id, company_id, quotation_no, quotation_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount_or_percent, percent, amount, tax_amount, allocation_factor,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_quotation_no, v_quotation_date,
            (v_charge->>'serial_no')::integer,
            (v_charge->>'charge_id')::uuid,
            v_charge->>'charge_name',
            coalesce((v_charge->>'is_taxable')::boolean, false),
            (nullif(v_charge->>'tax_id', ''))::uuid,
            coalesce(v_charge->>'nature', 'ADD'),
            (nullif(v_charge->>'gl_account_id', ''))::uuid,
            coalesce(v_charge->>'amount_or_percent', 'AMOUNT'),
            (v_charge->>'percent')::numeric,
            coalesce((v_charge->>'amount')::numeric, 0),
            coalesce((v_charge->>'tax_amount')::numeric, 0),
            (v_charge->>'allocation_factor')::numeric,
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_quotation_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_sales_quotation(JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_approve_sales_quotation
-- Completeness validation only — NO period/backdate checks (this
-- document never posts to the books, see header comment above) and NO
-- GL/stock effect of any kind. Locks the quotation from further line
-- edits, same as every other Approve in this schema.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_approve_sales_quotation(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_approved_by    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_sales_quotations%ROWTYPE;
    v_line   RECORD;
BEGIN
    SELECT * INTO v_header FROM rih_sales_quotations
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Quotation % dated % not found', p_quotation_no, p_quotation_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Quotation % is % and cannot be approved again', p_quotation_no, v_header.status;
    END IF;

    FOR v_line IN
        SELECT * FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date AND is_deleted = false
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;
        IF v_line.rate < 0 THEN
            RAISE EXCEPTION 'LINE_RATE_INVALID'
                USING DETAIL = format('Line %s: rate cannot be negative.', v_line.serial_no);
        END IF;
    END LOOP;

    UPDATE rih_sales_quotations SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_quotation(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_update_sales_quotation_status
-- Single generic function for the Send/Accept/Reject transitions
-- instead of three near-identical functions — validates the transition
-- server-side so a stale client can't illegally jump the state machine,
-- while avoiding boilerplate duplication. Not used for DRAFT→APPROVED
-- (that path needs the line-completeness checks in fn_approve_sales_
-- quotation above) or for CONVERTED/PARTIALLY_CONVERTED (owned by the
-- future Sales Order/Invoice conversion feature, not built here).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_update_sales_quotation_status(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_new_status     TEXT,
    p_user_id        UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_status TEXT;
    v_allowed        BOOLEAN := false;
BEGIN
    SELECT status INTO v_current_status FROM rih_sales_quotations
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Quotation % dated % not found', p_quotation_no, p_quotation_date;
    END IF;

    v_allowed := (v_current_status = 'APPROVED' AND p_new_status = 'SENT')
              OR (v_current_status = 'SENT'     AND p_new_status IN ('ACCEPTED', 'REJECTED'));

    IF NOT v_allowed THEN
        RAISE EXCEPTION 'INVALID_STATUS_TRANSITION'
            USING DETAIL = format('Sales Quotation % cannot move from % to %.', p_quotation_no, v_current_status, p_new_status);
    END IF;

    UPDATE rih_sales_quotations SET
        status = p_new_status,
        updated_at = now(), updated_by = p_user_id
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_update_sales_quotation_status(UUID, UUID, TEXT, DATE, TEXT, UUID) TO authenticated;


-- ============================================================
-- Menu seed — 'SL-QUO' (Sales Quotation) for every already-existing
-- company. fn_seed_client_modules (backend/functions/fn_seed_client_
-- modules.sql) is updated separately for FUTURE new clients — that
-- function only runs once, at fn_register_client time, same pattern
-- migration 062 used for PR-RET. Placed first in the Transactions
-- group (before Sales Invoice) since a quotation precedes an invoice
-- in the sales flow; existing SL-INV/SL-RET/SL-RCP serial_no values
-- are shifted down by one to make room.
-- ============================================================

UPDATE ric_master_menus SET serial_no = serial_no + 1
WHERE feature_code IN ('SL-INV', 'SL-RET', 'SL-RCP')
  AND module_id IN (SELECT id FROM ric_system_modules WHERE module_code = 'SL');

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'SL-QUO', 'Sales Quotation', '/sales/quotations',
    0, 'SL-TXN', 'Transactions', 0,
    true, true, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'SL'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
