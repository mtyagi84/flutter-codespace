-- ============================================================
-- Migration 086: Sales Order — third screen of the Sales module
-- ============================================================
-- Mirrors Purchase Order's role on the sales side: a customer commitment
-- document with ZERO stock and ZERO GL impact at any status. Real
-- inventory/financial effect only happens downstream, at a future Sales
-- Delivery/Invoice screen (mirroring GRN's role). See
-- docs/screens/sales_order.md for the full requirement document this
-- migration implements.
--
-- Three parts, built together because they're tightly coupled:
--   PART A — ric_user_sales_controls: per-user price-override/discount/
--            cost-visibility settings (new prerequisite raised during
--            design discussion — Odoo has no single equivalent; it's
--            assembled here as one purpose-built config table instead of
--            Odoo's fragmented field-security + Approvals-app + margin-
--            module approach).
--   PART B — rih_prospect_conversions + fn_convert_prospect_to_customer:
--            forced, inline, at the exact moment an AGAINST_QUOTATION
--            order is started against a PROSPECT quotation. Standalone/
--            reusable function, not embedded in the order-save function.
--   PART C — Sales Order itself: two entry modes, DIRECT and
--            AGAINST_QUOTATION (exactly one quotation per order — no
--            multi-quotation consolidation, unlike GRN's multi-PO
--            consolidation).
--
-- Design decisions (see requirement doc for the "why"):
--   • order_no + order_date are the document identity, per-location
--     numbering via the existing fn_next_trans_no (same scheme as Sales
--     Quotation's SQ, since Sales Order is the next step in the same
--     pipeline) — NOT PO's company-wide fn_next_company_doc_no.
--   • customer_id is always NOT NULL here — no customer_type/prospect
--     toggle on this document at all. By the time an Order exists, a
--     Direct order's customer was always real, and an Against-Quotation
--     order's prospect (if any) was already forced through conversion
--     before the order row is even created.
--   • Against-Quotation lines are ENTIRELY frozen (product/UOM/rate/
--     discount/tax) except the quantity actually being converted this
--     time (capped at the source line's remaining unconverted amount) —
--     this is what makes partial conversion possible, exactly as the
--     Sales Quotation module's own converted_qty column already
--     anticipated.
--   • price_source/price_override_reason give full traceability of where
--     a Direct-mode line's rate came from — mirrors source_line_type's
--     role in rid_finance_lines.
--   • delivered_qty is a running total (mirrors PO's qty_received),
--     consumed by a future Sales Delivery/Invoice screen — not acted on
--     here.
--   • Deliberately NO fn_check_period_open/fn_check_backdate_allowed at
--     Approve — this document never posts to the books, same
--     intentional deviation as Sales Quotation/Sales Price Master.
--   • Charges (rid_sales_order_charges) are ALWAYS editable in both
--     modes — the one area of flexibility on an otherwise-frozen
--     Against-Quotation order, per explicit instruction.
-- ============================================================


-- ============================================================
-- PART A: ric_user_sales_controls
-- ============================================================
-- Tenant-configurable per-user setting, same family as ric_user_menus.
-- All flags default false/0 — nothing granted until an admin explicitly
-- opts a user in (least-privilege default, matching ric_user_menus's own
-- behavior). A user with no row here is treated identically to a user
-- with an all-false row (see fn_save_sales_order's coalesce-based
-- resolution) — a missing row is never treated as permissive.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ric_user_sales_controls (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    user_id               UUID          NOT NULL REFERENCES rim_users(id),
    can_override_price    BOOLEAN       NOT NULL DEFAULT false,
    can_give_discount     BOOLEAN       NOT NULL DEFAULT false,
    -- NULL = unlimited (only meaningful when can_give_discount = true).
    max_discount_percent  NUMERIC(5,2),
    can_view_cost_price   BOOLEAN       NOT NULL DEFAULT false,
    is_active             BOOLEAN       NOT NULL DEFAULT true,
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_user_sales_controls UNIQUE (client_id, company_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_sales_controls_tenant ON ric_user_sales_controls (client_id, company_id);

DROP TRIGGER IF EXISTS trg_ric_user_sales_controls_updated_at ON ric_user_sales_controls;
CREATE TRIGGER trg_ric_user_sales_controls_updated_at
    BEFORE UPDATE ON ric_user_sales_controls
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE ric_user_sales_controls ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_user_sales_controls" ON ric_user_sales_controls;
CREATE POLICY "auth_rw_user_sales_controls" ON ric_user_sales_controls
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_user_sales_controls FROM anon;
GRANT SELECT, INSERT, UPDATE ON ric_user_sales_controls TO authenticated;


-- ============================================================
-- PART B: Prospect -> Customer Conversion
-- ============================================================

-- ------------------------------------------------------------
-- rih_prospect_conversions
-- Pure audit/traceability log of a conversion event — no dedicated list
-- screen in v1, exists purely so a future sales-pipeline/conversion-rate
-- report has real history to read (the Sales Quotation doc already
-- flagged this shape of report as a natural future consumer).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rih_prospect_conversions (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    source_quotation_no   TEXT          NOT NULL,
    source_quotation_date DATE          NOT NULL,
    new_customer_id       UUID          NOT NULL REFERENCES rim_accounts(id),
    notes                 TEXT,
    converted_by          UUID          REFERENCES rim_users(id),
    converted_at          TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_prospect_conversions_quotation
    ON rih_prospect_conversions (client_id, company_id, source_quotation_no, source_quotation_date);
CREATE INDEX IF NOT EXISTS idx_prospect_conversions_customer
    ON rih_prospect_conversions (new_customer_id);

ALTER TABLE rih_prospect_conversions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_prospect_conversions" ON rih_prospect_conversions;
CREATE POLICY "auth_rw_prospect_conversions" ON rih_prospect_conversions
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_prospect_conversions FROM anon;
GRANT SELECT, INSERT ON rih_prospect_conversions TO authenticated;


-- ------------------------------------------------------------
-- fn_convert_prospect_to_customer
-- Standalone/reusable (not embedded in fn_save_sales_order) so any
-- future trigger point can reuse it — same "shared engine, not a bespoke
-- path" discipline as fn_post_stock_movement/fn_post_voucher. Mirrors
-- the EXACT rim_accounts INSERT shape the existing Customer Master
-- screen already uses (lib/features/master/.../customer_master_screen.dart):
-- resolves the Customer group's parent (first non-posting account under
-- account_nature='Customer'), calls the existing fn_next_account_code,
-- hardcodes accounting_std='OHADA' (the same "derived from seeded data"
-- convention that screen already uses — this app's whole target region,
-- DRC/Zambia, is OHADA-zone).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_convert_prospect_to_customer(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_account        JSONB,   -- {account_name, account_currency_id, party_type, contact_person, phone, email,
                               --  address_line1, address_line2, city_id, country_id, tax_id, party_category,
                               --  credit_limit, credit_days}
    p_notes          TEXT,
    p_user_id        UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_quotation    rih_sales_quotations%ROWTYPE;
    v_group_id     UUID;
    v_account_code TEXT;
    v_new_id       UUID;
BEGIN
    SELECT * INTO v_quotation FROM rih_sales_quotations
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Quotation % dated % not found', p_quotation_no, p_quotation_date;
    END IF;
    IF v_quotation.customer_type != 'PROSPECT' THEN
        RAISE EXCEPTION 'ALREADY_A_CUSTOMER'
            USING DETAIL = format('Sales Quotation %s is already linked to a real customer.', p_quotation_no);
    END IF;

    SELECT id INTO v_group_id FROM rim_accounts
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND account_nature = 'Customer' AND posting_allowed = false AND is_deleted = false
    LIMIT 1;

    IF v_group_id IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_GROUP_NOT_CONFIGURED'
            USING DETAIL = 'No Customer group account exists yet — set up the Chart of Accounts Customer group first.';
    END IF;

    v_account_code := fn_next_account_code(p_client_id, p_company_id, v_group_id);

    INSERT INTO rim_accounts (
        client_id, company_id, parent_id, account_code, account_name,
        account_nature, posting_allowed, is_system_fixed, accounting_std,
        account_currency_id, party_type, contact_person, phone, email,
        address_line1, address_line2, city_id, country_id, tax_id, party_category,
        credit_limit, credit_days, is_credit_blocked, created_by, updated_by
    ) VALUES (
        p_client_id, p_company_id, v_group_id, v_account_code,
        trim(p_account->>'account_name'),
        'Customer', true, false, 'OHADA',
        (nullif(p_account->>'account_currency_id', ''))::uuid,
        nullif(p_account->>'party_type', ''),
        nullif(p_account->>'contact_person', ''),
        nullif(p_account->>'phone', ''),
        nullif(p_account->>'email', ''),
        nullif(p_account->>'address_line1', ''),
        nullif(p_account->>'address_line2', ''),
        (nullif(p_account->>'city_id', ''))::uuid,
        (nullif(p_account->>'country_id', ''))::uuid,
        nullif(p_account->>'tax_id', ''),
        nullif(p_account->>'party_category', ''),
        nullif(p_account->>'credit_limit', '')::numeric,
        coalesce(nullif(p_account->>'credit_days', '')::integer, 30),
        false,
        p_user_id, p_user_id
    ) RETURNING id INTO v_new_id;

    UPDATE rih_sales_quotations SET
        customer_type = 'CUSTOMER',
        customer_id   = v_new_id,
        updated_at = now(), updated_by = p_user_id
    WHERE id = v_quotation.id;

    INSERT INTO rih_prospect_conversions (
        client_id, company_id, source_quotation_no, source_quotation_date,
        new_customer_id, notes, converted_by
    ) VALUES (
        p_client_id, p_company_id, p_quotation_no, p_quotation_date,
        v_new_id, nullif(p_notes, ''), p_user_id
    );

    RETURN v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_convert_prospect_to_customer(UUID, UUID, TEXT, DATE, JSONB, TEXT, UUID) TO authenticated;


-- ============================================================
-- PART C: Sales Order
-- ============================================================

INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('SO', 'Sales Order', 'SALES', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- rih_sales_orders
-- customer_id is always NOT NULL — no prospect concept survives to this
-- document (see header comment). source_quotation_no/date are a nullable
-- soft/logical link (GRN's source_po_* pattern), set only when
-- order_mode = 'AGAINST_QUOTATION'.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rih_sales_orders (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    location_id           UUID          NOT NULL REFERENCES ric_locations(id),
    order_no              TEXT          NOT NULL,
    order_date            DATE          NOT NULL,
    order_mode            TEXT          NOT NULL CHECK (order_mode IN ('DIRECT','AGAINST_QUOTATION')),
    source_quotation_no   TEXT,
    source_quotation_date DATE,
    customer_id           UUID          NOT NULL REFERENCES rim_accounts(id),
    customer_po_ref       TEXT,
    sales_person_id       UUID          REFERENCES rim_users(id),
    order_currency_id     UUID          NOT NULL REFERENCES rim_currencies(id),
    rate_to_base          NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local         NUMERIC(18,8) NOT NULL DEFAULT 1,
    payment_terms         TEXT,
    delivery_terms        TEXT,
    gross_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_amount       NUMERIC(18,4) NOT NULL DEFAULT 0,
    charges_amount        NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    grand_total           NUMERIC(18,4) NOT NULL DEFAULT 0,
    status                TEXT          NOT NULL DEFAULT 'DRAFT'
                          CHECK (status IN ('DRAFT','APPROVED','PARTIALLY_DELIVERED','DELIVERED','CANCELLED')),
    approved_by           UUID          REFERENCES rim_users(id),
    approved_at           TIMESTAMPTZ,
    remarks               TEXT,
    is_active             BOOLEAN       NOT NULL DEFAULT true,
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rih_sales_orders UNIQUE (client_id, company_id, order_no, order_date),
    CONSTRAINT chk_sales_order_mode_source CHECK (
        (order_mode = 'DIRECT' AND source_quotation_no IS NULL AND source_quotation_date IS NULL) OR
        (order_mode = 'AGAINST_QUOTATION' AND source_quotation_no IS NOT NULL AND source_quotation_date IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_rih_so_tenant     ON rih_sales_orders (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rih_so_customer   ON rih_sales_orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_rih_so_status     ON rih_sales_orders (client_id, company_id, status);
CREATE INDEX IF NOT EXISTS idx_rih_so_date       ON rih_sales_orders (client_id, company_id, order_date DESC);
CREATE INDEX IF NOT EXISTS idx_rih_so_quotation
    ON rih_sales_orders (client_id, company_id, source_quotation_no, source_quotation_date);

DROP TRIGGER IF EXISTS trg_rih_sales_orders_updated_at ON rih_sales_orders;
CREATE TRIGGER trg_rih_sales_orders_updated_at
    BEFORE UPDATE ON rih_sales_orders
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_sales_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sales_orders" ON rih_sales_orders;
CREATE POLICY "auth_rw_sales_orders" ON rih_sales_orders
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_sales_orders FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_sales_orders TO authenticated;


-- ------------------------------------------------------------
-- rid_sales_order_lines
-- price_source/price_override_reason: traceability for Direct-mode
-- pricing (mirrors source_line_type's role in rid_finance_lines).
-- delivered_qty: running total for a future Sales Delivery/Invoice
-- screen (mirrors rid_purchase_order_lines.qty_received) — never
-- written to by this module. source_quotation_line_serial: nullable,
-- set only for AGAINST_QUOTATION lines, links back to the exact
-- rid_sales_quotation_lines row this was converted from.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rid_sales_order_lines (
    id                          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                   UUID          NOT NULL REFERENCES ric_clients(id),
    company_id                  UUID          NOT NULL REFERENCES ric_companies(id),
    order_no                    TEXT          NOT NULL,
    order_date                  DATE          NOT NULL,
    serial_no                   INTEGER       NOT NULL,
    product_id                  UUID          NOT NULL REFERENCES rim_products(id),
    item_description            TEXT,
    barcode                     TEXT,
    uom_id                      UUID          NOT NULL REFERENCES rim_common_masters(id),
    uom_conversion_factor       NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack                    NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose                   NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty                    NUMERIC(18,4) NOT NULL DEFAULT 0,
    rate                        NUMERIC(18,4) NOT NULL DEFAULT 0,
    price_source                TEXT          NOT NULL DEFAULT 'PRICE_MASTER'
                                CHECK (price_source IN ('PRICE_MASTER','QUOTATION','MANUAL_OVERRIDE')),
    price_override_reason       TEXT,
    gross_amount                NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_percent            NUMERIC(6,2)  NOT NULL DEFAULT 0,
    discount_amount             NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_group_id                UUID          REFERENCES rim_tax_groups(id),
    tax_amount                  NUMERIC(18,4) NOT NULL DEFAULT 0,
    final_amount                NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_amount                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    local_amount                NUMERIC(18,4) NOT NULL DEFAULT 0,
    charge_amount               NUMERIC(18,4) NOT NULL DEFAULT 0,
    landed_amount                NUMERIC(18,4) NOT NULL DEFAULT 0,
    delivered_qty                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    source_quotation_line_serial    INTEGER,
    remarks                          TEXT,
    is_deleted                        BOOLEAN  NOT NULL DEFAULT false,
    created_at                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                          UUID   REFERENCES rim_users(id),
    updated_at                          TIMESTAMPTZ,
    updated_by                          UUID   REFERENCES rim_users(id),
    CONSTRAINT uq_rid_so_lines UNIQUE (client_id, company_id, order_no, order_date, serial_no),
    CONSTRAINT rid_so_lines_header_fk
        FOREIGN KEY (client_id, company_id, order_no, order_date)
        REFERENCES  rih_sales_orders (client_id, company_id, order_no, order_date),
    CONSTRAINT chk_so_line_override_reason CHECK (
        price_source != 'MANUAL_OVERRIDE' OR (price_override_reason IS NOT NULL AND trim(price_override_reason) != '')
    )
);

CREATE INDEX IF NOT EXISTS idx_rid_so_lines_header  ON rid_sales_order_lines (client_id, company_id, order_no, order_date);
CREATE INDEX IF NOT EXISTS idx_rid_so_lines_product ON rid_sales_order_lines (product_id);

ALTER TABLE rid_sales_order_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_so_lines" ON rid_sales_order_lines;
CREATE POLICY "auth_rw_so_lines" ON rid_sales_order_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_order_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_order_lines TO authenticated;


-- ------------------------------------------------------------
-- rid_sales_order_charges — mirrors rid_sales_quotation_charges exactly.
-- Always editable in both order modes.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rid_sales_order_charges (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL REFERENCES ric_clients(id),
    company_id        UUID          NOT NULL REFERENCES ric_companies(id),
    order_no          TEXT          NOT NULL,
    order_date        DATE          NOT NULL,
    serial_no         INTEGER       NOT NULL,
    charge_id         UUID          NOT NULL REFERENCES rim_additional_charges(id),
    charge_name       TEXT          NOT NULL,
    is_taxable        BOOLEAN       NOT NULL DEFAULT false,
    tax_id            UUID          REFERENCES rim_taxes(id),
    nature            TEXT          NOT NULL DEFAULT 'ADD' CHECK (nature IN ('ADD','DEDUCT')),
    gl_account_id     UUID          REFERENCES rim_accounts(id),
    amount_or_percent TEXT          NOT NULL DEFAULT 'AMOUNT' CHECK (amount_or_percent IN ('AMOUNT','PERCENT')),
    percent           NUMERIC(6,2),
    amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount        NUMERIC(18,4) NOT NULL DEFAULT 0,
    allocation_factor NUMERIC(18,8),
    is_deleted        BOOLEAN       NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id),
    updated_at        TIMESTAMPTZ,
    updated_by        UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rid_so_charge_lines UNIQUE (client_id, company_id, order_no, order_date, serial_no),
    CONSTRAINT rid_so_charge_lines_header_fk
        FOREIGN KEY (client_id, company_id, order_no, order_date)
        REFERENCES  rih_sales_orders (client_id, company_id, order_no, order_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_so_charges_header ON rid_sales_order_charges (client_id, company_id, order_no, order_date);

ALTER TABLE rid_sales_order_charges ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_so_charge_lines" ON rid_sales_order_charges;
CREATE POLICY "auth_rw_so_charge_lines" ON rid_sales_order_charges
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_order_charges FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_order_charges TO authenticated;


-- ============================================================
-- PG FUNCTIONS
-- ============================================================


-- ------------------------------------------------------------
-- fn_save_sales_order — DRAFT-only save. Branches on order_mode.
--
-- DIRECT: per line, resolves fn_get_active_price; enforces the acting
-- user's ric_user_sales_controls (price override + discount cap) —
-- never trusts a cached client-side permission flag, resolves fresh
-- every save. A missing ric_user_sales_controls row is treated
-- identically to an all-false row (coalesce, not a separate branch).
--
-- AGAINST_QUOTATION: copies rate/discount/tax/UOM/product VERBATIM from
-- the referenced rid_sales_quotation_lines row — the client payload's
-- own values for those fields are ignored entirely, never trusted.
-- Only the quantity being converted this time is taken from the
-- payload, capped at that source line's remaining unconverted amount
-- (base_qty - converted_qty). Also re-validates the source quotation's
-- own status/expiry/customer_type every save (cheap, authoritative,
-- matches "never trust client" everywhere else) and FORCES the header's
-- customer_id to the quotation's own customer_id — this is what makes it
-- impossible for an order to ever reference a still-unconverted prospect
-- even if the Flutter wizard is somehow bypassed.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_save_sales_order(
    p_header  JSONB,
    p_lines   JSONB,
    p_charges JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id         UUID;
    v_company_id        UUID;
    v_location_id       UUID;
    v_order_no          TEXT;
    v_order_date        DATE;
    v_old_order_date    DATE;
    v_old_status        TEXT;
    v_is_new            BOOLEAN;
    v_order_mode        TEXT;
    v_customer_id       UUID;
    v_quotation         rih_sales_quotations%ROWTYPE;
    v_can_override      BOOLEAN;
    v_can_discount      BOOLEAN;
    v_max_discount      NUMERIC;
    v_line              JSONB;
    v_serial            INTEGER;
    v_price             RECORD;
    v_rate              NUMERIC;
    v_price_source      TEXT;
    v_override_reason   TEXT;
    v_discount_pct      NUMERIC;
    v_source_line       rid_sales_quotation_lines%ROWTYPE;
    v_source_serial     INTEGER;
    v_remaining         NUMERIC;
    v_convert_qty       NUMERIC;
    v_charge            JSONB;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_order_no    := nullif(trim(p_header->>'order_no'), '');
    v_order_date  := (p_header->>'order_date')::date;
    v_order_mode  := coalesce(p_header->>'order_mode', 'DIRECT');
    v_is_new      := v_order_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Order.';
    END IF;

    -- Resolve the acting user's Sales Controls fresh every save. A
    -- missing row leaves every SELECT'd column NULL; coalesce turns that
    -- into the safe all-false/0 default — never a separate IF NOT FOUND
    -- branch that could be forgotten.
    SELECT can_override_price, can_give_discount, max_discount_percent
      INTO v_can_override, v_can_discount, v_max_discount
    FROM ric_user_sales_controls
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND user_id = p_user_id AND is_deleted = false;
    v_can_override := coalesce(v_can_override, false);
    v_can_discount := coalesce(v_can_discount, false);

    v_customer_id := (nullif(p_header->>'customer_id', ''))::uuid;

    IF v_order_mode = 'AGAINST_QUOTATION' THEN
        SELECT * INTO v_quotation FROM rih_sales_quotations
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND quotation_no = p_header->>'source_quotation_no'
          AND quotation_date = (p_header->>'source_quotation_date')::date;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source Sales Quotation not found.';
        END IF;
        IF v_quotation.status NOT IN ('APPROVED','SENT','ACCEPTED','PARTIALLY_CONVERTED') THEN
            RAISE EXCEPTION 'QUOTATION_NOT_CONVERTIBLE'
                USING DETAIL = format('Sales Quotation %s is %s and cannot be converted.', v_quotation.quotation_no, v_quotation.status);
        END IF;
        IF v_quotation.valid_until_date < CURRENT_DATE THEN
            RAISE EXCEPTION 'QUOTATION_EXPIRED'
                USING DETAIL = format('Sales Quotation %s expired on %s.', v_quotation.quotation_no, v_quotation.valid_until_date);
        END IF;
        IF v_quotation.customer_type != 'CUSTOMER' THEN
            RAISE EXCEPTION 'PROSPECT_NOT_CONVERTED'
                USING DETAIL = format('Sales Quotation %s is still linked to a Prospect — convert it to a Customer first.', v_quotation.quotation_no);
        END IF;
        -- Never trust the client's own customer_id for an Against-
        -- Quotation order — always force it to the quotation's own.
        v_customer_id := v_quotation.customer_id;
    END IF;

    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Select a customer.';
    END IF;

    IF v_is_new THEN
        v_order_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'SO');
    ELSE
        SELECT order_date, status INTO v_old_order_date, v_old_status
        FROM   rih_sales_orders
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  order_no = v_order_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Sales Order % not found', v_order_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Sales Order % is % and cannot be edited.', v_order_no, v_old_status;
        END IF;

        DELETE FROM rid_sales_order_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;

        DELETE FROM rid_sales_order_charges
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_sales_orders (
            client_id, company_id, location_id, order_no, order_date, order_mode,
            source_quotation_no, source_quotation_date, customer_id, customer_po_ref,
            sales_person_id, order_currency_id, rate_to_base, rate_to_local,
            payment_terms, delivery_terms,
            gross_amount, discount_amount, charges_amount, tax_amount, grand_total,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_order_no, v_order_date, v_order_mode,
            nullif(p_header->>'source_quotation_no', ''), (nullif(p_header->>'source_quotation_date', ''))::date,
            v_customer_id, nullif(p_header->>'customer_po_ref', ''),
            (nullif(p_header->>'sales_person_id', ''))::uuid,
            (p_header->>'order_currency_id')::uuid,
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
        UPDATE rih_sales_orders SET
            location_id       = v_location_id,
            order_date        = v_order_date,
            customer_id       = v_customer_id,
            customer_po_ref   = nullif(p_header->>'customer_po_ref', ''),
            sales_person_id   = (nullif(p_header->>'sales_person_id', ''))::uuid,
            order_currency_id = (p_header->>'order_currency_id')::uuid,
            rate_to_base      = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local     = coalesce((p_header->>'rate_to_local')::numeric, 1),
            payment_terms     = nullif(p_header->>'payment_terms', ''),
            delivery_terms    = nullif(p_header->>'delivery_terms', ''),
            gross_amount      = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount   = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount    = coalesce((p_header->>'charges_amount')::numeric, 0),
            tax_amount        = coalesce((p_header->>'tax_amount')::numeric, 0),
            grand_total       = coalesce((p_header->>'grand_total')::numeric, 0),
            remarks           = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    -- Sorted by source_quotation_line_serial (NULL-safe — DIRECT-mode
    -- payloads have no such key, and ordering is a no-op there since no
    -- rid_sales_quotation_lines lock is taken in that branch) — AGAINST_
    -- QUOTATION mode locks rid_sales_quotation_lines rows below, and must
    -- do so in a fixed, deterministic order across concurrent saves to
    -- avoid the exact deadlock class documented for GRN/Material Issue
    -- (SELECT ... ORDER BY ... FOR UPDATE does not itself guarantee lock-
    -- acquisition order — only looping over an already-sorted key list does).
    FOR v_line IN
        SELECT value FROM jsonb_array_elements(p_lines) AS t(value)
        ORDER BY (value->>'source_quotation_line_serial')::integer NULLS LAST, (value->>'serial_no')::integer
    LOOP
        v_serial := (v_line->>'serial_no')::integer;

        IF v_order_mode = 'DIRECT' THEN
            SELECT selling_price, price_type INTO v_price
            FROM fn_get_active_price(
                v_client_id, v_company_id, v_location_id,
                (v_line->>'product_id')::uuid, (v_line->>'uom_id')::uuid,
                v_customer_id, v_order_date
            );

            v_override_reason := nullif(v_line->>'price_override_reason', '');

            IF FOUND AND (nullif(v_line->>'rate', '')::numeric IS NULL
                          OR (v_line->>'rate')::numeric = v_price.selling_price) THEN
                v_rate := v_price.selling_price;
                v_price_source := 'PRICE_MASTER';
            ELSIF NOT FOUND AND NOT v_can_override THEN
                RAISE EXCEPTION 'PRICE_NOT_CONFIGURED'
                    USING DETAIL = format('Line %s: [%s] %s has no active price configured for this customer/date.',
                        v_serial,
                        (SELECT product_code FROM rim_products WHERE id = (v_line->>'product_id')::uuid),
                        (SELECT product_name FROM rim_products WHERE id = (v_line->>'product_id')::uuid));
            ELSE
                IF NOT v_can_override THEN
                    RAISE EXCEPTION 'PRICE_OVERRIDE_NOT_ALLOWED'
                        USING DETAIL = format('Line %s: you are not authorized to change the resolved price.', v_serial);
                END IF;
                IF v_override_reason IS NULL THEN
                    RAISE EXCEPTION 'OVERRIDE_REASON_REQUIRED'
                        USING DETAIL = format('Line %s: enter a reason for overriding the price.', v_serial);
                END IF;
                v_rate := coalesce((v_line->>'rate')::numeric, 0);
                v_price_source := 'MANUAL_OVERRIDE';
            END IF;

            v_discount_pct := coalesce((v_line->>'discount_percent')::numeric, 0);
            IF v_discount_pct > 0 THEN
                IF NOT v_can_discount THEN
                    RAISE EXCEPTION 'DISCOUNT_NOT_ALLOWED'
                        USING DETAIL = format('Line %s: you are not authorized to give a discount.', v_serial);
                END IF;
                IF v_max_discount IS NOT NULL AND v_discount_pct > v_max_discount THEN
                    RAISE EXCEPTION 'DISCOUNT_EXCEEDS_LIMIT'
                        USING DETAIL = format('Line %s: discount %s%% exceeds your authorized maximum of %s%%.', v_serial, v_discount_pct, v_max_discount);
                END IF;
            END IF;

            v_source_serial := NULL;
        ELSE
            -- AGAINST_QUOTATION: copy every priced field VERBATIM from the
            -- source line, never from the client payload.
            v_source_serial := (v_line->>'source_quotation_line_serial')::integer;

            SELECT * INTO v_source_line FROM rid_sales_quotation_lines
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND serial_no = v_source_serial AND is_deleted = false
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Quotation line % not found.', v_source_serial;
            END IF;

            v_remaining := v_source_line.base_qty - v_source_line.converted_qty;
            v_convert_qty := coalesce((v_line->>'base_qty')::numeric, 0);
            IF v_convert_qty <= 0 OR v_convert_qty > v_remaining THEN
                RAISE EXCEPTION 'QUOTATION_QTY_EXCEEDED'
                    USING DETAIL = format('Line %s: only %s remains unconverted on quotation %s.', v_serial, v_remaining, v_quotation.quotation_no);
            END IF;

            v_rate         := v_source_line.rate;
            v_price_source := 'QUOTATION';
            v_override_reason := NULL;
            v_discount_pct := v_source_line.discount_percent;
        END IF;

        INSERT INTO rid_sales_order_lines (
            client_id, company_id, order_no, order_date, serial_no,
            product_id, item_description, barcode, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, price_source, price_override_reason,
            gross_amount, discount_percent, discount_amount,
            tax_group_id, tax_amount, final_amount, base_amount, local_amount,
            charge_amount, landed_amount, source_quotation_line_serial, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date, v_serial,
            CASE WHEN v_order_mode = 'DIRECT' THEN (v_line->>'product_id')::uuid ELSE v_source_line.product_id END,
            nullif(v_line->>'item_description', ''),
            nullif(v_line->>'barcode', ''),
            CASE WHEN v_order_mode = 'DIRECT' THEN (v_line->>'uom_id')::uuid ELSE v_source_line.uom_id END,
            CASE WHEN v_order_mode = 'DIRECT' THEN coalesce((v_line->>'uom_conversion_factor')::numeric, 1) ELSE v_source_line.uom_conversion_factor END,
            coalesce((v_line->>'qty_pack')::numeric, 0),
            coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            v_rate, v_price_source, v_override_reason,
            coalesce((v_line->>'gross_amount')::numeric, 0),
            v_discount_pct,
            coalesce((v_line->>'discount_amount')::numeric, 0),
            CASE WHEN v_order_mode = 'DIRECT' THEN (nullif(v_line->>'tax_group_id', ''))::uuid ELSE v_source_line.tax_group_id END,
            coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            coalesce((v_line->>'base_amount')::numeric, 0),
            coalesce((v_line->>'local_amount')::numeric, 0),
            coalesce((v_line->>'charge_amount')::numeric, 0),
            coalesce((v_line->>'landed_amount')::numeric, 0),
            v_source_serial,
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_sales_order_charges (
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

GRANT EXECUTE ON FUNCTION fn_save_sales_order(JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_approve_sales_order
-- No fn_check_period_open/fn_check_backdate_allowed (never posts to the
-- books). No fn_post_voucher/fn_post_stock_movement call anywhere.
-- For AGAINST_QUOTATION: locks each referenced quotation line (one row
-- per statement, in source_quotation_line_serial sort order — the
-- deadlock-avoidance rule established for GRN/Material Issue), re-checks
-- remaining quantity as the authoritative gate (the save-time check was
-- only a UX pre-check, not a reservation), increments converted_qty, and
-- rolls the quotation header's status to PARTIALLY_CONVERTED or
-- CONVERTED once every line is fully consumed.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_approve_sales_order(
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
    v_header         rih_sales_orders%ROWTYPE;
    v_line           RECORD;
    v_source_line    rid_sales_quotation_lines%ROWTYPE;
    v_remaining      NUMERIC;
    v_all_converted  BOOLEAN;
    v_any_converted  BOOLEAN;
BEGIN
    SELECT * INTO v_header FROM rih_sales_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % dated % not found', p_order_no, p_order_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Order % is % and cannot be approved again', p_order_no, v_header.status;
    END IF;

    FOR v_line IN
        SELECT * FROM rid_sales_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
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

    IF v_header.order_mode = 'AGAINST_QUOTATION' THEN
        FOR v_line IN
            SELECT * FROM rid_sales_order_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
            ORDER BY source_quotation_line_serial
        LOOP
            SELECT * INTO v_source_line FROM rid_sales_quotation_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
              AND serial_no = v_line.source_quotation_line_serial
            FOR UPDATE;

            v_remaining := v_source_line.base_qty - v_source_line.converted_qty;
            IF v_line.base_qty > v_remaining THEN
                RAISE EXCEPTION 'QUOTATION_QTY_EXCEEDED'
                    USING DETAIL = format('Quotation %s line %s: only %s remains unconverted (another order may have consumed it since this draft was saved).',
                        v_header.source_quotation_no, v_source_line.serial_no, v_remaining);
            END IF;

            UPDATE rid_sales_quotation_lines SET
                converted_qty = converted_qty + v_line.base_qty,
                updated_at = now(), updated_by = p_approved_by
            WHERE id = v_source_line.id;
        END LOOP;

        SELECT
            bool_and(converted_qty >= base_qty),
            bool_or(converted_qty > 0)
        INTO v_all_converted, v_any_converted
        FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
          AND is_deleted = false;

        UPDATE rih_sales_quotations SET
            status = CASE WHEN v_all_converted THEN 'CONVERTED'
                          WHEN v_any_converted  THEN 'PARTIALLY_CONVERTED'
                          ELSE status END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date;
    END IF;

    UPDATE rih_sales_orders SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_order(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_cancel_sales_order
-- Allowed from DRAFT or APPROVED, only while nothing has been delivered
-- yet (delivered_qty is always 0 in this build — no Delivery/Invoice
-- screen exists to write it — so this check is a forward-compatible
-- guard, not yet reachable). For AGAINST_QUOTATION: rolls back each
-- line's converted_qty on the source quotation. Recomputing the
-- quotation's exact PRE-conversion status (APPROVED/SENT/ACCEPTED) isn't
-- tracked anywhere, so as a deliberate simplification this reverts to
-- 'APPROVED' whenever no quotation line has any remaining converted_qty
-- after the rollback — always a valid, convertible state — rather than
-- attempting to reconstruct the exact prior one.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cancel_sales_order(
    p_client_id  UUID,
    p_company_id UUID,
    p_order_no   TEXT,
    p_order_date DATE,
    p_user_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header        rih_sales_orders%ROWTYPE;
    v_line          RECORD;
    v_any_converted BOOLEAN;
BEGIN
    SELECT * INTO v_header FROM rih_sales_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % dated % not found', p_order_no, p_order_date;
    END IF;
    IF v_header.status NOT IN ('DRAFT', 'APPROVED') THEN
        RAISE EXCEPTION 'Sales Order % is % and cannot be cancelled', p_order_no, v_header.status;
    END IF;
    IF EXISTS (
        SELECT 1 FROM rid_sales_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
          AND delivered_qty > 0
    ) THEN
        RAISE EXCEPTION 'DELIVERY_ALREADY_STARTED'
            USING DETAIL = format('Sales Order %s already has delivered quantity and cannot be cancelled.', p_order_no);
    END IF;

    IF v_header.order_mode = 'AGAINST_QUOTATION' AND v_header.status = 'APPROVED' THEN
        FOR v_line IN
            SELECT * FROM rid_sales_order_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
            ORDER BY source_quotation_line_serial
        LOOP
            UPDATE rid_sales_quotation_lines SET
                converted_qty = greatest(0, converted_qty - v_line.base_qty),
                updated_at = now(), updated_by = p_user_id
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
              AND serial_no = v_line.source_quotation_line_serial;
        END LOOP;

        SELECT bool_or(converted_qty > 0) INTO v_any_converted
        FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
          AND is_deleted = false;

        UPDATE rih_sales_quotations SET
            status = CASE WHEN NOT v_any_converted THEN 'APPROVED' ELSE 'PARTIALLY_CONVERTED' END,
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
          AND status IN ('CONVERTED', 'PARTIALLY_CONVERTED');
    END IF;

    UPDATE rih_sales_orders SET
        status = 'CANCELLED',
        updated_at = now(), updated_by = p_user_id
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_cancel_sales_order(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ============================================================
-- Menu seed — 'SL-SO' for every already-existing company, positioned in
-- the same SL-TXN group as Sales Quotation, right after it.
-- fn_seed_client_modules.sql updated separately for future clients.
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
    co.client_id, co.id, sm.id, 'SL-SO', 'Sales Order', '/sales/orders',
    1, 'SL-TXN', 'Transactions', 0,
    true, true, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'SL'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
