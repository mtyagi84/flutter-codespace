-- ============================================================
-- Migration 074: Stock Receipt (inter-location arrival)
-- ============================================================
-- Closes the loop Stock Transfer (073) opened — ONE receipt per transfer
-- (see 073's own header comment), confirming actual received qty per
-- line, which can be LESS than what was transferred (transit shortage/
-- damage). Any shortfall is FINAL and immediate: no partial-then-later-
-- more-arrives concept, matching what was actually asked for.
--
-- Batch/serial candidates for a receipt line come from what THAT SPECIFIC
-- transfer line dispatched (rid_transaction_line_batches/serials tagged
-- source_doc_type='STOCK_TRANSFER') — NOT from "whatever's currently
-- available at a location" (Material Issue's model) or "whatever this GRN
-- line received" (Purchase Return's model) — these specific units are in
-- transit, not yet in any location's own stock, so the only valid
-- candidates are exactly what was sent.
--
-- GL posting reads rih_stock_transfers.posting_mode, stored at Transfer-
-- approve time (never re-derived) — see 073's own header comment for why:
--   SAME_BOOK    — STXJ: Dr Stock@TO (received qty's landed value, per
--                  line) + Dr STOCK_TRANSFER_LOSS_ACCOUNT (shortfall's
--                  landed value, if any) = Cr Stock-in-Transit (the FULL
--                  originally-transferred landed value for that line) —
--                  always balances by construction.
--   INTER_ENTITY — STXP: Dr Stock@TO (received qty x sales_price + this
--                  line's already-apportioned charge_amount, per line) +
--                  Dr STOCK_TRANSFER_LOSS_ACCOUNT (shortfall qty x
--                  sales_price only — charges are a fixed cost of the
--                  shipment regardless of what arrived, never reduced by
--                  a shortage) = Cr FROM_group.supplier_account_id
--                  (aggregate, FULL transferred qty x sales_price, tagged
--                  inv_bill_no=transfer_no) + Cr-or-Dr each charge's own
--                  account (nature-aware, full amount, once per charge —
--                  posted HERE, deferred from Transfer per 073's design).
-- ============================================================

CREATE TABLE IF NOT EXISTS rih_stock_receipts (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    from_location_id    UUID          NOT NULL REFERENCES ric_locations(id),
    to_location_id      UUID          NOT NULL REFERENCES ric_locations(id),
    source_transfer_no  TEXT          NOT NULL,
    source_transfer_date DATE         NOT NULL,
    receipt_no          TEXT          NOT NULL,
    receipt_date        DATE          NOT NULL,
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
    UNIQUE (client_id, company_id, receipt_no, receipt_date),
    UNIQUE (client_id, company_id, source_transfer_no, source_transfer_date) -- one receipt per transfer
);

CREATE INDEX IF NOT EXISTS idx_stock_receipts_status ON rih_stock_receipts (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_stock_receipts_updated_at ON rih_stock_receipts;
CREATE TRIGGER trg_rih_stock_receipts_updated_at
    BEFORE UPDATE ON rih_stock_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_stock_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_receipts" ON rih_stock_receipts;
CREATE POLICY "auth_rw_stock_receipts" ON rih_stock_receipts
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_stock_receipts FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_stock_receipts TO authenticated;


CREATE TABLE IF NOT EXISTS rid_stock_receipt_lines (
    id                          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                   UUID          NOT NULL,
    company_id                  UUID          NOT NULL,
    receipt_no                  TEXT          NOT NULL,
    receipt_date                DATE          NOT NULL,
    serial_no                   INTEGER       NOT NULL,
    source_transfer_line_serial INTEGER       NOT NULL,
    product_id                  UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                      UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor       NUMERIC(18,6) NOT NULL DEFAULT 1,
    received_qty_pack           NUMERIC(18,4) NOT NULL DEFAULT 0,
    received_qty_loose          NUMERIC(18,4) NOT NULL DEFAULT 0,
    received_base_qty           NUMERIC(18,4) NOT NULL DEFAULT 0,
    remarks                     TEXT,
    is_deleted                  BOOLEAN       NOT NULL DEFAULT false,
    created_at                  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by                  UUID          REFERENCES rim_users(id),
    updated_at                  TIMESTAMPTZ,
    updated_by                  UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, receipt_no, receipt_date, serial_no),
    FOREIGN KEY (client_id, company_id, receipt_no, receipt_date)
        REFERENCES rih_stock_receipts (client_id, company_id, receipt_no, receipt_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_receipt_lines_product ON rid_stock_receipt_lines (product_id);

ALTER TABLE rid_stock_receipt_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_receipt_lines" ON rid_stock_receipt_lines;
CREATE POLICY "auth_rw_stock_receipt_lines" ON rid_stock_receipt_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_stock_receipt_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_stock_receipt_lines TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_receipt — DRAFT-only
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_stock_receipt(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_transfer_line_serial, product_id, uom_id, uom_conversion_factor, received_qty_pack, received_qty_loose, received_base_qty, remarks}, ...]
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
            received_qty_pack, received_qty_loose, received_base_qty, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_receipt_no, v_receipt_date, (v_line->>'serial_no')::integer,
            (v_line->>'source_transfer_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'received_qty_pack')::numeric, 0), coalesce((v_line->>'received_qty_loose')::numeric, 0),
            coalesce((v_line->>'received_base_qty')::numeric, 0),
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

GRANT EXECUTE ON FUNCTION fn_save_stock_receipt(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_stock_receipt
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_stock_receipt(
    p_client_id   UUID,
    p_company_id  UUID,
    p_receipt_no  TEXT,
    p_receipt_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header           rih_stock_receipts%ROWTYPE;
    v_transfer         rih_stock_transfers%ROWTYPE;
    v_from_group_id    UUID;
    v_supplier_account UUID;
    v_from_group_name  TEXT;
    v_line             RECORD;
    v_transfer_line    rid_stock_transfer_lines%ROWTYPE;
    v_batch            rid_transaction_line_batches%ROWTYPE;
    v_serial_row       rid_transaction_line_serials%ROWTYPE;
    v_charge           RECORD;
    v_has_batches      BOOLEAN;
    v_has_serials      BOOLEAN;
    v_shortfall_qty    NUMERIC;
    v_unit_value       NUMERIC;
    v_stock_account    UUID;
    v_loss_account     UUID;
    v_stxj_lines       JSONB := '[]'::jsonb;
    v_stxp_lines       JSONB := '[]'::jsonb;
    v_stxp_total       NUMERIC := 0;
    v_trans_no         TEXT; v_trans_date DATE;
    v_base_ccy         TEXT;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_stock_receipts
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Receipt % dated % not found', p_receipt_no, p_receipt_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Receipt % is % and cannot be approved again', p_receipt_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_receipt_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_RECEIPT', p_receipt_date);

    IF p_receipt_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Receipt date %s is in the future — a stock receipt cannot be dated ahead of today.', p_receipt_date);
    END IF;

    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = p_company_id;

    -- 3. Lock the Transfer header, read its stored posting_mode.
    SELECT * INTO v_transfer FROM rih_stock_transfers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND transfer_no = v_header.source_transfer_no AND transfer_date = v_header.source_transfer_date
    FOR UPDATE;

    IF v_transfer.status != 'APPROVED' THEN
        RAISE EXCEPTION 'Stock Transfer % is % — only an APPROVED transfer can be received.', v_transfer.transfer_no, v_transfer.status;
    END IF;

    IF v_transfer.posting_mode = 'INTER_ENTITY' THEN
        SELECT group_id INTO v_from_group_id FROM ric_locations WHERE id = v_transfer.from_location_id;
        SELECT supplier_account_id, group_name INTO v_supplier_account, v_from_group_name
        FROM ric_location_groups WHERE id = v_from_group_id;

        IF v_supplier_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Location group "%s" has no Supplier Account configured — set it up in Location Groups first.', v_from_group_name);
        END IF;
    END IF;

    -- 4. Per line: lock the transfer line, post stock IN for what was
    --    actually received, write off any shortfall, accumulate GL.
    --    Sorted by product_id — fixed lock-ordering rule.
    FOR v_line IN
        SELECT * FROM rid_stock_receipt_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT * INTO v_transfer_line FROM rid_stock_transfer_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND transfer_no = v_transfer.transfer_no AND transfer_date = v_transfer.transfer_date
          AND serial_no = v_line.source_transfer_line_serial
        FOR UPDATE;

        IF v_line.received_base_qty > v_transfer_line.base_qty THEN
            RAISE EXCEPTION 'RECEIPT_QTY_EXCEEDS_TRANSFERRED'
                USING DETAIL = format('Line %s: received qty %s exceeds the transferred qty %s.',
                    v_line.serial_no, v_line.received_base_qty, v_transfer_line.base_qty);
        END IF;

        v_shortfall_qty := v_transfer_line.base_qty - v_line.received_base_qty;

        -- Stock: IN at TO for what actually arrived — batch/serial branch
        -- mirrors fn_approve_grn's v_has_batches/v_has_serials pattern,
        -- using THIS RECEIPT's own allocation (a subset of what the
        -- transfer originally dispatched).
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_transfer.posting_mode = 'SAME_BOOK' THEN
            v_unit_value := (v_transfer_line.cost_price * v_transfer_line.base_qty + v_transfer_line.charge_amount)
                            / NULLIF(v_transfer_line.base_qty, 0);
        ELSE
            v_unit_value := (v_transfer_line.sales_price * v_transfer_line.base_qty + v_transfer_line.charge_amount)
                            / NULLIF(v_transfer_line.base_qty, 0);
        END IF;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id,
                    p_receipt_date, 'TRANSFER_IN', v_batch.base_qty,
                    v_unit_value, v_unit_value, v_batch.batch_no, v_batch.expiry_date, NULL,
                    'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id,
                    p_receipt_date, 'TRANSFER_IN', 1,
                    v_unit_value, v_unit_value, NULL, NULL, v_serial_row.serial_no,
                    'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
                );
            END LOOP;
        ELSIF v_line.received_base_qty > 0 THEN
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id,
                p_receipt_date, 'TRANSFER_IN', v_line.received_base_qty,
                v_unit_value, v_unit_value, NULL, NULL, NULL,
                'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
            );
        END IF;

        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        IF v_shortfall_qty > 0 THEN
            v_loss_account := fn_resolve_account_link(p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id, 'STOCK_TRANSFER_LOSS_ACCOUNT');
            IF v_loss_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Stock Transfer Loss Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;
        END IF;

        IF v_transfer.posting_mode = 'SAME_BOOK' THEN
            v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'DR',
                'trans_amount', v_line.received_base_qty * v_unit_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line.received_base_qty * v_unit_value, 'base_rate', 1,
                'local_amount', v_line.received_base_qty * v_unit_value, 'local_rate', 1,
                'party_amount', v_line.received_base_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_RECEIVED', 'source_line_no', v_line.serial_no
            ));
            IF v_shortfall_qty > 0 THEN
                v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_loss_account, 'trans_nature', 'DR',
                    'trans_amount', v_shortfall_qty * v_unit_value, 'trans_currency', v_base_ccy,
                    'base_amount', v_shortfall_qty * v_unit_value, 'base_rate', 1,
                    'local_amount', v_shortfall_qty * v_unit_value, 'local_rate', 1,
                    'party_amount', v_shortfall_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                    'source_line_type', 'TRANSFER_LOSS', 'source_line_no', v_line.serial_no
                ));
            END IF;
            v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                'account_id', fn_resolve_account_link(p_client_id, p_company_id, v_transfer.from_location_id, v_line.product_id, 'STOCK_IN_TRANSIT_ACCOUNT'),
                'trans_nature', 'CR',
                'trans_amount', v_transfer_line.base_qty * v_unit_value, 'trans_currency', v_base_ccy,
                'base_amount', v_transfer_line.base_qty * v_unit_value, 'base_rate', 1,
                'local_amount', v_transfer_line.base_qty * v_unit_value, 'local_rate', 1,
                'party_amount', v_transfer_line.base_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_IN_TRANSIT_CLEARED', 'source_line_no', v_line.serial_no
            ));
        ELSE
            v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'DR',
                'trans_amount', v_line.received_base_qty * v_unit_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line.received_base_qty * v_unit_value, 'base_rate', 1,
                'local_amount', v_line.received_base_qty * v_unit_value, 'local_rate', 1,
                'party_amount', v_line.received_base_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_RECEIVED', 'source_line_no', v_line.serial_no
            ));
            IF v_shortfall_qty > 0 THEN
                v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_loss_account, 'trans_nature', 'DR',
                    'trans_amount', v_shortfall_qty * v_transfer_line.sales_price, 'trans_currency', v_base_ccy,
                    'base_amount', v_shortfall_qty * v_transfer_line.sales_price, 'base_rate', 1,
                    'local_amount', v_shortfall_qty * v_transfer_line.sales_price, 'local_rate', 1,
                    'party_amount', v_shortfall_qty * v_transfer_line.sales_price, 'party_currency', v_base_ccy, 'party_rate', 1,
                    'source_line_type', 'TRANSFER_LOSS', 'source_line_no', v_line.serial_no
                ));
            END IF;
            v_stxp_total := v_stxp_total + (v_transfer_line.base_qty * v_transfer_line.sales_price);
        END IF;
    END LOOP;

    -- 5. Inter-entity only: aggregate Supplier Cr (full transferred value,
    --    tagged with the transfer's own number so it rides the existing
    --    pending-bills mechanism) + each charge's own account (deferred
    --    from Transfer, per 073's design — posted here, once per charge,
    --    full amount, nature-aware).
    IF v_transfer.posting_mode = 'INTER_ENTITY' THEN
        v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_supplier_account, 'trans_nature', 'CR',
            'trans_amount', v_stxp_total, 'trans_currency', v_base_ccy,
            'base_amount', v_stxp_total, 'base_rate', 1,
            'local_amount', v_stxp_total, 'local_rate', 1,
            'party_amount', v_stxp_total, 'party_currency', v_base_ccy, 'party_rate', 1,
            'inv_bill_no', v_transfer.transfer_no, 'inv_bill_date', v_transfer.transfer_date,
            'source_line_type', 'INTER_ENTITY_PAYABLE'
        ));

        FOR v_charge IN
            SELECT * FROM rid_stock_transfer_charge_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND transfer_no = v_transfer.transfer_no AND transfer_date = v_transfer.transfer_date AND is_deleted = false
        LOOP
            IF v_charge.gl_account_id IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
            END IF;
            v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge.gl_account_id,
                'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
                'trans_amount', v_charge.amount, 'trans_currency', v_base_ccy,
                'base_amount', v_charge.amount, 'base_rate', 1,
                'local_amount', v_charge.amount, 'local_rate', 1,
                'party_amount', v_charge.amount, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'CHARGE', 'source_line_no', v_charge.serial_no
            ));
        END LOOP;
    END IF;

    -- 6. Post the one voucher for this receipt.
    IF v_transfer.posting_mode = 'SAME_BOOK' THEN
        SELECT trans_no, trans_date INTO v_trans_no, v_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_transfer.to_location_id, 'STXJ', p_receipt_date,
            v_stxj_lines, 'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
        );
    ELSE
        SELECT trans_no, trans_date INTO v_trans_no, v_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_transfer.to_location_id, 'STXP', p_receipt_date,
            v_stxp_lines, 'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
        );
    END IF;

    -- 7. Close the transfer — one receipt per transfer, always final.
    UPDATE rih_stock_transfers SET
        status = 'CLOSED',
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_transfer.id;

    -- 8. Mark the receipt approved.
    UPDATE rih_stock_receipts SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_trans_no,
        posted_voucher_date = v_trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_receipt(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
