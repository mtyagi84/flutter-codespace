-- ============================================================
-- Migration 068: Material Issue for Consumption
-- ============================================================
-- Fulfillment document — mirrors GRN's role relative to a PO, but against
-- a Material Requisition instead. One Issue can consolidate lines from one
-- or more APPROVED (or PARTIALLY_ISSUED) requisitions, as long as they all
-- share the SAME From Location as the Issue header itself.
--
-- Batch/serial selection is built in from day one (not retrofitted later,
-- unlike Purchase Return) — same mandatory-allocation + strict,
-- flag-independent negative-stock check from migrations 060/063, since a
-- batch/serial-tracked product can never go negative regardless of
-- allow_negative_stock flags.
--
-- No document currency at all — this is a pure internal stock/expense
-- movement, always posted in the company's OWN base currency (no
-- supplier/customer, nothing analogous to a GRN's foreign-currency rate).
-- local_amount is still derived via a fresh fn_get_exchange_rate lookup
-- (base -> local) for ledger-printing consistency with every other module,
-- matching the "always-multiply" multicurrency rule even when trans/base
-- happen to be the same currency.
--
-- GL posting: one Dr (resolved Consumption Expense account, via the new
-- rim_department_consumption_areas table) / Cr (STOCK_ACCOUNT, existing
-- fn_resolve_account_link framework) pair PER LINE — no aggregation across
-- lines sharing the same account, same simplicity precedent GRN/Purchase
-- Return already use for their own per-line Stock/Accrual pairs. Valuation
-- uses the product's CURRENT moving-average cost_price at this location
-- (pre-fetched under the same row lock fn_post_stock_movement itself
-- takes, since that function returns VOID and never hands the cost back to
-- the caller) — batch/serial splitting only affects HOW the stock ledger
-- records the movement, never the blended average cost used for valuation
-- (same principle GRN's own inward posting already follows: one average
-- cost per product+location, regardless of batch identity).
--
-- Lock order (fixed, matching every prior module in this schema): 1)
-- Material Requisition headers, sorted; 2) rid_material_requisition_lines
-- rows, one per statement in a fixed sort order; 3) rim_product_location
-- rows, sorted by product_id — one row per statement throughout, never a
-- single "ORDER BY ... FOR UPDATE", per the deadlock-avoidance rule
-- established in 036/038.
-- ============================================================

CREATE TABLE IF NOT EXISTS rih_material_issue_headers (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    location_id         UUID          NOT NULL REFERENCES ric_locations(id), -- the From Location, must match every referenced requisition's own location
    issue_no            TEXT          NOT NULL,
    issue_date          DATE          NOT NULL,
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
    UNIQUE (client_id, company_id, issue_no, issue_date)
);

CREATE INDEX IF NOT EXISTS idx_material_issue_headers_status ON rih_material_issue_headers (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_material_issue_headers_updated_at ON rih_material_issue_headers;
CREATE TRIGGER trg_rih_material_issue_headers_updated_at
    BEFORE UPDATE ON rih_material_issue_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_material_issue_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_material_issue_headers" ON rih_material_issue_headers;
CREATE POLICY "auth_rw_material_issue_headers" ON rih_material_issue_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_material_issue_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_material_issue_headers TO authenticated;


CREATE TABLE IF NOT EXISTS rid_material_issue_lines (
    id                        UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                 UUID          NOT NULL,
    company_id                UUID          NOT NULL,
    issue_no                  TEXT          NOT NULL,
    issue_date                DATE          NOT NULL,
    serial_no                 INTEGER       NOT NULL,
    source_requisition_no     TEXT          NOT NULL,
    source_requisition_date   DATE          NOT NULL,
    source_requisition_line_serial INTEGER  NOT NULL,
    product_id                UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                    UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor     NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack                  NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty                  NUMERIC(18,4) NOT NULL DEFAULT 0,   -- the ISSUE quantity
    department_id             UUID          REFERENCES rim_common_masters(id),
    consumption_area_id       UUID          REFERENCES rim_common_masters(id),
    remarks                   TEXT,
    is_deleted                BOOLEAN       NOT NULL DEFAULT false,
    created_at                TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by                UUID          REFERENCES rim_users(id),
    updated_at                TIMESTAMPTZ,
    updated_by                UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, issue_no, issue_date, serial_no),
    FOREIGN KEY (client_id, company_id, issue_no, issue_date)
        REFERENCES rih_material_issue_headers (client_id, company_id, issue_no, issue_date)
);

