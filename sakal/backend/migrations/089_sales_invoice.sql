-- ============================================================
-- Migration 089: Sales Invoice ("Quick Invoice") — core
-- ============================================================
-- Second of three Quick Invoice migrations (088 config, 089 this file,
-- 090 manager review) — see docs/screens/sales_invoice.md for the full
-- requirement document. This is the first Sales-module screen with
-- REAL GL/stock impact (Sales Quotation/Order never post).
--
-- Two-function shape, same as every other module: fn_save_sales_invoice
-- (DRAFT stage/re-stage only) + fn_approve_sales_invoice (the only place
-- GL/stock actually posts). The "auto-approve on Save" feel the user
-- asked for is pure Flutter orchestration — online, the entry screen
-- calls save then immediately approve in one click; offline, only save
-- is queued (via the standard SyncEngine/generateLocalId() retrofit),
-- leaving the invoice in DRAFT until a human reviews it on the new
-- Manager Review screen (090) — which also doubles as the safety net for
-- a rare ONLINE race-condition failure (stock vanishes between save and
-- approve). Same functions serve both paths, zero special-casing.
--
-- Key design decisions (see the plan/requirement doc for full "why"):
--   • Whole-document consumption of a Quotation/Order — no partial
--     invoicing, one invoice per source document. NO reservation column
--     on rih_sales_quotations/rih_sales_orders: fn_save_sales_invoice
--     locks the source row FOR UPDATE (already needed to validate it)
--     and checks live NOT EXISTS against rih_sales_invoices inside that
--     same lock — identical concurrency guarantee to a stored flag, zero
--     schema addition, and cancelling an invoice automatically re-opens
--     its source with no separate "un-reserve" step.
--   • AGAINST_QUOTATION/AGAINST_ORDER modes IGNORE the client's own
--     p_lines entirely — every line is re-derived server-side from the
--     locked source document, copied verbatim (product/uom/qty/rate/
--     discount/tax). Stricter than Sales Order's own quotation-consuming
--     mode (which at least lets the client choose a partial qty) — here
--     there's nothing left for the client to legitimately choose, so
--     there's nothing to trust it for either.
--   • Two GL vouchers: SI (Sales) always, COS (Cost of Sales, JV nature)
--     only when stock actually dispatches — mirrors Purchase Bill's
--     PUR+EXC split, for the identical reason (a voucher can only have
--     one trans_currency; Customer/Sales/Tax are in the invoice's own
--     currency, Stock/COGS are always base currency).
--   • Cash sales post through the exact same Customer-DR/Sales-CR
--     mechanism as Credit sales (against the user's own cash_customer_id
--     from ric_user_quick_invoice_setup) — a cash sale is just a credit
--     sale to a special customer, same-day settled. Settlement (the
--     Receipt Voucher) calls fn_save_finance_voucher +
--     fn_post_finance_voucher DIRECTLY (never fn_post_voucher, which
--     hardcodes is_on_account=true and would never run the Against-Bill
--     settlement branch) — is_on_account=false, settling line's
--     inv_bill_no/inv_bill_date = the SI voucher's own trans_no/date,
--     and (critically) the settling line's account_id must be the exact
--     SAME account_id as the SI voucher's own Customer DR line, since
--     fn_post_finance_voucher's settlement lookup joins on account_id
--     too, not just trans_no/date.
--   • discount_given_by is populated on EVERY discounted line (not just
--     overridden ones) — the cashier's own user_id when within their own
--     ric_user_sales_controls cap, or a supervisor's user_id (verified
--     via fn_verify_discount_override, re-checked again here server-side)
--     when an override was used. Header-level discount_percent (fans out
--     client-side to every line) is stored purely as a record of what
--     blanket discount was applied at entry — all real validation stays
--     at the line level.
--   • Cancel only from DRAFT — once APPROVED (GL/stock posted), this
--     build has no reversal path; that's a future Sales Return module's
--     job, matching this project's Immutability principle literally
--     (never edit/unwind a posted transaction in place).
--   • Charges (rid_sales_invoice_charges, reusing the shared
--     rim_additional_charges master — same shape as Quotation/Order's own
--     rid_sales_quotation_charges/rid_sales_order_charges) are freely
--     editable client-side in DIRECT mode only. AGAINST_QUOTATION/
--     AGAINST_ORDER copy the source document's charges VERBATIM
--     server-side — the client's own p_charges is ignored in those two
--     modes, same "nothing left to legitimately choose" rule already
--     governing this module's line-item copying (unlike Sales Order,
--     which keeps charges always-editable in every mode since it never
--     posts GL and allows partial-qty conversion). Each charge posts its
--     own gl_account_id directly (Cr for ADD, Dr for DEDUCT, same
--     direction-flip rule as GRN charges) plus its own single-tax CR/DR
--     leg — the first place any Sales-module charge's gl_account_id
--     actually posts, since Quotation/Order never post GL at all.
--   • fn_get_invoiceable_quotations/fn_get_invoiceable_orders were
--     considered but dropped: Sales Order's own quotation picker already
--     does its remaining-qty filtering client-side (no dedicated RPC),
--     and rih_sales_invoices' quotation_no/order_no are
--     soft (non-FK) links PostgREST can't embed-filter on anyway. Same
--     approach here — a plain status-filtered fetch of quotations/orders,
--     a plain fetch of already-invoiced source keys, client-side
--     subtraction. The picker is only ever a UX pre-check; the
--     authoritative check is the row-locked NOT EXISTS in
--     fn_save_sales_invoice below regardless of what the picker showed.
-- ============================================================


-- ============================================================
-- Voucher types
-- ============================================================

INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('SI',  'Sales Invoice',    'SALES',   NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true),
    ('COS', 'Cost of Sales',    'JOURNAL', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ============================================================
-- rih_sales_invoices
-- ============================================================
CREATE TABLE IF NOT EXISTS rih_sales_invoices (
    id                       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                UUID          NOT NULL REFERENCES ric_clients(id),
    company_id               UUID          NOT NULL REFERENCES ric_companies(id),
    location_id              UUID          NOT NULL REFERENCES ric_locations(id),
    invoice_no               TEXT          NOT NULL,
    invoice_date              DATE         NOT NULL,
    invoice_mode              TEXT         NOT NULL CHECK (invoice_mode IN ('DIRECT','AGAINST_QUOTATION','AGAINST_ORDER')),
    quotation_no       TEXT,
    quotation_date     DATE,
    order_no           TEXT,
    order_date         DATE,
    sale_type                 TEXT         NOT NULL CHECK (sale_type IN ('CASH','CREDIT')),
    customer_id                UUID        NOT NULL REFERENCES rim_accounts(id),
    -- Cash-sale walk-in snapshot only (Sales-Quotation-style free text) —
    -- never creates a rim_accounts row. Always NULL for CREDIT.
    party_name                  TEXT,
    party_phone                  TEXT,
    party_address                 TEXT,
    sales_person_id                UUID     REFERENCES rim_users(id),
    invoice_currency_id             UUID    NOT NULL REFERENCES rim_currencies(id),
    rate_to_base                     NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local                     NUMERIC(18,8) NOT NULL DEFAULT 1,
    -- Header fan-out convenience only — see header comment. Not re-validated.
    discount_percent                   NUMERIC(6,2)  NOT NULL DEFAULT 0,
    gross_amount                        NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_amount                      NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- Net of ADD/DEDUCT charges (rid_sales_invoice_charges), item taxes
    -- excluded — mirrors rih_sales_orders.charges_amount exactly.
    charges_amount                        NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount                            NUMERIC(18,4) NOT NULL DEFAULT 0,
    grand_total                            NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- Snapshotted from ric_companies.quick_invoice_dispatch_stock /
    -- quick_invoice_collect_cash AT SAVE TIME — a later company-flag
    -- change never reinterprets an existing invoice's own history.
    stock_dispatch_mode                     TEXT NOT NULL CHECK (stock_dispatch_mode IN ('IMMEDIATE','DEFERRED')),
    cash_collection_mode                     TEXT NOT NULL CHECK (cash_collection_mode IN ('IMMEDIATE','DEFERRED')),
    status                                    TEXT NOT NULL DEFAULT 'DRAFT'
                                              CHECK (status IN ('DRAFT','APPROVED','CANCELLED')),
    sales_voucher_no                          TEXT,
    sales_voucher_date                        DATE,
    cos_voucher_no                            TEXT,
    cos_voucher_date                          DATE,
    local_receipt_voucher_no                  TEXT,
    local_receipt_voucher_date                DATE,
    base_receipt_voucher_no                   TEXT,
    base_receipt_voucher_date                 DATE,
    -- What the cashier actually collected at Save time (both nullable —
    -- 0/absent means "not collected in that currency"). Consumed at
    -- Approve time to build the Receipt Voucher(s), regardless of
    -- whether Approve runs immediately (online) or later via Manager
    -- Review (offline) — the amount was already fixed at the point of
    -- sale, not re-decided later.
    collected_amount_local                    NUMERIC(18,4),
    collected_amount_base                     NUMERIC(18,4),
    approved_by                               UUID REFERENCES rim_users(id),
    approved_at                               TIMESTAMPTZ,
    cancellation_reason                       TEXT,
    remarks                                   TEXT,
    is_deleted                                BOOLEAN NOT NULL DEFAULT false,
    created_at                                TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                                UUID REFERENCES rim_users(id),
    updated_at                                TIMESTAMPTZ,
    updated_by                                UUID REFERENCES rim_users(id),
    CONSTRAINT uq_rih_sales_invoices UNIQUE (client_id, company_id, invoice_no, invoice_date),
    CONSTRAINT chk_si_mode_source CHECK (
        (invoice_mode = 'DIRECT'            AND quotation_no IS NULL AND order_no IS NULL) OR
        (invoice_mode = 'AGAINST_QUOTATION' AND quotation_no IS NOT NULL AND quotation_date IS NOT NULL AND order_no IS NULL) OR
        (invoice_mode = 'AGAINST_ORDER'     AND order_no IS NOT NULL AND order_date IS NOT NULL AND quotation_no IS NULL)
    ),
    CONSTRAINT chk_si_cancel_reason CHECK (status != 'CANCELLED' OR (cancellation_reason IS NOT NULL AND trim(cancellation_reason) != ''))
);

-- Charges retrofit (this file's own charges addition, layered onto an
-- already-run first version of this migration) — CREATE TABLE IF NOT
-- EXISTS above is a no-op once the table already exists, so a column
-- added to that statement never actually lands on a re-run. ALTER TABLE
-- ADD COLUMN IF NOT EXISTS is what actually applies it idempotently.
ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS charges_amount NUMERIC(18,4) NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_rih_si_tenant     ON rih_sales_invoices (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rih_si_customer   ON rih_sales_invoices (customer_id);
CREATE INDEX IF NOT EXISTS idx_rih_si_status     ON rih_sales_invoices (client_id, company_id, location_id, status);
CREATE INDEX IF NOT EXISTS idx_rih_si_date       ON rih_sales_invoices (client_id, company_id, invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_rih_si_quotation
    ON rih_sales_invoices (client_id, company_id, quotation_no, quotation_date);
CREATE INDEX IF NOT EXISTS idx_rih_si_order
    ON rih_sales_invoices (client_id, company_id, order_no, order_date);
CREATE INDEX IF NOT EXISTS idx_rih_si_created_by ON rih_sales_invoices (client_id, company_id, created_by);

DROP TRIGGER IF EXISTS trg_rih_sales_invoices_updated_at ON rih_sales_invoices;
CREATE TRIGGER trg_rih_sales_invoices_updated_at
    BEFORE UPDATE ON rih_sales_invoices
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_sales_invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sales_invoices" ON rih_sales_invoices;
CREATE POLICY "auth_rw_sales_invoices" ON rih_sales_invoices
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_sales_invoices FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_sales_invoices TO authenticated;


-- ============================================================
-- rid_sales_invoice_lines
-- ============================================================
CREATE TABLE IF NOT EXISTS rid_sales_invoice_lines (
    id                          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                   UUID          NOT NULL REFERENCES ric_clients(id),
    company_id                  UUID          NOT NULL REFERENCES ric_companies(id),
    invoice_no                  TEXT          NOT NULL,
    invoice_date                DATE          NOT NULL,
    serial_no                   INTEGER       NOT NULL,
    product_id                  UUID          NOT NULL REFERENCES rim_products(id),
    item_description             TEXT,
    barcode                       TEXT,
    uom_id                         UUID       NOT NULL REFERENCES rim_common_masters(id),
    uom_conversion_factor            NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack                          NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose                          NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty                            NUMERIC(18,4) NOT NULL DEFAULT 0,
    rate                                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    price_source                          TEXT NOT NULL DEFAULT 'PRICE_MASTER'
                                          CHECK (price_source IN ('PRICE_MASTER','QUOTATION','ORDER','MANUAL_OVERRIDE')),
    price_override_reason                 TEXT,
    price_source_entry_no                  TEXT,
    gross_amount                            NUMERIC(18,4) NOT NULL DEFAULT 0,
    discount_percent                         NUMERIC(6,2)  NOT NULL DEFAULT 0,
    discount_amount                           NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- NOT NULL whenever discount_percent > 0 (CHECK below) — the cashier's
    -- own id when within their own cap, a verified supervisor's id when
    -- an override was needed. Never null when a discount was actually given.
    discount_given_by                          UUID REFERENCES rim_users(id),
    tax_group_id                                UUID REFERENCES rim_tax_groups(id),
    tax_amount                                   NUMERIC(18,4) NOT NULL DEFAULT 0,
    final_amount                                  NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_amount                                    NUMERIC(18,4) NOT NULL DEFAULT 0,
    local_amount                                    NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- This line's apportioned share of rid_sales_invoice_charges — same
    -- allocation-factor idiom as rid_sales_order_lines.charge_amount.
    -- landed_amount = final_amount + charge_amount, the all-inclusive
    -- price. Neither is re-derived server-side (client-computed, trusted,
    -- same as every other Sales-module charge apportionment).
    charge_amount                                    NUMERIC(18,4) NOT NULL DEFAULT 0,
    landed_amount                                     NUMERIC(18,4) NOT NULL DEFAULT 0,
    source_quotation_line_serial                     INTEGER,
    source_order_line_serial                          INTEGER,
    remarks                                            TEXT,
    is_deleted                                          BOOLEAN NOT NULL DEFAULT false,
    created_at                                          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                                          UUID REFERENCES rim_users(id),
    updated_at                                          TIMESTAMPTZ,
    updated_by                                          UUID REFERENCES rim_users(id),
    CONSTRAINT uq_rid_si_lines UNIQUE (client_id, company_id, invoice_no, invoice_date, serial_no),
    CONSTRAINT rid_si_lines_header_fk
        FOREIGN KEY (client_id, company_id, invoice_no, invoice_date)
        REFERENCES  rih_sales_invoices (client_id, company_id, invoice_no, invoice_date),
    CONSTRAINT chk_si_line_discount_given_by CHECK (discount_percent = 0 OR discount_given_by IS NOT NULL),
    CONSTRAINT chk_si_line_override_reason CHECK (
        price_source != 'MANUAL_OVERRIDE' OR (price_override_reason IS NOT NULL AND trim(price_override_reason) != '')
    )
);

-- Same ALTER-not-CREATE retrofit reasoning as rih_sales_invoices.charges_amount above.
ALTER TABLE rid_sales_invoice_lines ADD COLUMN IF NOT EXISTS charge_amount  NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE rid_sales_invoice_lines ADD COLUMN IF NOT EXISTS landed_amount NUMERIC(18,4) NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_rid_si_lines_header  ON rid_sales_invoice_lines (client_id, company_id, invoice_no, invoice_date);
CREATE INDEX IF NOT EXISTS idx_rid_si_lines_product ON rid_sales_invoice_lines (product_id);

ALTER TABLE rid_sales_invoice_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_si_lines" ON rid_sales_invoice_lines;
CREATE POLICY "auth_rw_si_lines" ON rid_sales_invoice_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_invoice_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_invoice_lines TO authenticated;


-- ------------------------------------------------------------
-- rid_sales_invoice_charges — mirrors rid_sales_order_charges exactly.
-- DIRECT mode: freely editable, client-supplied every save (same
-- "always editable" convention as Sales Order — see fn_save_sales_invoice
-- below). AGAINST_QUOTATION/AGAINST_ORDER mode: server-copied VERBATIM
-- from the source document's own charges — the client's own p_charges is
-- ignored in those two modes, same "nothing left to legitimately choose"
-- rule already governing this module's line-item copying.
-- gl_account_id is the first real GL consumer of this column across the
-- whole Sales-module charges shape — Quotation/Order never post GL, so
-- it was captured but unused there.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rid_sales_invoice_charges (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL REFERENCES ric_clients(id),
    company_id        UUID          NOT NULL REFERENCES ric_companies(id),
    invoice_no        TEXT          NOT NULL,
    invoice_date      DATE          NOT NULL,
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
    CONSTRAINT uq_rid_si_charge_lines UNIQUE (client_id, company_id, invoice_no, invoice_date, serial_no),
    CONSTRAINT rid_si_charge_lines_header_fk
        FOREIGN KEY (client_id, company_id, invoice_no, invoice_date)
        REFERENCES  rih_sales_invoices (client_id, company_id, invoice_no, invoice_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_si_charges_header ON rid_sales_invoice_charges (client_id, company_id, invoice_no, invoice_date);

ALTER TABLE rid_sales_invoice_charges ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_si_charge_lines" ON rid_sales_invoice_charges;
CREATE POLICY "auth_rw_si_charge_lines" ON rid_sales_invoice_charges
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_sales_invoice_charges FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_sales_invoice_charges TO authenticated;


-- ============================================================
-- Lock trigger for ric_user_quick_invoice_setup (088) — deferred to here
-- since it needs rih_sales_invoices, which now exists in this file. See
-- 088's own header comment for why this wasn't created there directly.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_lock_quick_invoice_setup()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM rih_sales_invoices
        WHERE client_id = OLD.client_id AND company_id = OLD.company_id
          AND created_by = OLD.user_id AND is_deleted = false
        LIMIT 1
    ) THEN
        RAISE EXCEPTION 'QUICK_INVOICE_SETUP_LOCKED'
            USING DETAIL = 'This user has already made a Quick Invoice — their setup can no longer be changed.';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lock_quick_invoice_setup ON ric_user_quick_invoice_setup;
CREATE TRIGGER trg_lock_quick_invoice_setup
    BEFORE UPDATE ON ric_user_quick_invoice_setup
    FOR EACH ROW EXECUTE FUNCTION fn_lock_quick_invoice_setup();


-- ============================================================
-- fn_save_sales_invoice
-- ============================================================
-- DRAFT-only stage/re-stage. Never posts GL/stock — that's
-- fn_approve_sales_invoice's job alone, whether triggered immediately
-- (online) or later via Manager Review (offline-synced or a rare online
-- failure).
--
-- DIRECT: per line, resolves fn_get_active_price (currency-aware, 086);
-- enforces the acting user's ric_user_sales_controls (price override +
-- discount cap), same governance shape as fn_save_sales_order, plus the
-- discount_given_by attribution described in the header comment. Batch/
-- serial candidate selections (p_batches/p_serials, same generic
-- rid_transaction_line_batches/rid_transaction_line_serials tables and
-- shape GRN/Material Issue/Purchase Return already use) are staged now
-- when stock_dispatch_mode will be IMMEDIATE and the product is tracked
-- — mandatory allocation, same strict rule as every other
-- immediate-stock-effect module.
--
-- AGAINST_QUOTATION/AGAINST_ORDER: the client's own p_lines is IGNORED
-- entirely — every line is re-derived server-side, copied verbatim, from
-- the locked source document (whole-document, no partial quantity).
-- Batch/serial staging still comes from the client in these modes (a
-- Quotation/Order never carries batch/serial — there was no stock effect
-- at that stage to allocate against).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_save_sales_invoice(
    p_header  JSONB,
    p_lines   JSONB,
    p_charges JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id           UUID;
    v_company_id          UUID;
    v_location_id         UUID;
    v_invoice_no          TEXT;
    v_invoice_date        DATE;
    v_old_invoice_date    DATE;
    v_old_status          TEXT;
    v_is_new              BOOLEAN;
    v_invoice_mode        TEXT;
    v_sale_type           TEXT;
    v_customer_id         UUID;
    v_quotation           rih_sales_quotations%ROWTYPE;
    v_order                rih_sales_orders%ROWTYPE;
    v_quick_setup           ric_user_quick_invoice_setup%ROWTYPE;
    v_can_override         BOOLEAN;
    v_can_discount          BOOLEAN;
    v_max_discount           NUMERIC;
    v_dispatch_stock          BOOLEAN;
    v_collect_cash              BOOLEAN;
    v_line                       JSONB;
    v_serial                      INTEGER;
    v_price                        RECORD;
    v_rate                          NUMERIC;
    v_price_source                   TEXT;
    v_override_reason                 TEXT;
    v_discount_pct                     NUMERIC;
    v_discount_given_by                 UUID;
    v_sup_can_discount                   BOOLEAN;
    v_sup_max_discount                    NUMERIC;
    v_source_line                          rid_sales_quotation_lines%ROWTYPE;
    v_source_order_line                     rid_sales_order_lines%ROWTYPE;
    v_order_currency_code                    TEXT;
    v_price_entry_no                          TEXT;
    v_charge                                   JSONB;
    v_source_charge                             rid_sales_quotation_charges%ROWTYPE;
    v_source_order_charge                        rid_sales_order_charges%ROWTYPE;
    v_batch                                    JSONB;
    v_serial_row                                JSONB;
    v_is_batch_tracked                           BOOLEAN;
    v_is_serial_tracked                           BOOLEAN;
    v_has_batches                                  BOOLEAN;
    v_has_serials                                   BOOLEAN;
    v_check_line                                     RECORD;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_invoice_no   := nullif(trim(p_header->>'invoice_no'), '');
    v_invoice_date := (p_header->>'invoice_date')::date;
    v_invoice_mode := coalesce(p_header->>'invoice_mode', 'DIRECT');
    v_sale_type    := coalesce(p_header->>'sale_type', 'CASH');
    v_is_new       := v_invoice_no IS NULL;

    IF v_invoice_mode = 'DIRECT' AND jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Invoice.';
    END IF;

    -- Company-level immediate/deferred flags, snapshotted onto the header.
    SELECT quick_invoice_dispatch_stock, quick_invoice_collect_cash
      INTO v_dispatch_stock, v_collect_cash
    FROM ric_companies WHERE id = v_company_id;

    -- Sales Controls, same coalesce-to-safe-default resolution as
    -- fn_save_sales_order — a missing row is never permissive.
    SELECT can_override_price, can_give_discount, max_discount_percent
      INTO v_can_override, v_can_discount, v_max_discount
    FROM ric_user_sales_controls
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND user_id = p_user_id AND is_deleted = false;
    v_can_override := coalesce(v_can_override, false);
    v_can_discount := coalesce(v_can_discount, false);

    -- Resolve customer + party snapshot.
    IF v_sale_type = 'CASH' THEN
        SELECT * INTO v_quick_setup FROM ric_user_quick_invoice_setup
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND user_id = p_user_id AND is_deleted = false AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                USING DETAIL = 'This user has no Quick Invoice Setup — ask an admin to assign a location, cash customer, and cash accounts first.';
        END IF;
        v_customer_id := v_quick_setup.cash_customer_id;
    ELSE
        v_customer_id := (nullif(p_header->>'customer_id', ''))::uuid;
        -- AGAINST_QUOTATION/AGAINST_ORDER derive v_customer_id from the
        -- locked source document further below (v_quotation.customer_id /
        -- v_order.customer_id) — the client-supplied payload legitimately
        -- omits customer_id in these two modes, so this check only
        -- applies to DIRECT.
        IF v_customer_id IS NULL AND v_invoice_mode = 'DIRECT' THEN
            RAISE EXCEPTION 'Select a customer.';
        END IF;
    END IF;

    SELECT currency_id INTO v_order_currency_code
    FROM rim_currencies WHERE id = (p_header->>'invoice_currency_id')::uuid;

    -- Lock + validate + (for AGAINST_* modes) re-derive from the source
    -- document. The row lock here is what makes the live "already
    -- invoiced?" check below race-safe — a second concurrent save on the
    -- same source document blocks until this transaction commits.
    IF v_invoice_mode = 'AGAINST_QUOTATION' THEN
        SELECT * INTO v_quotation FROM rih_sales_quotations
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND quotation_no = p_header->>'quotation_no'
          AND quotation_date = (p_header->>'quotation_date')::date
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source Sales Quotation not found.';
        END IF;
        IF v_quotation.status NOT IN ('APPROVED','SENT','ACCEPTED') THEN
            RAISE EXCEPTION 'QUOTATION_NOT_INVOICEABLE'
                USING DETAIL = format('Sales Quotation %s is %s and cannot be invoiced.', v_quotation.quotation_no, v_quotation.status);
        END IF;
        IF v_quotation.customer_type != 'CUSTOMER' THEN
            RAISE EXCEPTION 'PROSPECT_NOT_CONVERTED'
                USING DETAIL = format('Sales Quotation %s is still linked to a Prospect — it must be converted (via a Sales Order) before it can be invoiced.', v_quotation.quotation_no);
        END IF;
        IF EXISTS (
            -- rih_sales_orders' OWN reference-to-its-source-quotation columns
            -- (source_quotation_no/date, from 087) — deliberately NOT renamed
            -- by this migration's quotation_no/order_no cleanup, since that
            -- only touched rih_sales_invoices' own columns.
            SELECT 1 FROM rih_sales_orders
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND source_quotation_no = v_quotation.quotation_no AND source_quotation_date = v_quotation.quotation_date
              AND status != 'CANCELLED'
        ) THEN
            RAISE EXCEPTION 'QUOTATION_HAS_ORDER'
                USING DETAIL = format('Sales Quotation %s already has a Sales Order raised against it — invoice that Order instead.', v_quotation.quotation_no);
        END IF;
        IF EXISTS (
            SELECT 1 FROM rih_sales_invoices
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND status != 'CANCELLED'
              AND (v_is_new OR invoice_no != v_invoice_no)
        ) THEN
            RAISE EXCEPTION 'QUOTATION_ALREADY_INVOICED'
                USING DETAIL = format('Sales Quotation %s has already been invoiced.', v_quotation.quotation_no);
        END IF;

        v_customer_id := v_quotation.customer_id;
    ELSIF v_invoice_mode = 'AGAINST_ORDER' THEN
        SELECT * INTO v_order FROM rih_sales_orders
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = p_header->>'order_no'
          AND order_date = (p_header->>'order_date')::date
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source Sales Order not found.';
        END IF;
        IF v_order.status != 'APPROVED' THEN
            RAISE EXCEPTION 'ORDER_NOT_INVOICEABLE'
                USING DETAIL = format('Sales Order %s is %s and cannot be invoiced.', v_order.order_no, v_order.status);
        END IF;
        IF EXISTS (
            SELECT 1 FROM rih_sales_invoices
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND order_no = v_order.order_no AND order_date = v_order.order_date
              AND status != 'CANCELLED'
              AND (v_is_new OR invoice_no != v_invoice_no)
        ) THEN
            RAISE EXCEPTION 'ORDER_ALREADY_INVOICED'
                USING DETAIL = format('Sales Order %s has already been invoiced.', v_order.order_no);
        END IF;

        v_customer_id := v_order.customer_id;
    END IF;

    IF v_is_new THEN
        v_invoice_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'SI');
    ELSE
        SELECT invoice_date, status INTO v_old_invoice_date, v_old_status
        FROM   rih_sales_invoices
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  invoice_no = v_invoice_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Sales Invoice % not found', v_invoice_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Sales Invoice % is % and cannot be edited.', v_invoice_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_old_invoice_date;

        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_old_invoice_date;

        DELETE FROM rid_sales_invoice_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND invoice_date = v_old_invoice_date;

        DELETE FROM rid_sales_invoice_charges
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND invoice_date = v_old_invoice_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_sales_invoices (
            client_id, company_id, location_id, invoice_no, invoice_date, invoice_mode,
            quotation_no, quotation_date, order_no, order_date,
            sale_type, customer_id, party_name, party_phone, party_address, sales_person_id,
            invoice_currency_id, rate_to_base, rate_to_local, discount_percent,
            gross_amount, discount_amount, charges_amount, tax_amount, grand_total,
            stock_dispatch_mode, cash_collection_mode,
            collected_amount_local, collected_amount_base,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_invoice_no, v_invoice_date, v_invoice_mode,
            nullif(p_header->>'quotation_no', ''), (nullif(p_header->>'quotation_date', ''))::date,
            nullif(p_header->>'order_no', ''), (nullif(p_header->>'order_date', ''))::date,
            v_sale_type, v_customer_id,
            CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_name', '') END,
            CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_phone', '') END,
            CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_address', '') END,
            coalesce((nullif(p_header->>'sales_person_id', ''))::uuid,
                     CASE WHEN v_sale_type = 'CASH' THEN v_quick_setup.default_sales_person_id END),
            (p_header->>'invoice_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'discount_percent')::numeric, 0),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            CASE WHEN coalesce(v_dispatch_stock, true) THEN 'IMMEDIATE' ELSE 'DEFERRED' END,
            CASE WHEN coalesce(v_collect_cash, true)   THEN 'IMMEDIATE' ELSE 'DEFERRED' END,
            (nullif(p_header->>'collected_amount_local', ''))::numeric,
            (nullif(p_header->>'collected_amount_base', ''))::numeric,
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_sales_invoices SET
            location_id       = v_location_id,
            invoice_date      = v_invoice_date,
            sale_type         = v_sale_type,
            customer_id       = v_customer_id,
            party_name        = CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_name', '') END,
            party_phone       = CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_phone', '') END,
            party_address     = CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_address', '') END,
            sales_person_id   = (nullif(p_header->>'sales_person_id', ''))::uuid,
            invoice_currency_id = (p_header->>'invoice_currency_id')::uuid,
            rate_to_base      = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local     = coalesce((p_header->>'rate_to_local')::numeric, 1),
            discount_percent  = coalesce((p_header->>'discount_percent')::numeric, 0),
            gross_amount      = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount   = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount    = coalesce((p_header->>'charges_amount')::numeric, 0),
            tax_amount        = coalesce((p_header->>'tax_amount')::numeric, 0),
            grand_total       = coalesce((p_header->>'grand_total')::numeric, 0),
            collected_amount_local = (nullif(p_header->>'collected_amount_local', ''))::numeric,
            collected_amount_base  = (nullif(p_header->>'collected_amount_base', ''))::numeric,
            remarks           = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    IF v_invoice_mode = 'DIRECT' THEN
        FOR v_line IN
            SELECT value FROM jsonb_array_elements(p_lines) AS t(value)
            ORDER BY (value->>'serial_no')::integer
        LOOP
            v_serial := (v_line->>'serial_no')::integer;

            SELECT selling_price, price_type, entry_no INTO v_price
            FROM fn_get_active_price(
                v_client_id, v_company_id, v_location_id,
                (v_line->>'product_id')::uuid, (v_line->>'uom_id')::uuid,
                v_customer_id, v_invoice_date, v_order_currency_code
            );
            v_price_entry_no := NULL;
            v_override_reason := nullif(v_line->>'price_override_reason', '');

            IF FOUND AND (nullif(v_line->>'rate', '')::numeric IS NULL
                          OR (v_line->>'rate')::numeric = v_price.selling_price) THEN
                v_rate := v_price.selling_price;
                v_price_source := 'PRICE_MASTER';
                v_price_entry_no := v_price.entry_no;
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

            -- Discount governance + mandatory discount_given_by attribution
            -- (header comment point 2) — always populated when a discount
            -- was actually given, never just an "override" marker.
            v_discount_pct := coalesce((v_line->>'discount_percent')::numeric, 0);
            IF v_discount_pct > 0 THEN
                IF v_can_discount AND (v_max_discount IS NULL OR v_discount_pct <= v_max_discount) THEN
                    v_discount_given_by := p_user_id;
                ELSE
                    v_discount_given_by := (nullif(v_line->>'discount_given_by', ''))::uuid;
                    IF v_discount_given_by IS NULL OR v_discount_given_by = p_user_id THEN
                        RAISE EXCEPTION 'DISCOUNT_OVERRIDE_REQUIRED'
                            USING DETAIL = format('Line %s: discount %s%% exceeds your authorized limit — get a supervisor override first.', v_serial, v_discount_pct);
                    END IF;
                    SELECT can_give_discount, max_discount_percent
                      INTO v_sup_can_discount, v_sup_max_discount
                    FROM ric_user_sales_controls
                    WHERE client_id = v_client_id AND company_id = v_company_id
                      AND user_id = v_discount_given_by AND is_deleted = false;
                    IF NOT coalesce(v_sup_can_discount, false)
                       OR (v_sup_max_discount IS NOT NULL AND v_discount_pct > v_sup_max_discount) THEN
                        RAISE EXCEPTION 'DISCOUNT_OVERRIDE_INVALID'
                            USING DETAIL = format('Line %s: the supervisor who authorized this discount is not currently eligible to approve %s%%.', v_serial, v_discount_pct);
                    END IF;
                END IF;
            ELSE
                v_discount_given_by := NULL;
            END IF;

            SELECT tracking_type IN ('BATCH','BATCH_WITH_EXPIRY'), tracking_type = 'SERIAL'
              INTO v_is_batch_tracked, v_is_serial_tracked
            FROM rim_products WHERE id = (v_line->>'product_id')::uuid;

            v_has_batches := EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
                                      WHERE (value->>'line_serial')::integer = v_serial);
            v_has_serials := EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
                                      WHERE (value->>'line_serial')::integer = v_serial);

            IF coalesce(v_dispatch_stock, true) THEN
                IF v_is_batch_tracked AND NOT v_has_batches THEN
                    RAISE EXCEPTION 'BATCH_ALLOCATION_REQUIRED'
                        USING DETAIL = format('Line %s: select which batch(es) this sale is dispatching from.', v_serial);
                END IF;
                IF v_is_serial_tracked AND NOT v_has_serials THEN
                    RAISE EXCEPTION 'SERIAL_ALLOCATION_REQUIRED'
                        USING DETAIL = format('Line %s: select which serial(s) this sale is dispatching.', v_serial);
                END IF;
            END IF;

            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source, price_override_reason, price_source_entry_no,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount,
                remarks, created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_serial,
                (v_line->>'product_id')::uuid,
                nullif(v_line->>'item_description', ''),
                nullif(v_line->>'barcode', ''),
                (v_line->>'uom_id')::uuid,
                coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
                coalesce((v_line->>'qty_pack')::numeric, 0),
                coalesce((v_line->>'qty_loose')::numeric, 0),
                coalesce((v_line->>'base_qty')::numeric, 0),
                v_rate, v_price_source, v_override_reason, v_price_entry_no,
                coalesce((v_line->>'gross_amount')::numeric, 0),
                v_discount_pct,
                coalesce((v_line->>'discount_amount')::numeric, 0),
                v_discount_given_by,
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

        -- DIRECT mode only: charges are freshly client-supplied every
        -- save (same "always editable" convention as Sales Order) — see
        -- the header comment on rid_sales_invoice_charges for why
        -- AGAINST_QUOTATION/AGAINST_ORDER modes never reach this branch.
        FOR v_charge IN SELECT * FROM jsonb_array_elements(coalesce(p_charges, '[]'::jsonb))
        LOOP
            INSERT INTO rid_sales_invoice_charges (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
                amount_or_percent, percent, amount, tax_amount, allocation_factor,
                created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date,
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
    ELSIF v_invoice_mode = 'AGAINST_QUOTATION' THEN
        FOR v_source_line IN
            SELECT * FROM rid_sales_quotation_lines
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount,
                source_quotation_line_serial, created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_line.serial_no,
                v_source_line.product_id, v_source_line.item_description, v_source_line.barcode,
                v_source_line.uom_id, v_source_line.uom_conversion_factor,
                v_source_line.qty_pack, v_source_line.qty_loose, v_source_line.base_qty,
                v_source_line.rate, 'QUOTATION',
                v_source_line.gross_amount, v_source_line.discount_percent, v_source_line.discount_amount,
                CASE WHEN v_source_line.discount_percent > 0 THEN p_user_id END,
                v_source_line.tax_group_id, v_source_line.tax_amount, v_source_line.final_amount,
                v_source_line.base_amount, v_source_line.local_amount,
                v_source_line.charge_amount, v_source_line.landed_amount,
                v_source_line.serial_no, p_user_id, p_user_id
            );
        END LOOP;

        -- Charges copied VERBATIM from the source quotation's own charges
        -- — the client's own p_charges is ignored here, same rule as the
        -- line copy just above.
        FOR v_source_charge IN
            SELECT * FROM rid_sales_quotation_charges
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_charges (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
                amount_or_percent, percent, amount, tax_amount, allocation_factor,
                created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_charge.serial_no,
                v_source_charge.charge_id, v_source_charge.charge_name, v_source_charge.is_taxable,
                v_source_charge.tax_id, v_source_charge.nature, v_source_charge.gl_account_id,
                v_source_charge.amount_or_percent, v_source_charge.percent, v_source_charge.amount,
                v_source_charge.tax_amount, v_source_charge.allocation_factor,
                p_user_id, p_user_id
            );
        END LOOP;
    ELSIF v_invoice_mode = 'AGAINST_ORDER' THEN
        FOR v_source_order_line IN
            SELECT * FROM rid_sales_order_lines
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND order_no = v_order.order_no AND order_date = v_order.order_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount,
                source_order_line_serial, created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_order_line.serial_no,
                v_source_order_line.product_id, v_source_order_line.item_description, v_source_order_line.barcode,
                v_source_order_line.uom_id, v_source_order_line.uom_conversion_factor,
                v_source_order_line.qty_pack, v_source_order_line.qty_loose, v_source_order_line.base_qty,
                v_source_order_line.rate, 'ORDER',
                v_source_order_line.gross_amount, v_source_order_line.discount_percent, v_source_order_line.discount_amount,
                CASE WHEN v_source_order_line.discount_percent > 0 THEN p_user_id END,
                v_source_order_line.tax_group_id, v_source_order_line.tax_amount, v_source_order_line.final_amount,
                v_source_order_line.base_amount, v_source_order_line.local_amount,
                v_source_order_line.charge_amount, v_source_order_line.landed_amount,
                v_source_order_line.serial_no, p_user_id, p_user_id
            );
        END LOOP;

        -- Charges copied VERBATIM from the source order's own charges —
        -- same rule as AGAINST_QUOTATION mode above.
        FOR v_source_order_charge IN
            SELECT * FROM rid_sales_order_charges
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND order_no = v_order.order_no AND order_date = v_order.order_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_charges (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
                amount_or_percent, percent, amount, tax_amount, allocation_factor,
                created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_order_charge.serial_no,
                v_source_order_charge.charge_id, v_source_order_charge.charge_name, v_source_order_charge.is_taxable,
                v_source_order_charge.tax_id, v_source_order_charge.nature, v_source_order_charge.gl_account_id,
                v_source_order_charge.amount_or_percent, v_source_order_charge.percent, v_source_order_charge.amount,
                v_source_order_charge.tax_amount, v_source_order_charge.allocation_factor,
                p_user_id, p_user_id
            );
        END LOOP;
    END IF;

    -- Batch/serial staging — same generic tables/shape as GRN/Material
    -- Issue/Purchase Return, keyed by this invoice as source_doc_*.
    -- Populated from the client in every mode (a Quotation/Order never
    -- carries batch/serial, since neither ever touches stock).
    FOR v_batch IN SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
    LOOP
        INSERT INTO rid_transaction_line_batches (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
            batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
        ) VALUES (
            v_client_id, v_company_id, 'SALES_INVOICE', v_invoice_no, v_invoice_date,
            (v_batch->>'line_serial')::integer,
            v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
            coalesce((v_batch->>'qty_pack')::numeric, 0),
            coalesce((v_batch->>'qty_loose')::numeric, 0),
            coalesce((v_batch->>'base_qty')::numeric, 0),
            p_user_id
        );
    END LOOP;

    FOR v_serial_row IN SELECT * FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
    LOOP
        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        ) VALUES (
            v_client_id, v_company_id, 'SALES_INVOICE', v_invoice_no, v_invoice_date,
            (v_serial_row->>'line_serial')::integer, v_serial_row->>'serial_no', p_user_id
        );
    END LOOP;

    -- Mandatory batch/serial allocation, checked UNIFORMLY across all
    -- three modes (not just DIRECT) whenever dispatch will be immediate —
    -- AGAINST_QUOTATION/AGAINST_ORDER lines are re-derived server-side
    -- above and never went through DIRECT's own per-line check, so this
    -- final pass re-reads every line just inserted for THIS invoice and
    -- validates it against what was actually staged into
    -- rid_transaction_line_batches/rid_transaction_line_serials.
    IF coalesce(v_dispatch_stock, true) THEN
        FOR v_check_line IN
            SELECT l.serial_no, l.product_id,
                   p.tracking_type IN ('BATCH','BATCH_WITH_EXPIRY') AS is_batch_tracked,
                   p.tracking_type = 'SERIAL' AS is_serial_tracked
            FROM rid_sales_invoice_lines l
            JOIN rim_products p ON p.id = l.product_id
            WHERE l.client_id = v_client_id AND l.company_id = v_company_id
              AND l.invoice_no = v_invoice_no AND l.invoice_date = v_invoice_date AND l.is_deleted = false
        LOOP
            IF v_check_line.is_batch_tracked AND NOT EXISTS (
                SELECT 1 FROM rid_transaction_line_batches
                WHERE client_id = v_client_id AND company_id = v_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_invoice_date
                  AND line_serial = v_check_line.serial_no
            ) THEN
                RAISE EXCEPTION 'BATCH_ALLOCATION_REQUIRED'
                    USING DETAIL = format('Line %s: select which batch(es) this sale is dispatching from.', v_check_line.serial_no);
            END IF;
            IF v_check_line.is_serial_tracked AND NOT EXISTS (
                SELECT 1 FROM rid_transaction_line_serials
                WHERE client_id = v_client_id AND company_id = v_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_invoice_date
                  AND line_serial = v_check_line.serial_no
            ) THEN
                RAISE EXCEPTION 'SERIAL_ALLOCATION_REQUIRED'
                    USING DETAIL = format('Line %s: select which serial(s) this sale is dispatching.', v_check_line.serial_no);
            END IF;
        END LOOP;
    END IF;

    RETURN v_invoice_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_sales_invoice(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ============================================================
-- fn_approve_sales_invoice
-- ============================================================
-- The only place this module posts GL/stock. Order of operations:
-- period/backdate checks -> resolve GL accounts -> post SI voucher
-- (always) -> if stock_dispatch_mode='IMMEDIATE': post stock per line
-- (existing fn_post_stock_movement negative-stock/batch-serial rules
-- apply unchanged, zero new logic) + post COS voucher -> if
-- cash_collection_mode='IMMEDIATE': post up to two Receipt Vouchers ->
-- flip status='APPROVED'.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approve_sales_invoice(
    p_client_id   UUID,
    p_company_id  UUID,
    p_invoice_no  TEXT,
    p_invoice_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header              rih_sales_invoices%ROWTYPE;
    v_line                rid_sales_invoice_lines%ROWTYPE;
    v_batch                rid_transaction_line_batches%ROWTYPE;
    v_serial_row             rid_transaction_line_serials%ROWTYPE;
    v_invoice_ccy              TEXT;
    v_base_ccy                  TEXT;
    v_local_ccy                   TEXT;
    v_sales_account                 UUID;
    v_cos_account                     UUID;
    v_stock_account                     UUID;
    v_taxable_amount                        NUMERIC;
    v_tax_line                                RECORD;
    v_charge_row                                rid_sales_invoice_charges%ROWTYPE;
    v_charge_amount                              NUMERIC;
    v_charge_tax_account                          UUID;
    v_customer_ccy                            TEXT;
    v_party_rate                                NUMERIC;
    v_party_ccy                                   TEXT;
    v_si_lines                                      JSONB := '[]'::jsonb;
    v_cos_lines                                       JSONB := '[]'::jsonb;
    v_si_result                                         RECORD;
    v_cos_voucher_no                                      TEXT;
    v_cos_voucher_date                                      DATE;
    v_has_batches                                           BOOLEAN;
    v_has_serials                                             BOOLEAN;
    v_unit_cost                                                 NUMERIC;
    v_line_cost_total                                             NUMERIC;
    v_receipt_header                                                    JSONB;
    v_receipt_lines                                                       JSONB;
    v_receipt_no                                                            TEXT;
    v_cash_account_local                                                      UUID;
    v_cash_account_base                                                        UUID;
    v_local_to_base_rate                                                        NUMERIC;
    v_base_to_local_rate                                                         NUMERIC;
    v_receipt_party_rate                                                          NUMERIC;
    v_receipt_party_ccy                                                            TEXT;
BEGIN
    SELECT * INTO v_header FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % dated % not found', p_invoice_no, p_invoice_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Invoice % is % and cannot be approved again', p_invoice_no, v_header.status;
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_invoice_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_INVOICE', p_invoice_date);

    SELECT currency_id INTO v_invoice_ccy FROM rim_currencies WHERE id = v_header.invoice_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- Customer line's own currency shortcut (same idiom as GRN's Supplier
    -- line / Purchase Bill's Supplier line: same-currency shortcut, else
    -- the header's own base/local rate, else a real exchange-rate lookup).
    SELECT c.currency_id INTO v_customer_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.customer_id;
    IF v_customer_ccy IS NULL OR v_customer_ccy = v_invoice_ccy THEN
        v_party_rate := 1; v_party_ccy := v_invoice_ccy;
    ELSIF v_customer_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_customer_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_invoice_ccy, v_customer_ccy, p_invoice_date);
        v_party_ccy := v_customer_ccy;
    END IF;

    -- Customer DR — one line for the whole invoice, tagged inv_bill_no=self
    -- so it appears in v_pending_bills regardless of collection mode.
    v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_header.customer_id, 'trans_nature', 'DR',
        'trans_amount', v_header.grand_total, 'trans_currency', v_invoice_ccy,
        'base_amount', v_header.grand_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_header.grand_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_header.grand_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', p_invoice_no, 'inv_bill_date', p_invoice_date,
        'source_line_type', 'CUSTOMER', 'source_line_no', 0
    ));

    -- Per-line Sales CR + per-tax Sales Tax CR.
    FOR v_line IN
        SELECT * FROM rid_sales_invoice_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;

        v_sales_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'SALES_ACCOUNT');
        IF v_sales_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Sales Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_taxable_amount := v_line.final_amount - v_line.tax_amount;

        v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_sales_account, 'trans_nature', 'CR',
            'trans_amount', v_taxable_amount, 'trans_currency', v_invoice_ccy,
            'base_amount', v_taxable_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_taxable_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_taxable_amount, 'party_currency', v_invoice_ccy, 'party_rate', 1,
            'source_line_type', 'SALES', 'source_line_no', v_line.serial_no
        ));

        IF v_line.tax_amount > 0 THEN
            IF v_line.tax_group_id IS NULL THEN
                RAISE EXCEPTION 'LINE_TAX_GROUP_MISSING'
                    USING DETAIL = format('Line %s: has a tax amount but no tax group.', v_line.serial_no);
            END IF;

            -- One CR line per active tax in the line's tax group, weighted
            -- by rate (same apportionment idiom as GRN's own tax handling).
            -- A RECORD variable is required here — PL/pgSQL's `FOR a, b IN
            -- SELECT ...` (destructuring straight into two scalars) is not
            -- valid syntax, only `FOR rec IN SELECT ...` is.
            FOR v_tax_line IN
                SELECT t.gl_output_account_id AS tax_account,
                       v_line.tax_amount * (coalesce(r.tax_rate, 0) / NULLIF(sum(coalesce(r.tax_rate, 0)) OVER (), 0)) AS tax_portion
                FROM rim_tax_group_members gm
                JOIN rim_taxes t ON t.id = gm.tax_id
                JOIN LATERAL (SELECT fn_get_active_tax_rate(gm.tax_id, p_invoice_date) AS tax_rate) r ON true
                WHERE gm.tax_group_id = v_line.tax_group_id
            LOOP
                IF v_tax_line.tax_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('Line %s: a tax in its tax group has no Output GL account configured.', v_line.serial_no);
                END IF;

                v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_tax_line.tax_account, 'trans_nature', 'CR',
                    'trans_amount', v_tax_line.tax_portion, 'trans_currency', v_invoice_ccy,
                    'base_amount', v_tax_line.tax_portion * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_tax_line.tax_portion * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_tax_line.tax_portion, 'party_currency', v_invoice_ccy, 'party_rate', 1,
                    'source_line_type', 'SALES_TAX', 'source_line_no', v_line.serial_no
                ));
            END LOOP;
        END IF;
    END LOOP;

    -- Charges — one CR (ADD) or DR (DEDUCT) leg per charge, straight to
    -- that charge's own gl_account_id (never fn_resolve_account_link;
    -- unlike product lines, a charge's GL account is captured directly on
    -- the charge row at entry time, same as GRN/PO charges). This is the
    -- first place any Sales-module charge's gl_account_id actually posts
    -- — Quotation/Order never post GL at all. tax_amount is trusted as
    -- stored (client-computed, same idiom as the charge's own `amount`)
    -- rather than re-derived server-side: unlike a product line's tax
    -- group (multiple member taxes needing weighted apportionment), a
    -- charge references exactly one tax_id, so there is no apportionment
    -- ambiguity to protect against by recomputing.
    FOR v_charge_row IN
        SELECT * FROM rid_sales_invoice_charges
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        IF v_charge_row.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge_row.charge_name);
        END IF;

        v_charge_amount := v_charge_row.amount;

        v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_charge_row.gl_account_id,
            'trans_nature', CASE WHEN v_charge_row.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
            'trans_amount', v_charge_amount, 'trans_currency', v_invoice_ccy,
            'base_amount', v_charge_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_charge_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_charge_amount, 'party_currency', v_invoice_ccy, 'party_rate', 1,
            'source_line_type', 'SALES_CHARGE', 'source_line_no', v_charge_row.serial_no
        ));

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

            v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge_tax_account,
                'trans_nature', CASE WHEN v_charge_row.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
                'trans_amount', v_charge_row.tax_amount, 'trans_currency', v_invoice_ccy,
                'base_amount', v_charge_row.tax_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                'local_amount', v_charge_row.tax_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                'party_amount', v_charge_row.tax_amount, 'party_currency', v_invoice_ccy, 'party_rate', 1,
                'source_line_type', 'SALES_CHARGE_TAX', 'source_line_no', v_charge_row.serial_no
            ));
        END IF;
    END LOOP;

    SELECT * INTO v_si_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'SI', p_invoice_date,
        v_si_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
    );

    -- FIX: the Customer DR line above was tagged inv_bill_no=p_invoice_no as
    -- a stand-in, since the SI voucher's own real trans_no isn't known until
    -- fn_post_voucher returns. But invoice_no and the SI voucher's trans_no
    -- are two different draws from the SAME 'SI' fn_next_trans_no sequence
    -- (one at save time for invoice_no, one here at approve time for the
    -- voucher itself) — they are NOT the same value. fn_post_finance_voucher's
    -- settlement lookup joins the settling line's inv_bill_no against this
    -- line's real trans_no, so the self-reference must be corrected to the
    -- voucher's actual trans_no/trans_date here, or Cash-sale settlement
    -- silently never finds this line. Filtered by source_line_type/
    -- source_line_no (not inv_bill_no, which this statement also SETs).
    UPDATE rid_finance_lines SET
        inv_bill_no   = v_si_result.trans_no,
        inv_bill_date = v_si_result.trans_date
    WHERE client_id       = p_client_id
      AND company_id      = p_company_id
      AND location_id     = v_header.location_id
      AND trans_no        = v_si_result.trans_no
      AND trans_date      = v_si_result.trans_date
      AND source_line_type = 'CUSTOMER' AND source_line_no = 0;

    -- Stock dispatch + Cost of Sales — only when this invoice snapshotted
    -- IMMEDIATE at save time.
    IF v_header.stock_dispatch_mode = 'IMMEDIATE' THEN
        v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date);

        FOR v_line IN
            SELECT * FROM rid_sales_invoice_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
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

            -- Snapshot current moving-average cost under the SAME lock
            -- fn_post_stock_movement re-acquires internally (Stock-
            -- Adjustment-style pre-fetch) — that function never hands
            -- cost back to the caller.
            SELECT cost_price INTO v_unit_cost
            FROM rim_product_location
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND location_id = v_header.location_id AND product_id = v_line.product_id
            FOR UPDATE;
            v_unit_cost := coalesce(v_unit_cost, 0);

            v_has_batches := EXISTS (
                SELECT 1 FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                  AND line_serial = v_line.serial_no
            );
            v_has_serials := EXISTS (
                SELECT 1 FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                  AND line_serial = v_line.serial_no
            );

            v_line_cost_total := 0;

            IF v_has_batches THEN
                FOR v_batch IN
                    SELECT * FROM rid_transaction_line_batches
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_invoice_date, 'SALES_INVOICE', -v_batch.base_qty,
                        NULL, NULL, v_batch.batch_no, NULL, NULL,
                        'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_batch.base_qty * v_unit_cost;
                END LOOP;
            ELSIF v_has_serials THEN
                FOR v_serial_row IN
                    SELECT * FROM rid_transaction_line_serials
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_invoice_date, 'SALES_INVOICE', -1,
                        NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                        'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_unit_cost;
                END LOOP;
            ELSE
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_invoice_date, 'SALES_INVOICE', -v_line.base_qty,
                    NULL, NULL, NULL, NULL, NULL,
                    'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
                );
                v_line_cost_total := v_line.base_qty * v_unit_cost;
            END IF;

            -- COS voucher: pure internal costing, always base currency,
            -- base_rate=1. No real external party, but rid_finance_lines
            -- requires party_currency NOT NULL regardless — same
            -- self-referential convention every other purely-internal
            -- voucher already uses (e.g. Material Issue's MIC lines,
            -- 068_material_issue.sql): party_amount/party_currency mirror
            -- trans_amount/trans_currency, party_rate=1.
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
        END LOOP;

        SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'COS', p_invoice_date,
            v_cos_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
        );
    END IF;

    -- Cash collection — settle up to two Receipt Vouchers against this
    -- invoice's own bill, via fn_save_finance_voucher +
    -- fn_post_finance_voucher DIRECTLY (never fn_post_voucher, which
    -- hardcodes is_on_account=true). Resolved from the ORIGINAL cashier's
    -- (v_header.created_by) own Quick Invoice Setup row, never
    -- p_approved_by — a manager posting this later via Manager Review
    -- didn't personally collect the cash, and may not even have a Quick
    -- Invoice Setup row of their own. A cashier with no such row at all
    -- (e.g. a Credit-only user who nonetheless collected cash on this
    -- sale) is a clear, explicit error rather than a silently-null
    -- account_id surfacing as a confusing constraint failure deep inside
    -- fn_save_finance_voucher.
    --
    -- IMPORTANT: each receipt voucher's own trans_currency is LOCAL or
    -- BASE respectively — NOT the invoice's own currency — so
    -- v_header.rate_to_base/rate_to_local (which convert FROM the
    -- invoice's currency) and the earlier v_party_rate/v_party_ccy (also
    -- resolved against the invoice's currency) are the WRONG basis here
    -- and must not be reused. Each receipt needs its own fresh
    -- local<->base rate and its own fresh customer-party rate resolved
    -- against ITS OWN trans_currency.
    IF v_header.cash_collection_mode = 'IMMEDIATE' THEN
        IF coalesce(v_header.collected_amount_local, 0) > 0 OR coalesce(v_header.collected_amount_base, 0) > 0 THEN
            v_cash_account_local := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
            v_cash_account_base  := fn_quick_cash_account_base(p_client_id, p_company_id, v_header.created_by);
        END IF;

        IF coalesce(v_header.collected_amount_local, 0) > 0 THEN
            IF v_cash_account_local IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user who created this invoice has no Quick Invoice Setup (Local Cash Account) — cannot collect cash.';
            END IF;

            -- Resolve local->base and this customer's party rate, both
            -- against LOCAL currency (this receipt's own trans_currency).
            IF v_customer_ccy IS NULL OR v_customer_ccy = v_local_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_local_ccy;
            ELSIF v_customer_ccy = v_base_ccy THEN
                v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_invoice_date));
                v_receipt_party_rate := v_local_to_base_rate; v_receipt_party_ccy := v_base_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_customer_ccy, p_invoice_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_invoice_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_invoice_date,
                'voucher_type_code', 'CRV', 'is_on_account', false,
                'remarks', format('Collection against Sales Invoice %s', p_invoice_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_cash_account_local,
                    'trans_nature', 'DR', 'trans_amount', v_header.collected_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.collected_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.collected_amount_local, 'local_rate', 1,
                    'party_amount', v_header.collected_amount_local, 'party_currency', v_local_ccy, 'party_rate', 1
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_header.customer_id,
                    'trans_nature', 'CR', 'trans_amount', v_header.collected_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.collected_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.collected_amount_local, 'local_rate', 1,
                    'party_amount', v_header.collected_amount_local * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_si_result.trans_no, 'inv_bill_date', v_si_result.trans_date
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_invoice_date, p_approved_by);
            UPDATE rih_sales_invoices SET local_receipt_voucher_no = v_receipt_no, local_receipt_voucher_date = p_invoice_date WHERE id = v_header.id;
        END IF;

        IF coalesce(v_header.collected_amount_base, 0) > 0 THEN
            IF v_cash_account_base IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user who created this invoice has no Quick Invoice Setup (Base Cash Account) — cannot collect cash.';
            END IF;

            -- Resolve base->local and this customer's party rate, both
            -- against BASE currency (this receipt's own trans_currency).
            IF v_customer_ccy IS NULL OR v_customer_ccy = v_base_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_base_ccy;
            ELSIF v_customer_ccy = v_local_ccy THEN
                v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date));
                v_receipt_party_rate := v_base_to_local_rate; v_receipt_party_ccy := v_local_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_customer_ccy, p_invoice_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_invoice_date,
                'voucher_type_code', 'CRV', 'is_on_account', false,
                'remarks', format('Collection against Sales Invoice %s', p_invoice_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_cash_account_base,
                    'trans_nature', 'DR', 'trans_amount', v_header.collected_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.collected_amount_base, 'base_rate', 1,
                    'local_amount', v_header.collected_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.collected_amount_base, 'party_currency', v_base_ccy, 'party_rate', 1
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_header.customer_id,
                    'trans_nature', 'CR', 'trans_amount', v_header.collected_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.collected_amount_base, 'base_rate', 1,
                    'local_amount', v_header.collected_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.collected_amount_base * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_si_result.trans_no, 'inv_bill_date', v_si_result.trans_date
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_invoice_date, p_approved_by);
            UPDATE rih_sales_invoices SET base_receipt_voucher_no = v_receipt_no, base_receipt_voucher_date = p_invoice_date WHERE id = v_header.id;
        END IF;
    END IF;

    UPDATE rih_sales_invoices SET
        status              = 'APPROVED',
        approved_by         = p_approved_by,
        approved_at         = now(),
        sales_voucher_no    = v_si_result.trans_no,
        sales_voucher_date  = v_si_result.trans_date,
        cos_voucher_no      = v_cos_voucher_no,
        cos_voucher_date    = v_cos_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_invoice(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ------------------------------------------------------------
-- Small helpers: resolve the APPROVING user's own quick-invoice cash
-- accounts. Used above so the DR leg of each Receipt Voucher always
-- comes from the SAME cashier's assigned cash drawer, regardless of
-- whether Approve runs immediately (that cashier, online) or later via
-- Manager Review (the original cashier who created the DRAFT, not the
-- reviewing manager) — resolved from the invoice's own created_by, not
-- p_approved_by, for exactly that reason.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_quick_cash_account_local(p_client_id UUID, p_company_id UUID, p_created_by UUID)
RETURNS UUID LANGUAGE sql STABLE AS $$
    SELECT local_cash_account_id FROM ric_user_quick_invoice_setup
    WHERE client_id = p_client_id AND company_id = p_company_id AND user_id = p_created_by AND is_deleted = false;
$$;

CREATE OR REPLACE FUNCTION fn_quick_cash_account_base(p_client_id UUID, p_company_id UUID, p_created_by UUID)
RETURNS UUID LANGUAGE sql STABLE AS $$
    SELECT base_cash_account_id FROM ric_user_quick_invoice_setup
    WHERE client_id = p_client_id AND company_id = p_company_id AND user_id = p_created_by AND is_deleted = false;
$$;

GRANT EXECUTE ON FUNCTION fn_quick_cash_account_local(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_quick_cash_account_base(UUID, UUID, UUID) TO authenticated;


-- ============================================================
-- fn_cancel_sales_invoice
-- ============================================================
-- DRAFT only — once APPROVED (GL/stock posted), this build has no
-- reversal path; that's a future Sales Return module's job (Immutability
-- principle: never edit/unwind a posted transaction in place). Covers a
-- cashier discarding a mistaken DRAFT, and a manager cancelling a
-- STOCK_ISSUE-blocked invoice from the Manager Review screen. Since
-- cancellation only ever happens pre-posting, the source Quotation/
-- Order's live NOT EXISTS check in fn_save_sales_invoice automatically
-- re-admits it — no separate rollback bookkeeping needed.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_cancel_sales_invoice(
    p_client_id  UUID,
    p_company_id UUID,
    p_invoice_no TEXT,
    p_invoice_date DATE,
    p_reason     TEXT,
    p_user_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_sales_invoices%ROWTYPE;
BEGIN
    IF nullif(trim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Enter a reason for cancelling this invoice.';
    END IF;

    SELECT * INTO v_header FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % dated % not found', p_invoice_no, p_invoice_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Invoice % is % and cannot be cancelled — once approved, a correction can only be made through a future Sales Return.', p_invoice_no, v_header.status;
    END IF;

    UPDATE rih_sales_invoices SET
        status = 'CANCELLED',
        cancellation_reason = trim(p_reason),
        updated_at = now(), updated_by = p_user_id
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_cancel_sales_invoice(UUID, UUID, TEXT, DATE, TEXT, UUID) TO authenticated;


-- ============================================================
-- fn_verify_discount_override
-- ============================================================
-- Deliberately NOT a reuse of fn_login: verifies the password with the
-- same bcrypt crypt() check, but never touches failed_attempts/
-- locked_until/last_login_at and never mints a JWT — the cashier's own
-- session stays exactly as it was, nothing about the supervisor's login
-- state changes. Returns the supervisor's identity only if BOTH the
-- credentials AND their own current discount eligibility check out.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_verify_discount_override(
    p_client_id                  UUID,
    p_company_id                 UUID,
    p_username                   TEXT,
    p_password                   TEXT,
    p_requested_discount_percent NUMERIC
)
RETURNS TABLE (user_id UUID, full_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user            rim_users%ROWTYPE;
    v_can_discount    BOOLEAN;
    v_max_discount    NUMERIC;
BEGIN
    SELECT * INTO v_user FROM rim_users
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND username = lower(trim(p_username)) AND is_deleted = false;

    IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_CREDENTIALS'; END IF;
    IF NOT v_user.is_active THEN RAISE EXCEPTION 'ACCOUNT_INACTIVE'; END IF;
    IF v_user.locked_until IS NOT NULL AND v_user.locked_until > now() THEN RAISE EXCEPTION 'ACCOUNT_LOCKED'; END IF;
    IF v_user.password_hash != crypt(p_password, v_user.password_hash) THEN
        RAISE EXCEPTION 'INVALID_CREDENTIALS';
    END IF;

    SELECT can_give_discount, max_discount_percent INTO v_can_discount, v_max_discount
    FROM ric_user_sales_controls
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND ric_user_sales_controls.user_id = v_user.id AND is_deleted = false;

    IF NOT coalesce(v_can_discount, false)
       OR (v_max_discount IS NOT NULL AND p_requested_discount_percent > v_max_discount) THEN
        RAISE EXCEPTION 'DISCOUNT_NOT_AUTHORIZED'
            USING DETAIL = format('%s is not authorized to approve a %s%% discount.', v_user.full_name, p_requested_discount_percent);
    END IF;

    RETURN QUERY SELECT v_user.id, v_user.full_name;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_verify_discount_override(UUID, UUID, TEXT, TEXT, NUMERIC) TO authenticated;
