-- ============================================================
-- 031_purchase_orders.sql
-- Purchase Order module — Phase 1 (PO only; GRN/Purchase Bill/Landed
-- Cost come later per the agreed phasing).
--
-- Tables:
--   rim_additional_charges     → shared Sales+Purchase charge type master
--   ril_company_doc_no_seq     → company-wide (not location-wide) document
--                                 numbering — PO numbers are shared across
--                                 all locations in a company, unlike Finance
--                                 vouchers which are numbered per location.
--                                 Deliberately NOT reusing ril_trans_no_seq /
--                                 fn_next_trans_no so Finance's tested,
--                                 already-deployed numbering is untouched.
--   rih_purchase_orders        → PO header
--   rid_purchase_order_lines   → PO item lines
--   rid_po_charge_lines        → PO-level additional charges (freight,
--                                 loading, handling…), apportioned across
--                                 lines via a computed allocation_factor
--                                 (charge_amount / PO value before charges).
--
-- Design decisions carried from discussion:
--   • order_no + order_date are the document identity (not a bare
--     order_no) — numbering can reset per period, so the pair is the
--     only stable reference, same lesson as Finance's trans_no/trans_date.
--   • Header PK is (client_id, company_id, order_no, order_date) — NO
--     location_id. PO documents are company-wide; location_id is still a
--     plain column (which location is ordering/receiving) but not part
--     of the document's identity.
--   • po_type (LOCAL/IMPORT) drives which import-only fields the UI shows;
--     one table, not two, since the difference is a handful of fields.
--   • indent_no/date, rfq_no/date, quotation_no/date are nullable
--     placeholders for the not-yet-built Indent/RFQ/Quotation modules —
--     zero schema cost today, no rework needed when those are built.
--   • Charges are a separate line table, not columns on the item line —
--     apportioned by value (CHARGE_FACTOR = charge_amount / PO value
--     before charges), matching the client's prior ERP design.
--   • Once a PO is APPROVED it is locked (mirrors Finance's is_posted
--     pattern). Charges and lines cannot change after approval — any
--     revision happens at GRN time, not by editing the PO.
--   • RLS uses proper JWT-claims tenant isolation (current_setting
--     ('request.jwt.claims', true)::json), per CLAUDE.md — NOT the
--     permissive dev_allow_all pattern that crept into migrations
--     028/029. Those two are cleanup debt, out of scope here.
-- ============================================================


-- ------------------------------------------------------------
-- rim_additional_charges
-- Shared charge-type master for both Sales and Purchase (freight,
-- loading, handling, insurance, customs…). Company-wide, no location_id.
-- amount_or_percent / percent / amount / tax_id / nature / gl_account are
-- DEFAULTS — a transaction line can override the amount or percent value,
-- but not the type/tax/account/nature (confirmed: "can overwrite amount
-- or percent, but can't change type").
-- ------------------------------------------------------------
CREATE TABLE rim_additional_charges (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL REFERENCES ric_clients(id),
    company_id             UUID          NOT NULL REFERENCES ric_companies(id),
    charge_code            TEXT          NOT NULL,
    charge_name            TEXT          NOT NULL,
    applicable_on          TEXT          NOT NULL DEFAULT 'BOTH'
                           CHECK (applicable_on IN ('SALES','PURCHASE','BOTH')),
    is_taxable             BOOLEAN       NOT NULL DEFAULT false,
    tax_id                 UUID          REFERENCES rim_taxes(id),
    nature                 TEXT          NOT NULL DEFAULT 'ADD'
                           CHECK (nature IN ('ADD','DEDUCT')),
    amount_or_percent      TEXT          NOT NULL DEFAULT 'AMOUNT'
                           CHECK (amount_or_percent IN ('AMOUNT','PERCENT')),
    default_percent        NUMERIC(6,2),
    default_amount         NUMERIC(18,4),
    default_gl_account_id  UUID          REFERENCES rim_accounts(id),
    sort_order              SMALLINT     NOT NULL DEFAULT 0,
    is_active                BOOLEAN     NOT NULL DEFAULT true,
    is_deleted                BOOLEAN     NOT NULL DEFAULT false,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                UUID        REFERENCES rim_users(id),
    updated_at                TIMESTAMPTZ,
    updated_by                UUID        REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, charge_code)
);

