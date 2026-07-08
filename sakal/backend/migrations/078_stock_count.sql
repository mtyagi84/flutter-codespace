-- ============================================================
-- Migration 078: Stock Count — Screen 1 (Counter)
-- ============================================================
-- First half of the physical stock-take module. A counter picks a
-- Location, a count date, and an optional category-subtree/item-nature
-- filter; the system snapshots every matching product into a worksheet
-- (rid_stock_count_lines, one row per PRODUCT, is_counted=false), and the
-- counter fills in Pack+Loose qty per row (or, for batch/serial-tracked
-- products, per lot/unit physically found) across as many DRAFT sessions
-- as needed, then Submits.
--
-- BLIND COUNT — deliberately no system/expected qty anywhere in this
-- screen's data path, to avoid biasing the physical count. Variance is
-- only computed later, in Screen 2 (migration 079).
--
-- Deliberately NO fn_check_period_open/fn_check_backdate_allowed anywhere
-- in this migration — Submit never touches ril_stock_ledger or GL. Those
-- checks belong entirely to Screen 2's Approve, which is what actually
-- posts.
--
-- UNCOUNTED != COUNTED-ZERO. is_counted is the authoritative "row
-- touched" flag (not just nullable qty) because for a batch/serial-
-- tracked product, "confirmed empty" and "never touched" both look like
-- zero children unless flagged explicitly. A row stays is_counted=false
-- (and every *_qty column NULL) until the counter either types a
-- pack/loose qty (untracked product) or adds at least one batch/serial
-- child OR explicitly hits "Mark Counted — None Found" (tracked product).
--
-- ONE ROW PER COUNTED PRODUCT, not per lot — unlike Opening Stock's flat
-- one-row-per-lot shape. The worksheet is pre-populated by filter, one
-- row per in-scope product; batch/serial detail for a tracked product
-- hangs off that one row via the EXISTING generic
-- rid_transaction_line_batches/rid_transaction_line_serials tables
-- (source_doc_type='STOCK_COUNT'), same tables Stock Adjustment already
-- uses — no new child table needed. Divergence from how Stock Adjustment
-- uses those same tables: Stock Adjustment's '-' line shows an
-- EXISTING-lot candidate picker (reveals what the system expects); Stock
-- Count's batch/serial entry is PURE free-text new-lot entry (GRN-style —
-- counter types what they physically found), regardless of whether that
-- lot already exists in the system. Showing "expected" candidates would
-- leak system data into what must stay a blind count.
-- ============================================================


-- ── 1. Voucher type: CNT (numbering only — no GL posting code needed) ──────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('CNT', 'Stock Count', 'STOCK', NULL, 'YEARLY', 'CNT/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 2. rih_stock_count_headers ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_stock_count_headers (
    id                             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                      UUID          NOT NULL REFERENCES ric_clients(id),
    company_id                     UUID          NOT NULL REFERENCES ric_companies(id),
    location_id                    UUID          NOT NULL REFERENCES ric_locations(id),
    count_no                       TEXT          NOT NULL,
    count_date                     DATE          NOT NULL,
    category_filter_id             UUID          REFERENCES rim_item_categories(id),  -- NULL = no category filter (all)
    nature_filter                  TEXT,                                              -- NULL = no filter; else rim_products.product_nature's CHECK value
    status                         TEXT          NOT NULL DEFAULT 'DRAFT'
                                    CHECK (status IN ('DRAFT','SUBMITTED','CONSOLIDATED')),
    submitted_by                   UUID          REFERENCES rim_users(id),
    submitted_at                   TIMESTAMPTZ,
    consolidated_into_review_no    TEXT,          -- reservation pointer, set by Screen 2 at its own DRAFT save
    consolidated_into_review_date  DATE,
    remarks                        TEXT,
    is_active                      BOOLEAN       NOT NULL DEFAULT true,
    is_deleted                     BOOLEAN       NOT NULL DEFAULT false,
    created_at                     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by                     UUID          REFERENCES rim_users(id),
    updated_at                     TIMESTAMPTZ,
    updated_by                     UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, count_no, count_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_count_headers_status   ON rih_stock_count_headers (client_id, company_id, status);
CREATE INDEX IF NOT EXISTS idx_stock_count_headers_location ON rih_stock_count_headers (client_id, company_id, location_id, status);

DROP TRIGGER IF EXISTS trg_rih_stock_count_headers_updated_at ON rih_stock_count_headers;
CREATE TRIGGER trg_rih_stock_count_headers_updated_at
    BEFORE UPDATE ON rih_stock_count_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_stock_count_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_count_headers" ON rih_stock_count_headers;
CREATE POLICY "auth_rw_stock_count_headers" ON rih_stock_count_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_stock_count_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_stock_count_headers TO authenticated;


-- ── 3. rid_stock_count_lines ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rid_stock_count_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    count_no              TEXT          NOT NULL,
    count_date            DATE          NOT NULL,
    serial_no             INTEGER       NOT NULL,   -- this row's own sequence, one per in-scope product
    product_id            UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1,
    is_counted             BOOLEAN       NOT NULL DEFAULT false,   -- authoritative "row touched" flag — see header note
    counted_qty_pack       NUMERIC(18,4),                          -- NULL until is_counted=true
    counted_qty_loose      NUMERIC(18,4),
    counted_base_qty       NUMERIC(18,4),                          -- NULL only when is_counted=false; batch/serial rows = SUM(children)
    barcode                 TEXT,          -- audit only: which scan jumped to this row, if any
    remarks                 TEXT,
    is_deleted               BOOLEAN       NOT NULL DEFAULT false,
    created_at               TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by               UUID          REFERENCES rim_users(id),
    updated_at                TIMESTAMPTZ,
    updated_by                UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, count_no, count_date, serial_no),
    FOREIGN KEY (client_id, company_id, count_no, count_date)
        REFERENCES rih_stock_count_headers (client_id, company_id, count_no, count_date),
    CONSTRAINT chk_stock_count_lines_counted CHECK (
        (is_counted = false AND counted_base_qty IS NULL) OR (is_counted = true)
    )
);

