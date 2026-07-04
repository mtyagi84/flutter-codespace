-- ============================================================
-- Migration 038: GRN (Goods Receipt Note)
-- ============================================================
-- Fourth and final foundational migration before GRN Flutter screens.
-- Depends on 035 (period/backdate checks), 036 (stock engine), 037
-- (voucher engine), 031 (Purchase Order), 032 (Account Link Setup),
-- 025 (Tax Master).
--
-- GRN supports two entry modes (rih_grn_headers.receipt_mode):
--   AGAINST_PO — single supplier, may consolidate lines from MULTIPLE open
--                POs of that same supplier. Header/line info and charges
--                carry forward from the linked PO(s) as editable defaults.
--   DIRECT     — single supplier, no PO reference at all.
-- One GRN line per item/PO-line reference, even if received across
-- multiple batches — batch/expiry split lives in a child table
-- (rid_transaction_line_batches), not as separate GRN lines. That table
-- (and its serial-tracking sibling rid_transaction_line_serials) is
-- document-type-generic — keyed by source_doc_type/no/date, not a GRN-only
-- FK — so Transfer, Sales Delivery and Adjustment reuse the same two
-- tables instead of each inventing their own. There is no header-level
-- PO-links junction table: "which GRNs touched PO X" is answered directly
-- off rid_grn_lines.source_po_* (already indexed) via v_grn_po_links, a
-- plain view — a maintained junction table would only add write overhead
-- (delete+reinsert on every edit) for a query an index already answers.
--
-- GL posting (fn_approve_grn), all resolved via fn_resolve_account_link /
-- the tax master's own GL links — nothing new invented:
--   DR Stock            = (line.final_amount - line.tax_amount) + line.charge_amount
--                          (net of tax; charge_amount already apportioned
--                          per line the same way PO computes it)
--   DR Input Tax         = line.tax_amount, apportioned across the tax
--                          group's member taxes by fn_get_active_tax_rate
--                          weight, credited to each tax's own gl_input_account_id
--   CR Purchase Accrual   = line.final_amount (tax-inclusive item value —
--                          this is what later matches against the Purchase
--                          Invoice, never posted to the supplier account
--                          directly at GRN time)
--   CR Charge account (per charge) = charge.amount + charge.tax_amount,
--                          credited to the charge's own frozen gl_account_id
--   DR Charge Tax (per taxable charge) = charge.tax_amount, credited (as
--                          part of the line above) via the charge's own
--                          tax_id -> rim_taxes.gl_input_account_id
-- All four balance exactly; see the worked proof in the design conversation
-- this migration was built from. One fn_post_voucher call per GRN, not per line.
--
-- Objects:
--   rih_grn_headers, rid_grn_lines, rid_grn_charge_lines
--   rid_transaction_line_batches, rid_transaction_line_serials → shared with
--     future Transfer/Sales Delivery/Adjustment, not GRN-specific
--   v_grn_po_links        → plain view, not a maintained table
--   fn_save_grn(...)     → draft-only, mirrors fn_save_purchase_order
--   fn_approve_grn(...)  → the orchestration described above
-- ============================================================

-- ── rih_grn_headers ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_grn_headers (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    location_id         UUID          NOT NULL REFERENCES ric_locations(id),
    grn_no              TEXT          NOT NULL,
    grn_date            DATE          NOT NULL,
    supplier_id         UUID          NOT NULL REFERENCES rim_accounts(id),
    receipt_mode        TEXT          NOT NULL CHECK (receipt_mode IN ('AGAINST_PO', 'DIRECT')),
    supplier_delivery_no   TEXT,
    supplier_delivery_date DATE,
    grn_currency_id     UUID          REFERENCES rim_currencies(id),
    rate_to_base        NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local       NUMERIC(18,8) NOT NULL DEFAULT 1,
    gross_amount        NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_amount     NUMERIC(18,4) NOT NULL DEFAULT 0,
    charges_amount      NUMERIC(18,4) NOT NULL DEFAULT 0,
    item_tax_amount     NUMERIC(18,4) NOT NULL DEFAULT 0,
    charge_tax_amount   NUMERIC(18,4) NOT NULL DEFAULT 0,
    grand_total         NUMERIC(18,4) NOT NULL DEFAULT 0,
    bill_to             TEXT,
    ship_to             TEXT,
    remarks             TEXT,
    status              TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'APPROVED')),
    approved_by         UUID          REFERENCES rim_users(id),
    approved_at         TIMESTAMPTZ,
    reversal_of_grn_no  TEXT,          -- reserved; reversal function is Phase 2
    posted_voucher_no   TEXT,          -- traceability back to the GL entry fn_post_voucher created
    posted_voucher_date DATE,
    is_active           BOOLEAN       NOT NULL DEFAULT true,
    is_deleted          BOOLEAN       NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          UUID          REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, grn_no, grn_date)
);