CREATE INDEX IF NOT EXISTS idx_material_issue_lines_source_req
    ON rid_material_issue_lines (client_id, company_id, source_requisition_no, source_requisition_date, source_requisition_line_serial);
CREATE INDEX IF NOT EXISTS idx_material_issue_lines_product ON rid_material_issue_lines (product_id);

ALTER TABLE rid_material_issue_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_material_issue_lines" ON rid_material_issue_lines;
CREATE POLICY "auth_rw_material_issue_lines" ON rid_material_issue_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_material_issue_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_material_issue_lines TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_material_issue — DRAFT-only, mirrors fn_save_purchase_return's
-- shape exactly (header, lines, batches, serials, user_id — no charges here).
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_material_issue(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_requisition_no, source_requisition_date, source_requisition_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, department_id, consumption_area_id, remarks}, ...]
    p_batches JSONB,   -- [{line_serial, batch_no, expiry_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials JSONB,   -- [{line_serial, serial_no}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id    UUID;
    v_company_id   UUID;
    v_location_id  UUID;
    v_issue_no     TEXT;
    v_issue_date   DATE;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
    v_batch        JSONB;
    v_req_ref      RECORD;
    v_req          rih_material_requisition_headers%ROWTYPE;
    v_line_qty     NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_issue_no    := nullif(trim(p_header->>'issue_no'), '');
    v_issue_date  := (p_header->>'issue_date')::date;
    v_is_new      := v_issue_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Material Issue.';
    END IF;

    IF v_is_new THEN
        v_issue_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'MISS');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_material_issue_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND issue_no = v_issue_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Material Issue % is % and cannot be edited.', v_issue_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = v_issue_no AND source_doc_date = v_issue_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = v_issue_no AND source_doc_date = v_issue_date;

        DELETE FROM rid_material_issue_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND issue_no = v_issue_no;
    END IF;

    -- Validate every referenced requisition: same location, APPROVED or
    -- already PARTIALLY_ISSUED (a requisition can be fulfilled across
    -- several separate Issues over time). One row per statement in a fixed
    -- sort order (deadlock-avoidance rule from 036/038).
    FOR v_req_ref IN
        SELECT DISTINCT value->>'source_requisition_no' AS req_no, value->>'source_requisition_date' AS req_date
        FROM jsonb_array_elements(p_lines)
        ORDER BY 1, 2
    LOOP
        SELECT * INTO v_req FROM rih_material_requisition_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND requisition_no = v_req_ref.req_no AND requisition_date = v_req_ref.req_date::date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Material Requisition % not found.', v_req_ref.req_no;
        END IF;
        IF v_req.status NOT IN ('APPROVED', 'PARTIALLY_ISSUED') THEN
            RAISE EXCEPTION 'Material Requisition % is % — only APPROVED or PARTIALLY_ISSUED requisitions can be issued against.', v_req.requisition_no, v_req.status;
        END IF;
        IF v_req.location_id != v_location_id THEN
            RAISE EXCEPTION 'Material Requisition % is from a different location than this Issue.', v_req.requisition_no;
        END IF;
    END LOOP;

    IF v_is_new THEN
        INSERT INTO rih_material_issue_headers (
            client_id, company_id, location_id, issue_no, issue_date, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_issue_no, v_issue_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_material_issue_headers SET
            location_id = v_location_id,
            issue_date  = v_issue_date,
            remarks     = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND issue_no = v_issue_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_material_issue_lines (
            client_id, company_id, issue_no, issue_date, serial_no,
            source_requisition_no, source_requisition_date, source_requisition_line_serial,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            department_id, consumption_area_id, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_issue_no, v_issue_date, (v_line->>'serial_no')::integer,
            v_line->>'source_requisition_no', (v_line->>'source_requisition_date')::date, (v_line->>'source_requisition_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'department_id', '')::uuid, nullif(v_line->>'consumption_area_id', '')::uuid,
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        -- Batch children for this line, if any were provided — same
        -- BATCH_QTY_MISMATCH rule as fn_save_grn/fn_save_purchase_return.
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
                v_client_id, v_company_id, 'MATERIAL_ISSUE', v_issue_no, v_issue_date, (v_line->>'serial_no')::integer,
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
                USING DETAIL = format('Line %s: batch quantities sum to %s but the issue quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'MATERIAL_ISSUE', v_issue_no, v_issue_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    RETURN v_issue_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_material_issue(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_material_issue
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_material_issue(
    p_client_id   UUID,
    p_company_id  UUID,
    p_issue_no    TEXT,
    p_issue_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header          rih_material_issue_headers%ROWTYPE;
    v_base_ccy        TEXT;
    v_local_ccy       TEXT;
    v_rate_to_local   NUMERIC;
    v_req_key         RECORD;
    v_line            RECORD;
    v_req_line        rid_material_requisition_lines%ROWTYPE;
    v_batch           rid_transaction_line_batches%ROWTYPE;
    v_serial_row      rid_transaction_line_serials%ROWTYPE;
    v_has_batches     BOOLEAN;
    v_has_serials     BOOLEAN;
    v_cost_price      NUMERIC;
    v_line_value      NUMERIC;
    v_stock_account   UUID;
    v_expense_account UUID;
    v_mic_lines       JSONB := '[]'::jsonb;
    v_mic_trans_no    TEXT;
    v_mic_trans_date  DATE;
    v_req_total_ordered  NUMERIC;
    v_req_total_issued   NUMERIC;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_material_issue_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND issue_no = p_issue_no AND issue_date = p_issue_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material Issue % dated % not found', p_issue_no, p_issue_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Material Issue % is % and cannot be approved again', p_issue_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_issue_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'MATERIAL_ISSUE', p_issue_date);

    IF p_issue_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Issue date %s is in the future — a Material Issue cannot be dated ahead of today.', p_issue_date);
    END IF;

    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_rate_to_local := CASE WHEN v_base_ccy = v_local_ccy THEN 1
                            ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_issue_date) END;

    -- 3. Lock every referenced requisition header, one row per statement in
    --    a fixed sort order (same rule as fn_save_material_issue / fn_approve_grn).
    FOR v_req_key IN
        SELECT DISTINCT source_requisition_no, source_requisition_date FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND issue_no = p_issue_no AND issue_date = p_issue_date AND is_deleted = false
        ORDER BY source_requisition_no, source_requisition_date
    LOOP
        PERFORM 1 FROM rih_material_requisition_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_req_key.source_requisition_no AND requisition_date = v_req_key.source_requisition_date
        FOR UPDATE;
    END LOOP;

    -- 4. Per line: lock+cap the requisition line, post stock (batch/serial
    --    branch), resolve accounts, accumulate GL lines. Sorted by
    --    product_id — second half of the fixed lock-ordering rule.
    FOR v_line IN
        SELECT * FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND issue_no = p_issue_no AND issue_date = p_issue_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        -- Lock + cap the source requisition line (rollup column, same
        -- pattern as rid_purchase_order_lines.qty_received).
        SELECT * INTO v_req_line FROM rid_material_requisition_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_line.source_requisition_no AND requisition_date = v_line.source_requisition_date
          AND serial_no = v_line.source_requisition_line_serial
        FOR UPDATE;

        IF v_req_line.issued_qty + v_line.base_qty > v_req_line.base_qty THEN
            RAISE EXCEPTION 'ISSUE_QTY_EXCEEDS_REQUESTED'
                USING DETAIL = format(
                    'Requisition %s line %s: already issued %s of %s requested, this issue adds %s more.',
                    v_line.source_requisition_no, v_line.source_requisition_line_serial,
                    v_req_line.issued_qty, v_req_line.base_qty, v_line.base_qty);
        END IF;

        UPDATE rid_material_requisition_lines SET
            issued_qty = issued_qty + v_line.base_qty,
            updated_at = now(), updated_by = p_approved_by
        WHERE id = v_req_line.id;

        -- Snapshot the CURRENT moving-average cost for this product+location
        -- BEFORE the movement — fn_post_stock_movement itself never returns
        -- it, and an outward movement doesn't change cost_price anyway, so
        -- reading it now (under the same row lock fn_post_stock_movement
        -- re-acquires internally) is safe and matches the value that will
        -- actually be snapshotted onto the ledger row.
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_line.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT cost_price INTO v_cost_price
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

        v_line_value := v_line.base_qty * coalesce(v_cost_price, 0);

        -- Stock: batch/serial-tracked lines post one row per batch/unit so
        -- each one's own strict, flag-independent balance check (063)
        -- fires — mirrors fn_approve_grn's/fn_approve_purchase_return's
        -- v_has_batches/v_has_serials pattern exactly.
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_issue_date, 'MATERIAL_ISSUE', -v_batch.base_qty,
                    NULL, NULL, v_batch.batch_no, v_batch.expiry_date, NULL,
                    'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_issue_date, 'MATERIAL_ISSUE', -1,
                    NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                    'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_issue_date, 'MATERIAL_ISSUE', -v_line.base_qty,
                NULL, NULL, NULL, NULL, NULL,
                'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by
            );
        END IF;

        -- Resolve the consumption expense account for this line's
        -- department + consumption area — hard error with human labels,
        -- never a raw ID, if the pair isn't configured.
        SELECT account_id INTO v_expense_account
        FROM rim_department_consumption_areas
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND consumption_area_id = v_line.consumption_area_id AND department_id = v_line.department_id
          AND is_deleted = false;

        IF v_expense_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format(
                    'Line %s: no expense account configured for consumption area "%s" under department "%s". Set it up in Consumption Area Setup first.',
                    v_line.serial_no,
                    (SELECT description FROM rim_common_masters WHERE id = v_line.consumption_area_id),
                    (SELECT description FROM rim_common_masters WHERE id = v_line.department_id));
        END IF;

        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_mic_lines := v_mic_lines || jsonb_build_array(
            jsonb_build_object(
                'account_id', v_expense_account, 'trans_nature', 'DR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'CONSUMPTION_EXPENSE', 'source_line_no', v_line.serial_no
            ),
            jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'CR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_REDUCTION', 'source_line_no', v_line.serial_no
            )
        );
    END LOOP;

    -- 5. Post the MIC voucher (skipped only if every line valued at zero,
    --    which would mean nothing to post — treated as a hard error since
    --    that always indicates an unconfigured/zero-cost product, not a
    --    legitimate zero-value consumption).
    IF jsonb_array_length(v_mic_lines) = 0 THEN
        RAISE EXCEPTION 'NO_ISSUE_LINES'
            USING DETAIL = 'This issue has no lines to post.';
    END IF;

    SELECT trans_no, trans_date INTO v_mic_trans_no, v_mic_trans_date FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'MIC', p_issue_date,
        v_mic_lines, 'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by
    );

    -- 6. Recompute status of every requisition touched by this issue —
    --    unconditional (no reopen flag, unlike Purchase Return/PO, since
    --    Material Issue has no reversal concept yet).
    FOR v_req_key IN
        SELECT DISTINCT source_requisition_no, source_requisition_date FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND issue_no = p_issue_no AND issue_date = p_issue_date AND is_deleted = false
        ORDER BY source_requisition_no, source_requisition_date
    LOOP
        SELECT coalesce(sum(base_qty), 0), coalesce(sum(issued_qty), 0)
        INTO v_req_total_ordered, v_req_total_issued
        FROM rid_material_requisition_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_req_key.source_requisition_no AND requisition_date = v_req_key.source_requisition_date
          AND is_deleted = false;

        UPDATE rih_material_requisition_headers SET
            status = CASE WHEN v_req_total_issued >= v_req_total_ordered THEN 'CLOSED' ELSE 'PARTIALLY_ISSUED' END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_req_key.source_requisition_no AND requisition_date = v_req_key.source_requisition_date
          AND status IN ('APPROVED', 'PARTIALLY_ISSUED');
    END LOOP;

    -- 7. Mark the issue approved.
    UPDATE rih_material_issue_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_mic_trans_no,
        posted_voucher_date = v_mic_trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_material_issue(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
