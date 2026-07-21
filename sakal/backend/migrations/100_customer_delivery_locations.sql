-- ============================================================
-- Migration 100: Customer Delivery Locations
-- ============================================================
-- A customer can have multiple physical delivery/ship-to addresses,
-- distinct from their billing/registered address on rim_accounts
-- itself (address_line1/2, city_id — used for invoicing/statements).
-- Nothing like this existed before: Sales Order's ship_to/bill_to
-- (087) are bare free-text columns with no master behind them.
--
-- Modeled on the common mid-market ERP "shipping address list"
-- pattern (Tally/Busy/Zoho) rather than Odoo's heavier hierarchical
-- child-contact model or SAP's separate Ship-To Party partner
-- function — a flat one-to-many table keyed to rim_accounts fits
-- this schema's existing "snapshot party details onto documents"
-- convention (Sales Order's own party_name/phone/address snapshot
-- for prospects) without introducing a new abstraction.
--
-- Consumed first by Sales Delivery (migration 102): a delivery
-- copies one of these rows into its own header as a point-in-time
-- SNAPSHOT (rih_sales_delivery_headers.ship_to_*) — never a live FK
-- read at print/report time — so a later edit to the customer's
-- saved address never silently rewrites history on an already-
-- approved delivery.
-- ============================================================

CREATE TABLE IF NOT EXISTS rim_customer_delivery_locations (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID          NOT NULL REFERENCES ric_clients(id),
    company_id      UUID          NOT NULL REFERENCES ric_companies(id),
    customer_id     UUID          NOT NULL REFERENCES rim_accounts(id),
    location_name   TEXT          NOT NULL,   -- e.g. "Main Warehouse - Kinshasa"
    address_line1   TEXT,
    address_line2   TEXT,
    city_id         UUID          REFERENCES rim_cities(id),
    contact_person  TEXT,
    contact_phone   TEXT,
    is_default      BOOLEAN       NOT NULL DEFAULT false,
    is_active       BOOLEAN       NOT NULL DEFAULT true,
    is_deleted      BOOLEAN       NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by      UUID          REFERENCES rim_users(id),
    updated_at      TIMESTAMPTZ,
    updated_by      UUID          REFERENCES rim_users(id)
);

-- Partial (not plain) UNIQUE — at most one is_default=true per customer
-- among non-deleted rows; a soft-deleted default doesn't block a new one.
CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_delivery_locations_default
    ON rim_customer_delivery_locations (client_id, company_id, customer_id)
    WHERE is_default = true AND is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_customer_delivery_locations_customer
    ON rim_customer_delivery_locations (client_id, company_id, customer_id)
    WHERE is_deleted = false;

DROP TRIGGER IF EXISTS trg_rim_customer_delivery_locations_updated_at ON rim_customer_delivery_locations;
CREATE TRIGGER trg_rim_customer_delivery_locations_updated_at
    BEFORE UPDATE ON rim_customer_delivery_locations
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rim_customer_delivery_locations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_customer_delivery_locations" ON rim_customer_delivery_locations;
CREATE POLICY "auth_rw_customer_delivery_locations" ON rim_customer_delivery_locations
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_customer_delivery_locations FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_customer_delivery_locations TO authenticated;