CREATE INDEX IF NOT EXISTS idx_grn_headers_supplier ON rih_grn_headers (client_id, company_id, supplier_id);
CREATE INDEX IF NOT EXISTS idx_grn_headers_status    ON rih_grn_headers (client_id, company_id, status);

CREATE TRIGGER trg_rih_grn_headers_updated_at
    BEFORE UPDATE ON rih_grn_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_grn_headers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_grn_headers" ON rih_grn_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_grn_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_grn_headers TO authenticated;

-- ── rid_grn_lines ─────────────────────────────────────────────────────────────
-- source_po_* triple is nullable — NULL for Direct GRN lines, set for
-- Against-PO lines. This is what fn_approve_grn uses to increment the PO
-- line's qty_received; v_grn_po_links (a plain view, defined after this
-- table) reads the same columns for display/filtering, nothing separate.
CREATE TABLE IF NOT EXISTS rid_grn_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    grn_no                TEXT          NOT NULL,
    grn_date              DATE          NOT NULL,
    serial_no             INTEGER       NOT NULL,
    product_id            UUID          NOT NULL REFERENCES rim_products(id),
    source_po_order_no    TEXT,
    source_po_order_date  DATE,
    source_po_line_serial INTEGER,
    item_description      TEXT,
    uom_id                UUID,
    uom_conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack              NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose              NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty              NUMERIC(18,4) NOT NULL DEFAULT 0,
    rate                  NUMERIC(18,4) NOT NULL DEFAULT 0,
    gross_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_percent      NUMERIC(6,2)  NOT NULL DEFAULT 0,
    discount_amount       NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_group_id          UUID          REFERENCES rim_tax_groups(id),
    tax_amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    final_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    local_amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    charge_amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    landed_amount             NUMERIC(18,4) NOT NULL DEFAULT 0,
    department_id          UUID,
    consumption_area_id     UUID,
    is_deleted              BOOLEAN      NOT NULL DEFAULT false,
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by                UUID        REFERENCES rim_users(id),
    updated_at                  TIMESTAMPTZ,
    updated_by                    UUID     REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, grn_no, grn_date, serial_no),
    FOREIGN KEY (client_id, company_id, grn_no, grn_date)
        REFERENCES rih_grn_headers (client_id, company_id, grn_no, grn_date)
);

CREATE INDEX IF NOT EXISTS idx_grn_lines_source_po
    ON rid_grn_lines (client_id, company_id, source_po_order_no, source_po_order_date, source_po_line_serial);
CREATE INDEX IF NOT EXISTS idx_grn_lines_product
    ON rid_grn_lines (product_id);

ALTER TABLE rid_grn_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_grn_lines" ON rid_grn_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_grn_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_grn_lines TO authenticated;

