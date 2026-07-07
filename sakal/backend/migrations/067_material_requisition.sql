-- ============================================================
-- Migration 067: Material Requisition for Consumption
-- ============================================================
-- Pure intent document — mirrors Purchase Order's role relative to GRN.
-- No stock movement, no GL posting at all; Material Issue (068) is the
-- fulfillment document that actually moves stock/posts GL against an
-- APPROVED requisition, the same way GRN fulfills a PO.
--
-- requisition_no + requisition_date are the document identity (not a bare
-- requisition_no) — numbering resets per period, same lesson carried from
-- every other document in this schema.
--
-- department_id/consumption_area_id are chosen PER LINE, reusing the exact
-- same rim_common_masters-backed columns already established on rid_grn_
-- lines/rid_purchase_order_lines (migration 031) — nothing new there, just
-- the same per-line tagging pattern applied to a new document type.
--
-- issued_qty rolls up as Material Issues are approved against this
-- requisition's lines (068) — mirrors rid_purchase_order_lines.qty_received
-- exactly, including the CLOSED/PARTIALLY_ISSUED status recompute.
--
-- Line/date validation (qty>0, product/department/area required, the
-- department+area pair must actually exist in rim_department_consumption_
-- areas, backdate control, and a hard future-date block) is enforced ONLY
-- at Approve, never at DRAFT save — same "drafts may be incomplete"
-- convention PO's own line-completeness check (040) and every period/
-- backdate check in this schema already follow.
-- ============================================================

CREATE TABLE IF NOT EXISTS rih_material_requisition_headers (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL REFERENCES ric_clients(id),
    company_id        UUID          NOT NULL REFERENCES ric_companies(id),
    location_id       UUID          NOT NULL REFERENCES ric_locations(id), -- the From Location
    requisition_no    TEXT          NOT NULL,
    requisition_date  DATE          NOT NULL,
    requested_by      TEXT,          -- free text; autocompletes against rim_users client-side, not an FK
    reason            TEXT,
    remarks           TEXT,
    status            TEXT          NOT NULL DEFAULT 'DRAFT'
                      CHECK (status IN ('DRAFT','APPROVED','PARTIALLY_ISSUED','CLOSED')),
    approved_by       UUID          REFERENCES rim_users(id),
    approved_at       TIMESTAMPTZ,
    is_active         BOOLEAN       NOT NULL DEFAULT true,
    is_deleted        BOOLEAN       NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id),
    updated_at        TIMESTAMPTZ,
    updated_by        UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, requisition_no, requisition_date)
);

CREATE INDEX IF NOT EXISTS idx_material_requisition_headers_status ON rih_material_requisition_headers (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_material_requisition_headers_updated_at ON rih_material_requisition_headers;
CREATE TRIGGER trg_rih_material_requisition_headers_updated_at
    BEFORE UPDATE ON rih_material_requisition_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_material_requisition_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_material_requisition_headers" ON rih_material_requisition_headers;
CREATE POLICY "auth_rw_material_requisition_headers" ON rih_material_requisition_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_material_requisition_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_material_requisition_headers TO authenticated;


CREATE TABLE IF NOT EXISTS rid_material_requisition_lines (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL,
    company_id            UUID          NOT NULL,
    requisition_no        TEXT          NOT NULL,
    requisition_date      DATE          NOT NULL,
    serial_no             INTEGER       NOT NULL,
    product_id            UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack              NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose             NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty              NUMERIC(18,4) NOT NULL DEFAULT 0,   -- requested qty
    department_id         UUID          REFERENCES rim_common_masters(id),
    consumption_area_id   UUID          REFERENCES rim_common_masters(id),
    remarks               TEXT,
    issued_qty            NUMERIC(18,4) NOT NULL DEFAULT 0,   -- rollup, updated by fn_approve_material_issue (068)
    is_deleted            BOOLEAN       NOT NULL DEFAULT false,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, requisition_no, requisition_date, serial_no),
    FOREIGN KEY (client_id, company_id, requisition_no, requisition_date)
        REFERENCES rih_material_requisition_headers (client_id, company_id, requisition_no, requisition_date)
);

CREATE INDEX IF NOT EXISTS idx_material_requisition_lines_product ON rid_material_requisition_lines (product_id);

