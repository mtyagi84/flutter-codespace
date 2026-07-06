-- ============================================================
-- Migration 063: Batch/Serial selection + validation for Purchase Return
-- ============================================================
-- Discussed live: a batch/serial-tracked product being returned must let
-- the user pick WHICH batch(es)/serial(s) are going back, and — since a
-- batch or serial is a specific, identifiable physical unit, not a fungible
-- aggregate quantity — it can NEVER honor allow_negative_stock (item or
-- location flag). You cannot have "-2 units of batch LOT-042"; either the
-- batch has enough remaining balance or it doesn't, full stop. This is
-- stricter than the aggregate-quantity check migration 060 already added,
-- not a relaxation of it — aggregate (non-tracked) products keep 060's
-- flag-gated behavior unchanged.
--
-- 1. fn_post_stock_movement — extended (same 17-param signature as 049/060,
--    CREATE OR REPLACE replaces in place) with a strict, flag-independent
--    balance check whenever p_batch_no or p_serial_no is supplied on an
--    outward movement:
--      BATCH  — SUM(qty_change) for that exact batch_no (this product,
--               this location) must cover the requested outward qty.
--      SERIAL — SUM(qty_change) for that exact serial_no must currently be
--               > 0 (i.e. that unit is actually on hand here) before it can
--               be taken out again.
--    Untracked movements (both NULL) are unchanged — still governed by
--    060's item-AND-location allow_negative_stock flags.
--
-- 2. v_batch_stock_balance / v_serial_stock_status — plain aggregate views
--    over ril_stock_ledger (the only source of truth; no separate running-
--    balance table exists). Flutter uses these to show "Available: N" next
--    to each pickable batch/serial in the Purchase Return entry screen —
--    a UX hint only; the real enforcement is #1 above, at Approve time.
--
-- 3. fn_save_purchase_return — signature changes from
--    (header, lines, charges, user_id) to
--    (header, lines, batches, serials, charges, user_id), mirroring
--    fn_save_grn's param order exactly. The old 4-param overload is
--    explicitly dropped (not left as dead orphan) since this is a straight
--    signature change, not an additive one. Batch quantities per line are
--    validated to sum to that line's own return qty (BATCH_QTY_MISMATCH),
--    identical rule to fn_save_grn — no separate serial-count check on the
--    backend, same asymmetry fn_save_grn itself has (that check lives only
--    in the Flutter entry screen for both GRN and now Purchase Return).
--
-- 4. fn_approve_purchase_return — the single aggregate
--    fn_post_stock_movement call per return line is replaced with the same
--    v_has_batches/v_has_serials branch fn_approve_grn already uses, looping
--    one row at a time so each batch/serial's own strict check (#1) fires
--    per unit/lot rather than once for the line's total.
-- ============================================================


