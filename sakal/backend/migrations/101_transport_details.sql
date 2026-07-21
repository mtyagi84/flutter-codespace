-- ============================================================
-- Migration 101: Transport Details (generic)
-- ============================================================
-- Vehicle/transporter/driver capture — confirmed via repo-wide search
-- that nothing like this exists anywhere in this schema today. Built
-- generic from the start rather than as a Sales-Delivery-only table,
-- same source_doc_type/source_doc_no/source_doc_date keying idiom as
-- rid_transaction_line_batches (038_grn.sql) — a future GRN/Stock
-- Transfer/Purchase Return module gets vehicle capture for free by
-- reusing this same table with its own source_doc_type tag, no schema
-- change needed.
--
-- v1 scope: ONE vehicle per document (UNIQUE on the source-doc key).
-- A future "Delivery Run" concept (many deliveries under one vehicle
-- trip/manifest, mirroring Odoo's wave transfers / SAP's shipment
-- grouping) would be a different, separate table — not building that
-- here, flagged as a deferred idea in docs/screens/sales_delivery.md.
--
-- All fields optional — a document can be saved with none of them
-- filled; this table is purely additive convenience data, never
-- validated or required by any fn_approve_* function.
-- ============================================================

CREATE TABLE IF NOT EXISTS rid_transport_details (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        UUID          NOT NULL REFERENCES ric_clients(id),
    company_id       UUID          NOT NULL REFERENCES ric_companies(id),
    source_doc_type  TEXT          NOT NULL,
    source_doc_no    TEXT          NOT NULL,
    source_doc_date  DATE          NOT NULL,
    vehicle_no       TEXT,
    transporter_name TEXT,
    driver_name      TEXT,
    driver_phone     TEXT,
    remarks          TEXT,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by       UUID          REFERENCES rim_users(id),
    updated_at       TIMESTAMPTZ,
    updated_by       UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rid_transport_details UNIQUE (client_id, company_id, source_doc_type, source_doc_no, source_doc_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_transport_details_doc
    ON rid_transport_details (client_id, company_id, source_doc_type, source_doc_no, source_doc_date);

DROP TRIGGER IF EXISTS trg_rid_transport_details_updated_at ON rid_transport_details;
CREATE TRIGGER trg_rid_transport_details_updated_at
    BEFORE UPDATE ON rid_transport_details
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rid_transport_details ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_transport_details" ON rid_transport_details;
CREATE POLICY "auth_rw_transport_details" ON rid_transport_details
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_transport_details FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_transport_details TO authenticated;
