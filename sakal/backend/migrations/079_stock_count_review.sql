-- ============================================================
-- Migration 079: Stock Count Review — Screen 2 (Manager)
-- ============================================================
-- Second half of the physical stock-take module (078). A manager picks
-- multiple SUBMITTED Stock Count entries for the same location, sees them
-- clubbed (summed) per product/batch/serial against system stock AS OF a
-- chosen date, reviews the variance, and Approves — which computes the
-- final netted +/- lines and posts them through the EXISTING Stock
-- Adjustment engine (fn_save_stock_adjustment + fn_approve_stock_adjustment,
-- migration 076) — never a bespoke posting path. Inherits, for free: cost
-- lookup, GL account resolution, COST_NOT_ESTABLISHED guard, and the
-- strict batch/serial negative-stock rule.
--
-- NEVER MERGE SAME-PRODUCT QUANTITIES AT WRITE TIME — the codebase-wide
-- convention confirmed across Purchase Bill<-GRNs / GRN<-POs / Material
-- Issue<-Requisitions: none of them merge; they keep one row per source-
-- document reference and compute clubbed totals via a query at read time.
-- rid_stock_count_review_sources is membership-only (which submitted
-- counts this review includes); the clubbed variance itself is computed
-- on demand by fn_compute_stock_count_variance, never written as a merged
-- copy — called by BOTH the on-screen preview grid and Approve, so what
-- the manager sees is guaranteed to be what gets posted.
--
-- VARIANCE BASIS = system stock AS OF the review's own as_of_date,
-- computed by summing ril_stock_ledger (immutable, append-only, the
-- schema's sole source of truth) up to that date — never a live read of
-- rim_product_location.current_stock. Stays correct even if counting
-- spanned days or the manager reviews long after counting.
--
-- UNKNOWN SERIAL (physically counted, but the system has zero/no ledger
-- history for it at this location): flagged is_unknown_serial, excluded
-- from auto-adjustment entirely — never auto-create a '+' line with no
-- established cost/origin. Batch gets NORMAL +/- treatment (a never-
-- before-seen batch found physically is a legitimate '+' correction, same
-- as Stock Adjustment already allows) — only serial gets this exception.
--
-- RESERVATION-ONCE-CONSUMED, mirroring rih_grn_headers.billed_invoice_no
-- (054): a submitted count picked into a manager's DRAFT review is locked
-- (consolidated_into_review_no/date) from being picked into a second
-- concurrent review, reserved at DRAFT save already, not just Approve.
-- ============================================================


-- ── 1. Stock Adjustment traceability (additive — mirrors rih_finance_
--      headers.source_doc_type/no/date from migration 037, which Stock
--      Adjustment's own header currently lacks) ─────────────────────────────
ALTER TABLE rih_stock_adjustment_headers
    ADD COLUMN IF NOT EXISTS source_doc_type TEXT,
    ADD COLUMN IF NOT EXISTS source_doc_no   TEXT,
    ADD COLUMN IF NOT EXISTS source_doc_date DATE;

CREATE INDEX IF NOT EXISTS idx_stock_adjustment_headers_source
    ON rih_stock_adjustment_headers (client_id, company_id, source_doc_type, source_doc_no, source_doc_date);


-- ── 2. Voucher type: CNTR (numbering only) ───────────────────────────────────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('CNTR', 'Stock Count Review', 'STOCK', NULL, 'YEARLY', 'CNTR/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 3. rih_stock_count_review_headers ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_stock_count_review_headers (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL REFERENCES ric_clients(id),
    company_id             UUID          NOT NULL REFERENCES ric_companies(id),
    location_id            UUID          NOT NULL REFERENCES ric_locations(id),
    review_no              TEXT          NOT NULL,
    review_date            DATE          NOT NULL,
    as_of_date             DATE          NOT NULL,   -- the ONE canonical variance-comparison date, manager-set
    reason_id              UUID          REFERENCES rim_common_masters(id),  -- STOCK_ADJUSTMENT_REASON, e.g. 'Physical Count Variance'
    status                 TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by            UUID          REFERENCES rim_users(id),
    approved_at            TIMESTAMPTZ,
    posted_adjustment_no   TEXT,
    posted_adjustment_date DATE,
    remarks                TEXT,
    is_active               BOOLEAN       NOT NULL DEFAULT true,
    is_deleted               BOOLEAN       NOT NULL DEFAULT false,
    created_at               TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by                UUID          REFERENCES rim_users(id),
    updated_at                TIMESTAMPTZ,
    updated_by                UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, review_no, review_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_count_review_headers_status ON rih_stock_count_review_headers (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_stock_count_review_headers_updated_at ON rih_stock_count_review_headers;
CREATE TRIGGER trg_rih_stock_count_review_headers_updated_at
    BEFORE UPDATE ON rih_stock_count_review_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_stock_count_review_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_count_review_headers" ON rih_stock_count_review_headers;
CREATE POLICY "auth_rw_stock_count_review_headers" ON rih_stock_count_review_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_stock_count_review_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_stock_count_review_headers TO authenticated;


-- ── 4. rid_stock_count_review_sources — membership junction only ────────────
CREATE TABLE IF NOT EXISTS rid_stock_count_review_sources (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL,
    company_id        UUID          NOT NULL,
    review_no         TEXT          NOT NULL,
    review_date       DATE          NOT NULL,
    source_count_no   TEXT          NOT NULL,
    source_count_date DATE          NOT NULL,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, review_no, review_date, source_count_no, source_count_date),
    FOREIGN KEY (client_id, company_id, review_no, review_date)
        REFERENCES rih_stock_count_review_headers (client_id, company_id, review_no, review_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_count_review_sources_source
    ON rid_stock_count_review_sources (client_id, company_id, source_count_no, source_count_date);

ALTER TABLE rid_stock_count_review_sources ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_count_review_sources" ON rid_stock_count_review_sources;
CREATE POLICY "auth_rw_stock_count_review_sources" ON rid_stock_count_review_sources
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_stock_count_review_sources FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_stock_count_review_sources TO authenticated;


-- ── 5. Menu seed for existing companies ──────────────────────────────────────
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, 'IN-CNR', 'Stock Count Review', '/inventory/stock-count-review',
    9, 'IN-OPS', 'Operations', 0, true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'IN'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_adjustment widened — SAME 5-param signature, header JSONB
-- just accepts three more optional keys. The manual Stock Adjustment
-- screen never sends them, so they stay NULL there — fully backward
-- compatible.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_stock_adjustment(
    p_header  JSONB,
    p_lines   JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_location_id    UUID;
    v_adjustment_no  TEXT;
    v_adjustment_date DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
    v_batch          JSONB;
    v_line_qty       NUMERIC;
    v_batch_qty_sum  NUMERIC;
BEGIN
    v_client_id       := (p_header->>'client_id')::uuid;
    v_company_id      := (p_header->>'company_id')::uuid;
    v_location_id     := (p_header->>'location_id')::uuid;
    v_adjustment_no   := nullif(trim(p_header->>'adjustment_no'), '');
    v_adjustment_date := (p_header->>'adjustment_date')::date;
    v_is_new          := v_adjustment_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Stock Adjustment.';
    END IF;

    IF v_is_new THEN
        v_adjustment_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'ADJ');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_adjustment_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND adjustment_no = v_adjustment_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Adjustment % is % and cannot be edited.', v_adjustment_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = v_adjustment_no AND source_doc_date = v_adjustment_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = v_adjustment_no AND source_doc_date = v_adjustment_date;

        DELETE FROM rid_stock_adjustment_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND adjustment_no = v_adjustment_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_adjustment_headers (
            client_id, company_id, location_id, adjustment_no, adjustment_date,
            reason_id, remarks, source_doc_type, source_doc_no, source_doc_date,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_adjustment_no, v_adjustment_date,
            nullif(p_header->>'reason_id', '')::uuid, nullif(p_header->>'remarks', ''),
            nullif(p_header->>'source_doc_type', ''), nullif(p_header->>'source_doc_no', ''),
            (nullif(p_header->>'source_doc_date', ''))::date,
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_adjustment_headers SET
            location_id     = v_location_id,
            adjustment_date = v_adjustment_date,
            reason_id       = nullif(p_header->>'reason_id', '')::uuid,
            remarks         = nullif(p_header->>'remarks', ''),
            source_doc_type = nullif(p_header->>'source_doc_type', ''),
            source_doc_no   = nullif(p_header->>'source_doc_no', ''),
            source_doc_date = (nullif(p_header->>'source_doc_date', ''))::date,
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND adjustment_no = v_adjustment_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_stock_adjustment_lines (
            client_id, company_id, adjustment_no, adjustment_date, serial_no,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            adjust_flag, system_qty, barcode, reason_id, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_adjustment_no, v_adjustment_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            v_line->>'adjust_flag',
            nullif(v_line->>'system_qty', '')::numeric,
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'reason_id', '')::uuid,
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

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
                v_client_id, v_company_id, 'STOCK_ADJUSTMENT', v_adjustment_no, v_adjustment_date, (v_line->>'serial_no')::integer,
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
                USING DETAIL = format('Line %s: batch quantities sum to %s but the adjustment quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'STOCK_ADJUSTMENT', v_adjustment_no, v_adjustment_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    RETURN v_adjustment_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_stock_adjustment(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_count_review — DRAFT-only. Reservation pattern copied
-- exactly from fn_save_purchase_invoice's GRN-reservation logic (054).
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_stock_count_review(
    p_header      JSONB,   -- {client_id, company_id, location_id, review_no, review_date, as_of_date, reason_id, remarks}
    p_source_refs JSONB,   -- [{source_count_no, source_count_date}, ...] — the counts currently checked
    p_user_id     UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id       UUID;
    v_company_id      UUID;
    v_location_id     UUID;
    v_review_no       TEXT;
    v_review_date     DATE;
    v_old_review_date DATE;
    v_old_status      TEXT;
    v_is_new          BOOLEAN;
    v_ref             JSONB;
    v_count           rih_stock_count_headers%ROWTYPE;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_review_no   := nullif(trim(p_header->>'review_no'), '');
    v_review_date := (p_header->>'review_date')::date;
    v_is_new      := v_review_no IS NULL;

    IF jsonb_array_length(p_source_refs) = 0 THEN
        RAISE EXCEPTION 'Select at least one submitted Stock Count to build a Review.';
    END IF;

    IF v_is_new THEN
        v_review_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'CNTR');
    ELSE
        SELECT review_date, status INTO v_old_review_date, v_old_status
        FROM rih_stock_count_review_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND review_no = v_review_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Count Review % is % and cannot be edited.', v_review_no, v_old_status;
        END IF;

        -- Un-reserve whatever this draft previously held.
        UPDATE rih_stock_count_headers SET
            status = 'SUBMITTED', consolidated_into_review_no = NULL, consolidated_into_review_date = NULL,
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND consolidated_into_review_no = v_review_no AND consolidated_into_review_date = v_old_review_date;

        DELETE FROM rid_stock_count_review_sources
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND review_no = v_review_no AND review_date = v_old_review_date;
    END IF;

    -- Lock + validate + reserve each referenced count, one row per
    -- statement in a fixed sort order (deadlock-avoidance rule, 036/038 —
    -- SELECT ... ORDER BY ... FOR UPDATE does NOT guarantee lock-acquisition
    -- order, so lock one row per statement in a loop over sorted keys).
    FOR v_ref IN
        SELECT value FROM jsonb_array_elements(p_source_refs)
        ORDER BY value->>'source_count_no', value->>'source_count_date'
    LOOP
        SELECT * INTO v_count FROM rih_stock_count_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND count_no = v_ref->>'source_count_no' AND count_date = (v_ref->>'source_count_date')::date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Stock Count % not found.', v_ref->>'source_count_no';
        END IF;
        IF v_count.status = 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Count % is still DRAFT — it must be Submitted before it can be reviewed.', v_count.count_no;
        END IF;
        IF v_count.location_id != v_location_id THEN
            RAISE EXCEPTION 'Stock Count % is at a different location than this Review.', v_count.count_no;
        END IF;
        IF v_count.consolidated_into_review_no IS NOT NULL AND v_count.consolidated_into_review_no != v_review_no THEN
            RAISE EXCEPTION 'Stock Count % is already part of Review %.', v_count.count_no, v_count.consolidated_into_review_no;
        END IF;

        UPDATE rih_stock_count_headers SET
            status = 'CONSOLIDATED', consolidated_into_review_no = v_review_no, consolidated_into_review_date = v_review_date,
            updated_at = now(), updated_by = p_user_id
        WHERE id = v_count.id;

        INSERT INTO rid_stock_count_review_sources (
            client_id, company_id, review_no, review_date, source_count_no, source_count_date, created_by
        ) VALUES (
            v_client_id, v_company_id, v_review_no, v_review_date, v_count.count_no, v_count.count_date, p_user_id
        );
    END LOOP;

    IF v_is_new THEN
        INSERT INTO rih_stock_count_review_headers (
            client_id, company_id, location_id, review_no, review_date, as_of_date, reason_id, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_review_no, v_review_date,
            (p_header->>'as_of_date')::date, nullif(p_header->>'reason_id', '')::uuid,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_count_review_headers SET
            location_id = v_location_id, review_date = v_review_date, as_of_date = (p_header->>'as_of_date')::date,
            reason_id = nullif(p_header->>'reason_id', '')::uuid, remarks = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND review_no = v_review_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    RETURN v_review_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_stock_count_review(JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_compute_stock_count_variance — the single source of truth for
-- netting, called by BOTH the on-screen preview grid and Approve.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_compute_stock_count_variance(
    p_client_id   UUID,
    p_company_id  UUID,
    p_review_no   TEXT,
    p_review_date DATE
)
RETURNS TABLE (
    product_id        UUID,
    product_code       TEXT,
    product_name       TEXT,
    tracking_type      TEXT,
    batch_no            TEXT,
    expiry_date          DATE,
    serial_no             TEXT,
    counted_qty            NUMERIC,
    system_qty             NUMERIC,   -- SUM(ril_stock_ledger.qty_change) as of review.as_of_date
    variance_qty            NUMERIC,   -- counted - system
    adjust_flag              TEXT,      -- '+' / '-' / NULL (zero variance OR unknown serial — either way, no line posted)
    is_unknown_serial         BOOLEAN,   -- serial physically found but system_qty <= 0 here — exception, never auto-posted
    unit_cost                 NUMERIC    -- informational only; fn_approve_stock_adjustment re-fetches the real cost under lock
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_location_id UUID;
    v_as_of_date  DATE;
BEGIN
    SELECT location_id, as_of_date INTO v_location_id, v_as_of_date
    FROM rih_stock_count_review_headers
    WHERE client_id = p_client_id AND company_id = p_company_id AND review_no = p_review_no AND review_date = p_review_date;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Count Review % dated % not found', p_review_no, p_review_date;
    END IF;

    RETURN QUERY
    WITH sources AS (
        SELECT rs.source_count_no, rs.source_count_date FROM rid_stock_count_review_sources rs
        WHERE rs.client_id = p_client_id AND rs.company_id = p_company_id
          AND rs.review_no = p_review_no AND rs.review_date = p_review_date
    ),
    -- untracked: SUM across sources — same product counted in different,
    -- non-overlapping zones by different counters is genuinely additive.
    untracked_counts AS (
        SELECT l.product_id AS product_id, NULL::text AS batch_no, NULL::date AS expiry_date, NULL::text AS serial_no,
               SUM(l.counted_base_qty) AS counted_qty
        FROM rid_stock_count_lines l
        JOIN sources s ON s.source_count_no = l.count_no AND s.source_count_date = l.count_date
        JOIN rim_products p ON p.id = l.product_id
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id AND l.is_deleted = false
          AND l.is_counted = true AND p.tracking_type = 'NONE'
        GROUP BY l.product_id
    ),
    -- batch: club by product+batch_no across sources — additive.
    batch_counts AS (
        SELECT l.product_id AS product_id, b.batch_no AS batch_no, max(b.expiry_date) AS expiry_date, NULL::text AS serial_no,
               SUM(b.base_qty) AS counted_qty
        FROM rid_stock_count_lines l
        JOIN sources s ON s.source_count_no = l.count_no AND s.source_count_date = l.count_date
        JOIN rid_transaction_line_batches b
          ON b.client_id = l.client_id AND b.company_id = l.company_id
         AND b.source_doc_type = 'STOCK_COUNT' AND b.source_doc_no = l.count_no AND b.source_doc_date = l.count_date
         AND b.line_serial = l.serial_no
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id AND l.is_deleted = false AND l.is_counted = true
        GROUP BY l.product_id, b.batch_no
    ),
    -- serial: DISTINCT, not SUM — a serial found in two overlapping counts
    -- is the SAME physical unit, never double-counted.
    serial_counts AS (
        SELECT DISTINCT l.product_id AS product_id, NULL::text AS batch_no, NULL::date AS expiry_date, sr.serial_no AS serial_no,
               1::numeric AS counted_qty
        FROM rid_stock_count_lines l
        JOIN sources s ON s.source_count_no = l.count_no AND s.source_count_date = l.count_date
        JOIN rid_transaction_line_serials sr
          ON sr.client_id = l.client_id AND sr.company_id = l.company_id
         AND sr.source_doc_type = 'STOCK_COUNT' AND sr.source_doc_no = l.count_no AND sr.source_doc_date = l.count_date
         AND sr.line_serial = l.serial_no
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id AND l.is_deleted = false AND l.is_counted = true
    ),
    all_counts AS (
        SELECT * FROM untracked_counts
        UNION ALL SELECT * FROM batch_counts
        UNION ALL SELECT * FROM serial_counts
    ),
    system_untracked AS (
        SELECT sl.product_id AS product_id, SUM(sl.qty_change) AS system_qty
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.location_id = v_location_id AND sl.trans_date <= v_as_of_date
          AND sl.batch_no IS NULL AND sl.serial_no IS NULL
        GROUP BY sl.product_id
    ),
    system_batch AS (
        SELECT sl.product_id AS product_id, sl.batch_no AS batch_no, SUM(sl.qty_change) AS system_qty
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.location_id = v_location_id AND sl.trans_date <= v_as_of_date AND sl.batch_no IS NOT NULL
        GROUP BY sl.product_id, sl.batch_no
    ),
    system_serial AS (
        SELECT sl.product_id AS product_id, sl.serial_no AS serial_no, SUM(sl.qty_change) AS system_qty
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.location_id = v_location_id AND sl.trans_date <= v_as_of_date AND sl.serial_no IS NOT NULL
        GROUP BY sl.product_id, sl.serial_no
    )
    SELECT
        c.product_id, p.product_code, p.product_name, p.tracking_type, c.batch_no, c.expiry_date, c.serial_no,
        c.counted_qty,
        coalesce(CASE WHEN c.serial_no IS NOT NULL THEN ss.system_qty
                       WHEN c.batch_no  IS NOT NULL THEN sb.system_qty
                       ELSE su.system_qty END, 0) AS system_qty,
        c.counted_qty - coalesce(CASE WHEN c.serial_no IS NOT NULL THEN ss.system_qty
                                        WHEN c.batch_no  IS NOT NULL THEN sb.system_qty
                                        ELSE su.system_qty END, 0) AS variance_qty,
        CASE
            WHEN c.serial_no IS NOT NULL AND coalesce(ss.system_qty, 0) <= 0 THEN NULL
            WHEN (c.counted_qty - coalesce(CASE WHEN c.batch_no IS NOT NULL THEN sb.system_qty ELSE su.system_qty END, 0)) > 0 THEN '+'
            WHEN (c.counted_qty - coalesce(CASE WHEN c.batch_no IS NOT NULL THEN sb.system_qty ELSE su.system_qty END, 0)) < 0 THEN '-'
            ELSE NULL
        END AS adjust_flag,
        (c.serial_no IS NOT NULL AND coalesce(ss.system_qty, 0) <= 0) AS is_unknown_serial,
        pl.cost_price AS unit_cost
    FROM all_counts c
    JOIN rim_products p ON p.id = c.product_id
    LEFT JOIN system_untracked su ON su.product_id = c.product_id AND c.batch_no IS NULL AND c.serial_no IS NULL
    LEFT JOIN system_batch     sb ON sb.product_id = c.product_id AND sb.batch_no = c.batch_no
    LEFT JOIN system_serial    ss ON ss.product_id = c.product_id AND ss.serial_no = c.serial_no
    LEFT JOIN rim_product_location pl
           ON pl.client_id = p_client_id AND pl.company_id = p_company_id
          AND pl.location_id = v_location_id AND pl.product_id = c.product_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_compute_stock_count_variance(UUID, UUID, TEXT, DATE) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_stock_count_review — computes, then calls into the EXISTING
-- Stock Adjustment engine. Never writes ril_stock_ledger/rid_finance_lines
-- directly.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_stock_count_review(
    p_client_id   UUID,
    p_company_id  UUID,
    p_review_no   TEXT,
    p_review_date DATE,
    p_approved_by UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_header        rih_stock_count_review_headers%ROWTYPE;
    v_src           RECORD;
    v_row           RECORD;
    v_serial_no     INTEGER := 0;
    v_adj_header    JSONB;
    v_adj_lines     JSONB := '[]'::jsonb;
    v_adj_batches   JSONB := '[]'::jsonb;
    v_adj_serials   JSONB := '[]'::jsonb;
    v_uom_id        UUID;
    v_adjustment_no TEXT;
    v_unknown_count INTEGER := 0;
BEGIN
    SELECT * INTO v_header FROM rih_stock_count_review_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND review_no = p_review_no AND review_date = p_review_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Count Review % dated % not found', p_review_no, p_review_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Count Review % is % and cannot be approved again', p_review_no, v_header.status;
    END IF;

    -- Defensive fail-fast (fn_approve_stock_adjustment re-checks this on
    -- adjustment_date = as_of_date too, once it's called below).
    PERFORM fn_check_period_open(p_company_id, v_header.as_of_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_COUNT_REVIEW', v_header.as_of_date);
    IF v_header.as_of_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('As of date %s is in the future.', v_header.as_of_date);
    END IF;
    IF v_header.reason_id IS NULL THEN
        RAISE EXCEPTION 'A reason must be selected before this Review can be approved.';
    END IF;

    -- Lock every source count, fixed sort order (deadlock rule).
    FOR v_src IN
        SELECT source_count_no, source_count_date FROM rid_stock_count_review_sources
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND review_no = p_review_no AND review_date = p_review_date
        ORDER BY source_count_no, source_count_date
    LOOP
        PERFORM 1 FROM rih_stock_count_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND count_no = v_src.source_count_no AND count_date = v_src.source_count_date
        FOR UPDATE;
    END LOOP;

    FOR v_row IN SELECT * FROM fn_compute_stock_count_variance(p_client_id, p_company_id, p_review_no, p_review_date)
    LOOP
        IF v_row.is_unknown_serial THEN
            v_unknown_count := v_unknown_count + 1;
            CONTINUE;   -- never auto-created — resolved manually outside this module
        END IF;
        IF v_row.adjust_flag IS NULL THEN
            CONTINUE;   -- zero variance — no line
        END IF;

        v_serial_no := v_serial_no + 1;
        SELECT base_uom_id INTO v_uom_id FROM rim_products WHERE id = v_row.product_id;

        v_adj_lines := v_adj_lines || jsonb_build_array(jsonb_build_object(
            'serial_no', v_serial_no, 'product_id', v_row.product_id,
            'uom_id', v_uom_id, 'uom_conversion_factor', 1,
            'qty_pack', abs(v_row.variance_qty), 'qty_loose', 0, 'base_qty', abs(v_row.variance_qty),
            'adjust_flag', v_row.adjust_flag, 'system_qty', v_row.system_qty,
            'reason_id', v_header.reason_id,
            'remarks', format('Stock Count Review %s (as of %s)', p_review_no, v_header.as_of_date)
        ));

        IF v_row.batch_no IS NOT NULL THEN
            v_adj_batches := v_adj_batches || jsonb_build_array(jsonb_build_object(
                'line_serial', v_serial_no, 'batch_no', v_row.batch_no, 'expiry_date', v_row.expiry_date,
                'qty_pack', abs(v_row.variance_qty), 'qty_loose', 0, 'base_qty', abs(v_row.variance_qty)
            ));
        ELSIF v_row.serial_no IS NOT NULL THEN
            v_adj_serials := v_adj_serials || jsonb_build_array(jsonb_build_object(
                'line_serial', v_serial_no, 'serial_no', v_row.serial_no
            ));
        END IF;
    END LOOP;

    IF jsonb_array_length(v_adj_lines) = 0 THEN
        RAISE EXCEPTION 'NO_VARIANCE_LINES'
            USING DETAIL = format('No non-zero variance to post (%s unknown-serial exception(s) were skipped — resolve those separately).', v_unknown_count);
    END IF;

    v_adj_header := jsonb_build_object(
        'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
        'adjustment_date', v_header.as_of_date, 'reason_id', v_header.reason_id,
        'remarks', format('Auto-posted from Stock Count Review %s', p_review_no),
        'source_doc_type', 'STOCK_COUNT_REVIEW', 'source_doc_no', p_review_no, 'source_doc_date', p_review_date
    );

    -- Compose the EXISTING engine — never write ril_stock_ledger/
    -- rid_finance_lines directly.
    v_adjustment_no := fn_save_stock_adjustment(v_adj_header, v_adj_lines, v_adj_batches, v_adj_serials, p_approved_by);
    PERFORM fn_approve_stock_adjustment(p_client_id, p_company_id, v_adjustment_no, v_header.as_of_date, p_approved_by);

    UPDATE rih_stock_count_review_headers SET
        status = 'APPROVED', approved_by = p_approved_by, approved_at = now(),
        posted_adjustment_no = v_adjustment_no, posted_adjustment_date = v_header.as_of_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;

    RETURN v_adjustment_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_count_review(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
