-- ============================================================
-- Migration 083: Sales Price Master — second screen of the Sales module
-- ============================================================
-- Pays off the deferral migration 026 explicitly named in its own header
-- comment: "rim_product_location_price and fn_get_product_price deferred
-- to Sales module." See docs/screens/sales_price_master.md for the full
-- requirement document this migration implements (revised after
-- discussion — this replaces an earlier company-wide draft that was
-- never run/committed).
--
-- Design decisions (see requirement doc for the "why"):
--   • LOCATION-WISE, not company-wide — a product can price differently
--     per store. location_id lives on the header (one location per
--     batch, locked once a line exists) AND is snapshotted onto every
--     line (needed because the generic/customer coexistence uniqueness
--     rule below is enforced via a partial index at the LINE grain, and a
--     partial index cannot reach across tables to read the header).
--   • PER-LOCATION numbering via fn_next_trans_no (voucher type 'PRC',
--     format '{TYPE}/{LOC}/{YYYY}/{SEQ5}') — same scheme as Sales
--     Quotation, NOT Purchase Order's company-wide fn_next_company_doc_no
--     (an earlier draft of this migration wrongly used the latter).
--   • Header carries price_currency_id/rate_to_base/rate_to_local, same
--     shape as rih_sales_quotations — a batch is entered in one currency.
--   • A batch is either GENERIC (customer_id NULL) or CUSTOMER-specific
--     (customer_id required) — never mixed within one batch.
--   • effective_date/price_type/customer_id/location_id/status are all
--     SNAPSHOTTED from the header onto every line at save/approve time —
--     never trust the client payload for these on an existing batch.
--   • Coexistence of a GENERIC and a CUSTOMER price for the same
--     location+product+uom+date is solved with two partial unique
--     indexes (rim_account_link_defaults's WHERE-NULL pattern,
--     generalized), scoped to status = 'APPROVED' only.
--   • cost_price and margin_percent on the line are SNAPSHOT/CONVENIENCE
--     values, computed and supplied by the client — the server never
--     re-derives them. The one thing the server DOES
--     authoritatively enforce is: selling_price < cost_price implies
--     below_cost_reason_id IS NOT NULL, both at Save and again at
--     Approve (belt and suspenders — Save is the normal path, Approve
--     guards against a DRAFT written via direct API access).
--   • below_cost_reason_id points at a NEW rim_common_master_types entry,
--     'PRICE_BELOW_COST_REASON' — global type, seeded here; actual reason
--     VALUES are per-tenant and entered by the company via the existing
--     Common Masters screen, same convention as UNIT/BRAND/ITEM_SIZE.
--   • barcode on the line is an AUDIT field only — what was actually
--     scanned to build/identify this line, never a value silently
--     defaulted from the product's own catalog barcode. Duplicate
--     barcodes within one batch are rejected at Save.
--   • "Latest effective date wins" expiry model — unchanged, no
--     effective_to column, no overlap validation.
--   • Approve NEVER checks effective_date against today.
--   • Deliberately NO fn_check_period_open/fn_check_backdate_allowed at
--     Approve — this document never posts to the books at any status.
--   • Two states only: DRAFT -> APPROVED.
--   • fn_get_active_price now takes p_location_id as a HARD FILTER (no
--     cross-location fallback) — only Customer -> Generic falls back,
--     always within the same location.
-- ============================================================


-- ------------------------------------------------------------
-- New global common-master type for the below-cost reason picker. Global
-- (no client/company scoping), same shape as the UNIT/BRAND/ITEM_SIZE
-- types seeded in 022_common_masters.sql. Actual reason VALUES are
-- per-tenant rows added later via the Common Masters screen — not seeded
-- here.
-- ------------------------------------------------------------
INSERT INTO rim_common_master_types (type_key, type_name)
VALUES ('PRICE_BELOW_COST_REASON', 'Price Below Cost Reason')
ON CONFLICT (type_key) DO NOTHING;