CREATE INDEX idx_rim_additional_charges_tenant ON rim_additional_charges (client_id, company_id, is_deleted);

CREATE TRIGGER trg_rim_additional_charges_updated_at
    BEFORE UPDATE ON rim_additional_charges
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rim_additional_charges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_additional_charges" ON rim_additional_charges
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_additional_charges FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_additional_charges TO authenticated;


-- ------------------------------------------------------------
-- rim_common_master_types — new type_keys for line-level attribution
-- ------------------------------------------------------------
INSERT INTO rim_common_master_types (type_key, type_name) VALUES
    ('DEPARTMENT',        'Department'),
    ('CONSUMPTION_AREA',  'Consumption Area')
ON CONFLICT (type_key) DO NOTHING;


-- ------------------------------------------------------------
-- rim_voucher_types — widen voucher_nature to allow PURCHASE, seed
-- the two PO document types. PO numbering is company-wide, so these
-- rows are consumed by fn_next_company_doc_no below, NOT fn_next_trans_no.
-- ------------------------------------------------------------
ALTER TABLE rim_voucher_types
    DROP CONSTRAINT rim_voucher_types_nature_check;

ALTER TABLE rim_voucher_types
    ADD CONSTRAINT rim_voucher_types_nature_check
        CHECK (voucher_nature IN ('RECEIPT','PAYMENT','JOURNAL','DEBIT_NOTE','CREDIT_NOTE','STOCK','PURCHASE'));

INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('PO-LOC', 'Purchase Order - Local',  'PURCHASE', NULL, 'YEARLY', 'PO/{YYYY}/{SEQ5}',  true),
    ('PO-IMP', 'Purchase Order - Import', 'PURCHASE', NULL, 'YEARLY', 'POI/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- ril_company_doc_no_seq
-- Company-wide (no location) counterpart to ril_trans_no_seq.
-- Same FOR UPDATE locking pattern to prevent duplicate numbers under
-- concurrent users.
-- ------------------------------------------------------------
CREATE TABLE ril_company_doc_no_seq (
    client_id           UUID        NOT NULL REFERENCES ric_clients(id),
    company_id          UUID        NOT NULL REFERENCES ric_companies(id),
    voucher_type_code   TEXT        NOT NULL,
    current_seq         INTEGER     NOT NULL DEFAULT 0,
    last_reset_date     DATE,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (client_id, company_id, voucher_type_code)
);

ALTER TABLE ril_company_doc_no_seq ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_company_doc_no_seq" ON ril_company_doc_no_seq
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ril_company_doc_no_seq FROM anon;
GRANT SELECT, INSERT, UPDATE ON ril_company_doc_no_seq TO authenticated;


-- ------------------------------------------------------------
-- rih_purchase_orders
-- location_id is a plain reference column (which location is ordering /
-- will receive) — deliberately NOT part of the composite key, since PO
-- documents are company-wide, not per-location.
-- ------------------------------------------------------------
CREATE TABLE rih_purchase_orders (
    id                   UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            UUID          NOT NULL REFERENCES ric_clients(id),
    company_id           UUID          NOT NULL REFERENCES ric_companies(id),
    location_id          UUID          NOT NULL REFERENCES ric_locations(id),
    order_no             TEXT          NOT NULL,
    order_date           DATE          NOT NULL,
    po_type              TEXT          NOT NULL DEFAULT 'LOCAL'
                         CHECK (po_type IN ('LOCAL','IMPORT')),
    supplier_id          UUID          NOT NULL REFERENCES rim_accounts(id),
    supplier_ref_no      TEXT,
    supplier_ref_date    DATE,
    -- Forward-compatible placeholders for not-yet-built Indent/RFQ/Quotation
    indent_no            TEXT,
    indent_date          DATE,
    rfq_no               TEXT,
    rfq_date             DATE,
    quotation_no         TEXT,
    quotation_date       DATE,
    payment_terms        TEXT,
    po_currency_id       UUID          NOT NULL REFERENCES rim_currencies(id),
    rate_to_base         NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local        NUMERIC(18,8) NOT NULL DEFAULT 1,
    -- Denormalized rollups for fast list-screen display.
    -- item_tax_amount (VAT on goods) and charge_tax_amount (VAT on
    -- freight/handling/etc.) are kept separate — different tax bases,
    -- different VAT-return reporting category, don't merge them.
    gross_amount         NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_amount       NUMERIC(18,4) NOT NULL DEFAULT 0,
    charges_amount         NUMERIC(18,4) NOT NULL DEFAULT 0,
    item_tax_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
    charge_tax_amount         NUMERIC(18,4) NOT NULL DEFAULT 0,
    grand_total                NUMERIC(18,4) NOT NULL DEFAULT 0,
    buyer_id             UUID          REFERENCES rim_users(id),
    status                TEXT          NOT NULL DEFAULT 'DRAFT'
                         CHECK (status IN ('DRAFT','APPROVED','PARTIALLY_RECEIVED','CLOSED','CANCELLED')),
    approved_by           UUID          REFERENCES rim_users(id),
    approved_at           TIMESTAMPTZ,
    closed_by             UUID          REFERENCES rim_users(id),
    closed_at             TIMESTAMPTZ,
    order_subject         TEXT,
    bill_to               TEXT,
    ship_to               TEXT,
    remarks               TEXT,
    is_active             BOOLEAN       NOT NULL DEFAULT true,
    is_deleted             BOOLEAN      NOT NULL DEFAULT false,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by               UUID        REFERENCES rim_users(id),
    updated_at                TIMESTAMPTZ,
    updated_by                 UUID       REFERENCES rim_users(id),
    CONSTRAINT uq_rih_purchase_orders UNIQUE (client_id, company_id, order_no, order_date)
);

CREATE INDEX idx_rih_po_tenant   ON rih_purchase_orders (client_id, company_id, is_deleted);
CREATE INDEX idx_rih_po_supplier ON rih_purchase_orders (supplier_id);
CREATE INDEX idx_rih_po_status   ON rih_purchase_orders (client_id, company_id, status);
CREATE INDEX idx_rih_po_date     ON rih_purchase_orders (client_id, company_id, order_date DESC);

CREATE TRIGGER trg_rih_purchase_orders_updated_at
    BEFORE UPDATE ON rih_purchase_orders
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_purchase_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_purchase_orders" ON rih_purchase_orders
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_purchase_orders FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_purchase_orders TO authenticated;


-- ------------------------------------------------------------
-- rid_purchase_order_lines
-- ------------------------------------------------------------
CREATE TABLE rid_purchase_order_lines (
    id                       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                UUID          NOT NULL REFERENCES ric_clients(id),
    company_id               UUID          NOT NULL REFERENCES ric_companies(id),
    order_no                 TEXT          NOT NULL,
    order_date                DATE         NOT NULL,
    serial_no                 INTEGER      NOT NULL,
    product_id                UUID         NOT NULL REFERENCES rim_products(id),
    item_description           TEXT,
    -- What was actually scanned to select this line — audit only,
    -- rim_product_uom.barcode remains the source of truth
    barcode                     TEXT,
    uom_id                       UUID       NOT NULL REFERENCES rim_common_masters(id),
    -- Snapshotted at line-entry time so a later change to the product's
    -- own conversion factor doesn't silently rewrite historical POs
    uom_conversion_factor         NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack                       NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose                       NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- qty_pack * uom_conversion_factor + qty_loose, in the product's base UOM
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
    -- This line's apportioned share of rid_po_charge_lines, computed as
    -- sum(charge.allocation_factor * this line's gross_amount) across all
    -- PO charges. Estimate only — actual costing happens at GRN.
    charge_amount                              NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- final_amount + charge_amount — the true estimated landed cost of
    -- this line, shown to the buyer before approval.
    landed_amount                               NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- Nullable — only meaningful for internal-consumption purchases
    -- (product_nature != 'TRADING'), not resale stock
    department_id                               UUID         REFERENCES rim_common_masters(id),
    consumption_area_id                          UUID         REFERENCES rim_common_masters(id),
    -- System-populated read-only snapshot for audit ("why was this PO raised")
    qty_on_hand_at_order                          NUMERIC(18,4),
    reorder_level_at_order                         NUMERIC(18,4),
    -- Running total, incremented by future fn_post_grn
    qty_received                                    NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_deleted                                       BOOLEAN      NOT NULL DEFAULT false,
    created_at                                        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by                                         UUID        REFERENCES rim_users(id),
    updated_at                                          TIMESTAMPTZ,
    updated_by                                           UUID       REFERENCES rim_users(id),
    CONSTRAINT uq_rid_po_lines UNIQUE (client_id, company_id, order_no, order_date, serial_no),
    CONSTRAINT rid_po_lines_header_fk
        FOREIGN KEY (client_id, company_id, order_no, order_date)
        REFERENCES  rih_purchase_orders (client_id, company_id, order_no, order_date)
);

CREATE INDEX idx_rid_po_lines_header  ON rid_purchase_order_lines (client_id, company_id, order_no, order_date);
CREATE INDEX idx_rid_po_lines_product ON rid_purchase_order_lines (product_id);

ALTER TABLE rid_purchase_order_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_po_lines" ON rid_purchase_order_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_purchase_order_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_purchase_order_lines TO authenticated;


-- ------------------------------------------------------------
-- rid_po_charge_lines
-- is_taxable / tax_id / nature / gl_account_id / amount_or_percent are
-- frozen copies from rim_additional_charges at entry time (type is
-- locked — only percent/amount are editable per transaction, per
-- "can overwrite amount or percent, but can't change type").
-- allocation_factor = amount / (PO value before charges) — computed by
-- the application, stored here so it doesn't need to be recomputed
-- later when GRN/Landed Cost references it.
-- ------------------------------------------------------------
CREATE TABLE rid_po_charge_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    order_no              TEXT          NOT NULL,
    order_date             DATE         NOT NULL,
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
    is_deleted                           BOOLEAN     NOT NULL DEFAULT false,
    created_at                            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                             UUID       REFERENCES rim_users(id),
    updated_at                              TIMESTAMPTZ,
    updated_by                               UUID      REFERENCES rim_users(id),
    CONSTRAINT uq_rid_po_charge_lines UNIQUE (client_id, company_id, order_no, order_date, serial_no),
    CONSTRAINT rid_po_charge_lines_header_fk
        FOREIGN KEY (client_id, company_id, order_no, order_date)
        REFERENCES  rih_purchase_orders (client_id, company_id, order_no, order_date)
);

CREATE INDEX idx_rid_po_charges_header ON rid_po_charge_lines (client_id, company_id, order_no, order_date);

ALTER TABLE rid_po_charge_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_po_charge_lines" ON rid_po_charge_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_po_charge_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_po_charge_lines TO authenticated;


-- ============================================================
-- PG FUNCTIONS
-- ============================================================


-- ------------------------------------------------------------
-- fn_next_company_doc_no
-- Company-wide equivalent of fn_next_trans_no (no {LOC} token, no
-- location scoping). Same FOR UPDATE row-lock pattern.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_next_company_doc_no(
    p_client_id    UUID,
    p_company_id   UUID,
    p_voucher_type TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_vt           RECORD;
    v_seq          INTEGER;
    v_last_reset   DATE;
    v_today        DATE := current_date;
    v_should_reset BOOLEAN := false;
    v_result       TEXT;
BEGIN
    SELECT vt.reset_frequency, vt.trans_no_format
    INTO   v_vt
    FROM   rim_voucher_types vt
    WHERE  vt.voucher_type_code = p_voucher_type
      AND  vt.is_active  = true
      AND  vt.is_deleted = false
      AND  (vt.is_system = true
            OR (vt.client_id = p_client_id AND vt.company_id = p_company_id))
    ORDER BY vt.is_system ASC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher type % not found or inactive', p_voucher_type;
    END IF;

    INSERT INTO ril_company_doc_no_seq (client_id, company_id, voucher_type_code, current_seq, last_reset_date)
    VALUES (p_client_id, p_company_id, p_voucher_type, 0, v_today)
    ON CONFLICT (client_id, company_id, voucher_type_code) DO NOTHING;

    SELECT current_seq, last_reset_date
    INTO   v_seq, v_last_reset
    FROM   ril_company_doc_no_seq
    WHERE  client_id = p_client_id AND company_id = p_company_id
      AND  voucher_type_code = p_voucher_type
    FOR UPDATE;

    v_should_reset := CASE v_vt.reset_frequency
        WHEN 'DAILY'   THEN v_last_reset IS NULL OR v_last_reset < v_today
        WHEN 'MONTHLY' THEN v_last_reset IS NULL
                         OR to_char(v_last_reset, 'YYYY-MM') < to_char(v_today, 'YYYY-MM')
        WHEN 'YEARLY'  THEN v_last_reset IS NULL
                         OR to_char(v_last_reset, 'YYYY') < to_char(v_today, 'YYYY')
        ELSE false
    END;

    v_seq := CASE WHEN v_should_reset THEN 1 ELSE v_seq + 1 END;

    UPDATE ril_company_doc_no_seq SET
        current_seq     = v_seq,
        last_reset_date = v_today,
        updated_at      = now()
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND voucher_type_code = p_voucher_type;

    v_result := v_vt.trans_no_format;
    v_result := replace(v_result, '{YYYY}', to_char(v_today, 'YYYY'));
    v_result := replace(v_result, '{MM}',   to_char(v_today, 'MM'));
    v_result := replace(v_result, '{DD}',   to_char(v_today, 'DD'));
    v_result := replace(v_result, '{SEQ6}', lpad(v_seq::text, 6, '0'));
    v_result := replace(v_result, '{SEQ5}', lpad(v_seq::text, 5, '0'));
    v_result := replace(v_result, '{SEQ4}', lpad(v_seq::text, 4, '0'));

    RETURN v_result;
END;
$$;


-- ------------------------------------------------------------
-- fn_save_purchase_order
-- Draft-only save: generates order_no on first save, blocks edits once
-- status != 'DRAFT'. Lines and charges are deleted and re-inserted on
-- every save (same rationale as Finance drafts — no audit value for
-- unposted revisions).
-- p_lines / p_charges: JSONB arrays.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_save_purchase_order(
    p_header  JSONB,
    p_lines   JSONB,
    p_charges JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_order_no       TEXT;
    v_order_date     DATE;
    v_old_order_date DATE;
    v_is_new         BOOLEAN;
    v_voucher_type   TEXT;
    v_line           JSONB;
    v_charge         JSONB;
BEGIN
    v_client_id  := (p_header->>'client_id')::uuid;
    v_company_id := (p_header->>'company_id')::uuid;
    v_order_no   := nullif(trim(p_header->>'order_no'), '');
    v_order_date := (p_header->>'order_date')::date;
    v_is_new     := v_order_no IS NULL;

    v_voucher_type := CASE WHEN p_header->>'po_type' = 'IMPORT' THEN 'PO-IMP' ELSE 'PO-LOC' END;

    IF v_is_new THEN
        v_order_no := fn_next_company_doc_no(v_client_id, v_company_id, v_voucher_type);
    ELSE
        SELECT order_date INTO v_old_order_date
        FROM   rih_purchase_orders
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  order_no = v_order_no AND is_deleted = false;

        IF EXISTS (
            SELECT 1 FROM rih_purchase_orders
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND order_no = v_order_no AND status != 'DRAFT'
        ) THEN
            RAISE EXCEPTION 'Purchase Order % is % and cannot be edited.',
                v_order_no, (SELECT status FROM rih_purchase_orders
                              WHERE client_id = v_client_id AND company_id = v_company_id AND order_no = v_order_no);
        END IF;

        DELETE FROM rid_purchase_order_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;

        DELETE FROM rid_po_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_purchase_orders (
            client_id, company_id, location_id, order_no, order_date, po_type,
            supplier_id, supplier_ref_no, supplier_ref_date,
            indent_no, indent_date, rfq_no, rfq_date, quotation_no, quotation_date,
            payment_terms, po_currency_id, rate_to_base, rate_to_local,
            gross_amount, discount_amount, charges_amount, item_tax_amount, charge_tax_amount, grand_total,
            buyer_id, order_subject, bill_to, ship_to, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, (p_header->>'location_id')::uuid, v_order_no, v_order_date,
            coalesce(p_header->>'po_type', 'LOCAL'),
            (p_header->>'supplier_id')::uuid,
            nullif(p_header->>'supplier_ref_no', ''), (nullif(p_header->>'supplier_ref_date', ''))::date,
            nullif(p_header->>'indent_no', ''), (nullif(p_header->>'indent_date', ''))::date,
            nullif(p_header->>'rfq_no', ''), (nullif(p_header->>'rfq_date', ''))::date,
            nullif(p_header->>'quotation_no', ''), (nullif(p_header->>'quotation_date', ''))::date,
            nullif(p_header->>'payment_terms', ''),
            (p_header->>'po_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'item_tax_amount')::numeric, 0),
            coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            (nullif(p_header->>'buyer_id', ''))::uuid,
            nullif(p_header->>'order_subject', ''),
            nullif(p_header->>'bill_to', ''), nullif(p_header->>'ship_to', ''),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_purchase_orders SET
            location_id        = (p_header->>'location_id')::uuid,
            order_date          = v_order_date,
            po_type              = coalesce(p_header->>'po_type', 'LOCAL'),
            supplier_id           = (p_header->>'supplier_id')::uuid,
            supplier_ref_no        = nullif(p_header->>'supplier_ref_no', ''),
            supplier_ref_date       = (nullif(p_header->>'supplier_ref_date', ''))::date,
            indent_no                = nullif(p_header->>'indent_no', ''),
            indent_date               = (nullif(p_header->>'indent_date', ''))::date,
            rfq_no                     = nullif(p_header->>'rfq_no', ''),
            rfq_date                    = (nullif(p_header->>'rfq_date', ''))::date,
            quotation_no                 = nullif(p_header->>'quotation_no', ''),
            quotation_date                = (nullif(p_header->>'quotation_date', ''))::date,
            payment_terms                  = nullif(p_header->>'payment_terms', ''),
            po_currency_id                   = (p_header->>'po_currency_id')::uuid,
            rate_to_base                      = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local                       = coalesce((p_header->>'rate_to_local')::numeric, 1),
            gross_amount                          = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount                         = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount                            = coalesce((p_header->>'charges_amount')::numeric, 0),
            item_tax_amount                             = coalesce((p_header->>'item_tax_amount')::numeric, 0),
            charge_tax_amount                            = coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            grand_total                                   = coalesce((p_header->>'grand_total')::numeric, 0),
            buyer_id                                        = (nullif(p_header->>'buyer_id', ''))::uuid,
            order_subject                                     = nullif(p_header->>'order_subject', ''),
            bill_to                                             = nullif(p_header->>'bill_to', ''),
            ship_to                                               = nullif(p_header->>'ship_to', ''),
            remarks                                                = nullif(p_header->>'remarks', ''),
            updated_at                                               = now(),
            updated_by                                                 = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_purchase_order_lines (
            client_id, company_id, order_no, order_date, serial_no,
            product_id, item_description, barcode, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, gross_amount,
            discount_percent, discount_amount, tax_group_id, tax_amount,
            final_amount, base_amount, local_amount, charge_amount, landed_amount,
            department_id, consumption_area_id,
            qty_on_hand_at_order, reorder_level_at_order,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date,
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
            (nullif(v_line->>'department_id', ''))::uuid,
            (nullif(v_line->>'consumption_area_id', ''))::uuid,
            (v_line->>'qty_on_hand_at_order')::numeric,
            (v_line->>'reorder_level_at_order')::numeric,
            p_user_id, p_user_id
        );
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_po_charge_lines (
            client_id, company_id, order_no, order_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount_or_percent, percent, amount, tax_amount, allocation_factor,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date,
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

    RETURN v_order_no;
END;
$$;


-- ------------------------------------------------------------
-- fn_approve_purchase_order
-- Locks the PO. No GL posting — PO is not a financial document (that
-- happens later at Purchase Bill). Once approved, lines/charges can no
-- longer change; corrections happen at GRN, per agreed design.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_approve_purchase_order(
    p_client_id   UUID,
    p_company_id  UUID,
    p_order_no    TEXT,
    p_order_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_purchase_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_header FROM rih_purchase_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Order % dated % not found', p_order_no, p_order_date;
    END IF;

    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Purchase Order % is % and cannot be approved again', p_order_no, v_header.status;
    END IF;

    UPDATE rih_purchase_orders SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(),
        updated_by  = p_approved_by
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_next_company_doc_no(UUID, UUID, TEXT)            TO authenticated;
GRANT EXECUTE ON FUNCTION fn_save_purchase_order(JSONB, JSONB, JSONB, UUID)   TO authenticated;
GRANT EXECUTE ON FUNCTION fn_approve_purchase_order(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