CREATE INDEX IF NOT EXISTS idx_stock_count_lines_product ON rid_stock_count_lines (product_id);
CREATE INDEX IF NOT EXISTS idx_stock_count_lines_doc     ON rid_stock_count_lines (client_id, company_id, count_no, count_date);

ALTER TABLE rid_stock_count_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_count_lines" ON rid_stock_count_lines;
CREATE POLICY "auth_rw_stock_count_lines" ON rid_stock_count_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_stock_count_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_stock_count_lines TO authenticated;


-- ── 4. Menu seed for existing companies (mirrors migration 071's pattern) ────
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, 'IN-CNT', 'Stock Count', '/inventory/stock-count',
    8, 'IN-OPS', 'Operations', 0, true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'IN'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_stock_count_eligible_products — first Flutter caller of
-- fn_category_subtree (024). Called ONCE when the counter starts a new
-- count; the returned row set becomes the worksheet's fixed scope, never
-- re-run on resume (resuming reads rid_stock_count_lines directly).
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_stock_count_eligible_products(
    p_client_id   UUID,
    p_company_id  UUID,
    p_category_id UUID DEFAULT NULL,
    p_nature      TEXT DEFAULT NULL
)
RETURNS TABLE (
    product_id    UUID,
    product_code  TEXT,
    product_name  TEXT,
    tracking_type TEXT,
    base_uom_id   UUID,
    uom_label     TEXT,
    barcode       TEXT,
    part_number   TEXT
)
LANGUAGE sql STABLE
AS $$
    SELECT p.id, p.product_code, p.product_name, p.tracking_type, p.base_uom_id, u.description, p.barcode, p.part_number
    FROM rim_products p
    LEFT JOIN rim_common_masters u ON u.id = p.base_uom_id
    WHERE p.client_id = p_client_id AND p.company_id = p_company_id
      AND p.is_active = true AND p.is_deleted = false
      AND (p_category_id IS NULL OR p.category_id IN (SELECT id FROM fn_category_subtree(p_category_id)))
      AND (p_nature IS NULL OR p.product_nature = p_nature)
    ORDER BY p.product_code;
$$;

GRANT EXECUTE ON FUNCTION fn_stock_count_eligible_products(UUID, UUID, UUID, TEXT) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_count — DRAFT-only. p_lines is the FULL worksheet on every
-- save (not incremental) — same delete+reinsert shape as
-- fn_save_stock_adjustment (076).
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_stock_count(
    p_header  JSONB,   -- {client_id, company_id, location_id, count_no, count_date, category_filter_id, nature_filter, remarks}
    p_lines   JSONB,   -- [{serial_no, product_id, uom_id, uom_conversion_factor, is_counted, counted_qty_pack, counted_qty_loose, counted_base_qty, barcode, remarks}, ...]
    p_batches JSONB,   -- [{line_serial, batch_no, expiry_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials JSONB,   -- [{line_serial, serial_no}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_location_id    UUID;
    v_count_no       TEXT;
    v_count_date     DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
    v_batch          JSONB;
    v_is_counted     BOOLEAN;
    v_line_qty       NUMERIC;
    v_batch_qty_sum  NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_count_no    := nullif(trim(p_header->>'count_no'), '');
    v_count_date  := (p_header->>'count_date')::date;
    v_is_new      := v_count_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'No products in scope for this count — check the category/nature filter.';
    END IF;

    IF v_is_new THEN
        v_count_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'CNT');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_count_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND count_no = v_count_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Count % is % and cannot be edited.', v_count_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_COUNT' AND source_doc_no = v_count_no AND source_doc_date = v_count_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_COUNT' AND source_doc_no = v_count_no AND source_doc_date = v_count_date;
        DELETE FROM rid_stock_count_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND count_no = v_count_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_count_headers (
            client_id, company_id, location_id, count_no, count_date,
            category_filter_id, nature_filter, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_count_no, v_count_date,
            nullif(p_header->>'category_filter_id', '')::uuid, nullif(p_header->>'nature_filter', ''),
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        -- category_filter_id/nature_filter are immutable after creation — the
        -- worksheet's scope is fixed at first save, only counted values change.
        UPDATE rih_stock_count_headers SET
            location_id = v_location_id,
            count_date  = v_count_date,
            remarks     = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND count_no = v_count_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_is_counted := coalesce((v_line->>'is_counted')::boolean, false);

        INSERT INTO rid_stock_count_lines (
            client_id, company_id, count_no, count_date, serial_no,
            product_id, uom_id, uom_conversion_factor,
            is_counted, counted_qty_pack, counted_qty_loose, counted_base_qty,
            barcode, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_count_no, v_count_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            v_is_counted,
            CASE WHEN v_is_counted THEN coalesce((v_line->>'counted_qty_pack')::numeric, 0) END,
            CASE WHEN v_is_counted THEN coalesce((v_line->>'counted_qty_loose')::numeric, 0) END,
            CASE WHEN v_is_counted THEN coalesce((v_line->>'counted_base_qty')::numeric, 0) END,
            nullif(v_line->>'barcode', ''), nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        IF v_is_counted THEN
            v_line_qty := coalesce((v_line->>'counted_base_qty')::numeric, 0);
            v_batch_qty_sum := 0;

            FOR v_batch IN
                SELECT value FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
                WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
            LOOP
                INSERT INTO rid_transaction_line_batches (
                    client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                    batch_no, expiry_date, qty_pack, qty_loose, base_qty, created_by
                ) VALUES (
                    v_client_id, v_company_id, 'STOCK_COUNT', v_count_no, v_count_date, (v_line->>'serial_no')::integer,
                    v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date,
                    coalesce((v_batch->>'qty_pack')::numeric, 0), coalesce((v_batch->>'qty_loose')::numeric, 0),
                    coalesce((v_batch->>'base_qty')::numeric, 0), p_user_id
                );
                v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
            END LOOP;

            IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
                RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                    USING DETAIL = format('Line %s: batch quantities sum to %s but the counted quantity is %s.',
                                           v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
            END IF;

            INSERT INTO rid_transaction_line_serials (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
            )
            SELECT v_client_id, v_company_id, 'STOCK_COUNT', v_count_no, v_count_date, (v_line->>'serial_no')::integer,
                   value->>'serial_no', p_user_id
            FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
        END IF;
    END LOOP;

    RETURN v_count_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_stock_count(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_submit_stock_count — locks DRAFT->SUBMITTED. No ledger/GL effect at
-- all, so no period/backdate checks belong here.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_submit_stock_count(
    p_client_id  UUID,
    p_company_id UUID,
    p_count_no   TEXT,
    p_count_date DATE,
    p_user_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header        rih_stock_count_headers%ROWTYPE;
    v_counted_lines INTEGER;
BEGIN
    SELECT * INTO v_header FROM rih_stock_count_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND count_no = p_count_no AND count_date = p_count_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Count % dated % not found', p_count_no, p_count_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Count % is % and cannot be submitted again', p_count_no, v_header.status;
    END IF;

    SELECT count(*) INTO v_counted_lines FROM rid_stock_count_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND count_no = p_count_no AND count_date = p_count_date AND is_deleted = false AND is_counted = true;

    IF v_counted_lines = 0 THEN
        RAISE EXCEPTION 'NO_COUNTED_LINES'
            USING DETAIL = 'At least one product must be counted before this Stock Count can be submitted.';
    END IF;

    UPDATE rih_stock_count_headers SET
        status = 'SUBMITTED', submitted_by = p_user_id, submitted_at = now(),
        updated_at = now(), updated_by = p_user_id
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_submit_stock_count(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