-- ── rid_transaction_line_batches ──────────────────────────────────────────────
-- Document-type-generic draft-entry staging for BATCH / BATCH_WITH_EXPIRY
-- items — GRN today, Transfer/Sales Delivery/Adjustment later reuse the same
-- table instead of each inventing rid_<module>_line_batches. Keyed by
-- source_doc_type/no/date + line_serial rather than an FK to any one
-- module's line table (different doc types have different line tables) —
-- each module's own fn_save_* is responsible for delete+reinsert on edit,
-- exactly like rid_grn_lines.source_po_* is already a soft/logical
-- cross-module reference with no FK. SUM(base_qty) across a line's batch
-- children must equal that line's own base_qty — validated in fn_save_grn.
CREATE TABLE IF NOT EXISTS rid_transaction_line_batches (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID          NOT NULL,
    company_id      UUID          NOT NULL,
    source_doc_type TEXT          NOT NULL,   -- 'GRN', later 'TRANSFER_OUT', 'SALES_INVOICE', ...
    source_doc_no   TEXT          NOT NULL,
    source_doc_date DATE          NOT NULL,
    line_serial     INTEGER       NOT NULL,
    batch_no        TEXT          NOT NULL,
    expiry_date     DATE,
    qty_pack        NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose       NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty        NUMERIC(18,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by      UUID          REFERENCES rim_users(id)
);

CREATE INDEX IF NOT EXISTS idx_txn_line_batches_doc
    ON rid_transaction_line_batches (client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial);

ALTER TABLE rid_transaction_line_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_transaction_line_batches" ON rid_transaction_line_batches
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_transaction_line_batches FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_transaction_line_batches TO authenticated;

-- ── rid_transaction_line_serials ──────────────────────────────────────────────
-- Same generalization as rid_transaction_line_batches, for SERIAL-tracked
-- items. This is draft-entry staging only (mutable, deleted+reinserted on
-- edit) — the immutable posted record of each serial unit lives directly on
-- ril_stock_ledger.serial_no, one ledger row per unit, once approved.
CREATE TABLE IF NOT EXISTS rid_transaction_line_serials (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID        NOT NULL,
    company_id      UUID        NOT NULL,
    source_doc_type TEXT        NOT NULL,
    source_doc_no   TEXT        NOT NULL,
    source_doc_date DATE        NOT NULL,
    line_serial     INTEGER     NOT NULL,
    serial_no       TEXT        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID        REFERENCES rim_users(id)
);

CREATE INDEX IF NOT EXISTS idx_txn_line_serials_doc
    ON rid_transaction_line_serials (client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial);

ALTER TABLE rid_transaction_line_serials ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_transaction_line_serials" ON rid_transaction_line_serials
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_transaction_line_serials FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_transaction_line_serials TO authenticated;

-- ── v_grn_po_links ─────────────────────────────────────────────────────────────
-- "Which GRNs touched PO X" answered as a plain view off rid_grn_lines
-- (already indexed on source_po_*), not a maintained junction table —
-- avoids a redundant delete+reinsert-on-every-edit table for a query an
-- index already answers.
CREATE OR REPLACE VIEW v_grn_po_links AS
SELECT DISTINCT client_id, company_id, grn_no, grn_date, source_po_order_no, source_po_order_date
FROM rid_grn_lines
WHERE source_po_order_no IS NOT NULL AND is_deleted = false;

-- ── rid_grn_charge_lines ──────────────────────────────────────────────────────
-- Same shape as rid_po_charge_lines. source_po_order_no/date (nullable) keeps
-- charges pulled from multiple consolidated POs traceable to their origin
-- instead of being merged. Pre-populated from the linked PO(s)' charge lines
-- as editable defaults in Against-PO mode — these are the REAL final figures,
-- PO's own charge_amount/landed_amount were only ever an estimate.
CREATE TABLE IF NOT EXISTS rid_grn_charge_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    grn_no                TEXT          NOT NULL,
    grn_date              DATE          NOT NULL,
    serial_no             INTEGER       NOT NULL,
    charge_id             UUID          NOT NULL REFERENCES rim_additional_charges(id),
    charge_name           TEXT          NOT NULL,
    is_taxable             BOOLEAN      NOT NULL DEFAULT false,
    tax_id                  UUID        REFERENCES rim_taxes(id),
    nature                   TEXT       NOT NULL DEFAULT 'ADD' CHECK (nature IN ('ADD', 'DEDUCT')),
    gl_account_id              UUID     REFERENCES rim_accounts(id),
    amount_or_percent            TEXT   NOT NULL DEFAULT 'AMOUNT' CHECK (amount_or_percent IN ('AMOUNT', 'PERCENT')),
    percent                        NUMERIC(6,2),
    amount                           NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount                        NUMERIC(18,4) NOT NULL DEFAULT 0,
    allocation_factor                  NUMERIC(18,8),
    source_po_order_no                  TEXT,
    source_po_order_date                 DATE,
    is_deleted                            BOOLEAN NOT NULL DEFAULT false,
    created_at                             TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                              UUID   REFERENCES rim_users(id),
    updated_at                                TIMESTAMPTZ,
    updated_by                                 UUID  REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, grn_no, grn_date, serial_no),
    FOREIGN KEY (client_id, company_id, grn_no, grn_date)
        REFERENCES rih_grn_headers (client_id, company_id, grn_no, grn_date)
);

ALTER TABLE rid_grn_charge_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_grn_charge_lines" ON rid_grn_charge_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_grn_charge_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_grn_charge_lines TO authenticated;

