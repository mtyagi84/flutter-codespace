-- ============================================================
-- 112_inventory_approve_permission.sql
--
-- Batch 2 of the fn_check_approve_permission rollout (Purchase was batch
-- 1, migration 110 + the 111 regression fix). Extends the same
-- server-side approve-permission re-check to all 8 Inventory approve
-- functions — none currently re-check permission server-side, identical
-- gap to every other module fixed so far:
--   fn_approve_material_requisition    -> IN-MRQ
--   fn_approve_material_issue          -> IN-MIS
--   fn_approve_stock_transfer_request  -> IN-STR
--   fn_approve_stock_transfer          -> IN-TRF
--   fn_approve_stock_receipt           -> IN-SRC
--   fn_approve_stock_adjustment        -> IN-ADJ (guarded, see below)
--   fn_approve_opening_stock           -> IN-OPN
--   fn_approve_stock_count_review      -> IN-CNR (RETURNS TEXT, not VOID)
--
-- Every function body below is reproduced verbatim from its current live
-- definition (067/080/072/080/080/080/084/080 respectively) with exactly
-- one new PERFORM fn_check_approve_permission(...) line inserted
-- immediately after the existing status-check block, before period/
-- backdate checks — same insertion rule as 108/109/110.
--
-- ── IN-ADJ needed the SAME guard as migration 111's fix, applied
--    PROACTIVELY this time rather than discovered as a live regression ──
-- fn_approve_stock_count_review does NOT go through a generic posting
-- engine to record its computed variance — it directly COMPOSES
-- fn_save_stock_adjustment + fn_approve_stock_adjustment (see
-- 079_stock_count_review.sql's own header comment: "Composes the
-- EXISTING engine — never write ril_stock_ledger/rid_finance_lines
-- directly"), tagging the adjustment's own header with
-- source_doc_type='STOCK_COUNT_REVIEW' (rih_stock_adjustment_headers
-- gained this nullable column in migration 079 specifically for this
-- traceability). If fn_approve_stock_adjustment's new IN-ADJ check fired
-- unconditionally, approving a Stock Count Review would ALSO silently
-- require the user to separately hold Stock Adjustment (IN-ADJ) approve
-- permission — the exact same class of bug migration 111 fixed for
-- GRN/Purchase Return's auto-posted JV voucher, just caught here before
-- shipping instead of after. Fixed the same way: IN-ADJ is only checked
-- when v_header.source_doc_type IS NULL (a direct human approval on the
-- Stock Adjustment screen) — an auto-posted-from-Review adjustment is
-- already gated by the Review's own IN-CNR check one level up.
-- ============================================================

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_material_requisition — verbatim from 067_material_requisition.sql
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-MRQ');

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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_material_issue — verbatim from 080_manufacturing_date.sql
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-MIS');

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
                    'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_stock_transfer_request — verbatim from 072_stock_transfer_request.sql
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-STR');

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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_stock_transfer — verbatim from 080_manufacturing_date.sql
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-TRF');

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
                    'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_stock_receipt — verbatim from 080_manufacturing_date.sql
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-SRC');

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
                    'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_stock_adjustment — verbatim from 080_manufacturing_date.sql
--
-- IN-ADJ check is GUARDED with "AND v_header.source_doc_type IS NULL" —
-- see this migration's own header comment for the full reasoning. An
-- adjustment auto-posted from Stock Count Review's own composition
-- (source_doc_type='STOCK_COUNT_REVIEW') is already gated by that
-- Review's own IN-CNR check one level up; checking IN-ADJ again here
-- too would be the exact regression migration 111 already fixed once,
-- for the identical reason (an internal composition call is not a
-- second, separate human action).
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — GUARDED to a direct
    -- human approval only (source_doc_type IS NULL). See this migration's
    -- own header comment for the full reasoning.
    IF v_header.source_doc_type IS NULL THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-ADJ');
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
                    'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_opening_stock — verbatim from 084_opening_stock_multi_lot_fix.sql
-- ════════════════════════════════════════════════════════════════════
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
    v_product          RECORD;
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-OPN');

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_opening_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'OPENING_STOCK', p_opening_date);

    IF p_opening_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Opening date %s is in the future — an Opening Stock entry cannot be dated ahead of today.', p_opening_date);
    END IF;

    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = p_company_id;

    -- 3. Pass 1: validate every DISTINCT product's PRE-EXISTING state
    --    before this document touches anything. Locks each row (held for
    --    the rest of the transaction) so pass 2's own lock below is a
    --    harmless re-lock on the same row, same transaction.
    FOR v_product IN
        SELECT DISTINCT product_id FROM rid_opening_stock_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND opening_no = p_opening_no AND opening_date = p_opening_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_product.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT current_stock, cost_price INTO v_current_stock, v_current_cost
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_product.product_id
        FOR UPDATE;

        IF coalesce(v_current_stock, 0) <> 0 OR coalesce(v_current_cost, 0) <> 0 THEN
            RAISE EXCEPTION 'OPENING_STOCK_ALREADY_ESTABLISHED'
                USING DETAIL = format(
                    '[%s] %s already has stock/cost established at this location (qty %s, cost %s) — Opening Stock can only be used before any other stock movement.',
                    (SELECT product_code FROM rim_products WHERE id = v_product.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_product.product_id),
                    v_current_stock, v_current_cost);
        END IF;
    END LOOP;

    -- 4. Pass 2: process every line — every product referenced here has
    --    already been validated as having no pre-existing stock/cost in
    --    pass 1, so no guard re-check is needed (and re-checking here
    --    would reintroduce the exact bug this migration fixes).
    FOR v_line IN
        SELECT * FROM rid_opening_stock_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND opening_no = p_opening_no AND opening_date = p_opening_date AND is_deleted = false
        ORDER BY product_id, line_no
    LOOP
        SELECT id INTO v_pl_id
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

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

        -- 5. Post the movement. One call per line — no v_has_batches/
        --    v_has_serials branching needed since batch/serial identity
        --    is already resolved per-line, not nested in a child table.
        PERFORM fn_post_stock_movement(
            p_client_id, p_company_id, v_header.location_id, v_line.product_id,
            p_opening_date, 'OPENING_STOCK', v_line.base_qty,
            v_line.unit_cost, v_unit_cost_spec,
            v_line.batch_no, v_line.expiry_date, v_line.serial_no,
            'OPENING_STOCK', p_opening_no, p_opening_date, p_approved_by,
            p_manufacturing_date => v_line.manufacturing_date
        );
    END LOOP;

    -- 6. No fn_post_voucher call — this document never posts to GL.

    -- 7. Mark the entry approved.
    UPDATE rih_opening_stock_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_opening_stock(UUID, UUID, TEXT, DATE, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_stock_count_review — verbatim from 080_manufacturing_date.sql
-- RETURNS TEXT (not VOID) — preserved exactly.
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-CNR');

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
                'manufacturing_date', v_row.manufacturing_date,
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