ALTER TABLE rid_material_requisition_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_material_requisition_lines" ON rid_material_requisition_lines;
CREATE POLICY "auth_rw_material_requisition_lines" ON rid_material_requisition_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_material_requisition_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_material_requisition_lines TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_material_requisition — DRAFT-only
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_material_requisition(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, department_id, consumption_area_id, remarks}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_location_id    UUID;
    v_requisition_no TEXT;
    v_requisition_date DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
BEGIN
    v_client_id        := (p_header->>'client_id')::uuid;
    v_company_id       := (p_header->>'company_id')::uuid;
    v_location_id      := (p_header->>'location_id')::uuid;
    v_requisition_no   := nullif(trim(p_header->>'requisition_no'), '');
    v_requisition_date := (p_header->>'requisition_date')::date;
    v_is_new           := v_requisition_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Material Requisition.';
    END IF;

    IF v_is_new THEN
        v_requisition_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'MREQ');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_material_requisition_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND requisition_no = v_requisition_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Material Requisition % is % and cannot be edited.', v_requisition_no, v_old_status;
        END IF;

        DELETE FROM rid_material_requisition_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND requisition_no = v_requisition_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_material_requisition_headers (
            client_id, company_id, location_id, requisition_no, requisition_date,
            requested_by, reason, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_requisition_no, v_requisition_date,
            nullif(p_header->>'requested_by', ''), nullif(p_header->>'reason', ''), nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_material_requisition_headers SET
            location_id      = v_location_id,
            requisition_date = v_requisition_date,
            requested_by     = nullif(p_header->>'requested_by', ''),
            reason           = nullif(p_header->>'reason', ''),
            remarks          = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND requisition_no = v_requisition_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_material_requisition_lines (
            client_id, company_id, requisition_no, requisition_date, serial_no,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            department_id, consumption_area_id, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_requisition_no, v_requisition_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'department_id', '')::uuid, nullif(v_line->>'consumption_area_id', '')::uuid,
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_requisition_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_material_requisition(JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_material_requisition — completeness validation only, no
-- stock/GL effect whatsoever.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_material_requisition(
    p_client_id      UUID,
    p_company_id     UUID,
    p_requisition_no TEXT,
    p_requisition_date DATE,
    p_approved_by    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_material_requisition_headers%ROWTYPE;
    v_line   RECORD;
    v_area_department_id UUID;
BEGIN
    SELECT * INTO v_header FROM rih_material_requisition_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND requisition_no = p_requisition_no AND requisition_date = p_requisition_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material Requisition % dated % not found', p_requisition_no, p_requisition_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Material Requisition % is % and cannot be approved again', p_requisition_no, v_header.status;
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_requisition_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'MATERIAL_REQUISITION', p_requisition_date);

    IF p_requisition_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Requisition date %s is in the future — a requisition cannot be dated ahead of today.', p_requisition_date);
    END IF;

    FOR v_line IN
        SELECT * FROM rid_material_requisition_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = p_requisition_no AND requisition_date = p_requisition_date AND is_deleted = false
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;
        IF v_line.department_id IS NULL OR v_line.consumption_area_id IS NULL THEN
            RAISE EXCEPTION 'LINE_DEPARTMENT_AREA_REQUIRED'
                USING DETAIL = format('Line %s: both Department and Consumption Area are required.', v_line.serial_no);
        END IF;

        SELECT department_id INTO v_area_department_id
        FROM rim_department_consumption_areas
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND consumption_area_id = v_line.consumption_area_id AND is_deleted = false;

        IF NOT FOUND OR v_area_department_id != v_line.department_id THEN
            RAISE EXCEPTION 'LINE_DEPARTMENT_AREA_MISMATCH'
                USING DETAIL = format(
                    'Line %s: consumption area "%s" is not configured under department "%s". Set it up in Consumption Area Setup first.',
                    v_line.serial_no,
                    (SELECT description FROM rim_common_masters WHERE id = v_line.consumption_area_id),
                    (SELECT description FROM rim_common_masters WHERE id = v_line.department_id));
        END IF;
    END LOOP;

    UPDATE rih_material_requisition_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_material_requisition(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
