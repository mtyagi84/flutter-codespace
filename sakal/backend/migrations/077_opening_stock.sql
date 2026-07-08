-- ============================================================
-- Migration 077: Opening Stock
-- ============================================================
-- One-time (per product/location) document a new company — or an existing
-- company adding a new location — uses to establish each product's
-- starting quantity and cost before go-live. Designed interactively;
-- final shape below.
--
-- NO GL POSTING AT ALL — the first module in this schema to call
-- fn_post_stock_movement without also calling fn_post_voucher. Opening
-- Stock only sets rim_product_location.current_stock/cost_price and
-- appends to the stock ledger; the company's overall opening trial
-- balance (including the Stock account's own lump-sum opening Dr, which
-- should reconcile against the sum of everything entered here) is handled
-- separately, later, via a Finance-side account-opening-balances upload —
-- out of scope here, and NOT rim_opening_balances (013, Chart-of-Accounts
-- opening balance per account per financial year — a different shape of
-- data, untouched by this migration).
--
-- ONE LINE PER PHYSICAL LOT/UNIT, not one line per product — deliberately
-- diverges from every other module's "one line per product + child
-- rid_transaction_line_batches/rid_transaction_line_serials table" shape.
-- batch_no/expiry_date/serial_no live directly on rid_opening_stock_lines.
-- A serial-tracked product with 5 units on hand is 5 lines; a batch-
-- tracked product with 2 batches is 2 lines; an untracked product is 1
-- line. Better fit for what this document actually is (a flat stock-take/
-- legacy-export list), and makes a future Excel-upload trivial (one
-- spreadsheet row = one line, no nesting). `line_no` is this line's own
-- sequence number — NOT a serial-tracked product's physical serial number,
-- which is the separate `serial_no` column.
--
-- Cost IS user-entered — the one deliberate inversion of Stock
-- Adjustment's core rule (076): Stock Adjustment refuses to invent a cost
-- basis that doesn't exist yet; Opening Stock's entire job is to establish
-- that basis for the first time. unit_cost (base currency) is required on
-- every line; unit_cost_specific is derived via fn_get_exchange_rate if
-- the product's cost_currency_id differs from base (same-currency
-- shortcut otherwise, same "always-multiply" rule as everywhere else).
--
-- Hard guard against double-entry: a line is blocked at Approve if the
-- product already has ANY stock/cost at that location (current_stock <> 0
-- OR cost_price <> 0 on rim_product_location) — OPENING_STOCK_ALREADY_
-- ESTABLISHED. Prevents accidentally re-running opening stock on
-- something that's already been through a real GRN.
--
-- One voucher-type code only (OPST) — numbers the document; no separate
-- posting code needed since there's no posting at all.
-- ============================================================


-- ── 1. rih_opening_stock_headers ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_opening_stock_headers (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    location_id         UUID          NOT NULL REFERENCES ric_locations(id),
    opening_no          TEXT          NOT NULL,
    opening_date        DATE          NOT NULL,
    remarks             TEXT,
    status              TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by         UUID          REFERENCES rim_users(id),
    approved_at         TIMESTAMPTZ,
    is_active           BOOLEAN       NOT NULL DEFAULT true,
    is_deleted          BOOLEAN       NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          UUID          REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, opening_no, opening_date)
);