-- ------------------------------------------------------------
-- rim_voucher_types — seed 'PRC'. PER-LOCATION numbering, consumed by the
-- existing fn_next_trans_no (NOT fn_next_company_doc_no — pricing is
-- location-wise, same numbering scheme as Sales Quotation's 'SQ').
-- 'SALES' is already an allowed voucher_nature value as of migration 081.
-- ------------------------------------------------------------
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('PRC', 'Price Master', 'SALES', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- rih_price_master_headers
-- location_id is a plain column (which store this batch prices, and an
-- input to fn_next_trans_no's per-location sequence) — it is NOT part of
-- the header's own composite identity (client_id, company_id, entry_no,
-- entry_date), same shape as Sales Quotation's own location_id.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rih_price_master_headers (
    id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id          UUID        NOT NULL REFERENCES ric_clients(id),
    company_id         UUID        NOT NULL REFERENCES ric_companies(id),
    location_id        UUID        NOT NULL REFERENCES ric_locations(id),
    entry_no           TEXT        NOT NULL,
    entry_date         DATE        NOT NULL,
    -- GENERIC = customer_id NULL, applies to every customer at this
    -- location. CUSTOMER = customer_id required, overrides the generic
    -- price for that one customer at this location only. A batch is
    -- never mixed.
    price_type         TEXT        NOT NULL DEFAULT 'GENERIC'
                       CHECK (price_type IN ('GENERIC', 'CUSTOMER')),
    customer_id        UUID        REFERENCES rim_accounts(id),
    -- May be before, on, or after entry_date — no validation against
    -- today in either direction. Gates fn_get_active_price only; has zero
    -- bearing on whether the batch itself can be approved.
    effective_date     DATE        NOT NULL,
    -- Currency this batch's lines are entered in. rate_to_base/local
    -- mirror rih_sales_quotations' own shape.
    price_currency_id  UUID        NOT NULL REFERENCES rim_currencies(id),
    rate_to_base       NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local      NUMERIC(18,8) NOT NULL DEFAULT 1,
    status             TEXT        NOT NULL DEFAULT 'DRAFT'
                       CHECK (status IN ('DRAFT', 'APPROVED')),
    approved_by        UUID        REFERENCES rim_users(id),
    approved_at        TIMESTAMPTZ,
    remarks            TEXT,
    is_deleted         BOOLEAN     NOT NULL DEFAULT false,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         UUID        REFERENCES rim_users(id),
    updated_at         TIMESTAMPTZ,
    updated_by         UUID        REFERENCES rim_users(id),
    CONSTRAINT uq_rih_price_master_headers UNIQUE (client_id, company_id, entry_no, entry_date),
    CONSTRAINT chk_price_master_customer_type CHECK (
        (price_type = 'GENERIC'  AND customer_id IS NULL) OR
        (price_type = 'CUSTOMER' AND customer_id IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_rih_pm_tenant   ON rih_price_master_headers (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rih_pm_location ON rih_price_master_headers (location_id);
CREATE INDEX IF NOT EXISTS idx_rih_pm_customer ON rih_price_master_headers (customer_id);
CREATE INDEX IF NOT EXISTS idx_rih_pm_status   ON rih_price_master_headers (client_id, company_id, status);
CREATE INDEX IF NOT EXISTS idx_rih_pm_eff_date ON rih_price_master_headers (client_id, company_id, effective_date DESC);

DROP TRIGGER IF EXISTS trg_rih_price_master_headers_updated_at ON rih_price_master_headers;
CREATE TRIGGER trg_rih_price_master_headers_updated_at
    BEFORE UPDATE ON rih_price_master_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_price_master_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_price_master_headers" ON rih_price_master_headers;
CREATE POLICY "auth_rw_price_master_headers" ON rih_price_master_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_price_master_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_price_master_headers TO authenticated;


-- ------------------------------------------------------------
-- rid_price_master_lines
-- location_id/price_type/customer_id/effective_date/status are all
-- SNAPSHOTTED from the header at save/approve time (never trust the
-- client payload for these) — required because the two partial unique
-- indexes below live at the LINE grain and a partial index cannot
-- reference another table's column.
-- cost_price/margin_percent are convenience/audit snapshots supplied by
-- the client — the server's only authoritative check involving them is
-- the below-cost
-- reason requirement, enforced in fn_save/fn_approve, not a CHECK
-- constraint (same reasoning as rid_sales_quotation_lines.rate having no
-- table-level CHECK — a DRAFT may temporarily hold an incomplete value).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rid_price_master_lines (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID        NOT NULL REFERENCES ric_clients(id),
    company_id            UUID        NOT NULL REFERENCES ric_companies(id),
    entry_no              TEXT        NOT NULL,
    entry_date            DATE        NOT NULL,
    serial_no             INTEGER     NOT NULL,
    product_id            UUID        NOT NULL REFERENCES rim_products(id),
    uom_id                UUID        NOT NULL REFERENCES rim_common_masters(id),
    -- Snapshotted at line-entry time, same rationale as every other line
    -- table's uom_conversion_factor.
    uom_conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1,
    -- What was actually scanned to build/identify this line — audit only,
    -- rim_product_uom.barcode remains the source of truth. NULL if the
    -- line was added via the Product Autocomplete instead of a scan.
    barcode               TEXT,
    -- Cost Price in the HEADER's currency at entry time (see the doc's
    -- three-way currency rule) — a snapshot, never re-derived here.
    cost_price            NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- Convenience/audit value: (selling_price - cost_price) / cost_price
    -- * 100, computed client-side, stored as supplied (markup-on-cost
    -- convention, confirmed with the user).
    margin_percent        NUMERIC(8,4),
    -- Named selling_price, not sales_price — that name already belongs to
    -- rid_stock_transfer_lines.sales_price (unrelated inter-entity field).
    selling_price         NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- Required iff selling_price < cost_price — enforced in
    -- fn_save_price_master_batch and re-checked in
    -- fn_approve_price_master_batch, never a CHECK constraint (needs a
    -- cross-column conditional, and DRAFT rows must stay editable even if
    -- momentarily incomplete).
    below_cost_reason_id  UUID        REFERENCES rim_common_masters(id),
    -- No tax_group_id here — rim_products.sales_tax_group_id is already
    -- the authoritative link, so a future Sales Order/Invoice resolves tax
    -- group from the product at the point of sale, not from this line.
    -- is_tax_inclusive stays: it's a property of THIS price entry (whether
    -- the typed selling_price already has tax baked in), not something the
    -- product master can answer.
    is_tax_inclusive      BOOLEAN     NOT NULL DEFAULT false,
    remarks               TEXT,
    -- Snapshot of the header's own columns — see migration header comment.
    location_id           UUID        NOT NULL REFERENCES ric_locations(id),
    price_type            TEXT        NOT NULL
                          CHECK (price_type IN ('GENERIC', 'CUSTOMER')),
    customer_id           UUID        REFERENCES rim_accounts(id),
    effective_date        DATE        NOT NULL,
    status                TEXT        NOT NULL DEFAULT 'DRAFT'
                          CHECK (status IN ('DRAFT', 'APPROVED')),
    is_deleted            BOOLEAN     NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by            UUID        REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID        REFERENCES rim_users(id),
    CONSTRAINT uq_rid_price_master_lines UNIQUE (client_id, company_id, entry_no, entry_date, serial_no),
    CONSTRAINT rid_price_master_lines_header_fk
        FOREIGN KEY (client_id, company_id, entry_no, entry_date)
        REFERENCES  rih_price_master_headers (client_id, company_id, entry_no, entry_date),
    -- Defense-in-depth mirror of the header's own XOR check, in case the
    -- snapshot ever drifts from the header (it shouldn't — both are only
    -- ever written by fn_save_price_master_batch/fn_approve_price_master_batch).
    CONSTRAINT chk_price_master_line_customer CHECK (
        (price_type = 'GENERIC'  AND customer_id IS NULL) OR
        (price_type = 'CUSTOMER' AND customer_id IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_rid_pm_lines_header   ON rid_price_master_lines (client_id, company_id, entry_no, entry_date);
CREATE INDEX IF NOT EXISTS idx_rid_pm_lines_product   ON rid_price_master_lines (product_id);
CREATE INDEX IF NOT EXISTS idx_rid_pm_lines_barcode    ON rid_price_master_lines (client_id, company_id, entry_no, entry_date, barcode) WHERE barcode IS NOT NULL;

-- The core coexistence rule: a GENERIC price and a CUSTOMER-specific price
-- for the same location+product+uom+effective_date must be able to
-- coexist; two GENERIC prices (or two prices for the SAME customer) at
-- that same combination must not. Scoped to APPROVED only — see migration
-- header comment (two DRAFT batches touching the same combination must be
-- allowed to coexist; the constraint fires at Approve, not Save).
CREATE UNIQUE INDEX IF NOT EXISTS uq_price_master_generic_active
    ON rid_price_master_lines (client_id, company_id, location_id, product_id, uom_id, effective_date)
    WHERE price_type = 'GENERIC' AND status = 'APPROVED' AND is_deleted = false;

CREATE UNIQUE INDEX IF NOT EXISTS uq_price_master_customer_active
    ON rid_price_master_lines (client_id, company_id, location_id, product_id, uom_id, customer_id, effective_date)
    WHERE price_type = 'CUSTOMER' AND status = 'APPROVED' AND is_deleted = false;

-- Read-side index for fn_get_active_price's resolution query.
CREATE INDEX IF NOT EXISTS idx_price_master_lines_resolve
    ON rid_price_master_lines (client_id, company_id, location_id, product_id, uom_id, customer_id, effective_date DESC)
    WHERE status = 'APPROVED' AND is_deleted = false;

ALTER TABLE rid_price_master_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_price_master_lines" ON rid_price_master_lines;
CREATE POLICY "auth_rw_price_master_lines" ON rid_price_master_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_price_master_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_price_master_lines TO authenticated;


-- ============================================================
-- PG FUNCTIONS
-- ============================================================


-- ------------------------------------------------------------
-- fn_save_price_master_batch — DRAFT-only save.
-- Generates entry_no on first save via fn_next_trans_no (voucher type
-- 'PRC', PER-LOCATION). Lines are deleted and re-inserted on every save.
-- Every line's location_id/price_type/customer_id/effective_date/status
-- is stamped from the HEADER, never trusted from the client payload.
-- Validates: price_type/customer_id XOR, >=1 line, no duplicate
-- (product_id, uom_id) pair, no duplicate non-null barcode, and every
-- below-cost line has a reason.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_save_price_master_batch(
    p_header  JSONB,
    p_lines   JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_location_id    UUID;
    v_entry_no       TEXT;
    v_entry_date     DATE;
    v_old_entry_date DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_price_type     TEXT;
    v_customer_id    UUID;
    v_effective_date DATE;
    v_line           JSONB;
    v_dup_count      INTEGER;
    v_dup_barcode    INTEGER;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_entry_no    := nullif(trim(p_header->>'entry_no'), '');
    v_entry_date  := (p_header->>'entry_date')::date;
    v_is_new      := v_entry_no IS NULL;

    v_price_type     := coalesce(p_header->>'price_type', 'GENERIC');
    v_customer_id    := (nullif(p_header->>'customer_id', ''))::uuid;
    v_effective_date := (p_header->>'effective_date')::date;

    IF v_location_id IS NULL THEN
        RAISE EXCEPTION 'Select a location.';
    END IF;
    IF v_price_type NOT IN ('GENERIC', 'CUSTOMER') THEN
        RAISE EXCEPTION 'Price Type must be Generic or Customer-Specific.';
    END IF;
    IF v_price_type = 'CUSTOMER' AND v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Select a customer, or switch to Generic.';
    END IF;
    IF v_price_type = 'GENERIC' AND v_customer_id IS NOT NULL THEN
        RAISE EXCEPTION 'A Generic batch cannot have a customer selected.';
    END IF;
    IF v_effective_date IS NULL THEN
        RAISE EXCEPTION 'Effective Date is required.';
    END IF;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one product price line.';
    END IF;

    SELECT count(*) INTO v_dup_count
    FROM (
        SELECT (l->>'product_id')::uuid AS product_id, (l->>'uom_id')::uuid AS uom_id
        FROM jsonb_array_elements(p_lines) l
        GROUP BY 1, 2
        HAVING count(*) > 1
    ) dupes;
    IF v_dup_count > 0 THEN
        RAISE EXCEPTION 'Each product+UOM combination can only appear once in a batch.';
    END IF;

    SELECT count(*) INTO v_dup_barcode
    FROM (
        SELECT nullif(l->>'barcode', '') AS barcode
        FROM jsonb_array_elements(p_lines) l
        WHERE nullif(l->>'barcode', '') IS NOT NULL
        GROUP BY 1
        HAVING count(*) > 1
    ) dupes;
    IF v_dup_barcode > 0 THEN
        RAISE EXCEPTION 'DUPLICATE_BARCODE'
            USING DETAIL = 'The same barcode is scanned onto more than one line in this batch.';
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        IF coalesce((v_line->>'selling_price')::numeric, 0) < coalesce((v_line->>'cost_price')::numeric, 0)
           AND nullif(v_line->>'below_cost_reason_id', '') IS NULL THEN
            RAISE EXCEPTION 'BELOW_COST_REASON_REQUIRED'
                USING DETAIL = format('Line %s: selling price is below cost — choose a reason.', v_line->>'serial_no');
        END IF;
    END LOOP;

    IF v_is_new THEN
        v_entry_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'PRC');

        INSERT INTO rih_price_master_headers (
            client_id, company_id, location_id, entry_no, entry_date,
            price_type, customer_id, effective_date,
            price_currency_id, rate_to_base, rate_to_local, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_entry_no, v_entry_date,
            v_price_type, v_customer_id, v_effective_date,
            (p_header->>'price_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        SELECT entry_date, status INTO v_old_entry_date, v_old_status
        FROM   rih_price_master_headers
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  entry_no = v_entry_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Price Master batch % not found', v_entry_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Price Master batch % is % and cannot be edited.', v_entry_no, v_old_status;
        END IF;

        UPDATE rih_price_master_headers SET
            location_id        = v_location_id,
            entry_date         = v_entry_date,
            price_type         = v_price_type,
            customer_id        = v_customer_id,
            effective_date     = v_effective_date,
            price_currency_id  = (p_header->>'price_currency_id')::uuid,
            rate_to_base       = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local      = coalesce((p_header->>'rate_to_local')::numeric, 1),
            remarks            = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND entry_no = v_entry_no AND status = 'DRAFT' AND is_deleted = false;

        DELETE FROM rid_price_master_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND entry_no = v_entry_no AND entry_date = v_old_entry_date;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_price_master_lines (
            client_id, company_id, entry_no, entry_date, serial_no,
            product_id, uom_id, uom_conversion_factor, barcode,
            cost_price, margin_percent, selling_price, below_cost_reason_id,
            is_tax_inclusive, remarks,
            location_id, price_type, customer_id, effective_date,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_entry_no, v_entry_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            (v_line->>'uom_id')::uuid,
            coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            nullif(v_line->>'barcode', ''),
            coalesce((v_line->>'cost_price')::numeric, 0),
            (v_line->>'margin_percent')::numeric,
            coalesce((v_line->>'selling_price')::numeric, 0),
            (nullif(v_line->>'below_cost_reason_id', ''))::uuid,
            coalesce((v_line->>'is_tax_inclusive')::boolean, false),
            nullif(v_line->>'remarks', ''),
            v_location_id, v_price_type, v_customer_id, v_effective_date,
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_entry_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_price_master_batch(JSONB, JSONB, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_approve_price_master_batch
-- Completeness validation only — NO period/backdate checks and,
-- deliberately, NO check of effective_date against today. Re-checks the
-- below-cost-reason rule (belt and suspenders against a DRAFT written via
-- direct API access, bypassing the UI's inline enforcement). Flips
-- header + every line to APPROVED together; the line UPDATE is what the
-- two partial unique indexes actually guard, so a collision with another
-- already-approved batch is caught and re-raised as a friendly, named
-- error instead of a raw constraint violation.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_approve_price_master_batch(
    p_client_id   UUID,
    p_company_id  UUID,
    p_entry_no    TEXT,
    p_entry_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_price_master_headers%ROWTYPE;
    v_line   RECORD;
    v_conflict_product TEXT;
BEGIN
    SELECT * INTO v_header FROM rih_price_master_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND entry_no = p_entry_no AND entry_date = p_entry_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Price Master batch % dated % not found', p_entry_no, p_entry_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Price Master batch % is % and cannot be approved again', p_entry_no, v_header.status;
    END IF;

    FOR v_line IN
        SELECT * FROM rid_price_master_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND entry_no = p_entry_no AND entry_date = p_entry_date AND is_deleted = false
    LOOP
        IF v_line.selling_price < 0 THEN
            RAISE EXCEPTION 'LINE_PRICE_INVALID'
                USING DETAIL = format('Line %s: selling price cannot be negative.', v_line.serial_no);
        END IF;
        IF v_line.selling_price < v_line.cost_price AND v_line.below_cost_reason_id IS NULL THEN
            RAISE EXCEPTION 'BELOW_COST_REASON_REQUIRED'
                USING DETAIL = format('Line %s: selling price is below cost — choose a reason.', v_line.serial_no);
        END IF;
    END LOOP;

    BEGIN
        UPDATE rid_price_master_lines SET
            status = 'APPROVED', updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND entry_no = p_entry_no AND entry_date = p_entry_date AND is_deleted = false;
    EXCEPTION WHEN unique_violation THEN
        SELECT format('[%s] %s', p.product_code, p.product_name)
        INTO   v_conflict_product
        FROM   rid_price_master_lines l
        JOIN   rim_products p ON p.id = l.product_id
        WHERE  l.client_id = p_client_id AND l.company_id = p_company_id
          AND  l.entry_no = p_entry_no AND l.entry_date = p_entry_date AND l.is_deleted = false
        LIMIT 1;

        RAISE EXCEPTION 'PRICE_ALREADY_EXISTS'
            USING DETAIL = format(
                'An approved price already exists for the same location/product/UOM/date combination (e.g. %s). Change the effective date or edit the existing price instead.',
                coalesce(v_conflict_product, 'one of the products in this batch')
            );
    END;

    UPDATE rih_price_master_headers SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_price_master_batch(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_get_active_price — the frozen resolution contract for the
-- not-yet-built Sales Order/Sales Invoice screens. p_location_id is a
-- HARD FILTER (pricing never falls back across locations) — only
-- Customer -> Generic falls back, within that same location. Both the
-- approval-gate (status='APPROVED') and the date-gate
-- (effective_date <= p_as_of_date) are enforced together in the same
-- WHERE clause. Returns NO ROWS if nothing qualifies.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_get_active_price(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID,
    p_product_id  UUID,
    p_uom_id      UUID,
    p_customer_id UUID,
    p_as_of_date  DATE
)
RETURNS TABLE (
    selling_price    NUMERIC,
    entry_no         TEXT,
    effective_date   DATE,
    price_type       TEXT,
    is_tax_inclusive BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_customer_id IS NOT NULL THEN
        RETURN QUERY
        SELECT l.selling_price, l.entry_no, l.effective_date, l.price_type, l.is_tax_inclusive
        FROM   rid_price_master_lines l
        WHERE  l.client_id = p_client_id AND l.company_id = p_company_id
          AND  l.location_id = p_location_id
          AND  l.product_id = p_product_id AND l.uom_id = p_uom_id
          AND  l.price_type = 'CUSTOMER' AND l.customer_id = p_customer_id
          AND  l.status = 'APPROVED' AND l.is_deleted = false
          AND  l.effective_date <= p_as_of_date
        ORDER BY l.effective_date DESC, l.created_at DESC
        LIMIT 1;

        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    RETURN QUERY
    SELECT l.selling_price, l.entry_no, l.effective_date, l.price_type, l.is_tax_inclusive
    FROM   rid_price_master_lines l
    WHERE  l.client_id = p_client_id AND l.company_id = p_company_id
      AND  l.location_id = p_location_id
      AND  l.product_id = p_product_id AND l.uom_id = p_uom_id
      AND  l.price_type = 'GENERIC' AND l.customer_id IS NULL
      AND  l.status = 'APPROVED' AND l.is_deleted = false
      AND  l.effective_date <= p_as_of_date
    ORDER BY l.effective_date DESC, l.created_at DESC
    LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_get_active_price(UUID, UUID, UUID, UUID, UUID, UUID, DATE) TO authenticated;


-- ============================================================
-- Menu seed — 'SL-PRC' (Price Master) for every already-existing company.
-- Unaffected by the location-wise redesign — menus don't concern
-- location scoping. fn_seed_client_modules (backend/functions/fn_seed_
-- client_modules.sql) is updated separately for FUTURE new clients.
-- Placed in a NEW group 'SL-MST' ("Pricing & Setup") positioned ABOVE the
-- existing 'SL-TXN' ("Transactions") group.
-- ============================================================

UPDATE ric_master_menus SET group_serial_no = 1
WHERE group_code = 'SL-TXN'
  AND module_id IN (SELECT id FROM ric_system_modules WHERE module_code = 'SL');

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'SL-PRC', 'Price Master', '/sales/price-master',
    0, 'SL-MST', 'Pricing & Setup', 0,
    true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'SL'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
