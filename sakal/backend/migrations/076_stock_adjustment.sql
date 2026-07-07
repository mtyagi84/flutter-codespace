-- ============================================================
-- Migration 076: Stock Adjustment
-- ============================================================
-- Ad-hoc, single-location quantity correction — increase or decrease a
-- product's stock at one location, with a reason, posting a Dr/Cr pair
-- against a resolvable Stock Adjustment account. Deliberately NOT combined
-- with Stock Take / physical inventory count — that is a fully separate
-- future module (its own tables/screen); no adjustment_type column or other
-- shared hook exists here for it.
--
-- Reused, not reinvented:
--   - STOCK_ADJUSTMENT_ACCOUNT account-link type already seeded (032),
--     never consumed until now.
--   - ADJUSTMENT_IN / ADJUSTMENT_OUT already valid ril_stock_ledger
--     trans_type values (036), never used until now — no CHECK-constraint
--     migration needed, unlike Material Issue's 067/068 -> 069/070 gap.
--   - rid_transaction_line_batches/rid_transaction_line_serials (the same
--     generic per-source-doc-line child tables every other module uses) —
--     direction lives on the parent line's adjust_flag, not on the batch/
--     serial row itself: a '+' line's batch/serial rows are NEW lots being
--     created (GRN-style entry); a '-' line's are EXISTING lots being
--     reduced (picker from v_batch_stock_balance/v_serial_stock_status,
--     same mandatory-allocation + strict "can never go negative" rule as
--     063). fn_save_stock_adjustment's batch/serial handling is therefore
--     identical regardless of direction — only fn_approve_stock_adjustment
--     branches by adjust_flag.
--   - IN-ADJ menu entry ('Stock Adjustment', /inventory/adjustments)
--     already exists for every company since the very first menu seed
--     (005) as a placeholder — same situation 071 documented for IN-TRF.
--     No menu migration needed; only the Flutter placeholder route gets
--     replaced with the real screen.
--
-- Cost is never user-entered (confirmed live): a '+' line's value comes
-- from the product's OWN current moving-average cost_price/cost_price_
-- specific at this location (rim_product_location), fetched under the same
-- row lock fn_post_stock_movement re-acquires internally, and persisted
-- onto the line itself (unit_cost/unit_cost_specific columns) for
-- reporting and voucher traceability — NOT derived by any fresh fx-rate
-- conversion. Blending "current average" into "current average" is
-- mathematically a no-op on cost (only quantity moves), which is exactly
-- the intended behavior: Stock Adjustment corrects quantity, never
-- invents a new cost basis. A '+' line on a product/location with no
-- established cost yet (cost_price NULL or 0 — never received via GRN, no
-- opening stock) is a hard block (COST_NOT_ESTABLISHED) — Stock Adjustment
-- is strictly a quantity-correction tool, never a way to introduce value
-- without a documented cost source. A '-' line is never blocked on this;
-- it simply records whatever cost is currently there, same as every other
-- outward-movement precedent in this schema (Material Issue, Purchase
-- Return).
--
-- No document currency — posts entirely in company base currency, same as
-- Material Issue's MIC (local_amount still derived via fn_get_exchange_
-- rate for print/ledger consistency, per the always-multiply rule).
--
-- Voucher codes: ADJ numbers adjustment_no; ADJV is the separate GL-
-- posting code, kept apart per the established numbering-vs-posting rule
-- (ril_trans_no_seq keys on (company, location, voucher_type_code)). Not
-- JV — this is a final, non-provisional entry (same reasoning that gave
-- Material Issue its own MIC instead of generic JV).
--
-- Reason: new STOCK_ADJUSTMENT_REASON common-master type (mirrors 064's
-- PURCHASE_RETURN_REASON exactly). Header reason_id is required; an
-- optional per-line reason_id overrides it for reporting.
-- ============================================================


