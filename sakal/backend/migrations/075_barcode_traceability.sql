-- ============================================================
-- Migration 075: Barcode traceability on every transaction line
-- ============================================================
-- rim_products.barcode and rim_product_uom.barcode (per-pack-size barcode —
-- a carton and a piece of the same product can each carry their own) have
-- existed since the product master (026), but no transaction line table in
-- the app persists WHICH barcode was actually scanned/resolved to build
-- that line. rid_purchase_order_lines already has the column and
-- fn_save_purchase_order already reads it (that module was built with it
-- from the start) — this migration brings the other 7 line tables up to the
-- same shape: rid_grn_lines, rid_material_requisition_lines,
-- rid_material_issue_lines, rid_stock_transfer_request_lines,
-- rid_stock_transfer_lines, rid_stock_receipt_lines,
-- rid_purchase_return_lines.
--
-- Purely additive on both sides: ALTER TABLE ADD COLUMN (nullable, no
-- backfill needed — historical lines simply have no recorded barcode), and
-- one more optional JSONB key (`nullif(v_line->>'barcode', '')`) read into
-- each fn_save_* function's existing INSERT. No signature changes, no
-- behavior change for any caller that doesn't send the key.
--
-- Where the value comes from is a Flutter-side concern, not a backend one —
-- the backend treats `barcode` identically everywhere, whether Flutter got
-- it from a fresh barcode scan (GRN, PO, Material Requisition, Stock
-- Transfer Request, Stock Transfer's DIRECT mode all have/get a per-row
-- scan field) or copied it from an already-fetched source document's own
-- line (Material Issue from its Material Requisition lines, Purchase Return
-- from its GRN lines, Stock Receipt from its Stock Transfer lines, Stock
-- Transfer's AGAINST_REQUEST mode from its Stock Transfer Request lines —
-- none of these have an independent product-selection step to hang a scan
-- control off, so their natural value is whatever the upstream line already
-- carries).
-- ============================================================

ALTER TABLE rid_grn_lines                      ADD COLUMN IF NOT EXISTS barcode TEXT;
ALTER TABLE rid_material_requisition_lines     ADD COLUMN IF NOT EXISTS barcode TEXT;
ALTER TABLE rid_material_issue_lines           ADD COLUMN IF NOT EXISTS barcode TEXT;
ALTER TABLE rid_stock_transfer_request_lines   ADD COLUMN IF NOT EXISTS barcode TEXT;
ALTER TABLE rid_stock_transfer_lines           ADD COLUMN IF NOT EXISTS barcode TEXT;
ALTER TABLE rid_stock_receipt_lines            ADD COLUMN IF NOT EXISTS barcode TEXT;
ALTER TABLE rid_purchase_return_lines          ADD COLUMN IF NOT EXISTS barcode TEXT;