CREATE INDEX IF NOT EXISTS idx_opening_stock_headers_status ON rih_opening_stock_headers (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_opening_stock_headers_updated_at ON rih_opening_stock_headers;
CREATE TRIGGER trg_rih_opening_stock_headers_updated_at
    BEFORE UPDATE ON rih_opening_stock_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_opening_stock_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_opening_stock_headers" ON rih_opening_stock_headers;
CREATE POLICY "auth_rw_opening_stock_headers" ON rih_opening_stock_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_opening_stock_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_opening_stock_headers TO authenticated;


-- ── 2. rid_opening_stock_lines ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rid_opening_stock_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    opening_no            TEXT          NOT NULL,
    opening_date          DATE          NOT NULL,
    line_no               INTEGER       NOT NULL,   -- this line's own sequence — NOT the product's physical serial number
    product_id            UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1,
    pack_qty              NUMERIC(18,4) NOT NULL DEFAULT 0,
    loose_qty             NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty              NUMERIC(18,4) NOT NULL DEFAULT 0,
    batch_no              TEXT,
    expiry_date           DATE,
    serial_no             TEXT,          -- the physical unit's own serial number (SERIAL-tracked products only)
    unit_cost             NUMERIC(18,4) NOT NULL,   -- REQUIRED, user-entered — the one inversion of Stock Adjustment's rule
    unit_cost_specific    NUMERIC(18,4),             -- populated by fn_approve_opening_stock from unit_cost, never user-entered
    barcode               TEXT,
    remarks               TEXT,
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, opening_no, opening_date, line_no),
    FOREIGN KEY (client_id, company_id, opening_no, opening_date)
        REFERENCES rih_opening_stock_headers (client_id, company_id, opening_no, opening_date)
);

CREATE INDEX IF NOT EXISTS idx_opening_stock_lines_product ON rid_opening_stock_lines (product_id);

ALTER TABLE rid_opening_stock_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_opening_stock_lines" ON rid_opening_stock_lines;
CREATE POLICY "auth_rw_opening_stock_lines" ON rid_opening_stock_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_opening_stock_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_opening_stock_lines TO authenticated;