-- ── 1. fn_post_stock_movement: strict batch/serial check ────────────────────
CREATE OR REPLACE FUNCTION fn_post_stock_movement(
    p_client_id         UUID,
    p_company_id        UUID,
    p_location_id       UUID,
    p_product_id        UUID,
    p_trans_date        DATE,
    p_trans_type        TEXT,
    p_qty_change        NUMERIC,                -- signed: positive = IN, negative = OUT
    p_unit_cost_base     NUMERIC DEFAULT NULL,   -- required (NOT NULL) when p_qty_change > 0
    p_unit_cost_specific NUMERIC DEFAULT NULL,   -- required (NOT NULL) when p_qty_change > 0
    p_batch_no           TEXT    DEFAULT NULL,
    p_expiry_date        DATE    DEFAULT NULL,
    p_serial_no          TEXT    DEFAULT NULL,   -- SERIAL-tracked products: caller loops one unit (qty=+/-1) per serial
    p_source_doc_type    TEXT    DEFAULT NULL,
    p_source_doc_no      TEXT    DEFAULT NULL,
    p_source_doc_date    DATE    DEFAULT NULL,
    p_user_id            UUID    DEFAULT NULL,
    p_rate_to_base       NUMERIC DEFAULT NULL    -- FX rate (trans currency -> base) used for p_unit_cost_base, stored for audit (049)
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_pl_id           UUID;
    v_qty_before      NUMERIC(18,4);
    v_cost_before      NUMERIC(18,4);
    v_cost_before_spec NUMERIC(18,4);
    v_qty_after       NUMERIC(18,4);
    v_cost_after       NUMERIC(18,4);
    v_cost_after_spec  NUMERIC(18,4);
    v_item_allows_negative BOOLEAN;
    v_location_allows_negative BOOLEAN;
    v_batch_balance    NUMERIC;
    v_serial_balance   NUMERIC;
BEGIN
    PERFORM fn_check_period_open(p_company_id, p_trans_date);

    IF p_qty_change > 0 AND p_unit_cost_base IS NULL THEN
        RAISE EXCEPTION 'UNIT_COST_REQUIRED'
            USING DETAIL = 'p_unit_cost_base is required for inward stock movements.';
    END IF;

    -- Get-or-create then lock the balance row for the duration of this transaction.
    INSERT INTO rim_product_location (
        client_id, company_id, location_id, product_id,
        current_stock, cost_price, cost_price_specific, created_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id, p_product_id,
        0, 0, NULL, p_user_id
    )
    ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

    SELECT id, current_stock, cost_price, cost_price_specific
    INTO v_pl_id, v_qty_before, v_cost_before, v_cost_before_spec
    FROM rim_product_location
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND location_id = p_location_id AND product_id = p_product_id
    FOR UPDATE;

    v_qty_after := v_qty_before + p_qty_change;

    -- NEW (063): a batch or serial is a specific identifiable unit/lot —
    -- its own balance must cover the outward movement, unconditionally
    -- (allow_negative_stock flags never apply here, unlike the aggregate
    -- check below).
    IF p_qty_change < 0 AND p_batch_no IS NOT NULL THEN
        SELECT coalesce(sum(qty_change), 0) INTO v_batch_balance
        FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = p_location_id AND product_id = p_product_id
          AND batch_no = p_batch_no;

        IF v_batch_balance + p_qty_change < 0 THEN
            RAISE EXCEPTION 'BATCH_INSUFFICIENT_STOCK'
                USING DETAIL = format(
                    'Batch %s of [%s] %s has %s on hand at this location, %s requested. Batch-tracked stock can never go negative.',
                    p_batch_no,
                    (SELECT product_code FROM rim_products WHERE id = p_product_id),
                    (SELECT product_name FROM rim_products WHERE id = p_product_id),
                    v_batch_balance, abs(p_qty_change));
        END IF;
    ELSIF p_qty_change < 0 AND p_serial_no IS NOT NULL THEN
        SELECT coalesce(sum(qty_change), 0) INTO v_serial_balance
        FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = p_location_id AND product_id = p_product_id
          AND serial_no = p_serial_no;

        IF v_serial_balance + p_qty_change < 0 THEN
            RAISE EXCEPTION 'SERIAL_NOT_IN_STOCK'
                USING DETAIL = format(
                    'Serial %s of [%s] %s is not currently in stock at this location. Serial-tracked stock can never go negative.',
                    p_serial_no,
                    (SELECT product_code FROM rim_products WHERE id = p_product_id),
                    (SELECT product_name FROM rim_products WHERE id = p_product_id));
        END IF;
    ELSIF p_qty_change < 0 AND v_qty_after < 0 THEN
        -- Untracked (aggregate) products only — existing 060 flag-gated check.
        SELECT coalesce((flags->>'allow_negative_stock')::boolean, false) INTO v_item_allows_negative
        FROM rim_products WHERE id = p_product_id;

        SELECT is_negative_stock_allowed INTO v_location_allows_negative
        FROM ric_locations WHERE id = p_location_id;

        IF NOT (coalesce(v_item_allows_negative, false) AND coalesce(v_location_allows_negative, false)) THEN
            RAISE EXCEPTION 'NEGATIVE_STOCK_NOT_ALLOWED'
                USING DETAIL = format(
                    'Not enough stock: [%s] %s has %s on hand at this location, %s requested. Enable "Allow Negative Stock" on both the item and the location to override.',
                    (SELECT product_code FROM rim_products WHERE id = p_product_id),
                    (SELECT product_name FROM rim_products WHERE id = p_product_id),
                    v_qty_before, abs(p_qty_change));
        END IF;
    END IF;

    IF p_qty_change > 0 THEN
        -- Independent weighted-average in each currency: before+/current-in formula
        -- run twice, never cost_price_after ÷ today's rate.
        v_cost_after := (v_qty_before * v_cost_before + p_qty_change * p_unit_cost_base) / v_qty_after;
        v_cost_after_spec := (v_qty_before * COALESCE(v_cost_before_spec, 0)
                               + p_qty_change * COALESCE(p_unit_cost_specific, 0)) / v_qty_after;

        INSERT INTO ril_cost_price_history (
            client_id, company_id, location_id, product_id, trans_date,
            source_doc_type, source_doc_no, source_doc_date,
            qty_before, cost_price_before, cost_price_before_specific,
            qty_in, cost_price_in, cost_price_in_specific,
            qty_after, cost_price_after, cost_price_after_specific,
            rate_to_base,
            created_by
        ) VALUES (
            p_client_id, p_company_id, p_location_id, p_product_id, p_trans_date,
            p_source_doc_type, p_source_doc_no, p_source_doc_date,
            v_qty_before, v_cost_before, v_cost_before_spec,
            p_qty_change, p_unit_cost_base, p_unit_cost_specific,
            v_qty_after, v_cost_after, v_cost_after_spec,
            p_rate_to_base,
            p_user_id
        );
    ELSE
        -- Outward movement: cost never changes, only current_stock. Snapshot the
        -- CURRENT average cost onto the ledger row for COGS — never caller-supplied.
        v_cost_after := v_cost_before;
        v_cost_after_spec := v_cost_before_spec;
    END IF;

    UPDATE rim_product_location
    SET current_stock = v_qty_after,
        cost_price = v_cost_after,
        cost_price_specific = v_cost_after_spec,
        updated_at = now(),
        updated_by = p_user_id
    WHERE id = v_pl_id;

    INSERT INTO ril_stock_ledger (
        client_id, company_id, location_id, product_id, trans_date, trans_type,
        qty_change, base_qty, batch_no, expiry_date, serial_no, unit_cost,
        source_doc_type, source_doc_no, source_doc_date, created_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id, p_product_id, p_trans_date, p_trans_type,
        p_qty_change, abs(p_qty_change), p_batch_no, p_expiry_date, p_serial_no, v_cost_after,
        p_source_doc_type, p_source_doc_no, p_source_doc_date, p_user_id
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_post_stock_movement(
    UUID, UUID, UUID, UUID, DATE, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT, TEXT, TEXT, DATE, UUID, NUMERIC
) TO authenticated;


-- ── 2. Read-side balance views for the Flutter picker ────────────────────────
CREATE OR REPLACE VIEW v_batch_stock_balance AS
SELECT client_id, company_id, location_id, product_id, batch_no,
       max(expiry_date) AS expiry_date,
       sum(qty_change)  AS balance
FROM ril_stock_ledger
WHERE batch_no IS NOT NULL
GROUP BY client_id, company_id, location_id, product_id, batch_no;

CREATE OR REPLACE VIEW v_serial_stock_status AS
SELECT client_id, company_id, location_id, product_id, serial_no,
       sum(qty_change) AS balance,
       CASE WHEN sum(qty_change) > 0 THEN 'IN_STOCK' ELSE 'OUT' END AS status
FROM ril_stock_ledger
WHERE serial_no IS NOT NULL
GROUP BY client_id, company_id, location_id, product_id, serial_no;


-- ── 3. fn_save_purchase_return: accept p_batches/p_serials ───────────────────
DROP FUNCTION IF EXISTS fn_save_purchase_return(JSONB, JSONB, JSONB, UUID);

CREATE OR REPLACE FUNCTION fn_save_purchase_return(
    p_header    JSONB,
    p_lines     JSONB,   -- [{serial_no, source_grn_no, source_grn_date, source_grn_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate, tax_group_id, gross_amount, tax_amount, final_amount}, ...]
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
            tax_group_id, gross_amount, tax_amount, final_amount,
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


-- ── 4. fn_approve_purchase_return: per-batch/serial stock reversal ───────────
CREATE OR REPLACE FUNCTION fn_approve_purchase_return(
    p_client_id   UUID,
    p_company_id  UUID,
    p_return_no   TEXT,
    p_return_date DATE,
    p_reopen_po   BOOLEAN,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header            rih_purchase_return_headers%ROWTYPE;
    v_return_ccy        TEXT;
    v_base_ccy          TEXT;
    v_local_ccy         TEXT;
    v_grn_key           RECORD;
    v_grn               rih_grn_headers%ROWTYPE;
    v_line              RECORD;
    v_tax_row           RECORD;
    v_po_key            RECORD;
    v_batch             rid_transaction_line_batches%ROWTYPE;
    v_serial_row        rid_transaction_line_serials%ROWTYPE;
    v_has_batches       BOOLEAN;
    v_has_serials       BOOLEAN;
    v_total_est_taxable NUMERIC := 0;
    v_total_est_tax_billed NUMERIC := 0;
    v_grn_taxable       NUMERIC;
    v_grn_tax           NUMERIC;
    v_line_actual_taxable NUMERIC;
    v_line_actual_tax   NUMERIC;
    v_account_ccy       TEXT;
    v_party_rate        NUMERIC;
    v_party_ccy         TEXT;
    v_stock_account     UUID;
    v_accrual_account   UUID;
    v_returns_account    UUID;
    v_anchor_product_id UUID;
    v_rate_sum          NUMERIC;
    v_jv_lines          JSONB := '[]'::jsonb;
    v_sdn_lines         JSONB := '[]'::jsonb;
    v_jv_trans_no       TEXT;
    v_jv_trans_date     DATE;
    v_sdn_trans_no      TEXT;
    v_sdn_trans_date    DATE;
    v_supplier_dr_total NUMERIC := 0;
    v_sdn_cr_total      NUMERIC := 0;
    v_plug              NUMERIC;
    v_po_total_ordered  NUMERIC;
    v_po_total_received NUMERIC;
    v_po_any_short      BOOLEAN;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_purchase_return_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND return_no = p_return_no AND return_date = p_return_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Return % dated % not found', p_return_no, p_return_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Purchase Return % is % and cannot be approved again', p_return_no, v_header.status;
    END IF;

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_return_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'PURCHASE_RETURN', p_return_date);

    -- 3. Lock every referenced GRN, one row per statement in a fixed sort
    --    order (same rule as fn_save_purchase_return / fn_approve_grn).
    FOR v_grn_key IN
        SELECT DISTINCT source_grn_no, source_grn_date FROM rid_purchase_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY source_grn_no, source_grn_date
    LOOP
        PERFORM 1 FROM rih_grn_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = v_grn_key.source_grn_no AND grn_date = v_grn_key.source_grn_date
        FOR UPDATE;
    END LOOP;

    SELECT currency_id INTO v_return_ccy FROM rim_currencies WHERE id = v_header.return_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- 4. Suggestion totals across ALL lines — used purely as apportionment
    --    weights for the header's user-confirmed taxable_amount/tax_amount.
    --    Tax weight only accumulates from lines whose GRN is already billed
    --    (an unbilled GRN's line-level tax_amount is just the still-deferred
    --    GR/IR estimate — no real VAT exists there to reverse).
    SELECT coalesce(sum(l.gross_amount), 0) INTO v_total_est_taxable
    FROM rid_purchase_return_lines l
    WHERE l.client_id = p_client_id AND l.company_id = p_company_id
      AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false;

    IF v_total_est_taxable = 0 THEN
        RAISE EXCEPTION 'NO_RETURN_LINES'
            USING DETAIL = 'This return has no lines with a non-zero value to apportion against.';
    END IF;

    -- Anchor product for the Purchase Returns contra account resolution
    -- below — fn_resolve_account_link's own cache keys on product_id, so a
    -- NULL product_id (even though COMPANY-level resolution doesn't
    -- logically need one) would always cache-miss. Same precedent as
    -- Purchase Bill's Exchange Gain/Loss anchor (059).
    SELECT product_id INTO v_anchor_product_id
    FROM rid_purchase_return_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
    LIMIT 1;

    SELECT coalesce(sum(l.tax_amount), 0) INTO v_total_est_tax_billed
    FROM rid_purchase_return_lines l
    JOIN rih_grn_headers g
      ON g.client_id = l.client_id AND g.company_id = l.company_id
     AND g.grn_no = l.source_grn_no AND g.grn_date = l.source_grn_date
    WHERE l.client_id = p_client_id AND l.company_id = p_company_id
      AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false
      AND g.billed_invoice_no IS NOT NULL;

    IF v_header.tax_amount <> 0 AND v_total_est_tax_billed = 0 THEN
        RAISE EXCEPTION 'NO_BILLED_LINES_FOR_TAX'
            USING DETAIL = 'A non-zero VAT amount was entered, but none of this return''s lines belong to an already-billed GRN.';
    END IF;

    -- 5. Walk each referenced GRN — post stock reversal for every line
    --    (always), then branch the financial reversal by billed status.
    FOR v_grn_key IN
        SELECT DISTINCT source_grn_no, source_grn_date FROM rid_purchase_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY source_grn_no, source_grn_date
    LOOP
        SELECT * INTO v_grn FROM rih_grn_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = v_grn_key.source_grn_no AND grn_date = v_grn_key.source_grn_date;

        v_grn_taxable := 0;
        v_grn_tax := 0;

        FOR v_line IN
            SELECT l.*, gl.source_po_order_no, gl.source_po_order_date, gl.source_po_line_serial,
                   gl.base_qty AS grn_line_base_qty
            FROM rid_purchase_return_lines l
            JOIN rid_grn_lines gl
              ON gl.client_id = l.client_id AND gl.company_id = l.company_id
             AND gl.grn_no = l.source_grn_no AND gl.grn_date = l.source_grn_date
             AND gl.serial_no = l.source_grn_line_serial
            WHERE l.client_id = p_client_id AND l.company_id = p_company_id
              AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false
              AND l.source_grn_no = v_grn_key.source_grn_no AND l.source_grn_date = v_grn_key.source_grn_date
            ORDER BY l.product_id
        LOOP
            -- Cap the returned qty against what's left returnable on this
            -- GRN line — SUM of every OTHER already-APPROVED return against
            -- the same GRN line (this return itself is still DRAFT during
            -- this check, so it's naturally excluded) must not, combined
            -- with this line's own qty, exceed what the GRN line originally
            -- received. A line can be partially returned across several
            -- separate Purchase Return documents over time.
            DECLARE
                v_already_returned NUMERIC;
            BEGIN
                SELECT coalesce(sum(pl.base_qty), 0) INTO v_already_returned
                FROM rid_purchase_return_lines pl
                JOIN rih_purchase_return_headers ph
                  ON ph.client_id = pl.client_id AND ph.company_id = pl.company_id
                 AND ph.return_no = pl.return_no AND ph.return_date = pl.return_date
                WHERE pl.client_id = p_client_id AND pl.company_id = p_company_id
                  AND pl.source_grn_no = v_line.source_grn_no AND pl.source_grn_date = v_line.source_grn_date
                  AND pl.source_grn_line_serial = v_line.source_grn_line_serial
                  AND pl.is_deleted = false AND ph.status = 'APPROVED';

                IF v_already_returned + v_line.base_qty > v_line.grn_line_base_qty THEN
                    RAISE EXCEPTION 'RETURN_QTY_EXCEEDS_RECEIVED'
                        USING DETAIL = format(
                            'GRN %s line %s: already returned %s of %s received, this return adds %s more.',
                            v_line.source_grn_no, v_line.source_grn_line_serial,
                            v_already_returned, v_line.grn_line_base_qty, v_line.base_qty);
                END IF;
            END;

            -- Stock: always reverses, regardless of billed status. No
            -- unit_cost needed for an outward movement — fn_post_stock_
            -- movement snapshots the CURRENT average cost itself. Batch/
            -- serial-tracked lines post one row per batch/unit instead of
            -- one aggregate call, so each batch/serial's own strict,
            -- flag-independent balance check (migration 063) fires —
            -- mirrors fn_approve_grn's v_has_batches/v_has_serials pattern.
            SELECT EXISTS (
                SELECT 1 FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                  AND line_serial = v_line.serial_no
            ) INTO v_has_batches;

            SELECT EXISTS (
                SELECT 1 FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                  AND line_serial = v_line.serial_no
            ) INTO v_has_serials;

            IF v_has_batches THEN
                FOR v_batch IN
                    SELECT * FROM rid_transaction_line_batches
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_return_date, 'PURCHASE_RETURN', -v_batch.base_qty,
                        NULL, NULL, v_batch.batch_no, v_batch.expiry_date, NULL,
                        'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
                    );
                END LOOP;
            ELSIF v_has_serials THEN
                FOR v_serial_row IN
                    SELECT * FROM rid_transaction_line_serials
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_return_date, 'PURCHASE_RETURN', -1,
                        NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                        'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
                    );
                END LOOP;
            ELSE
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_return_date, 'PURCHASE_RETURN', -v_line.base_qty,
                    NULL, NULL, NULL, NULL, NULL,
                    'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
                );
            END IF;

            -- Roll qty_received BACK on the referenced PO line, if any —
            -- always, regardless of p_reopen_po (that flag only gates the
            -- PO's own status recompute below, not this figure).
            IF v_line.source_po_order_no IS NOT NULL THEN
                UPDATE rid_purchase_order_lines SET
                    qty_received = qty_received - v_line.base_qty,
                    updated_at = now(), updated_by = p_approved_by
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND order_no = v_line.source_po_order_no AND order_date = v_line.source_po_order_date
                  AND serial_no = v_line.source_po_line_serial;
            END IF;

            v_line_actual_taxable := v_header.taxable_amount * (v_line.gross_amount / v_total_est_taxable);
            v_grn_taxable := v_grn_taxable + v_line_actual_taxable;

            IF v_grn.billed_invoice_no IS NULL THEN
                -- Unbilled: reverse the still-provisional Accrual, tax-
                -- exclusive — mirrors exactly how the GRN itself posted it.
                v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
                v_accrual_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'PURCHASE_ACCRUAL_ACCOUNT');
                IF v_stock_account IS NULL OR v_accrual_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('No Stock/Purchase Accrual Account resolved for product %s.',
                            (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
                END IF;

                v_jv_lines := v_jv_lines || jsonb_build_array(
                    jsonb_build_object(
                        'account_id', v_accrual_account, 'trans_nature', 'DR',
                        'trans_amount', v_line_actual_taxable, 'trans_currency', v_return_ccy,
                        'base_amount', v_line_actual_taxable * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_line_actual_taxable * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line_actual_taxable, 'party_currency', v_return_ccy, 'party_rate', 1,
                        'source_line_type', 'ACCRUAL_REVERSAL'
                    ),
                    jsonb_build_object(
                        'account_id', v_stock_account, 'trans_nature', 'CR',
                        'trans_amount', v_line_actual_taxable, 'trans_currency', v_return_ccy,
                        'base_amount', v_line_actual_taxable * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_line_actual_taxable * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line_actual_taxable, 'party_currency', v_return_ccy, 'party_rate', 1,
                        'source_line_type', 'STOCK_REVERSAL'
                    )
                );
            ELSE
                -- Billed: Accrual already net-zero (cleared by the Bill) —
                -- untouched. Reverse Stock + Input VAT instead; Supplier is
                -- posted once, in aggregate, after this loop.
                v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
                IF v_stock_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('No Stock Account resolved for product %s.',
                            (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
                END IF;

                v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_stock_account, 'trans_nature', 'CR',
                    'trans_amount', v_line_actual_taxable, 'trans_currency', v_return_ccy,
                    'base_amount', v_line_actual_taxable * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_line_actual_taxable * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_line_actual_taxable, 'party_currency', v_return_ccy, 'party_rate', 1,
                    'source_line_type', 'STOCK_REVERSAL'
                ));
                v_sdn_cr_total := v_sdn_cr_total + (v_line_actual_taxable * v_header.rate_to_base);

                IF v_total_est_tax_billed > 0 AND v_line.tax_group_id IS NOT NULL AND v_line.tax_amount <> 0 THEN
                    v_line_actual_tax := v_header.tax_amount * (v_line.tax_amount / v_total_est_tax_billed);
                    v_grn_tax := v_grn_tax + v_line_actual_tax;

                    SELECT coalesce(sum(fn_get_active_tax_rate(tgm.tax_id, p_return_date)), 0) INTO v_rate_sum
                    FROM rim_tax_group_members tgm
                    WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                      AND tgm.tax_group_id = v_line.tax_group_id;

                    IF v_rate_sum > 0 THEN
                        FOR v_tax_row IN
                            SELECT tgm.tax_id, t.gl_input_account_id, t.tax_code, t.tax_name,
                                   fn_get_active_tax_rate(tgm.tax_id, p_return_date) AS rate
                            FROM rim_tax_group_members tgm
                            JOIN rim_taxes t ON t.id = tgm.tax_id
                            WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                              AND tgm.tax_group_id = v_line.tax_group_id
                        LOOP
                            IF v_tax_row.gl_input_account_id IS NULL THEN
                                RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                                    USING DETAIL = format('Tax [%s] %s has no Input GL account configured.',
                                        v_tax_row.tax_code, v_tax_row.tax_name);
                            END IF;

                            v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
                                'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'CR',
                                'trans_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum, 'trans_currency', v_return_ccy,
                                'base_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                                'local_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                                'party_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum, 'party_currency', v_return_ccy, 'party_rate', 1,
                                'source_line_type', 'INPUT_VAT_REVERSAL'
                            ));
                            v_sdn_cr_total := v_sdn_cr_total + (v_line_actual_tax * v_tax_row.rate / v_rate_sum * v_header.rate_to_base);
                        END LOOP;
                    END IF;
                END IF;
            END IF;
        END LOOP;

        IF v_grn.billed_invoice_no IS NOT NULL THEN
            v_supplier_dr_total := v_supplier_dr_total + v_grn_taxable + v_grn_tax;
        END IF;
    END LOOP;

    -- 6. One aggregate Supplier DR line for the whole SDN (one supplier per
    --    return, by construction) — deliberately NOT tagged with inv_bill_no
    --    (a plain on-account debit note, not tied into bill-settlement
    --    tracking — a known v1 simplification).
    IF v_supplier_dr_total > 0 THEN
        SELECT c.currency_id INTO v_account_ccy
        FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
        WHERE a.id = v_header.supplier_id;
        IF v_account_ccy IS NULL OR v_account_ccy = v_return_ccy THEN
            v_party_rate := 1; v_party_ccy := v_return_ccy;
        ELSIF v_account_ccy = v_base_ccy THEN
            v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
        ELSIF v_account_ccy = v_local_ccy THEN
            v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_return_ccy, v_account_ccy, p_return_date);
            v_party_ccy := v_account_ccy;
        END IF;

        v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_header.supplier_id, 'trans_nature', 'DR',
            'trans_amount', v_supplier_dr_total, 'trans_currency', v_return_ccy,
            'base_amount', v_supplier_dr_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_supplier_dr_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_supplier_dr_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'source_line_type', 'SUPPLIER_REVERSAL'
        ));

        -- Plug: whatever the confirmed Supplier amount doesn't split evenly
        -- across Stock+VAT — e.g. the user typed Supplier/VAT figures that
        -- don't reconcile to the penny, or a negotiated settlement differs
        -- from the pure return value. Unlike Purchase Bill's Exchange plug,
        -- this one IS a genuine transaction-currency event (a real
        -- return-value adjustment, not a pure base-currency FX artifact),
        -- so it lives in this SAME voucher/currency, no separate voucher
        -- needed.
        v_plug := (v_supplier_dr_total * v_header.rate_to_base) - v_sdn_cr_total;
        IF abs(v_plug) > 0.0001 THEN
            v_returns_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_anchor_product_id, 'PURCHASE_RETURNS_ACCOUNT');
            IF v_returns_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = 'No Purchase Returns Account configured.';
            END IF;

            v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_returns_account,
                'trans_nature', CASE WHEN v_plug > 0 THEN 'CR' ELSE 'DR' END,
                'trans_amount', abs(v_plug) / v_header.rate_to_base, 'trans_currency', v_return_ccy,
                'base_amount', abs(v_plug), 'base_rate', v_header.rate_to_base,
                'local_amount', abs(v_plug) * (v_header.rate_to_local / v_header.rate_to_base), 'local_rate', v_header.rate_to_local,
                'party_amount', abs(v_plug) / v_header.rate_to_base, 'party_currency', v_return_ccy, 'party_rate', 1,
                'source_line_type', 'RETURN_VALUE_ADJUSTMENT'
            ));
        END IF;
    END IF;

    -- 7. Post whichever vouchers are needed. Both tag the same
    --    source_doc_type/source_doc_no, so the Posted Journal Entries
    --    section finds either or both with no extra plumbing.
    IF jsonb_array_length(v_jv_lines) > 0 THEN
        SELECT trans_no, trans_date INTO v_jv_trans_no, v_jv_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'JV', p_return_date,
            v_jv_lines, 'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
        );
    END IF;

    IF jsonb_array_length(v_sdn_lines) > 0 THEN
        SELECT trans_no, trans_date INTO v_sdn_trans_no, v_sdn_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'SDN', p_return_date,
            v_sdn_lines, 'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
        );
    END IF;

    -- 8. Recompute status of every PO touched by this return, ONLY if the
    --    caller chose to reopen — qty_received itself already moved above
    --    regardless of this flag.
    IF p_reopen_po THEN
        FOR v_po_key IN
            SELECT DISTINCT gl.source_po_order_no, gl.source_po_order_date
            FROM rid_purchase_return_lines l
            JOIN rid_grn_lines gl
              ON gl.client_id = l.client_id AND gl.company_id = l.company_id
             AND gl.grn_no = l.source_grn_no AND gl.grn_date = l.source_grn_date
             AND gl.serial_no = l.source_grn_line_serial
            WHERE l.client_id = p_client_id AND l.company_id = p_company_id
              AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false
              AND gl.source_po_order_no IS NOT NULL
        LOOP
            SELECT coalesce(sum(base_qty), 0), coalesce(sum(qty_received), 0)
            INTO v_po_total_ordered, v_po_total_received
            FROM rid_purchase_order_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = v_po_key.source_po_order_no AND order_date = v_po_key.source_po_order_date
              AND is_deleted = false;

            v_po_any_short := v_po_total_received < v_po_total_ordered;

            UPDATE rih_purchase_orders SET
                status = CASE WHEN v_po_any_short THEN 'PARTIALLY_RECEIVED' ELSE 'CLOSED' END,
                closed_by = CASE WHEN v_po_any_short THEN NULL ELSE closed_by END,
                closed_at = CASE WHEN v_po_any_short THEN NULL ELSE closed_at END,
                updated_at = now(), updated_by = p_approved_by
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = v_po_key.source_po_order_no AND order_date = v_po_key.source_po_order_date
              AND status IN ('APPROVED', 'PARTIALLY_RECEIVED', 'CLOSED');
        END LOOP;
    END IF;

    -- 9. Mark the return approved. Primary voucher reference is the SDN if
    --    this return touched any billed GRN, else the JV.
    UPDATE rih_purchase_return_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = coalesce(v_sdn_trans_no, v_jv_trans_no),
        posted_voucher_date = coalesce(v_sdn_trans_date, v_jv_trans_date),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_purchase_return(UUID, UUID, TEXT, DATE, BOOLEAN, UUID) TO authenticated;