-- ── fn_save_grn ───────────────────────────────────────────────────────────────
-- Draft-only, mirrors fn_save_purchase_order's delete-and-reinsert pattern
-- exactly: NEW -> fn_next_trans_no (location-scoped, unlike PO's company-wide
-- numbering — a GRN is a location event). EDIT draft -> lock header row FOR
-- UPDATE before the status check (closes a TOCTOU race against a concurrent
-- fn_approve_grn — the same fix belongs in fn_save_purchase_order, see
-- migration 039), then delete+reinsert lines/batches/serials/charges.
CREATE OR REPLACE FUNCTION fn_save_grn(
    p_header  JSONB,
    p_lines   JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_charges JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id    UUID;
    v_company_id   UUID;
    v_location_id  UUID;
    v_grn_no       TEXT;
    v_grn_date     DATE;
    v_old_grn_date DATE;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
    v_batch        JSONB;
    v_serial       JSONB;
    v_charge       JSONB;
    v_line_qty     NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_grn_no      := nullif(trim(p_header->>'grn_no'), '');
    v_grn_date    := (p_header->>'grn_date')::date;
    v_is_new      := v_grn_no IS NULL;

    IF v_is_new THEN
        v_grn_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'GRN');
    ELSE
        -- Lock the header row before checking status — a plain SELECT here
        -- would leave a window where a concurrent fn_approve_grn commits
        -- between this check and the deletes below.
        SELECT grn_date, status INTO v_old_grn_date, v_old_status
        FROM rih_grn_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'GRN % is % and cannot be edited.', v_grn_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'GRN' AND source_doc_no = v_grn_no AND source_doc_date = v_old_grn_date;

        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'GRN' AND source_doc_no = v_grn_no AND source_doc_date = v_old_grn_date;

        DELETE FROM rid_grn_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND grn_date = v_old_grn_date;

        DELETE FROM rid_grn_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND grn_date = v_old_grn_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_grn_headers (
            client_id, company_id, location_id, grn_no, grn_date,
            supplier_id, receipt_mode, supplier_delivery_no, supplier_delivery_date,
            grn_currency_id, rate_to_base, rate_to_local,
            gross_amount, discount_amount, charges_amount, item_tax_amount, charge_tax_amount, grand_total,
            bill_to, ship_to, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_grn_no, v_grn_date,
            (p_header->>'supplier_id')::uuid,
            coalesce(p_header->>'receipt_mode', 'DIRECT'),
            nullif(p_header->>'supplier_delivery_no', ''), (nullif(p_header->>'supplier_delivery_date', ''))::date,
            (nullif(p_header->>'grn_currency_id', ''))::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'item_tax_amount')::numeric, 0),
            coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            nullif(p_header->>'bill_to', ''), nullif(p_header->>'ship_to', ''),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_grn_headers SET
            location_id             = v_location_id,
            grn_date                = v_grn_date,
            supplier_id              = (p_header->>'supplier_id')::uuid,
            receipt_mode              = coalesce(p_header->>'receipt_mode', 'DIRECT'),
            supplier_delivery_no       = nullif(p_header->>'supplier_delivery_no', ''),
            supplier_delivery_date      = (nullif(p_header->>'supplier_delivery_date', ''))::date,
            grn_currency_id               = (nullif(p_header->>'grn_currency_id', ''))::uuid,
            rate_to_base                   = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local                    = coalesce((p_header->>'rate_to_local')::numeric, 1),
            gross_amount                      = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount                    = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount                       = coalesce((p_header->>'charges_amount')::numeric, 0),
            item_tax_amount                        = coalesce((p_header->>'item_tax_amount')::numeric, 0),
            charge_tax_amount                        = coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            grand_total                                = coalesce((p_header->>'grand_total')::numeric, 0),
            bill_to                                      = nullif(p_header->>'bill_to', ''),
            ship_to                                        = nullif(p_header->>'ship_to', ''),
            remarks                                          = nullif(p_header->>'remarks', ''),
            updated_at                                         = now(),
            updated_by                                           = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_grn_lines (
            client_id, company_id, grn_no, grn_date, serial_no,
            product_id, source_po_order_no, source_po_order_date, source_po_line_serial,
            item_description, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, gross_amount,
            discount_percent, discount_amount, tax_group_id, tax_amount,
            final_amount, base_amount, local_amount, charge_amount, landed_amount,
            department_id, consumption_area_id, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_grn_no, v_grn_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'source_po_order_no', ''), (nullif(v_line->>'source_po_order_date', ''))::date,
            (v_line->>'source_po_line_serial')::integer,
            nullif(v_line->>'item_description', ''),
            (nullif(v_line->>'uom_id', ''))::uuid,
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
            p_user_id, p_user_id
        );

        -- Batch/serial children for this line, if any were provided
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
                v_client_id, v_company_id, 'GRN', v_grn_no, v_grn_date, (v_line->>'serial_no')::integer,
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
                USING DETAIL = format('Line %s: batch quantities sum to %s but the line quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        FOR v_serial IN
            SELECT * FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_serials (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
            ) VALUES (
                v_client_id, v_company_id, 'GRN', v_grn_no, v_grn_date, (v_line->>'serial_no')::integer,
                v_serial->>'serial_no', p_user_id
            );
        END LOOP;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_grn_charge_lines (
            client_id, company_id, grn_no, grn_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount_or_percent, percent, amount, tax_amount, allocation_factor,
            source_po_order_no, source_po_order_date, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_grn_no, v_grn_date,
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
            nullif(v_charge->>'source_po_order_no', ''), (nullif(v_charge->>'source_po_order_date', ''))::date,
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_grn_no;
END;
$$;

-- ── fn_approve_grn ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_grn(
    p_client_id   UUID,
    p_company_id  UUID,
    p_grn_no      TEXT,
    p_grn_date    DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_grn_headers%ROWTYPE;
    v_line                rid_grn_lines%ROWTYPE;
    v_batch                rid_transaction_line_batches%ROWTYPE;
    v_serial_row            rid_transaction_line_serials%ROWTYPE;
    v_charge                 rid_grn_charge_lines%ROWTYPE;
    v_po_line                 RECORD;
    v_po_key                  RECORD;
    v_tax_row                    RECORD;
    v_charge_tax_account          UUID;
    v_base_ccy                     TEXT;
    v_grn_ccy                        TEXT;
    v_product_ccy                      TEXT;
    v_rate_to_base                       NUMERIC;
    v_rate_to_specific                     NUMERIC;
    v_unit_cost_base                         NUMERIC;
    v_unit_cost_specific                       NUMERIC;
    v_stock_account                              UUID;
    v_accrual_account                              UUID;
    v_taxable_amount                                 NUMERIC;
    v_rate_sum                                         NUMERIC;
    v_has_batches                                        BOOLEAN;
    v_has_serials                                          BOOLEAN;
    v_voucher_lines                                        JSONB;
    v_voucher_result                                        RECORD;
    v_po_total_ordered                                        NUMERIC;
    v_po_total_received                                         NUMERIC;
    v_po_any_short                                                BOOLEAN;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_grn_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND grn_no = p_grn_no AND grn_date = p_grn_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'GRN % dated % not found', p_grn_no, p_grn_date;
    END IF;

    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'GRN % is % and cannot be approved again', p_grn_no, v_header.status;
    END IF;

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_grn_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'GRN', p_grn_date);

    -- 3. Lock referenced PO lines FOR UPDATE, one at a time in a fixed sort
    --    order, BEFORE any product-row lock below — fixed inter-type
    --    ordering rule from migration 036, prevents a deadlock class between
    --    concurrent GRNs touching overlapping POs and overlapping products in
    --    different orders. NOTE: a single "SELECT ... ORDER BY ... FOR UPDATE"
    --    statement does NOT guarantee locks are acquired in ORDER BY sequence
    --    in PostgreSQL — the sort and the row-locking are not reliably
    --    sequenced together. Locking must happen one row per statement,
    --    driven by a loop over an already-sorted key list, exactly like the
    --    per-line fn_post_stock_movement calls below already do correctly.
    FOR v_po_key IN
        SELECT DISTINCT gl.source_po_order_no, gl.source_po_order_date, gl.source_po_line_serial
        FROM rid_grn_lines gl
        WHERE gl.client_id = p_client_id AND gl.company_id = p_company_id
          AND gl.grn_no = p_grn_no AND gl.grn_date = p_grn_date
          AND gl.source_po_order_no IS NOT NULL
        ORDER BY gl.source_po_order_no, gl.source_po_order_date, gl.source_po_line_serial
    LOOP
        PERFORM 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = v_po_key.source_po_order_no AND order_date = v_po_key.source_po_order_date
          AND serial_no = v_po_key.source_po_line_serial
        FOR UPDATE;
    END LOOP;

    -- 4. Resolve currency codes needed for the exchange-rate bridge
    --    (rim_currencies.id UUID -> rim_currencies.currency_id TEXT code).
    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = p_company_id;
    SELECT currency_id INTO v_grn_ccy FROM rim_currencies WHERE id = v_header.grn_currency_id;

    v_voucher_lines := '[]'::jsonb;

    -- 5. Post stock (+ cost history) per line — sorted by product_id, the
    --    second half of the fixed lock-ordering rule — then accumulate this
    --    line's GL contributions.
    FOR v_line IN
        SELECT * FROM rid_grn_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = p_grn_no AND grn_date = p_grn_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT currency_id INTO v_product_ccy
        FROM rim_currencies WHERE id = (SELECT cost_currency_id FROM rim_products WHERE id = v_line.product_id);

        v_rate_to_base     := fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_base_ccy, p_grn_date);
        v_rate_to_specific := CASE WHEN v_product_ccy IS NULL THEN v_rate_to_base
                                    ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_product_ccy, p_grn_date) END;
        v_unit_cost_base     := v_line.rate * v_rate_to_base;
        v_unit_cost_specific := v_line.rate * v_rate_to_specific;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_grn_date, 'GRN', v_batch.base_qty,
                    v_unit_cost_base, v_unit_cost_specific,
                    v_batch.batch_no, v_batch.expiry_date, NULL,
                    'GRN', p_grn_no, p_grn_date, p_approved_by
                );
            END LOOP;
        ELSIF v_has_serials THEN
            -- One ledger row per unit — unifies serial tracking with the
            -- batch mechanism above instead of a separate audit-only table.
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_grn_date, 'GRN', 1,
                    v_unit_cost_base, v_unit_cost_specific,
                    NULL, NULL, v_serial_row.serial_no,
                    'GRN', p_grn_no, p_grn_date, p_approved_by
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_grn_date, 'GRN', v_line.base_qty,
                v_unit_cost_base, v_unit_cost_specific,
                NULL, NULL, NULL,
                'GRN', p_grn_no, p_grn_date, p_approved_by
            );
        END IF;

        -- GL: Stock Dr = net-of-tax item value + apportioned charge (see
        -- migration header comment for the full balance proof).
        v_taxable_amount := v_line.final_amount - v_line.tax_amount;
        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.', v_line.product_id);
        END IF;
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_stock_account, 'trans_nature', 'DR',
            'trans_amount', v_taxable_amount + v_line.charge_amount, 'trans_currency', v_base_ccy,
            'base_amount', v_taxable_amount + v_line.charge_amount, 'base_rate', 1,
            'local_amount', (v_taxable_amount + v_line.charge_amount) * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_taxable_amount + v_line.charge_amount, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        -- GL: Purchase Accrual Cr = tax-inclusive item value (never the
        -- supplier account directly, never with inv_bill_no — that
        -- linkage belongs to the future Purchase Invoice, not GRN).
        v_accrual_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'PURCHASE_ACCRUAL_ACCOUNT');
        IF v_accrual_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Purchase Accrual Account resolved for product %s.', v_line.product_id);
        END IF;
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_accrual_account, 'trans_nature', 'CR',
            'trans_amount', v_line.final_amount, 'trans_currency', v_base_ccy,
            'base_amount', v_line.final_amount, 'base_rate', 1,
            'local_amount', v_line.final_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_line.final_amount, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        -- GL: Input Tax Dr, apportioned across the tax group's member taxes
        -- by their effective rate weight, each to its own gl_input_account_id.
        IF v_line.tax_group_id IS NOT NULL AND v_line.tax_amount <> 0 THEN
            SELECT coalesce(sum(fn_get_active_tax_rate(tgm.tax_id, p_grn_date)), 0) INTO v_rate_sum
            FROM rim_tax_group_members tgm
            WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id AND tgm.tax_group_id = v_line.tax_group_id;

            IF v_rate_sum > 0 THEN
                FOR v_tax_row IN
                    SELECT tgm.tax_id, t.gl_input_account_id, fn_get_active_tax_rate(tgm.tax_id, p_grn_date) AS rate
                    FROM rim_tax_group_members tgm
                    JOIN rim_taxes t ON t.id = tgm.tax_id
                    WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id AND tgm.tax_group_id = v_line.tax_group_id
                LOOP
                    IF v_tax_row.gl_input_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Tax %s has no Input GL account configured.', v_tax_row.tax_id);
                    END IF;
                    v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'DR',
                        'trans_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum, 'trans_currency', v_base_ccy,
                        'base_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum, 'base_rate', 1,
                        'local_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum, 'party_currency', v_base_ccy, 'party_rate', 1
                    ));
                END LOOP;
            END IF;
        END IF;

        -- 6. Roll qty_received forward onto the referenced PO line, if any.
        IF v_line.source_po_order_no IS NOT NULL THEN
            UPDATE rid_purchase_order_lines SET
                qty_received = qty_received + v_line.base_qty,
                updated_at = now(), updated_by = p_approved_by
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = v_line.source_po_order_no AND order_date = v_line.source_po_order_date
              AND serial_no = v_line.source_po_line_serial;
        END IF;
    END LOOP;

    -- 7. Charges: Cr the charge's own account (tax-inclusive), Dr its tax
    --    (if taxable) to that tax's gl_input_account_id — the line-level
    --    charge_amount above already captured the NET charge inside Stock Dr.
    FOR v_charge IN
        SELECT * FROM rid_grn_charge_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = p_grn_no AND grn_date = p_grn_date AND is_deleted = false
    LOOP
        IF v_charge.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
        END IF;
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_charge.gl_account_id, 'trans_nature', 'CR',
            'trans_amount', v_charge.amount + v_charge.tax_amount, 'trans_currency', v_base_ccy,
            'base_amount', v_charge.amount + v_charge.tax_amount, 'base_rate', 1,
            'local_amount', (v_charge.amount + v_charge.tax_amount) * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_charge.amount + v_charge.tax_amount, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        IF v_charge.is_taxable AND v_charge.tax_id IS NOT NULL AND v_charge.tax_amount <> 0 THEN
            SELECT gl_input_account_id INTO v_charge_tax_account FROM rim_taxes WHERE id = v_charge.tax_id;
            IF v_charge_tax_account IS NULL THEN
                RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                    USING DETAIL = format('Charge tax %s has no Input GL account configured.', v_charge.tax_id);
            END IF;
            v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge_tax_account, 'trans_nature', 'DR',
                'trans_amount', v_charge.tax_amount, 'trans_currency', v_base_ccy,
                'base_amount', v_charge.tax_amount, 'base_rate', 1,
                'local_amount', v_charge.tax_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                'party_amount', v_charge.tax_amount, 'party_currency', v_base_ccy, 'party_rate', 1
            ));
        END IF;
    END LOOP;

    -- 8. One fn_post_voucher call for the whole GRN, not per line.
    SELECT * INTO v_voucher_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'JV', p_grn_date,
        v_voucher_lines, 'GRN', p_grn_no, p_grn_date, p_approved_by
    );

    -- 9. Recompute status of every PO referenced by this GRN, re-reading ALL
    --    of that PO's lines (not just the ones this GRN touched) for a
    --    consistent snapshot.
    FOR v_po_line IN
        SELECT DISTINCT source_po_order_no, source_po_order_date
        FROM rid_grn_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = p_grn_no AND grn_date = p_grn_date
          AND source_po_order_no IS NOT NULL
    LOOP
        SELECT coalesce(sum(base_qty), 0), coalesce(sum(qty_received), 0)
        INTO v_po_total_ordered, v_po_total_received
        FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = v_po_line.source_po_order_no AND order_date = v_po_line.source_po_order_date
          AND is_deleted = false;

        v_po_any_short := v_po_total_received < v_po_total_ordered;

        UPDATE rih_purchase_orders SET
            status = CASE WHEN v_po_any_short THEN 'PARTIALLY_RECEIVED' ELSE 'CLOSED' END,
            closed_by = CASE WHEN v_po_any_short THEN closed_by ELSE p_approved_by END,
            closed_at = CASE WHEN v_po_any_short THEN closed_at ELSE now() END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = v_po_line.source_po_order_no AND order_date = v_po_line.source_po_order_date
          AND status IN ('APPROVED', 'PARTIALLY_RECEIVED');
    END LOOP;

    -- 10. Mark GRN approved, store the GL traceability.
    UPDATE rih_grn_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_voucher_result.trans_no,
        posted_voucher_date = v_voucher_result.trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND grn_no = p_grn_no AND grn_date = p_grn_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_grn(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_approve_grn(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