-- ── 3. Voucher type: OPST (numbering only — no GL posting code needed) ──────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('OPST', 'Opening Stock', 'STOCK', NULL, 'YEARLY', 'OPST/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 4. Menu seed for existing companies (IN-OPN already added to ─────────────
--      fn_seed_client_modules.sql for future clients, in the same session) ──
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, 'IN-OPN', 'Opening Stock', '/inventory/opening-stock',
    7, 'IN-OPS', 'Operations', 0, true, false, true
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'IN'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_opening_stock — DRAFT-only. No batches/serials params needed —
-- unlike every other batch/serial-capable module's (header, lines,
-- batches, serials, user_id) shape, batch_no/expiry_date/serial_no are
-- flat on the line already.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_opening_stock(
    p_header  JSONB,
    p_lines   JSONB,   -- [{line_no, product_id, uom_id, uom_conversion_factor, pack_qty, loose_qty, base_qty, batch_no, expiry_date, serial_no, unit_cost, barcode, remarks}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id    UUID;
    v_company_id   UUID;
    v_location_id  UUID;
    v_opening_no   TEXT;
    v_opening_date DATE;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_opening_no   := nullif(trim(p_header->>'opening_no'), '');
    v_opening_date := (p_header->>'opening_date')::date;
    v_is_new       := v_opening_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise an Opening Stock entry.';
    END IF;

    IF v_is_new THEN
        v_opening_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'OPST');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_opening_stock_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND opening_no = v_opening_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Opening Stock % is % and cannot be edited.', v_opening_no, v_old_status;
        END IF;

        DELETE FROM rid_opening_stock_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND opening_no = v_opening_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_opening_stock_headers (
            client_id, company_id, location_id, opening_no, opening_date,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_opening_no, v_opening_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_opening_stock_headers SET
            location_id  = v_location_id,
            opening_date = v_opening_date,
            remarks      = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND opening_no = v_opening_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_opening_stock_lines (
            client_id, company_id, opening_no, opening_date, line_no,
            product_id, uom_id, uom_conversion_factor, pack_qty, loose_qty, base_qty,
            batch_no, expiry_date, serial_no, unit_cost, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_opening_no, v_opening_date, (v_line->>'line_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'pack_qty')::numeric, 0), coalesce((v_line->>'loose_qty')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'batch_no', ''), (nullif(v_line->>'expiry_date', ''))::date, nullif(v_line->>'serial_no', ''),
            coalesce((v_line->>'unit_cost')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_opening_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_opening_stock(JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_opening_stock — no fn_post_voucher call anywhere in this
-- function; this document never posts to GL.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_opening_stock(
    p_client_id     UUID,
    p_company_id    UUID,
    p_opening_no    TEXT,
    p_opening_date  DATE,
    p_approved_by   UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header           rih_opening_stock_headers%ROWTYPE;
    v_line             RECORD;
    v_pl_id            UUID;
    v_current_stock    NUMERIC;
    v_current_cost     NUMERIC;
    v_base_ccy         TEXT;
    v_cost_ccy         TEXT;
    v_unit_cost_spec   NUMERIC;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_opening_stock_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND opening_no = p_opening_no AND opening_date = p_opening_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Opening Stock % dated % not found', p_opening_no, p_opening_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Opening Stock % is % and cannot be approved again', p_opening_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_opening_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'OPENING_STOCK', p_opening_date);

    IF p_opening_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Opening date %s is in the future — an Opening Stock entry cannot be dated ahead of today.', p_opening_date);
    END IF;

    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = p_company_id;

    -- 3. Per line: lock the balance row, block on already-established
    --    stock/cost, derive unit_cost_specific, post the movement.
    --    Sorted by product_id — the only row-type here, so no multi-type
    --    lock-order concern like GRN/Material Issue have.
    FOR v_line IN
        SELECT * FROM rid_opening_stock_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND opening_no = p_opening_no AND opening_date = p_opening_date AND is_deleted = false
        ORDER BY product_id, line_no
    LOOP
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_line.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT id, current_stock, cost_price INTO v_pl_id, v_current_stock, v_current_cost
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

        IF coalesce(v_current_stock, 0) <> 0 OR coalesce(v_current_cost, 0) <> 0 THEN
            RAISE EXCEPTION 'OPENING_STOCK_ALREADY_ESTABLISHED'
                USING DETAIL = format(
                    'Line %s: [%s] %s already has stock/cost established at this location (qty %s, cost %s) — Opening Stock can only be used before any other stock movement.',
                    v_line.line_no,
                    (SELECT product_code FROM rim_products WHERE id = v_line.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_line.product_id),
                    v_current_stock, v_current_cost);
        END IF;

        -- Derive unit_cost_specific from the entered unit_cost — same-
        -- currency shortcut if the product's own cost_currency_id matches
        -- base, otherwise a real fn_get_exchange_rate lookup. Never left
        -- unset, or cost_price_specific's own weighted average (a no-op
        -- here, since this is the very first inward movement) would be
        -- silently wrong for every future movement that reads it.
        SELECT c.currency_id INTO v_cost_ccy
        FROM rim_products p LEFT JOIN rim_currencies c ON c.id = p.cost_currency_id
        WHERE p.id = v_line.product_id;

        IF v_cost_ccy IS NULL OR v_cost_ccy = v_base_ccy THEN
            v_unit_cost_spec := v_line.unit_cost;
        ELSE
            v_unit_cost_spec := v_line.unit_cost * fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_cost_ccy, p_opening_date);
        END IF;

        UPDATE rid_opening_stock_lines SET
            unit_cost_specific = v_unit_cost_spec,
            updated_at = now(), updated_by = p_approved_by
        WHERE id = v_line.id;

        -- 4. Post the movement. One call per line — no v_has_batches/
        --    v_has_serials branching needed since batch/serial identity
        --    is already resolved per-line, not nested in a child table.
        PERFORM fn_post_stock_movement(
            p_client_id, p_company_id, v_header.location_id, v_line.product_id,
            p_opening_date, 'OPENING_STOCK', v_line.base_qty,
            v_line.unit_cost, v_unit_cost_spec,
            v_line.batch_no, v_line.expiry_date, v_line.serial_no,
            'OPENING_STOCK', p_opening_no, p_opening_date, p_approved_by
        );
    END LOOP;

    -- 5. No fn_post_voucher call — this document never posts to GL.

    -- 6. Mark the entry approved.
    UPDATE rih_opening_stock_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_opening_stock(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
