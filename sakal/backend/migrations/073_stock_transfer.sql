-- ============================================================
-- Migration 073: Stock Transfer (inter-location dispatch)
-- ============================================================
-- Fulfillment document — mirrors GRN's DIRECT/AGAINST_PO duality via
-- against_request; can consolidate multiple lines from ONE Stock Transfer
-- Request (against_request=true) or stand alone (false, matches GRN's
-- DIRECT mode for an unplanned/emergency transfer).
--
-- Gains freight/transportation charges via the exact same rim_additional_
-- charges + apportion-by-value mechanism PO/GRN already use (071 widened
-- applicable_on to allow 'TRANSFER'). No tax on these charges — a stock
-- transfer is an internal movement, never a taxable purchase from a third
-- party (if a real transport company bill needs VAT recovery, that is a
-- separate Purchase Invoice against that transport company, not part of
-- this document).
--
-- posting_mode ('SAME_BOOK' or 'INTER_ENTITY') is resolved ONCE, here, at
-- Transfer-approve time, and STORED on the header — Stock Receipt (074)
-- reads this stored value rather than re-deriving it, so a location's
-- group reassignment between Transfer-approve and Receipt-approve (however
-- unlikely) can never make the two ends of one transfer disagree about
-- which accounting path they're on.
--
-- GL posting (see 071's header comment for the full worked-out design):
--   SAME_BOOK    — one STXJ voucher: Dr STOCK_IN_TRANSIT_ACCOUNT (cost +
--                  charges, per line) / Cr STOCK_ACCOUNT@FROM (cost only,
--                  per line, product-resolved) / Cr-or-Dr each charge's
--                  own account (nature-aware, full amount, once per
--                  charge) — charges posted NOW, same as GRN.
--   INTER_ENTITY — two vouchers, both FINAL (no later reversal even if
--                  Receipt reports a shortage — "bill for what was
--                  shipped" commercial practice):
--                    STXS: Dr TO_group.customer_account_id (aggregate,
--                          sales_price x qty, tagged inv_bill_no=
--                          transfer_no so it rides the existing
--                          pending-bills mechanism) / Cr FROM_group's
--                          inter_entity_sales_account_id (aggregate).
--                    STXC: Dr FROM_group's inter_entity_cogs_account_id
--                          (aggregate, cost_price x qty) / Cr
--                          STOCK_ACCOUNT@FROM (per line, product-resolved,
--                          cost_price x qty).
--                  Charges are DEFERRED to Stock Receipt's own STXP —
--                  landed cost is the BUYING entity's concern, which only
--                  exists once the purchase is actually recorded there.
--
-- ONE Stock Receipt per Stock Transfer (not many, unlike Requisition-&gt;
-- Issue or PO-&gt;GRN) — deliberately simpler, matching what was actually
-- asked for: a Transfer is received exactly once, and any shortfall at
-- that single event is FINAL (immediately written off, nothing "still
-- outstanding" to receive later). status is DRAFT -&gt; APPROVED -&gt; CLOSED,
-- the last transition owned by Stock Receipt's own approval (074).
--
-- Hard block if FROM location's rim_product_location.cost_price is
-- zero/unset for any line's product — you cannot transfer stock you have
-- no valuation for, and Receipt has no way to fix this after the fact.
--
-- Batch/serial: built in from day one, same mandatory-allocation + strict
-- flag-independent negative-stock check as Purchase Return/Material
-- Issue. ril_stock_ledger's trans_type constraints already allow
-- TRANSFER_OUT/TRANSFER_IN since the ORIGINAL 036 migration — no
-- constraint change needed here (unlike MATERIAL_ISSUE, which needed
-- 069/070 — this one was anticipated correctly the first time).
-- ============================================================

CREATE TABLE IF NOT EXISTS rih_stock_transfers (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    from_location_id    UUID          NOT NULL REFERENCES ric_locations(id),
    to_location_id      UUID          NOT NULL REFERENCES ric_locations(id),
    transfer_no         TEXT          NOT NULL,
    transfer_date       DATE          NOT NULL,
    against_request     BOOLEAN       NOT NULL DEFAULT false,
    source_request_no   TEXT,
    source_request_date DATE,
    remarks             TEXT,
    charges_amount      NUMERIC(18,4) NOT NULL DEFAULT 0,
    status              TEXT          NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT','APPROVED','CLOSED')),
    posting_mode        TEXT          CHECK (posting_mode IN ('SAME_BOOK','INTER_ENTITY')), -- set at Approve
    approved_by         UUID          REFERENCES rim_users(id),
    approved_at         TIMESTAMPTZ,
    posted_voucher_no   TEXT,   -- primary reference only (STXJ, or STXC for inter-entity) — Posted Journal Entries UI finds ALL vouchers via source_doc_type/no regardless
    posted_voucher_date DATE,
    is_active           BOOLEAN       NOT NULL DEFAULT true,
    is_deleted          BOOLEAN       NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          UUID          REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, transfer_no, transfer_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_transfers_status ON rih_stock_transfers (client_id, company_id, status);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_source_request
    ON rih_stock_transfers (client_id, company_id, source_request_no, source_request_date);

DROP TRIGGER IF EXISTS trg_rih_stock_transfers_updated_at ON rih_stock_transfers;
CREATE TRIGGER trg_rih_stock_transfers_updated_at
    BEFORE UPDATE ON rih_stock_transfers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_stock_transfers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_transfers" ON rih_stock_transfers;
CREATE POLICY "auth_rw_stock_transfers" ON rih_stock_transfers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_stock_transfers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_stock_transfers TO authenticated;


CREATE TABLE IF NOT EXISTS rid_stock_transfer_lines (
    id                         UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                  UUID          NOT NULL,
    company_id                 UUID          NOT NULL,
    transfer_no                TEXT          NOT NULL,
    transfer_date               DATE          NOT NULL,
    serial_no                    INTEGER       NOT NULL,
    source_request_no             TEXT,
    source_request_date            DATE,
    source_request_line_serial      INTEGER,
    product_id                        UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                              UUID          REFERENCES rim_common_masters(id),
    uom_conversion_factor                NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack                              NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose                              NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty                                NUMERIC(18,4) NOT NULL DEFAULT 0,   -- the TRANSFER quantity
    cost_price                              NUMERIC(18,4) NOT NULL DEFAULT 0,   -- captured at Approve from FROM's moving average
    sales_price                             NUMERIC(18,4),                     -- INTER_ENTITY only; NULL for same-book
    charge_amount                           NUMERIC(18,4) NOT NULL DEFAULT 0,   -- this line's apportioned share of charges
    remarks                                  TEXT,
    is_deleted                                BOOLEAN       NOT NULL DEFAULT false,
    created_at                                 TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by                                  UUID          REFERENCES rim_users(id),
    updated_at                                   TIMESTAMPTZ,
    updated_by                                    UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, transfer_no, transfer_date, serial_no),
    FOREIGN KEY (client_id, company_id, transfer_no, transfer_date)
        REFERENCES rih_stock_transfers (client_id, company_id, transfer_no, transfer_date)
);

CREATE INDEX IF NOT EXISTS idx_stock_transfer_lines_source_request
    ON rid_stock_transfer_lines (client_id, company_id, source_request_no, source_request_date, source_request_line_serial);
CREATE INDEX IF NOT EXISTS idx_stock_transfer_lines_product ON rid_stock_transfer_lines (product_id);

ALTER TABLE rid_stock_transfer_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_transfer_lines" ON rid_stock_transfer_lines;
CREATE POLICY "auth_rw_stock_transfer_lines" ON rid_stock_transfer_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_stock_transfer_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_stock_transfer_lines TO authenticated;


CREATE TABLE IF NOT EXISTS rid_stock_transfer_charge_lines (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL,
    company_id        UUID          NOT NULL,
    transfer_no       TEXT          NOT NULL,
    transfer_date     DATE          NOT NULL,
    serial_no         INTEGER       NOT NULL,
    charge_id         UUID          NOT NULL REFERENCES rim_additional_charges(id),
    charge_name       TEXT          NOT NULL,
    nature            TEXT          NOT NULL DEFAULT 'ADD' CHECK (nature IN ('ADD','DEDUCT')),
    gl_account_id     UUID          REFERENCES rim_accounts(id),
    amount_or_percent TEXT          NOT NULL DEFAULT 'AMOUNT' CHECK (amount_or_percent IN ('AMOUNT','PERCENT')),
    percent           NUMERIC(6,2),
    amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_deleted        BOOLEAN       NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id),
    updated_at        TIMESTAMPTZ,
    updated_by        UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, transfer_no, transfer_date, serial_no),
    FOREIGN KEY (client_id, company_id, transfer_no, transfer_date)
        REFERENCES rih_stock_transfers (client_id, company_id, transfer_no, transfer_date)
);

ALTER TABLE rid_stock_transfer_charge_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_stock_transfer_charge_lines" ON rid_stock_transfer_charge_lines;
CREATE POLICY "auth_rw_stock_transfer_charge_lines" ON rid_stock_transfer_charge_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_stock_transfer_charge_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_stock_transfer_charge_lines TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_stock_transfer — DRAFT-only
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_stock_transfer(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_request_no, source_request_date, source_request_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, sales_price, remarks}, ...]
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
            sales_price, charge_amount, remarks,
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

