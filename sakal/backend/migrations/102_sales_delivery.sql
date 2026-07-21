-- ============================================================
-- Migration 102: Sales Delivery (Against Invoice)
-- ============================================================
-- Plan written first in sakal/docs/screens/sales_delivery.md — read
-- that for the full requirement doc. This migration builds it as
-- designed there, no scope changes.
--
-- Consumes any Sales Invoice left with stock_dispatch_mode='DEFERRED'
-- (089/090) — that mode never dispatches stock or posts a COS voucher
-- at invoice-approve time; this module is the deferred counterpart,
-- letting a warehouse (re)dispatch it later, in one or more separate
-- Delivery documents against the same invoice.
--
-- Deliberately NON-FINANCIAL, structurally not just by convention —
-- neither rih_sales_delivery_headers nor rid_sales_delivery_lines has
-- a rate/tax/amount column anywhere. The only monetary effect is a
-- COS (Cost of Sales) voucher: DR Cost of Sales / CR Stock, at the
-- CURRENT rim_product_location.cost_price (not historical — this is a
-- fresh outward movement, unlike Sales Return's reversal, which must
-- stay symmetric with what the original invoice posted). COS is
-- REUSED as-is (already exists, JOURNAL nature, shared by Sales
-- Invoice and Sales Return) — no new posting code, since this is the
-- identical entry Sales Invoice's own IMMEDIATE mode already knows how
-- to make, just deferred. SDEL is a new voucher type, numbering ONLY.
--
-- One delivery references exactly ONE invoice (mirrors Sales Return's
-- single-invoice design) — but that same invoice can be the source of
-- many separate Sales Delivery documents over time, each dispatching
-- some remaining portion, until every line is fully delivered.
-- Enforced via a cumulative cap check at Approve time — but UNLIKE
-- Sales Return's live SUM() pattern, this uses a denormalized
-- delivered_qty counter on rid_sales_invoice_lines (mirrors the
-- already-existing, previously-unwired rid_sales_order_lines.
-- delivered_qty naming precedent from 087), incremented under the
-- SAME invoice-row lock that serializes concurrent approvals — chosen
-- because the Delivery picker modal needs a fast "which invoices still
-- have pending qty" query across many invoices, which a live per-check
-- SUM doesn't serve well through PostgREST. Safe specifically because
-- the increment happens inside the same locked transaction that
-- validates the cap — no window for drift. See v_sales_invoice_
-- delivery_status below, which also drives a new read-only badge on
-- the Sales Invoice screens (Flutter-only change, no schema here).
--
-- Batch/serial: NO source-document candidates to scope against — a
-- DEFERRED invoice never stages rid_transaction_line_batches/
-- rid_transaction_line_serials rows at all (fn_save_sales_invoice
-- skips that staging entirely when dispatch is deferred). Candidates
-- come from LIVE stock instead (v_batch_stock_balance/
-- v_serial_stock_status), same as Sales Invoice's own DIRECT-mode
-- dispatch — reuses the existing generic batches/serials tables with
-- source_doc_type='SALES_DELIVERY', staged at Save time, read back at
-- Approve time, same shape as every other module.
--
-- Traceability (req: "clear relation in stock lines, finance lines and
-- delivery lines for future amendment/reversal features"): the COS
-- voucher's lines are tagged source_line_type='COGS'/'STOCK',
-- source_line_no=<delivery line serial_no>; the voucher header is
-- tagged source_doc_type='SALES_DELIVERY'/source_doc_no/date; stock
-- ledger rows carry the same source_doc tag via fn_post_stock_movement.
-- Nothing consumes this yet — built in now anyway, same "lay the
-- traceability groundwork even before the amendment feature exists"
-- precedent as every other module's source_line_type tagging.
--
-- Offline-first: fn_save_sales_delivery/fn_approve_sales_delivery are
-- plain synchronous RPCs with no awareness of offline queuing — that
-- lives entirely in the Flutter layer (SyncEngine.enqueue for Save,
-- Approve always online-only). No schema impact here.
-- ============================================================


-- ── New voucher type: SDEL (numbering only) ─────────────────────────────
-- COS is reused as-is for GL posting — no new posting code needed.
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('SDEL', 'Sales Delivery', 'SALES', NULL, 'YEARLY', 'SDEL/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── ril_stock_ledger: add SALES_DELIVERY to BOTH CHECK constraints ──────
-- Two independent constraints (036/069/070) — both must be updated
-- together for any new trans_type, per the documented lesson from
-- Material Issue's own two-migration retrofit (069+070). Kept distinct
-- from SALES_INVOICE (not reused) so stock-ledger reporting can tell
-- "dispatched at invoice time" apart from "dispatched later via
-- Delivery" — source_doc_type alone isn't enough since trans_type is a
-- separate, independently-reported column.
ALTER TABLE ril_stock_ledger DROP CONSTRAINT chk_stock_ledger_direction;
ALTER TABLE ril_stock_ledger ADD CONSTRAINT chk_stock_ledger_direction CHECK (
    (trans_type IN ('GRN', 'TRANSFER_IN', 'ADJUSTMENT_IN', 'OPENING_STOCK', 'SALES_RETURN') AND qty_change > 0)
    OR
    (trans_type IN ('GRN_REVERSAL', 'PURCHASE_RETURN', 'SALES_INVOICE', 'TRANSFER_OUT', 'ADJUSTMENT_OUT', 'MATERIAL_ISSUE', 'SALES_DELIVERY') AND qty_change < 0)
);

ALTER TABLE ril_stock_ledger DROP CONSTRAINT ril_stock_ledger_trans_type_check;
ALTER TABLE ril_stock_ledger ADD CONSTRAINT ril_stock_ledger_trans_type_check
    CHECK (trans_type IN (
        'GRN','GRN_REVERSAL','PURCHASE_RETURN',
        'SALES_INVOICE','SALES_RETURN',
        'TRANSFER_OUT','TRANSFER_IN',
        'ADJUSTMENT_IN','ADJUSTMENT_OUT','OPENING_STOCK',
        'MATERIAL_ISSUE','SALES_DELIVERY'
    ));


-- ── rid_sales_invoice_lines.delivered_qty ────────────────────────────────
ALTER TABLE rid_sales_invoice_lines ADD COLUMN IF NOT EXISTS delivered_qty NUMERIC(18,4) NOT NULL DEFAULT 0;


-- ============================================================
-- rih_sales_delivery_headers
-- ============================================================
CREATE TABLE IF NOT EXISTS rih_sales_delivery_headers (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL REFERENCES ric_clients(id),
    company_id             UUID          NOT NULL REFERENCES ric_companies(id),
    location_id            UUID          NOT NULL REFERENCES ric_locations(id),
    delivery_no            TEXT          NOT NULL,
    delivery_date          DATE          NOT NULL,
    invoice_no             TEXT          NOT NULL,
    invoice_date           DATE          NOT NULL,
    customer_id            UUID          NOT NULL REFERENCES rim_accounts(id),
    -- Ship-to: SNAPSHOT columns, drive printing/reporting — never a
    -- live read of rim_customer_delivery_locations at print time.
    -- ship_to_location_id is provenance only (which saved location
    -- this was copied from, if any), nullable, never re-read live.
    ship_to_location_id       UUID       REFERENCES rim_customer_delivery_locations(id),
    ship_to_location_name     TEXT,
    ship_to_address_line1     TEXT,
    ship_to_address_line2     TEXT,
    ship_to_city_id           UUID       REFERENCES rim_cities(id),
    ship_to_contact_person    TEXT,
    ship_to_contact_phone     TEXT,
    -- Free-text field the dispatching staff/warehouse types, printed
    -- on the delivery slip — distinct from signatures.authorised_by
    -- (the internal approver), which is a system user.
    received_by_name       TEXT,
    reason                 TEXT,   -- free text label only, never branches logic
    remarks                TEXT,
    status                 TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by            UUID          REFERENCES rim_users(id),
    approved_at            TIMESTAMPTZ,
    cos_voucher_no         TEXT,
    cos_voucher_date       DATE,
    is_deleted             BOOLEAN       NOT NULL DEFAULT false,
    created_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by             UUID          REFERENCES rim_users(id),
    updated_at             TIMESTAMPTZ,
    updated_by             UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rih_sales_delivery_headers UNIQUE (client_id, company_id, delivery_no, delivery_date)
);

CREATE INDEX IF NOT EXISTS idx_rih_sd_tenant   ON rih_sales_delivery_headers (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rih_sd_invoice  ON rih_sales_delivery_headers (client_id, company_id, invoice_no, invoice_date);
CREATE INDEX IF NOT EXISTS idx_rih_sd_customer ON rih_sales_delivery_headers (customer_id);
CREATE INDEX IF NOT EXISTS idx_rih_sd_status   ON rih_sales_delivery_headers (client_id, company_id, location_id, status);
CREATE INDEX IF NOT EXISTS idx_rih_sd_date     ON rih_sales_delivery_headers (client_id, company_id, delivery_date DESC);

DROP TRIGGER IF EXISTS trg_rih_sales_delivery_headers_updated_at ON rih_sales_delivery_headers;
CREATE TRIGGER trg_rih_sales_delivery_headers_updated_at
    BEFORE UPDATE ON rih_sales_delivery_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_sales_delivery_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sales_delivery_headers" ON rih_sales_delivery_headers;
CREATE POLICY "auth_rw_sales_delivery_headers" ON rih_sales_delivery_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_sales_delivery_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_sales_delivery_headers TO authenticated;


-- ============================================================
-- rid_sales_delivery_lines — no financial columns at all
-- ============================================================
CREATE TABLE IF NOT EXISTS rid_sales_delivery_lines (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL,
    company_id             UUID          NOT NULL,
    delivery_no            TEXT          NOT NULL,
    delivery_date          DATE          NOT NULL,
    serial_no              INTEGER       NOT NULL,
    invoice_line_serial    INTEGER       NOT NULL,
    product_id             UUID          NOT NULL REFERENCES rim_products(id),
    -- Carried forward from the invoice line's own saved barcode column
    -- — consolidation document, never freshly scanned, no showBarcode
    -- gating needed (no scan UI here to gate).
    barcode                TEXT,
    uom_id                 UUID,
    uom_conversion_factor  NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack               NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose               NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty               NUMERIC(18,4) NOT NULL DEFAULT 0,   -- the DELIVERY quantity
    is_deleted              BOOLEAN      NOT NULL DEFAULT false,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by              UUID         REFERENCES rim_users(id),
    updated_at               TIMESTAMPTZ,
    updated_by                UUID       REFERENCES rim_users(id),
    CONSTRAINT uq_rid_sd_lines UNIQUE (client_id, company_id, delivery_no, delivery_date, serial_no),
    CONSTRAINT rid_sd_lines_header_fk
        FOREIGN KEY (client_id, company_id, delivery_no, delivery_date)
        REFERENCES  rih_sales_delivery_headers (client_id, company_id, delivery_no, delivery_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_sd_lines_header  ON rid_sales_delivery_lines (client_id, company_id, delivery_no, delivery_date);
CREATE INDEX IF NOT EXISTS idx_rid_sd_lines_product ON rid_sales_delivery_lines (product_id);

ALTER TABLE rid_sales_delivery_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sd_lines" ON rid_sales_delivery_lines;
CREATE POLICY "auth_rw_sd_lines" ON rid_sales_delivery_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_delivery_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_delivery_lines TO authenticated;


-- ============================================================
-- v_sales_invoice_delivery_status — pending-delivery rollup per invoice
-- ============================================================
-- Serves both the Delivery picker modal (filter delivery_status IN
-- ('PENDING','PARTIALLY_DELIVERED')) and the new Sales Invoice screens'
-- read-only status badge. IMMEDIATE-dispatch invoices never appear
-- here — correct, they were already fully dispatched at invoice-
-- approve time and have nothing pending.
CREATE OR REPLACE VIEW v_sales_invoice_delivery_status AS
SELECT h.client_id, h.company_id, h.invoice_no, h.invoice_date, h.location_id, h.customer_id,
       sum(l.base_qty) AS total_qty,
       sum(l.delivered_qty) AS delivered_qty,
       sum(l.base_qty - l.delivered_qty) AS pending_qty,
       CASE
           WHEN sum(l.base_qty - l.delivered_qty) <= 0 THEN 'DELIVERED'
           WHEN sum(l.delivered_qty) > 0 THEN 'PARTIALLY_DELIVERED'
           ELSE 'PENDING'
       END AS delivery_status
FROM rih_sales_invoices h
JOIN rid_sales_invoice_lines l
  ON l.client_id = h.client_id AND l.company_id = h.company_id
 AND l.invoice_no = h.invoice_no AND l.invoice_date = h.invoice_date
 AND l.is_deleted = false
WHERE h.stock_dispatch_mode = 'DEFERRED' AND h.status = 'APPROVED' AND h.is_deleted = false
GROUP BY h.client_id, h.company_id, h.invoice_no, h.invoice_date, h.location_id, h.customer_id;

GRANT SELECT ON v_sales_invoice_delivery_status TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_sales_delivery — DRAFT-only, mirrors fn_save_sales_return's shape
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_sales_delivery(
    p_header    JSONB,  -- {client_id, company_id, delivery_no, delivery_date, invoice_no, invoice_date, ship_to_location_id, ship_to_location_name, ship_to_address_line1, ship_to_address_line2, ship_to_city_id, ship_to_contact_person, ship_to_contact_phone, received_by_name, reason, remarks}
    p_lines     JSONB,  -- [{serial_no, invoice_line_serial, product_id, barcode, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty}, ...]
    p_batches   JSONB,  -- [{line_serial, batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials   JSONB,  -- [{line_serial, serial_no}, ...]
    p_transport JSONB,  -- {vehicle_no, transporter_name, driver_name, driver_phone, remarks} or NULL
    p_user_id   UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     UUID;
    v_company_id    UUID;
    v_delivery_no   TEXT;
    v_delivery_date DATE;
    v_invoice_no    TEXT;
    v_invoice_date  DATE;
    v_old_status    TEXT;
    v_is_new        BOOLEAN;
    v_invoice       rih_sales_invoices%ROWTYPE;
    v_line          JSONB;
    v_batch         JSONB;
    v_line_qty      NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id     := (p_header->>'client_id')::uuid;
    v_company_id    := (p_header->>'company_id')::uuid;
    v_delivery_no   := nullif(trim(p_header->>'delivery_no'), '');
    v_delivery_date := (p_header->>'delivery_date')::date;
    v_invoice_no    := p_header->>'invoice_no';
    v_invoice_date  := (p_header->>'invoice_date')::date;
    v_is_new        := v_delivery_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Delivery.';
    END IF;

    -- Every line must have a positive delivery quantity — zero-qty
    -- lines never reach the database, defense in depth alongside the
    -- Flutter-side guard that already prevents this.
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        IF coalesce((v_line->>'base_qty')::numeric, 0) <= 0 THEN
            RAISE EXCEPTION 'DELIVERY_QTY_ZERO_NOT_ALLOWED'
                USING DETAIL = format('Line %s has zero (or missing) delivery quantity — every line must deliver a positive quantity.', v_line->>'serial_no');
        END IF;
    END LOOP;

    -- Lock and validate the source invoice — must exist, be APPROVED,
    -- and still have deferred stock. location_id/customer_id are
    -- inherited from HERE, server-side, never trusted from the
    -- client — nothing left for the client to legitimately choose
    -- about a document already fixed by an approved invoice.
    SELECT * INTO v_invoice FROM rih_sales_invoices
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND invoice_no = v_invoice_no AND invoice_date = v_invoice_date
      AND is_deleted = false
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % not found.', v_invoice_no;
    END IF;
    IF v_invoice.status != 'APPROVED' THEN
        RAISE EXCEPTION 'Sales Invoice % is % — only APPROVED invoices can be delivered against.', v_invoice.invoice_no, v_invoice.status;
    END IF;
    IF v_invoice.stock_dispatch_mode != 'DEFERRED' THEN
        RAISE EXCEPTION 'INVOICE_NOT_ELIGIBLE_FOR_DELIVERY'
            USING DETAIL = format('Invoice %s already dispatched stock at invoice-approve time (stock_dispatch_mode=IMMEDIATE) — nothing left to deliver.', v_invoice.invoice_no);
    END IF;

    IF v_delivery_date < v_invoice.invoice_date THEN
        RAISE EXCEPTION 'DELIVERY_DATE_BEFORE_INVOICE_DATE'
            USING DETAIL = format('Delivery date %s cannot be earlier than the invoice date %s.', v_delivery_date, v_invoice.invoice_date);
    END IF;

    IF v_is_new THEN
        v_delivery_no := fn_next_trans_no(v_client_id, v_company_id, v_invoice.location_id, 'SDEL');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_sales_delivery_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND delivery_no = v_delivery_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Sales Delivery % is % and cannot be edited.', v_delivery_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = v_delivery_no AND source_doc_date = v_delivery_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = v_delivery_no AND source_doc_date = v_delivery_date;
        DELETE FROM rid_sales_delivery_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND delivery_no = v_delivery_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_sales_delivery_headers (
            client_id, company_id, location_id, delivery_no, delivery_date,
            invoice_no, invoice_date, customer_id,
            ship_to_location_id, ship_to_location_name, ship_to_address_line1, ship_to_address_line2,
            ship_to_city_id, ship_to_contact_person, ship_to_contact_phone,
            received_by_name, reason, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_invoice.location_id, v_delivery_no, v_delivery_date,
            v_invoice.invoice_no, v_invoice.invoice_date, v_invoice.customer_id,
            nullif(p_header->>'ship_to_location_id', '')::uuid, nullif(p_header->>'ship_to_location_name', ''),
            nullif(p_header->>'ship_to_address_line1', ''), nullif(p_header->>'ship_to_address_line2', ''),
            nullif(p_header->>'ship_to_city_id', '')::uuid,
            nullif(p_header->>'ship_to_contact_person', ''), nullif(p_header->>'ship_to_contact_phone', ''),
            nullif(p_header->>'received_by_name', ''), nullif(p_header->>'reason', ''), nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_sales_delivery_headers SET
            location_id            = v_invoice.location_id,
            delivery_date          = v_delivery_date,
            invoice_no             = v_invoice.invoice_no,
            invoice_date           = v_invoice.invoice_date,
            customer_id            = v_invoice.customer_id,
            ship_to_location_id    = nullif(p_header->>'ship_to_location_id', '')::uuid,
            ship_to_location_name  = nullif(p_header->>'ship_to_location_name', ''),
            ship_to_address_line1  = nullif(p_header->>'ship_to_address_line1', ''),
            ship_to_address_line2  = nullif(p_header->>'ship_to_address_line2', ''),
            ship_to_city_id        = nullif(p_header->>'ship_to_city_id', '')::uuid,
            ship_to_contact_person = nullif(p_header->>'ship_to_contact_person', ''),
            ship_to_contact_phone  = nullif(p_header->>'ship_to_contact_phone', ''),
            received_by_name       = nullif(p_header->>'received_by_name', ''),
            reason                 = nullif(p_header->>'reason', ''),
            remarks                = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND delivery_no = v_delivery_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_sales_delivery_lines (
            client_id, company_id, delivery_no, delivery_date, serial_no,
            invoice_line_serial, product_id, barcode,
            uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_delivery_no, v_delivery_date, (v_line->>'serial_no')::integer,
            (v_line->>'invoice_line_serial')::integer, (v_line->>'product_id')::uuid, nullif(v_line->>'barcode', ''),
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            p_user_id, p_user_id
        );

        -- Batch children for this line, if any — same BATCH_QTY_MISMATCH
        -- rule as every other module.
        v_line_qty := coalesce((v_line->>'base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'SALES_DELIVERY', v_delivery_no, v_delivery_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date,
                (nullif(v_batch->>'manufacturing_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the delivery quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'SALES_DELIVERY', v_delivery_no, v_delivery_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    -- Optional Transport Details (req #19) — upsert into the generic
    -- table, same transaction as the rest of the document.
    IF p_transport IS NOT NULL THEN
        INSERT INTO rid_transport_details (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date,
            vehicle_no, transporter_name, driver_name, driver_phone, remarks, created_by
        ) VALUES (
            v_client_id, v_company_id, 'SALES_DELIVERY', v_delivery_no, v_delivery_date,
            nullif(p_transport->>'vehicle_no', ''), nullif(p_transport->>'transporter_name', ''),
            nullif(p_transport->>'driver_name', ''), nullif(p_transport->>'driver_phone', ''),
            nullif(p_transport->>'remarks', ''), p_user_id
        )
        ON CONFLICT (client_id, company_id, source_doc_type, source_doc_no, source_doc_date)
        DO UPDATE SET
            vehicle_no       = excluded.vehicle_no,
            transporter_name = excluded.transporter_name,
            driver_name      = excluded.driver_name,
            driver_phone     = excluded.driver_phone,
            remarks          = excluded.remarks,
            updated_at = now(), updated_by = p_user_id;
    END IF;

    RETURN v_delivery_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_sales_delivery(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_sales_delivery
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_sales_delivery(
    p_client_id    UUID,
    p_company_id   UUID,
    p_delivery_no  TEXT,
    p_delivery_date DATE,
    p_approved_by  UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_sales_delivery_headers%ROWTYPE;
    v_invoice            rih_sales_invoices%ROWTYPE;
    v_invoice_line       rid_sales_invoice_lines%ROWTYPE;
    v_base_ccy           TEXT;
    v_local_ccy          TEXT;
    v_base_to_local_rate NUMERIC;
    v_line               RECORD;
    v_stock_account      UUID;
    v_cos_account        UUID;
    v_unit_cost          NUMERIC;
    v_line_cost_total    NUMERIC;
    v_cos_lines          JSONB := '[]'::jsonb;
    v_cos_voucher_no     TEXT;
    v_cos_voucher_date   DATE;
    v_batch              rid_transaction_line_batches%ROWTYPE;
    v_serial_row         rid_transaction_line_serials%ROWTYPE;
    v_has_batches        BOOLEAN;
    v_has_serials        BOOLEAN;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_sales_delivery_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND delivery_no = p_delivery_no AND delivery_date = p_delivery_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Delivery % dated % not found', p_delivery_no, p_delivery_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Delivery % is % and cannot be approved again', p_delivery_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks. Req: future-date lock
    --    is a HARD rule, not a company-configurable opt-in — mirrors
    --    Material Issue's belt-and-suspenders pattern (both the soft
    --    config check AND the unconditional guard), not Sales Return's
    --    config-only check.
    PERFORM fn_check_period_open(p_company_id, p_delivery_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_DELIVERY', p_delivery_date);

    IF p_delivery_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Delivery date %s is in the future — a Sales Delivery cannot be dated ahead of today.', p_delivery_date);
    END IF;

    -- 3. Lock the source invoice — this single lock is what serializes
    --    every concurrent Delivery-approval against this invoice,
    --    regardless of which draft Delivery document they come from.
    SELECT * INTO v_invoice FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % not found', v_header.invoice_no;
    END IF;

    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_delivery_date);

    -- 4. Per line: cap check (fresh, under the invoice lock above) +
    --    stock dispatch + COS lines.
    FOR v_line IN
        SELECT * FROM rid_sales_delivery_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND delivery_no = p_delivery_no AND delivery_date = p_delivery_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT * INTO v_invoice_line
        FROM rid_sales_invoice_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND serial_no = v_line.invoice_line_serial
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'INVOICE_LINE_NOT_FOUND'
                USING DETAIL = format('Invoice %s has no line %s.', v_header.invoice_no, v_line.invoice_line_serial);
        END IF;

        IF v_invoice_line.delivered_qty + v_line.base_qty > v_invoice_line.base_qty THEN
            RAISE EXCEPTION 'DELIVERY_QTY_EXCEEDS_PENDING'
                USING DETAIL = format(
                    'Invoice %s line %s: already delivered %s of %s invoiced, this delivery adds %s more.',
                    v_header.invoice_no, v_line.invoice_line_serial,
                    v_invoice_line.delivered_qty, v_invoice_line.base_qty, v_line.base_qty);
        END IF;

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

        -- Current moving-average cost — a fresh outward movement, not a
        -- reversal, so unlike Sales Return there is no historical cost
        -- to stay symmetric with. Same lock pattern fn_approve_sales_
        -- invoice's own IMMEDIATE-mode block and fn_approve_material_
        -- issue already use.
        SELECT cost_price INTO v_unit_cost
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;
        v_unit_cost := coalesce(v_unit_cost, 0);

        v_has_batches := EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
              AND line_serial = v_line.serial_no
        );
        v_has_serials := EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
              AND line_serial = v_line.serial_no
        );

        v_line_cost_total := 0;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_delivery_date, 'SALES_DELIVERY', -v_batch.base_qty,
                    NULL, NULL, v_batch.batch_no, NULL, NULL,
                    'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
                );
                v_line_cost_total := v_line_cost_total + v_batch.base_qty * v_unit_cost;
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_delivery_date, 'SALES_DELIVERY', -1,
                    NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                    'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
                );
                v_line_cost_total := v_line_cost_total + v_unit_cost;
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_delivery_date, 'SALES_DELIVERY', -v_line.base_qty,
                NULL, NULL, NULL, NULL, NULL,
                'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
            );
            v_line_cost_total := v_line.base_qty * v_unit_cost;
        END IF;

        -- DR Cost of Sales / CR Stock — same purely-internal-voucher
        -- convention as every prior COS/MIC-style entry: base currency
        -- throughout, party self-referential.
        v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_cos_account, 'trans_nature', 'DR',
            'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
            'base_amount', v_line_cost_total, 'base_rate', 1,
            'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
            'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
            'source_line_type', 'COGS', 'source_line_no', v_line.serial_no
        ));
        v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_stock_account, 'trans_nature', 'CR',
            'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
            'base_amount', v_line_cost_total, 'base_rate', 1,
            'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
            'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
            'source_line_type', 'STOCK', 'source_line_no', v_line.serial_no
        ));

        -- Safe increment — under the invoice lock held since step 3, so
        -- there is no window for drift between the cap check above and
        -- this write.
        UPDATE rid_sales_invoice_lines SET delivered_qty = delivered_qty + v_line.base_qty
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND serial_no = v_line.invoice_line_serial;
    END LOOP;

    SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'COS', p_delivery_date,
        v_cos_lines, 'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
    );

    -- 5. Mark the delivery approved.
    UPDATE rih_sales_delivery_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        cos_voucher_no   = v_cos_voucher_no,
        cos_voucher_date = v_cos_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_delivery(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── Menu seeding for existing companies ──────────────────────────────────
-- SL-DEL is a genuinely new feature (no prior placeholder existed —
-- confirmed against ric_master_menus/fn_seed_client_modules.sql, per
-- CLAUDE.md's own "always check for an existing placeholder first"
-- rule). Seated right after SL-RET, shifting SL-RCP down one — same
-- "shift down to seat the new feature in flow order" pattern migration
-- 088 used to seat SL-INR right after SL-INV.
--
-- SL-INR ("Sales Invoice - Manager Review") is REPURPOSED into the new
-- unified Pending Approvals screen (see docs/screens/sales_delivery.md
-- §5) — same feature_code kept (no menu-permission re-grant needed for
-- existing users), feature_name/screen_name updated to point at the
-- new screen that now also shows Sales Return/Sales Delivery DRAFTs.
UPDATE ric_master_menus
SET serial_no = 6
WHERE feature_code = 'SL-RCP';

UPDATE ric_master_menus
SET feature_name = 'Pending Approvals',
    screen_name  = '/sales/pending-approvals'
WHERE feature_code = 'SL-INR';

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, 'SL-DEL', 'Sales Delivery', '/sales/deliveries',
       5, 'SL-TXN', 'Transactions', 1, true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'SL'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