-- ── fn_save_grn ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_grn(
    p_header  JSONB,
    p_lines   JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_charges JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id    UUID;
    v_company_id   UUID;
    v_location_id  UUID;
    v_grn_no       TEXT;
    v_grn_date     DATE;
    v_old_grn_date DATE;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
    v_batch        JSONB;
    v_serial       JSONB;
    v_charge       JSONB;
    v_line_qty     NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_grn_no      := nullif(trim(p_header->>'grn_no'), '');
    v_grn_date    := (p_header->>'grn_date')::date;
    v_is_new      := v_grn_no IS NULL;

    IF v_is_new THEN
        v_grn_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'GRN');
    ELSE
        -- Lock the header row before checking status — a plain SELECT here
        -- would leave a window where a concurrent fn_approve_grn commits
        -- between this check and the deletes below.
        SELECT grn_date, status INTO v_old_grn_date, v_old_status
        FROM rih_grn_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'GRN % is % and cannot be edited.', v_grn_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'GRN' AND source_doc_no = v_grn_no AND source_doc_date = v_old_grn_date;

        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'GRN' AND source_doc_no = v_grn_no AND source_doc_date = v_old_grn_date;

        DELETE FROM rid_grn_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND grn_date = v_old_grn_date;

        DELETE FROM rid_grn_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND grn_date = v_old_grn_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_grn_headers (
            client_id, company_id, location_id, grn_no, grn_date,
            supplier_id, receipt_mode, supplier_delivery_no, supplier_delivery_date,
            grn_currency_id, rate_to_base, rate_to_local,
            gross_amount, discount_amount, charges_amount, item_tax_amount, charge_tax_amount, grand_total,
            bill_to, ship_to, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_grn_no, v_grn_date,
            (p_header->>'supplier_id')::uuid,
            coalesce(p_header->>'receipt_mode', 'DIRECT'),
            nullif(p_header->>'supplier_delivery_no', ''), (nullif(p_header->>'supplier_delivery_date', ''))::date,
            (nullif(p_header->>'grn_currency_id', ''))::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'item_tax_amount')::numeric, 0),
            coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            nullif(p_header->>'bill_to', ''), nullif(p_header->>'ship_to', ''),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_grn_headers SET
            location_id             = v_location_id,
            grn_date                = v_grn_date,
            supplier_id              = (p_header->>'supplier_id')::uuid,
            receipt_mode              = coalesce(p_header->>'receipt_mode', 'DIRECT'),
            supplier_delivery_no       = nullif(p_header->>'supplier_delivery_no', ''),
            supplier_delivery_date      = (nullif(p_header->>'supplier_delivery_date', ''))::date,
            grn_currency_id               = (nullif(p_header->>'grn_currency_id', ''))::uuid,
            rate_to_base                   = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local                    = coalesce((p_header->>'rate_to_local')::numeric, 1),
            gross_amount                      = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount                    = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount                       = coalesce((p_header->>'charges_amount')::numeric, 0),
            item_tax_amount                        = coalesce((p_header->>'item_tax_amount')::numeric, 0),
            charge_tax_amount                        = coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            grand_total                                = coalesce((p_header->>'grand_total')::numeric, 0),
            bill_to                                      = nullif(p_header->>'bill_to', ''),
            ship_to                                        = nullif(p_header->>'ship_to', ''),
            remarks                                          = nullif(p_header->>'remarks', ''),
            updated_at                                         = now(),
            updated_by                                           = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_grn_lines (
            client_id, company_id, grn_no, grn_date, serial_no,
            product_id, source_po_order_no, source_po_order_date, source_po_line_serial,
            item_description, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, gross_amount,
            discount_percent, discount_amount, tax_group_id, tax_amount,
            final_amount, base_amount, local_amount, charge_amount, landed_amount,
            department_id, consumption_area_id, barcode, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_grn_no, v_grn_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'source_po_order_no', ''), (nullif(v_line->>'source_po_order_date', ''))::date,
            (v_line->>'source_po_line_serial')::integer,
            nullif(v_line->>'item_description', ''),
            (nullif(v_line->>'uom_id', ''))::uuid,
            coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0),
            coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            coalesce((v_line->>'rate')::numeric, 0),
            coalesce((v_line->>'gross_amount')::numeric, 0),
            coalesce((v_line->>'discount_percent')::numeric, 0),
            coalesce((v_line->>'discount_amount')::numeric, 0),
            (nullif(v_line->>'tax_group_id', ''))::uuid,
            coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            coalesce((v_line->>'base_amount')::numeric, 0),
            coalesce((v_line->>'local_amount')::numeric, 0),
            coalesce((v_line->>'charge_amount')::numeric, 0),
            coalesce((v_line->>'landed_amount')::numeric, 0),
            (nullif(v_line->>'department_id', ''))::uuid,
            (nullif(v_line->>'consumption_area_id', ''))::uuid,
            nullif(v_line->>'barcode', ''),
            p_user_id, p_user_id
        );

        -- Batch/serial children for this line, if any were provided
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
                v_client_id, v_company_id, 'GRN', v_grn_no, v_grn_date, (v_line->>'serial_no')::integer,
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
                USING DETAIL = format('Line %s: batch quantities sum to %s but the line quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        FOR v_serial IN
            SELECT * FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_serials (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
            ) VALUES (
                v_client_id, v_company_id, 'GRN', v_grn_no, v_grn_date, (v_line->>'serial_no')::integer,
                v_serial->>'serial_no', p_user_id
            );
        END LOOP;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_grn_charge_lines (
            client_id, company_id, grn_no, grn_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount_or_percent, percent, amount, tax_amount, allocation_factor,
            source_po_order_no, source_po_order_date, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_grn_no, v_grn_date,
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
            nullif(v_charge->>'source_po_order_no', ''), (nullif(v_charge->>'source_po_order_date', ''))::date,
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_grn_no;
END;
$$;


-- ── fn_save_material_requisition ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_material_requisition(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, department_id, consumption_area_id, barcode, remarks}, ...]
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
            department_id, consumption_area_id, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_requisition_no, v_requisition_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'department_id', '')::uuid, nullif(v_line->>'consumption_area_id', '')::uuid,
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_requisition_no;
END;
$$;