GRANT EXECUTE ON FUNCTION fn_save_stock_transfer(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_stock_transfer
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_stock_transfer(
    p_client_id    UUID,
    p_company_id   UUID,
    p_transfer_no  TEXT,
    p_transfer_date DATE,
    p_approved_by  UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_stock_transfers%ROWTYPE;
    v_from_group_id      UUID;
    v_to_group_id        UUID;
    v_inter_location_model TEXT;
    v_posting_mode       TEXT;
    v_from_group_name    TEXT;
    v_to_group_name      TEXT;
    v_req                rih_stock_transfer_requests%ROWTYPE;
    v_req_line           rid_stock_transfer_request_lines%ROWTYPE;
    v_line               RECORD;
    v_batch              rid_transaction_line_batches%ROWTYPE;
    v_serial_row         rid_transaction_line_serials%ROWTYPE;
    v_charge             RECORD;
    v_has_batches        BOOLEAN;
    v_has_serials        BOOLEAN;
    v_cost_price         NUMERIC;
    v_sales_price         NUMERIC;
    v_stock_account       UUID;
    v_transit_account      UUID;
    v_customer_account      UUID;
    v_ie_sales_account        UUID;
    v_ie_cogs_account          UUID;
    v_stxj_lines          JSONB := '[]'::jsonb;
    v_stxs_lines          JSONB := '[]'::jsonb;
    v_stxc_lines          JSONB := '[]'::jsonb;
    v_sales_total         NUMERIC := 0;
    v_cogs_total          NUMERIC := 0;
    v_stxj_trans_no       TEXT; v_stxj_trans_date DATE;
    v_stxs_trans_no       TEXT; v_stxs_trans_date DATE;
    v_stxc_trans_no       TEXT; v_stxc_trans_date DATE;
    v_req_total_ordered   NUMERIC;
    v_req_total_transferred NUMERIC;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_stock_transfers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND transfer_no = p_transfer_no AND transfer_date = p_transfer_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Transfer % dated % not found', p_transfer_no, p_transfer_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Transfer % is % and cannot be approved again', p_transfer_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_transfer_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_TRANSFER', p_transfer_date);

    IF p_transfer_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Transfer date %s is in the future — a stock transfer cannot be dated ahead of today.', p_transfer_date);
    END IF;

    IF v_header.from_location_id = v_header.to_location_id THEN
        RAISE EXCEPTION 'FROM_TO_LOCATION_SAME'
            USING DETAIL = 'From Location and To Location cannot be the same.';
    END IF;

    -- 3. Resolve posting_mode: INTER_ENTITY only if the company model says
    --    so AND both locations have a group assigned AND those groups
    --    differ — NULL group on either side always falls back to SAME_BOOK.
    SELECT group_id INTO v_from_group_id FROM ric_locations WHERE id = v_header.from_location_id;
    SELECT group_id INTO v_to_group_id   FROM ric_locations WHERE id = v_header.to_location_id;
    SELECT inter_location_model INTO v_inter_location_model FROM ric_companies WHERE id = p_company_id;

    v_posting_mode := CASE
        WHEN v_inter_location_model = 'INTER_ENTITY'
         AND v_from_group_id IS NOT NULL AND v_to_group_id IS NOT NULL
         AND v_from_group_id != v_to_group_id
        THEN 'INTER_ENTITY'
        ELSE 'SAME_BOOK'
    END;

    -- 4. Lock the referenced request, one row per statement (its lines are
    --    locked inside the main line loop below, in product_id order).
    IF v_header.against_request THEN
        SELECT * INTO v_req FROM rih_stock_transfer_requests
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND request_no = v_header.source_request_no AND request_date = v_header.source_request_date
        FOR UPDATE;
    END IF;

    -- 5. Resolve inter-entity accounts up front (once), if needed.
    IF v_posting_mode = 'INTER_ENTITY' THEN
        SELECT customer_account_id, group_name INTO v_customer_account, v_to_group_name
        FROM ric_location_groups WHERE id = v_to_group_id;
        SELECT inter_entity_sales_account_id, inter_entity_cogs_account_id, group_name
        INTO v_ie_sales_account, v_ie_cogs_account, v_from_group_name
        FROM ric_location_groups WHERE id = v_from_group_id;

        IF v_customer_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Location group "%s" has no Customer Account configured — set it up in Location Groups first.', v_to_group_name);
        END IF;
        IF v_ie_sales_account IS NULL OR v_ie_cogs_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Location group "%s" has no Inter-Entity Sales/COGS account configured — set it up in Location Groups first.', v_from_group_name);
        END IF;
    END IF;
    -- v_transit_account is resolved PER LINE inside the loop below, with
    -- that line's real product_id — fn_resolve_account_link's own cache
    -- (rim_account_links) requires a NOT NULL product_id, so it can never
    -- be called with NULL here even for a COMPANY-granularity setup.

    -- 6. Per line: lock+cap the request line (if any), validate cost price,
    --    post stock (batch/serial branch), accumulate GL. Sorted by
    --    product_id — fixed lock-ordering rule.
    FOR v_line IN
        SELECT * FROM rid_stock_transfer_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND transfer_no = p_transfer_no AND transfer_date = p_transfer_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        IF v_line.source_request_no IS NOT NULL THEN
            SELECT * INTO v_req_line FROM rid_stock_transfer_request_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND request_no = v_line.source_request_no AND request_date = v_line.source_request_date
              AND serial_no = v_line.source_request_line_serial
            FOR UPDATE;

            IF v_req_line.transferred_qty + v_line.base_qty > v_req_line.base_qty THEN
                RAISE EXCEPTION 'TRANSFER_QTY_EXCEEDS_REQUESTED'
                    USING DETAIL = format(
                        'Request %s line %s: already transferred %s of %s requested, this transfer adds %s more.',
                        v_line.source_request_no, v_line.source_request_line_serial,
                        v_req_line.transferred_qty, v_req_line.base_qty, v_line.base_qty);
            END IF;

            UPDATE rid_stock_transfer_request_lines SET
                transferred_qty = transferred_qty + v_line.base_qty,
                updated_at = now(), updated_by = p_approved_by
            WHERE id = v_req_line.id;
        END IF;

        -- Cost price: lock + snapshot FROM's current moving average. Hard
        -- block if unavailable — you cannot transfer stock with no known
        -- value, and Receipt has no way to fix this after the fact.
        SELECT cost_price INTO v_cost_price
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.from_location_id AND product_id = v_line.product_id
        FOR UPDATE;

        IF v_cost_price IS NULL OR v_cost_price <= 0 THEN
            RAISE EXCEPTION 'COST_PRICE_NOT_AVAILABLE'
                USING DETAIL = format('No cost price available for [%s] %s at %s — it has no prior stock movement to derive a value from.',
                    (SELECT product_code FROM rim_products WHERE id = v_line.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_line.product_id),
                    (SELECT location_name FROM ric_locations WHERE id = v_header.from_location_id));
        END IF;

        v_sales_price := CASE WHEN v_posting_mode = 'INTER_ENTITY'
                               THEN coalesce(v_line.sales_price, v_cost_price)
                               ELSE NULL END;

        UPDATE rid_stock_transfer_lines SET cost_price = v_cost_price, sales_price = v_sales_price
        WHERE id = v_line.id;

        -- Stock: always leaves FROM immediately (TRANSFER_OUT), batch/serial
        -- branch mirrors fn_approve_grn's/fn_approve_purchase_return's
        -- v_has_batches/v_has_serials pattern exactly.
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.from_location_id, v_line.product_id,
                    p_transfer_date, 'TRANSFER_OUT', -v_batch.base_qty,
                    NULL, NULL, v_batch.batch_no, v_batch.expiry_date, NULL,
                    'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.from_location_id, v_line.product_id,
                    p_transfer_date, 'TRANSFER_OUT', -1,
                    NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                    'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.from_location_id, v_line.product_id,
                p_transfer_date, 'TRANSFER_OUT', -v_line.base_qty,
                NULL, NULL, NULL, NULL, NULL,
                'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
            );
        END IF;

        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.from_location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        IF v_posting_mode = 'SAME_BOOK' THEN
            -- Resolved fresh per line (never cached across iterations) —
            -- a CATEGORY/ITEM-granularity setup could legitimately resolve
            -- a different transit account per product.
            v_transit_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.from_location_id, v_line.product_id, 'STOCK_IN_TRANSIT_ACCOUNT');
            IF v_transit_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Stock in Transit Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;

            v_stxj_lines := v_stxj_lines || jsonb_build_array(
                jsonb_build_object(
                    'account_id', v_transit_account, 'trans_nature', 'DR',
                    'trans_amount', v_cost_price * v_line.base_qty + v_line.charge_amount, 'trans_currency',
                        (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                    'base_amount', v_cost_price * v_line.base_qty + v_line.charge_amount, 'base_rate', 1,
                    'local_amount', (v_cost_price * v_line.base_qty + v_line.charge_amount), 'local_rate', 1,
                    'party_amount', v_cost_price * v_line.base_qty + v_line.charge_amount,
                        'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                    'source_line_type', 'STOCK_IN_TRANSIT', 'source_line_no', v_line.serial_no
                ),
                jsonb_build_object(
                    'account_id', v_stock_account, 'trans_nature', 'CR',
                    'trans_amount', v_cost_price * v_line.base_qty, 'trans_currency',
                        (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                    'base_amount', v_cost_price * v_line.base_qty, 'base_rate', 1,
                    'local_amount', v_cost_price * v_line.base_qty, 'local_rate', 1,
                    'party_amount', v_cost_price * v_line.base_qty,
                        'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                    'source_line_type', 'STOCK_REDUCTION', 'source_line_no', v_line.serial_no
                )
            );
        ELSE
            v_sales_total := v_sales_total + (v_sales_price * v_line.base_qty);
            v_cogs_total  := v_cogs_total + (v_cost_price * v_line.base_qty);

            v_stxc_lines := v_stxc_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'CR',
                'trans_amount', v_cost_price * v_line.base_qty, 'trans_currency',
                    (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_cost_price * v_line.base_qty, 'base_rate', 1,
                'local_amount', v_cost_price * v_line.base_qty, 'local_rate', 1,
                'party_amount', v_cost_price * v_line.base_qty,
                    'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'source_line_type', 'STOCK_REDUCTION', 'source_line_no', v_line.serial_no
            ));
        END IF;
    END LOOP;

    -- 7. Charges — SAME_BOOK only (inter-entity defers these to Receipt).
    IF v_posting_mode = 'SAME_BOOK' THEN
        FOR v_charge IN
            SELECT * FROM rid_stock_transfer_charge_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND transfer_no = p_transfer_no AND transfer_date = p_transfer_date AND is_deleted = false
        LOOP
            IF v_charge.gl_account_id IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
            END IF;
            v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge.gl_account_id,
                'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
                'trans_amount', v_charge.amount, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_charge.amount, 'base_rate', 1,
                'local_amount', v_charge.amount, 'local_rate', 1,
                'party_amount', v_charge.amount, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'source_line_type', 'CHARGE', 'source_line_no', v_charge.serial_no
            ));
        END LOOP;

        SELECT trans_no, trans_date INTO v_stxj_trans_no, v_stxj_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.from_location_id, 'STXJ', p_transfer_date,
            v_stxj_lines, 'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
        );
    ELSE
        v_stxs_lines := jsonb_build_array(
            jsonb_build_object(
                'account_id', v_customer_account, 'trans_nature', 'DR',
                'trans_amount', v_sales_total, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_sales_total, 'base_rate', 1,
                'local_amount', v_sales_total, 'local_rate', 1,
                'party_amount', v_sales_total, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'inv_bill_no', p_transfer_no, 'inv_bill_date', p_transfer_date,
                'source_line_type', 'INTER_ENTITY_RECEIVABLE'
            ),
            jsonb_build_object(
                'account_id', v_ie_sales_account, 'trans_nature', 'CR',
                'trans_amount', v_sales_total, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_sales_total, 'base_rate', 1,
                'local_amount', v_sales_total, 'local_rate', 1,
                'party_amount', v_sales_total, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'source_line_type', 'INTER_ENTITY_SALES'
            )
        );
        SELECT trans_no, trans_date INTO v_stxs_trans_no, v_stxs_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.from_location_id, 'STXS', p_transfer_date,
            v_stxs_lines, 'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
        );

        v_stxc_lines := jsonb_build_array(jsonb_build_object(
            'account_id', v_ie_cogs_account, 'trans_nature', 'DR',
            'trans_amount', v_cogs_total, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
            'base_amount', v_cogs_total, 'base_rate', 1,
            'local_amount', v_cogs_total, 'local_rate', 1,
            'party_amount', v_cogs_total, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
            'source_line_type', 'INTER_ENTITY_COGS'
        )) || v_stxc_lines;
        SELECT trans_no, trans_date INTO v_stxc_trans_no, v_stxc_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.from_location_id, 'STXC', p_transfer_date,
            v_stxc_lines, 'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
        );
    END IF;

    -- 8. Recompute status of the referenced request, if any — unconditional,
    --    same rollup pattern as Material Requisition/Issue.
    IF v_header.against_request THEN
        SELECT coalesce(sum(base_qty), 0), coalesce(sum(transferred_qty), 0)
        INTO v_req_total_ordered, v_req_total_transferred
        FROM rid_stock_transfer_request_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND request_no = v_header.source_request_no AND request_date = v_header.source_request_date
          AND is_deleted = false;

        UPDATE rih_stock_transfer_requests SET
            status = CASE WHEN v_req_total_transferred >= v_req_total_ordered THEN 'CLOSED' ELSE 'PARTIALLY_TRANSFERRED' END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND request_no = v_header.source_request_no AND request_date = v_header.source_request_date
          AND status IN ('APPROVED', 'PARTIALLY_TRANSFERRED');
    END IF;

    -- 9. Mark the transfer approved.
    UPDATE rih_stock_transfers SET
        status = 'APPROVED',
        posting_mode = v_posting_mode,
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no   = coalesce(v_stxc_trans_no, v_stxj_trans_no),
        posted_voucher_date = coalesce(v_stxc_trans_date, v_stxj_trans_date),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_transfer(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
