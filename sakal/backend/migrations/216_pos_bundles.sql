-- ============================================================================
-- Migration 216: product bundles — schema + PREASSEMBLED mode (usable today
-- with zero change to fn_approve_sales_invoice)
-- ============================================================================
-- Per docs/pos/01_data_model.md §6. A bundle is itself a row in rim_products
-- (its own barcode/price/tax group, scannable like any product) — this
-- migration only adds the bundle-specific metadata tables.
--
-- Three modes, two shipped here, one deliberately NOT wired yet:
--   PREASSEMBLED — the bundle product carries REAL stock
--   (rim_product_location.current_stock), built by a separate assembly
--   transaction using the EXISTING Stock Adjustment screen/engine (a '+'
--   line on the bundle product, a '-' line on each component, both already
--   fully supported — no new assembly screen needed for v1). A POS sale of
--   it is then just an ordinary stocked-product sale: fn_approve_sales_invoice
--   needs no change at all, since the bundle product behaves exactly like
--   any other product it already knows how to dispatch.
--   COMMERCIAL — components auto-consumed from stock at sale time, no
--   separate bundle stock. NOT wired in this migration: doing this correctly
--   needs fn_approve_sales_invoice's stock-dispatch loop to detect a bundle
--   line and loop over its components instead of the line's own product_id
--   — a real, non-trivial change to that function's already-tested body.
--   Schema below is ready for it (rid_sales_invoice_line_bundle_components);
--   the engine change is deliberately deferred to its own future migration
--   rather than rushed alongside everything else built this session.
--   DYNAMIC_MIX — realized entirely through the scheme engine
--   (MIX_AND_MATCH, migration 212) — no separate code path, per design.
-- ============================================================================

CREATE TABLE IF NOT EXISTS rim_product_bundles (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID NOT NULL REFERENCES ric_clients(id),
    company_id        UUID NOT NULL REFERENCES ric_companies(id),
    bundle_product_id UUID NOT NULL REFERENCES rim_products(id),
    bundle_mode       TEXT NOT NULL CHECK (bundle_mode IN ('COMMERCIAL','PREASSEMBLED','DYNAMIC_MIX')),
    is_active         BOOLEAN NOT NULL DEFAULT true,
    is_deleted        BOOLEAN NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_bundle_product UNIQUE (bundle_product_id)
);

CREATE TABLE IF NOT EXISTS rim_bundle_components (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                   UUID NOT NULL REFERENCES ric_clients(id),
    company_id                  UUID NOT NULL REFERENCES ric_companies(id),
    bundle_id                   UUID NOT NULL REFERENCES rim_product_bundles(id),
    component_product_id        UUID NOT NULL REFERENCES rim_products(id),
    component_qty               NUMERIC(18,4) NOT NULL DEFAULT 1,
    component_rate_contribution NUMERIC(18,4),
    is_deleted                  BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_bundle_components_bundle ON rim_bundle_components (bundle_id) WHERE is_deleted = false;

-- Traceability shadow table for a future COMMERCIAL-mode explosion — mirrors
-- how rid_transaction_line_batches already shadows a line without changing
-- what the line itself displays. Created now (schema-ready) even though
-- nothing writes to it yet, so the later engine change is additive-only.
CREATE TABLE IF NOT EXISTS rid_sales_invoice_line_bundle_components (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID NOT NULL REFERENCES ric_clients(id),
    company_id             UUID NOT NULL REFERENCES ric_companies(id),
    invoice_no             TEXT NOT NULL,
    invoice_date           DATE NOT NULL,
    line_serial            INTEGER NOT NULL,
    component_product_id   UUID NOT NULL REFERENCES rim_products(id),
    component_qty          NUMERIC(18,4) NOT NULL,
    component_cost_price   NUMERIC(18,4)
);
CREATE INDEX IF NOT EXISTS idx_si_bundle_components_invoice ON rid_sales_invoice_line_bundle_components (client_id, company_id, invoice_no, invoice_date);

DROP POLICY IF EXISTS "auth_rw_rim_product_bundles" ON rim_product_bundles;
CREATE POLICY "auth_rw_rim_product_bundles" ON rim_product_bundles
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rim_product_bundles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rim_product_bundles FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_product_bundles TO authenticated;

DROP POLICY IF EXISTS "auth_rw_rim_bundle_components" ON rim_bundle_components;
CREATE POLICY "auth_rw_rim_bundle_components" ON rim_bundle_components
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rim_bundle_components ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rim_bundle_components FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_bundle_components TO authenticated;

DROP POLICY IF EXISTS "auth_rw_rid_si_line_bundle_components" ON rid_sales_invoice_line_bundle_components;
CREATE POLICY "auth_rw_rid_si_line_bundle_components" ON rid_sales_invoice_line_bundle_components
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rid_sales_invoice_line_bundle_components ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rid_sales_invoice_line_bundle_components FROM anon;
GRANT SELECT, INSERT ON rid_sales_invoice_line_bundle_components TO authenticated;