-- ── fn_save_material_issue ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_material_issue(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_requisition_no, source_requisition_date, source_requisition_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, department_id, consumption_area_id, barcode, remarks}, ...]
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
            department_id, consumption_area_id, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_issue_no, v_issue_date, (v_line->>'serial_no')::integer,
            v_line->>'source_requisition_no', (v_line->>'source_requisition_date')::date, (v_line->>'source_requisition_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'department_id', '')::uuid, nullif(v_line->>'consumption_area_id', '')::uuid,
            nullif(v_line->>'barcode', ''),
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


-- ── fn_save_stock_transfer_request ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_stock_transfer_request(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, barcode, remarks}, ...]
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
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_request_no, v_request_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_request_no;
END;
$$;


-- ── fn_save_stock_transfer ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_stock_transfer(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_request_no, source_request_date, source_request_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, sales_price, barcode, remarks}, ...]
    p_batches JSONB,
    p_serials JSONB,
    p_charges JSONB,   -- [{serial_no, charge_id, charge_name, nature, gl_account_id, amount_or_percent, percent, amount}, ...]
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
    v_transfer_no    TEXT;
    v_transfer_date  DATE;
    v_against_request BOOLEAN;
    v_source_request_no TEXT;
    v_source_request_date DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
    v_charge         JSONB;
    v_batch          JSONB;
    v_req            rih_stock_transfer_requests%ROWTYPE;
    v_line_qty       NUMERIC;
    v_batch_qty_sum  NUMERIC;
    v_charges_total  NUMERIC := 0;
