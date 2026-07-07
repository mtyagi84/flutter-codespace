-- ============================================================
-- Migration 072: Stock Transfer Request (inter-location)
-- ============================================================
-- Pure intent document — mirrors Material Requisition's role exactly, just
-- location -> location instead of location -> department. No stock/GL
-- effect at all; Stock Transfer (073) is the fulfillment document that
-- actually moves stock, the same way Material Issue fulfills a Material
-- Requisition.
--
-- Named "Stock Transfer Request" (not "Stock Requisition") deliberately —
-- this codebase already has Material Requisition (consumption, migration
-- 067), a genuinely different concept; reusing "Requisition" in the UI for
-- this one would be confusing.
--
-- transferred_qty rolls up as Stock Transfers are approved against this
-- request's lines — mirrors rid_material_requisition_lines.issued_qty /
-- rid_purchase_order_lines.qty_received exactly, same row-locked rollup
-- column pattern (not a live cross-document SUM).
--
-- Validation (qty>0, from != to, from_location.is_issue_allowed, backdate/
-- future-date) is enforced ONLY at Approve, never at DRAFT save — same
-- "drafts may be incomplete" convention every other module in this schema
-- follows.
-- ============================================================

CREATE TABLE IF NOT EXISTS rih_stock_transfer_requests (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        UUID          NOT NULL REFERENCES ric_clients(id),
    company_id       UUID          NOT NULL REFERENCES ric_companies(id),
    from_location_id UUID          NOT NULL REFERENCES ric_locations(id),
    to_location_id   UUID          NOT NULL REFERENCES ric_locations(id),
    request_no       TEXT          NOT NULL,
    request_date     DATE          NOT NULL,
    remarks          TEXT,
    status           TEXT          NOT NULL DEFAULT 'DRAFT'
                     CHECK (status IN ('DRAFT','APPROVED','PARTIALLY_TRANSFERRED','CLOSED')),
    approved_by      UUID          REFERENCES rim_users(id),
    approved_at      TIMESTAMPTZ,
    is_active        BOOLEAN       NOT NULL DEFAULT true,
    is_deleted       BOOLEAN       NOT NULL DEFAULT false,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by       UUID          REFERENCES rim_users(id),
    updated_at       TIMESTAMPTZ,
    updated_by       UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, request_no, request_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_transfer_requests_status ON rih_stock_transfer_requests (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_stock_transfer_requests_updated_at ON rih_stock_transfer_requests;
CREATE TRIGGER trg_rih_stock_transfer_requests_updated_at
    BEFORE UPDATE ON rih_stock_transfer_requests
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_stock_transfer_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_transfer_requests" ON rih_stock_transfer_requests;
CREATE POLICY "auth_rw_stock_transfer_requests" ON rih_stock_transfer_requests
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_stock_transfer_requests FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_stock_transfer_requests TO authenticated;


CREATE TABLE IF NOT EXISTS rid_stock_transfer_request_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    request_no            TEXT          NOT NULL,
    request_date          DATE          NOT NULL,
    serial_no             INTEGER       NOT NULL,
    product_id            UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack              NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose             NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty              NUMERIC(18,4) NOT NULL DEFAULT 0,   -- requested qty
    remarks               TEXT,
    transferred_qty       NUMERIC(18,4) NOT NULL DEFAULT 0,   -- rollup, updated by fn_approve_stock_transfer (073)
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, request_no, request_date, serial_no),
    FOREIGN KEY (client_id, company_id, request_no, request_date)
        REFERENCES rih_stock_transfer_requests (client_id, company_id, request_no, request_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_transfer_request_lines_product ON rid_stock_transfer_request_lines (product_id);

ALTER TABLE rid_stock_transfer_request_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_transfer_request_lines" ON rid_stock_transfer_request_lines;
CREATE POLICY "auth_rw_stock_transfer_request_lines" ON rid_stock_transfer_request_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_stock_transfer_request_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_stock_transfer_request_lines TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_transfer_request — DRAFT-only
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_stock_transfer_request(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, remarks}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_from_location  UUID;
    v_to_location    UUID;
    v_request_no     TEXT;
    v_request_date   DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
BEGIN
    v_client_id     := (p_header->>'client_id')::uuid;
    v_company_id    := (p_header->>'company_id')::uuid;
    v_from_location := (p_header->>'from_location_id')::uuid;
    v_to_location   := (p_header->>'to_location_id')::uuid;
    v_request_no    := nullif(trim(p_header->>'request_no'), '');
    v_request_date  := (p_header->>'request_date')::date;
    v_is_new        := v_request_no IS NULL;

    IF v_from_location = v_to_location THEN
        RAISE EXCEPTION 'FROM_TO_LOCATION_SAME'
            USING DETAIL = 'From Location and To Location cannot be the same.';
    END IF;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Stock Transfer Request.';
    END IF;

    IF v_is_new THEN
        v_request_no := fn_next_trans_no(v_client_id, v_company_id, v_from_location, 'STRQ');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_transfer_requests
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND request_no = v_request_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Transfer Request % is % and cannot be edited.', v_request_no, v_old_status;
        END IF;

        DELETE FROM rid_stock_transfer_request_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND request_no = v_request_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_transfer_requests (
            client_id, company_id, from_location_id, to_location_id, request_no, request_date,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_from_location, v_to_location, v_request_no, v_request_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_transfer_requests SET
            from_location_id = v_from_location,
            to_location_id   = v_to_location,
            request_date     = v_request_date,
            remarks          = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND request_no = v_request_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_stock_transfer_request_lines (
            client_id, company_id, request_no, request_date, serial_no,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_request_no, v_request_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_request_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_stock_transfer_request(JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_stock_transfer_request — completeness validation only, no
-- stock/GL effect whatsoever.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_stock_transfer_request(
    p_client_id   UUID,
    p_company_id  UUID,
    p_request_no  TEXT,
    p_request_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_stock_transfer_requests%ROWTYPE;
    v_line   RECORD;
    v_from_issue_allowed BOOLEAN;
BEGIN
    SELECT * INTO v_header FROM rih_stock_transfer_requests
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND request_no = p_request_no AND request_date = p_request_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Transfer Request % dated % not found', p_request_no, p_request_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Transfer Request % is % and cannot be approved again', p_request_no, v_header.status;
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_request_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_TRANSFER_REQUEST', p_request_date);

    IF p_request_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Request date %s is in the future — a stock transfer request cannot be dated ahead of today.', p_request_date);
    END IF;

    IF v_header.from_location_id = v_header.to_location_id THEN
        RAISE EXCEPTION 'FROM_TO_LOCATION_SAME'
            USING DETAIL = 'From Location and To Location cannot be the same.';
    END IF;

    SELECT is_issue_allowed INTO v_from_issue_allowed FROM ric_locations WHERE id = v_header.from_location_id;
    IF NOT coalesce(v_from_issue_allowed, false) THEN
        RAISE EXCEPTION 'ISSUE_NOT_ALLOWED_AT_LOCATION'
            USING DETAIL = format('%s does not allow material/stock issue — enable it in Location Setup first.',
                (SELECT location_name FROM ric_locations WHERE id = v_header.from_location_id));
    END IF;

    FOR v_line IN
        SELECT * FROM rid_stock_transfer_request_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND request_no = p_request_no AND request_date = p_request_date AND is_deleted = false
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;
    END LOOP;

    UPDATE rih_stock_transfer_requests SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_transfer_request(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