-- ── 1. Reason as a Common Master ─────────────────────────────────────────────
INSERT INTO rim_common_master_types (type_key, type_name) VALUES
    ('STOCK_ADJUSTMENT_REASON', 'Stock Adjustment Reason')
ON CONFLICT (type_key) DO NOTHING;

INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order, created_by)
SELECT co.client_id, co.id, t.id, v.description, v.sort_order, NULL
FROM ric_companies co
CROSS JOIN rim_common_master_types t
CROSS JOIN (VALUES
    ('Damage', 1),
    ('Expiry', 2),
    ('Theft / Shrinkage', 3),
    ('Physical Count Variance', 4),
    ('Data Entry Correction', 5),
    ('Other', 6)
) AS v(description, sort_order)
WHERE t.type_key = 'STOCK_ADJUSTMENT_REASON'
ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;


-- ── 2. Voucher types: ADJ (numbering) + ADJV (GL posting) ────────────────────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('ADJ',  'Stock Adjustment',         'STOCK', NULL, 'YEARLY', 'ADJ/{LOC}/{YYYY}/{SEQ5}', true),
    ('ADJV', 'Stock Adjustment Voucher', 'STOCK', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 3. rih_stock_adjustment_headers ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_stock_adjustment_headers (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    location_id         UUID          NOT NULL REFERENCES ric_locations(id),
    adjustment_no       TEXT          NOT NULL,
    adjustment_date     DATE          NOT NULL,
    reason_id           UUID          REFERENCES rim_common_masters(id),
    remarks             TEXT,
    status              TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by         UUID          REFERENCES rim_users(id),
    approved_at         TIMESTAMPTZ,
    posted_voucher_no   TEXT,
    posted_voucher_date DATE,
    is_active           BOOLEAN       NOT NULL DEFAULT true,
    is_deleted          BOOLEAN       NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          UUID          REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, adjustment_no, adjustment_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_adjustment_headers_status ON rih_stock_adjustment_headers (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_stock_adjustment_headers_updated_at ON rih_stock_adjustment_headers;
CREATE TRIGGER trg_rih_stock_adjustment_headers_updated_at
    BEFORE UPDATE ON rih_stock_adjustment_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_stock_adjustment_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_adjustment_headers" ON rih_stock_adjustment_headers;
CREATE POLICY "auth_rw_stock_adjustment_headers" ON rih_stock_adjustment_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_stock_adjustment_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_stock_adjustment_headers TO authenticated;


-- ── 4. rid_stock_adjustment_lines ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rid_stock_adjustment_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    adjustment_no         TEXT          NOT NULL,
    adjustment_date       DATE          NOT NULL,
    serial_no             INTEGER       NOT NULL,
    product_id            UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack              NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose             NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty              NUMERIC(18,4) NOT NULL DEFAULT 0,   -- the adjustment quantity, always positive; direction is adjust_flag
    adjust_flag           TEXT          NOT NULL CHECK (adjust_flag IN ('+','-')),
    system_qty            NUMERIC(18,4),                       -- current_stock snapshot at line-add time, display hint only
    unit_cost             NUMERIC(18,4),                       -- populated by fn_approve_stock_adjustment, never user-entered
    unit_cost_specific    NUMERIC(18,4),                       -- populated by fn_approve_stock_adjustment, never user-entered
    barcode               TEXT,
    reason_id             UUID          REFERENCES rim_common_masters(id), -- optional per-line override of the header reason
    remarks               TEXT,
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, adjustment_no, adjustment_date, serial_no),
    FOREIGN KEY (client_id, company_id, adjustment_no, adjustment_date)
        REFERENCES rih_stock_adjustment_headers (client_id, company_id, adjustment_no, adjustment_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_adjustment_lines_product ON rid_stock_adjustment_lines (product_id);

ALTER TABLE rid_stock_adjustment_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_adjustment_lines" ON rid_stock_adjustment_lines;
CREATE POLICY "auth_rw_stock_adjustment_lines" ON rid_stock_adjustment_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_stock_adjustment_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_stock_adjustment_lines TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_adjustment — DRAFT-only, mirrors fn_save_material_issue's
-- shape exactly (header, lines, batches, serials, user_id — no charges).
-- Batch/serial handling is identical regardless of adjust_flag direction —
-- only fn_approve_stock_adjustment branches by direction.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_stock_adjustment(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, adjust_flag, system_qty, barcode, reason_id, remarks}, ...]
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
            reason_id, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_adjustment_no, v_adjustment_date,
            nullif(p_header->>'reason_id', '')::uuid, nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_adjustment_headers SET
            location_id     = v_location_id,
            adjustment_date = v_adjustment_date,
            reason_id       = nullif(p_header->>'reason_id', '')::uuid,
            remarks         = nullif(p_header->>'remarks', ''),
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

        -- Batch children for this line, if any were provided — same
        -- BATCH_QTY_MISMATCH rule as every other module. Identical handling
        -- regardless of direction: a '+' line's batches are new lots, a
        -- '-' line's are existing lots being reduced — fn_approve_stock_
        -- adjustment is what applies the sign, not this save step.
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
-- fn_approve_stock_adjustment
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_stock_adjustment(
    p_client_id      UUID,
    p_company_id     UUID,
    p_adjustment_no  TEXT,
    p_adjustment_date DATE,
    p_approved_by    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header          rih_stock_adjustment_headers%ROWTYPE;
    v_base_ccy        TEXT;
    v_local_ccy       TEXT;
    v_rate_to_local   NUMERIC;
    v_line            RECORD;
    v_batch           rid_transaction_line_batches%ROWTYPE;
    v_serial_row      rid_transaction_line_serials%ROWTYPE;
    v_has_batches     BOOLEAN;
    v_has_serials     BOOLEAN;
    v_cost_price      NUMERIC;
    v_cost_price_spec NUMERIC;
    v_line_value      NUMERIC;
    v_signed_qty      NUMERIC;
    v_trans_type      TEXT;
    v_stock_account   UUID;
    v_adjustment_account UUID;
    v_adjv_lines      JSONB := '[]'::jsonb;
    v_adjv_trans_no   TEXT;
    v_adjv_trans_date DATE;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_stock_adjustment_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND adjustment_no = p_adjustment_no AND adjustment_date = p_adjustment_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Adjustment % dated % not found', p_adjustment_no, p_adjustment_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Adjustment % is % and cannot be approved again', p_adjustment_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_adjustment_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_ADJUSTMENT', p_adjustment_date);

    IF p_adjustment_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Adjustment date %s is in the future — a Stock Adjustment cannot be dated ahead of today.', p_adjustment_date);
    END IF;

    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_rate_to_local := CASE WHEN v_base_ccy = v_local_ccy THEN 1
                            ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_adjustment_date) END;

    -- 3. Per line: lock the balance row, fetch current cost, validate,
    --    branch batch/serial/aggregate posting, accumulate GL lines.
    --    Sorted by product_id — the only row-type here, so no multi-type
    --    lock-order concern like GRN/Material Issue have.
    FOR v_line IN
        SELECT * FROM rid_stock_adjustment_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND adjustment_no = p_adjustment_no AND adjustment_date = p_adjustment_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_line.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT cost_price, cost_price_specific INTO v_cost_price, v_cost_price_spec
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

        IF v_line.adjust_flag = '+' AND coalesce(v_cost_price, 0) = 0 THEN
            RAISE EXCEPTION 'COST_NOT_ESTABLISHED'
                USING DETAIL = format(
                    'Line %s: [%s] %s has no established cost at this location yet — receive it via GRN first, or set an opening cost, before adjusting it upward.',
                    v_line.serial_no,
                    (SELECT product_code FROM rim_products WHERE id = v_line.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        UPDATE rid_stock_adjustment_lines SET
            unit_cost = v_cost_price, unit_cost_specific = v_cost_price_spec,
            updated_at = now(), updated_by = p_approved_by
        WHERE id = v_line.id;

        v_line_value := v_line.base_qty * coalesce(v_cost_price, 0);
        v_signed_qty := CASE WHEN v_line.adjust_flag = '+' THEN v_line.base_qty ELSE -v_line.base_qty END;
        v_trans_type := CASE WHEN v_line.adjust_flag = '+' THEN 'ADJUSTMENT_IN' ELSE 'ADJUSTMENT_OUT' END;

        -- Stock movement: batch/serial-tracked lines post one row per
        -- batch/unit so each one's own strict, flag-independent balance
        -- check (063) fires — mirrors fn_approve_material_issue's
        -- v_has_batches/v_has_serials pattern exactly. Only inward ('+')
        -- movements pass a unit cost; outward ('-') movements let
        -- fn_post_stock_movement snapshot the current average itself.
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_adjustment_date, v_trans_type,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_batch.base_qty ELSE -v_batch.base_qty END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price ELSE NULL END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price_spec ELSE NULL END,
                    v_batch.batch_no, v_batch.expiry_date, NULL,
                    'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_adjustment_date, v_trans_type,
                    CASE WHEN v_line.adjust_flag = '+' THEN 1 ELSE -1 END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price ELSE NULL END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price_spec ELSE NULL END,
                    NULL, NULL, v_serial_row.serial_no,
                    'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_adjustment_date, v_trans_type, v_signed_qty,
                CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price ELSE NULL END,
                CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price_spec ELSE NULL END,
                NULL, NULL, NULL,
                'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by
            );
        END IF;

        -- GL: Dr/Cr direction flips with adjust_flag; both accounts
        -- resolved via the existing fn_resolve_account_link cascade.
        v_stock_account      := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
        v_adjustment_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ADJUSTMENT_ACCOUNT');

        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;
        IF v_adjustment_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Adjustment Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_adjv_lines := v_adjv_lines || jsonb_build_array(
            jsonb_build_object(
                'account_id', CASE WHEN v_line.adjust_flag = '+' THEN v_stock_account ELSE v_adjustment_account END,
                'trans_nature', 'DR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', CASE WHEN v_line.adjust_flag = '+' THEN 'STOCK_INCREASE' ELSE 'STOCK_ADJUSTMENT_CONTRA' END,
                'source_line_no', v_line.serial_no
            ),
            jsonb_build_object(
                'account_id', CASE WHEN v_line.adjust_flag = '+' THEN v_adjustment_account ELSE v_stock_account END,
                'trans_nature', 'CR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', CASE WHEN v_line.adjust_flag = '+' THEN 'STOCK_ADJUSTMENT_CONTRA' ELSE 'STOCK_DECREASE' END,
                'source_line_no', v_line.serial_no
            )
        );
    END LOOP;

    -- 4. Post the ADJV voucher (skipped only if every line valued at zero,
    --    which would mean nothing to post — treated as a hard error since
    --    a '+' line already blocks on zero cost, and a '-' line valued at
    --    zero would still legitimately need a stock-quantity movement, so
    --    an all-zero document indicates no lines at all).
    IF jsonb_array_length(v_adjv_lines) = 0 THEN
        RAISE EXCEPTION 'NO_ADJUSTMENT_LINES'
            USING DETAIL = 'This adjustment has no lines to post.';
    END IF;

    SELECT trans_no, trans_date INTO v_adjv_trans_no, v_adjv_trans_date FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'ADJV', p_adjustment_date,
        v_adjv_lines, 'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by
    );

    -- 5. Mark the adjustment approved.
    UPDATE rih_stock_adjustment_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_adjv_trans_no,
        posted_voucher_date = v_adjv_trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_adjustment(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