BEGIN
    v_client_id     := (p_header->>'client_id')::uuid;
    v_company_id    := (p_header->>'company_id')::uuid;
    v_from_location := (p_header->>'from_location_id')::uuid;
    v_to_location   := (p_header->>'to_location_id')::uuid;
    v_transfer_no   := nullif(trim(p_header->>'transfer_no'), '');
    v_transfer_date := (p_header->>'transfer_date')::date;
    v_against_request := coalesce((p_header->>'against_request')::boolean, false);
    v_source_request_no := nullif(p_header->>'source_request_no', '');
    v_source_request_date := (nullif(p_header->>'source_request_date', ''))::date;
    v_is_new        := v_transfer_no IS NULL;

    IF v_from_location = v_to_location THEN
        RAISE EXCEPTION 'FROM_TO_LOCATION_SAME'
            USING DETAIL = 'From Location and To Location cannot be the same.';
    END IF;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Stock Transfer.';
    END IF;

    IF v_against_request THEN
        SELECT * INTO v_req FROM rih_stock_transfer_requests
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND request_no = v_source_request_no AND request_date = v_source_request_date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Stock Transfer Request % not found.', v_source_request_no;
        END IF;
        IF v_req.status NOT IN ('APPROVED', 'PARTIALLY_TRANSFERRED') THEN
            RAISE EXCEPTION 'Stock Transfer Request % is % — only APPROVED or PARTIALLY_TRANSFERRED requests can be transferred against.', v_req.request_no, v_req.status;
        END IF;
        IF v_req.from_location_id != v_from_location OR v_req.to_location_id != v_to_location THEN
            RAISE EXCEPTION 'Stock Transfer Request % is for a different From/To Location pair.', v_req.request_no;
        END IF;
    END IF;

    IF v_is_new THEN
        v_transfer_no := fn_next_trans_no(v_client_id, v_company_id, v_from_location, 'STXF');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_transfers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND transfer_no = v_transfer_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Transfer % is % and cannot be edited.', v_transfer_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = v_transfer_no AND source_doc_date = v_transfer_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = v_transfer_no AND source_doc_date = v_transfer_date;

        DELETE FROM rid_stock_transfer_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND transfer_no = v_transfer_no;
        DELETE FROM rid_stock_transfer_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND transfer_no = v_transfer_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_transfers (
            client_id, company_id, from_location_id, to_location_id, transfer_no, transfer_date,
            against_request, source_request_no, source_request_date, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_from_location, v_to_location, v_transfer_no, v_transfer_date,
            v_against_request, v_source_request_no, v_source_request_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_transfers SET
            from_location_id    = v_from_location,
            to_location_id      = v_to_location,
            transfer_date       = v_transfer_date,
            against_request     = v_against_request,
            source_request_no   = v_source_request_no,
            source_request_date = v_source_request_date,
            remarks             = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND transfer_no = v_transfer_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_stock_transfer_lines (
            client_id, company_id, transfer_no, transfer_date, serial_no,
            source_request_no, source_request_date, source_request_line_serial,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            sales_price, charge_amount, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_transfer_no, v_transfer_date, (v_line->>'serial_no')::integer,
            nullif(v_line->>'source_request_no', ''), (nullif(v_line->>'source_request_date', ''))::date,
            (nullif(v_line->>'source_request_line_serial', ''))::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            (nullif(v_line->>'sales_price', ''))::numeric,
            coalesce((v_line->>'charge_amount')::numeric, 0),
            nullif(v_line->>'barcode', ''),
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
                v_client_id, v_company_id, 'STOCK_TRANSFER', v_transfer_no, v_transfer_date, (v_line->>'serial_no')::integer,
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
                USING DETAIL = format('Line %s: batch quantities sum to %s but the transfer quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'STOCK_TRANSFER', v_transfer_no, v_transfer_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_stock_transfer_charge_lines (
            client_id, company_id, transfer_no, transfer_date, serial_no,
            charge_id, charge_name, nature, gl_account_id,
            amount_or_percent, percent, amount,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_transfer_no, v_transfer_date, (v_charge->>'serial_no')::integer,
            (v_charge->>'charge_id')::uuid, v_charge->>'charge_name',
            coalesce(v_charge->>'nature', 'ADD'), nullif(v_charge->>'gl_account_id', '')::uuid,
            coalesce(v_charge->>'amount_or_percent', 'AMOUNT'),
            (v_charge->>'percent')::numeric,
            coalesce((v_charge->>'amount')::numeric, 0),
            p_user_id, p_user_id
        );
        v_charges_total := v_charges_total + coalesce((v_charge->>'amount')::numeric, 0);
    END LOOP;

    UPDATE rih_stock_transfers SET charges_amount = v_charges_total
    WHERE client_id = v_client_id AND company_id = v_company_id AND transfer_no = v_transfer_no;

    RETURN v_transfer_no;
END;
$$;


-- ── fn_save_stock_receipt ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_stock_receipt(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_transfer_line_serial, product_id, uom_id, uom_conversion_factor, received_qty_pack, received_qty_loose, received_base_qty, barcode, remarks}, ...]
    p_batches JSONB,
    p_serials JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     UUID;
    v_company_id    UUID;
    v_receipt_no    TEXT;
    v_receipt_date  DATE;
    v_transfer_no   TEXT;
    v_transfer_date DATE;
    v_old_status    TEXT;
    v_is_new        BOOLEAN;
    v_line          JSONB;
    v_batch         JSONB;
    v_transfer      rih_stock_transfers%ROWTYPE;
    v_line_qty      NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id     := (p_header->>'client_id')::uuid;
    v_company_id    := (p_header->>'company_id')::uuid;
    v_receipt_no    := nullif(trim(p_header->>'receipt_no'), '');
    v_receipt_date  := (p_header->>'receipt_date')::date;
    v_transfer_no   := p_header->>'source_transfer_no';
    v_transfer_date := (p_header->>'source_transfer_date')::date;
    v_is_new        := v_receipt_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Stock Receipt.';
    END IF;

    SELECT * INTO v_transfer FROM rih_stock_transfers
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND transfer_no = v_transfer_no AND transfer_date = v_transfer_date
      AND is_deleted = false
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Transfer % not found.', v_transfer_no;
    END IF;
    IF v_transfer.status != 'APPROVED' THEN
        RAISE EXCEPTION 'Stock Transfer % is % — only an APPROVED transfer can be received.', v_transfer.transfer_no, v_transfer.status;
    END IF;

    IF v_is_new THEN
        v_receipt_no := fn_next_trans_no(v_client_id, v_company_id, v_transfer.to_location_id, 'SRCP');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_receipts
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND receipt_no = v_receipt_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Receipt % is % and cannot be edited.', v_receipt_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = v_receipt_no AND source_doc_date = v_receipt_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = v_receipt_no AND source_doc_date = v_receipt_date;

        DELETE FROM rid_stock_receipt_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND receipt_no = v_receipt_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_receipts (
            client_id, company_id, from_location_id, to_location_id,
            source_transfer_no, source_transfer_date, receipt_no, receipt_date, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_transfer.from_location_id, v_transfer.to_location_id,
            v_transfer_no, v_transfer_date, v_receipt_no, v_receipt_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_receipts SET
            receipt_date = v_receipt_date,
            remarks      = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND receipt_no = v_receipt_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_stock_receipt_lines (
            client_id, company_id, receipt_no, receipt_date, serial_no,
            source_transfer_line_serial, product_id, uom_id, uom_conversion_factor,
            received_qty_pack, received_qty_loose, received_base_qty, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_receipt_no, v_receipt_date, (v_line->>'serial_no')::integer,
            (v_line->>'source_transfer_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'received_qty_pack')::numeric, 0), coalesce((v_line->>'received_qty_loose')::numeric, 0),
            coalesce((v_line->>'received_base_qty')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        v_line_qty := coalesce((v_line->>'received_base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'STOCK_RECEIPT', v_receipt_no, v_receipt_date, (v_line->>'serial_no')::integer,
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
                USING DETAIL = format('Line %s: batch quantities sum to %s but the received quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'STOCK_RECEIPT', v_receipt_no, v_receipt_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    RETURN v_receipt_no;
END;
$$;


-- ── fn_save_purchase_return ───────────────────────────────────────────────────
DROP FUNCTION IF EXISTS fn_save_purchase_return(JSONB, JSONB, JSONB, JSONB, JSONB, UUID);

CREATE OR REPLACE FUNCTION fn_save_purchase_return(
    p_header    JSONB,
    p_lines     JSONB,   -- [{serial_no, source_grn_no, source_grn_date, source_grn_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate, tax_group_id, gross_amount, tax_amount, final_amount, barcode}, ...]
    p_batches   JSONB,   -- [{line_serial, batch_no, expiry_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials   JSONB,   -- [{line_serial, serial_no}, ...]
    p_charges   JSONB,   -- [{serial_no, charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id, amount, tax_amount, source_grn_no, source_grn_date}, ...]
    p_user_id   UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     UUID;
    v_company_id    UUID;
    v_location_id   UUID;
    v_supplier_id   UUID;
    v_return_no     TEXT;
    v_return_date   DATE;
    v_old_status    TEXT;
    v_is_new        BOOLEAN;
    v_line          JSONB;
    v_charge        JSONB;
    v_batch         JSONB;
    v_grn_ref       RECORD;
    v_grn           rih_grn_headers%ROWTYPE;
    v_charges_total NUMERIC := 0;
    v_line_qty      NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_supplier_id := (p_header->>'supplier_id')::uuid;
    v_return_no   := nullif(trim(p_header->>'return_no'), '');
    v_return_date := (p_header->>'return_date')::date;
    v_is_new      := v_return_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Purchase Return.';
    END IF;

    IF v_is_new THEN
        v_return_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'PRET');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_purchase_return_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Purchase Return % is % and cannot be edited.', v_return_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = v_return_no AND source_doc_date = v_return_date;

        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = v_return_no AND source_doc_date = v_return_date;

        DELETE FROM rid_purchase_return_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
        DELETE FROM rid_purchase_return_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
    END IF;

    -- Validate every referenced GRN: same supplier, APPROVED. One row per
    -- statement in a fixed sort order (deadlock-avoidance rule from 036/038).
    FOR v_grn_ref IN
        SELECT DISTINCT value->>'source_grn_no' AS grn_no, value->>'source_grn_date' AS grn_date
        FROM jsonb_array_elements(p_lines)
        ORDER BY 1, 2
    LOOP
        SELECT * INTO v_grn FROM rih_grn_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_ref.grn_no AND grn_date = v_grn_ref.grn_date::date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'GRN % not found.', v_grn_ref.grn_no;
        END IF;
        IF v_grn.status != 'APPROVED' THEN
            RAISE EXCEPTION 'GRN % is % — only APPROVED GRNs can be returned against.', v_grn.grn_no, v_grn.status;
        END IF;
        IF v_grn.supplier_id != v_supplier_id THEN
            RAISE EXCEPTION 'GRN % does not belong to the selected supplier.', v_grn.grn_no;
        END IF;
    END LOOP;

    IF v_is_new THEN
        INSERT INTO rih_purchase_return_headers (
            client_id, company_id, location_id, return_no, return_date, supplier_id,
            return_currency_id, rate_to_base, rate_to_local,
            taxable_amount, tax_amount, charges_amount, return_total,
            reason, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_return_no, v_return_date, v_supplier_id,
            (p_header->>'return_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'taxable_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'return_total')::numeric, 0),
            nullif(p_header->>'reason', ''), nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_purchase_return_headers SET
            location_id          = v_location_id,
            return_date          = v_return_date,
            supplier_id          = v_supplier_id,
            return_currency_id  = (p_header->>'return_currency_id')::uuid,
            rate_to_base        = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local       = coalesce((p_header->>'rate_to_local')::numeric, 1),
            taxable_amount      = coalesce((p_header->>'taxable_amount')::numeric, 0),
            tax_amount          = coalesce((p_header->>'tax_amount')::numeric, 0),
            charges_amount      = coalesce((p_header->>'charges_amount')::numeric, 0),
            return_total        = coalesce((p_header->>'return_total')::numeric, 0),
            reason              = nullif(p_header->>'reason', ''),
            remarks             = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_purchase_return_lines (
            client_id, company_id, return_no, return_date, serial_no,
            source_grn_no, source_grn_date, source_grn_line_serial, product_id,
            uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate,
            tax_group_id, gross_amount, tax_amount, final_amount, barcode,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_line->>'serial_no')::integer,
            v_line->>'source_grn_no', (v_line->>'source_grn_date')::date, (v_line->>'source_grn_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0), coalesce((v_line->>'rate')::numeric, 0),
            nullif(v_line->>'tax_group_id', '')::uuid,
            coalesce((v_line->>'gross_amount')::numeric, 0), coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            p_user_id, p_user_id
        );

        -- Batch children for this line, if any were provided — same
        -- BATCH_QTY_MISMATCH rule as fn_save_grn.
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
                v_client_id, v_company_id, 'PURCHASE_RETURN', v_return_no, v_return_date, (v_line->>'serial_no')::integer,
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
                USING DETAIL = format('Line %s: batch quantities sum to %s but the return quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'PURCHASE_RETURN', v_return_no, v_return_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_purchase_return_charge_lines (
            client_id, company_id, return_no, return_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount, tax_amount, source_grn_no, source_grn_date,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_charge->>'serial_no')::integer,
            (v_charge->>'charge_id')::uuid, v_charge->>'charge_name',
            coalesce((v_charge->>'is_taxable')::boolean, false), nullif(v_charge->>'tax_id', '')::uuid,
            coalesce(v_charge->>'nature', 'ADD'), nullif(v_charge->>'gl_account_id', '')::uuid,
            coalesce((v_charge->>'amount')::numeric, 0), coalesce((v_charge->>'tax_amount')::numeric, 0),
            nullif(v_charge->>'source_grn_no', ''), nullif(v_charge->>'source_grn_date', '')::date,
            p_user_id, p_user_id
        );
        v_charges_total := v_charges_total + coalesce((v_charge->>'amount')::numeric, 0);
    END LOOP;

    UPDATE rih_purchase_return_headers SET charges_amount = v_charges_total
    WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;

    RETURN v_return_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_purchase_return(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;
