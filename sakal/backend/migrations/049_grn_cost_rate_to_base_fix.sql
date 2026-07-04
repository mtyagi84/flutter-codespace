-- ============================================================
-- Migration 049: fn_post_stock_movement — actually store rate_to_base
-- ============================================================
-- Bug reported live: after posting a GRN in USD (the company's base
-- currency), ril_cost_price_history.rate_to_base was NULL instead of 1.
--
-- Root cause: ril_cost_price_history.rate_to_base (036) was declared but
-- NEVER included in fn_post_stock_movement's INSERT column list — it was
-- always NULL regardless of currency, not just in the base-currency case.
-- fn_approve_grn already computes the exact rate needed
-- (v_rate_to_base := fn_get_exchange_rate(...)) per line, but never had a
-- parameter to hand it to fn_post_stock_movement.
--
-- Fix: fn_post_stock_movement gains a new trailing parameter
-- p_rate_to_base (DEFAULT NULL, so nothing else calling it breaks), stored
-- straight onto ril_cost_price_history.rate_to_base for inward movements.
-- fn_approve_grn (the only caller) now passes its already-computed
-- v_rate_to_base into all three call sites (batch/serial/plain).
--
-- New migration, not an edit to 036/046 — either may already be deployed.
-- Old fn_post_stock_movement signature is explicitly dropped since adding
-- a parameter creates a distinct overload otherwise (same pattern as
-- migration 040's fn_save_purchase_order signature change).
-- ============================================================

DROP FUNCTION IF EXISTS fn_post_stock_movement(
    UUID, UUID, UUID, UUID, DATE, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT, TEXT, TEXT, DATE, UUID
);

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
    p_rate_to_base       NUMERIC DEFAULT NULL    -- FX rate (trans currency -> base) used for p_unit_cost_base, stored for audit
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_pl_id           UUID;
    v_qty_before      NUMERIC(18,4);
    v_cost_before      NUMERIC(18,4);
    v_cost_before_spec NUMERIC(18,4);
    v_qty_after       NUMERIC(18,4);
    v_cost_after       NUMERIC(18,4);
    v_cost_after_spec  NUMERIC(18,4);
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

-- ── fn_approve_grn — pass the already-computed rate through ──────────────────
-- Identical to the 046 version except the three fn_post_stock_movement calls
-- now pass v_rate_to_base as the new trailing argument.
CREATE OR REPLACE FUNCTION fn_approve_grn(
    p_client_id   UUID,
    p_company_id  UUID,
    p_grn_no      TEXT,
    p_grn_date    DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_grn_headers%ROWTYPE;
    v_line                rid_grn_lines%ROWTYPE;
    v_batch                rid_transaction_line_batches%ROWTYPE;
    v_serial_row            rid_transaction_line_serials%ROWTYPE;
    v_charge                 rid_grn_charge_lines%ROWTYPE;
    v_po_line                 RECORD;
    v_po_key                  RECORD;
    v_tax_row                    RECORD;
    v_charge_tax_account          UUID;
    v_charge_tax_label            TEXT;
    v_base_ccy                     TEXT;
    v_grn_ccy                        TEXT;
    v_product_ccy                      TEXT;
    v_rate_to_base                       NUMERIC;
    v_rate_to_specific                     NUMERIC;
    v_unit_cost_base                         NUMERIC;
    v_unit_cost_specific                       NUMERIC;
    v_stock_account                              UUID;
    v_accrual_account                              UUID;
    v_taxable_amount                                 NUMERIC;
    v_rate_sum                                         NUMERIC;
    v_has_batches                                        BOOLEAN;
    v_has_serials                                          BOOLEAN;
    v_voucher_lines                                        JSONB;
    v_voucher_result                                        RECORD;
    v_po_total_ordered                                        NUMERIC;
    v_po_total_received                                         NUMERIC;
    v_po_any_short                                                BOOLEAN;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_grn_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND grn_no = p_grn_no AND grn_date = p_grn_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'GRN % dated % not found', p_grn_no, p_grn_date;
    END IF;

    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'GRN % is % and cannot be approved again', p_grn_no, v_header.status;
    END IF;

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_grn_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'GRN', p_grn_date);

    -- 3. Lock referenced PO lines FOR UPDATE, one at a time in a fixed sort
    --    order, BEFORE any product-row lock below — fixed inter-type
    --    ordering rule from migration 036, prevents a deadlock class between
    --    concurrent GRNs touching overlapping POs and overlapping products in
    --    different orders. NOTE: a single "SELECT ... ORDER BY ... FOR UPDATE"
    --    statement does NOT guarantee locks are acquired in ORDER BY sequence
    --    in PostgreSQL — the sort and the row-locking are not reliably
    --    sequenced together. Locking must happen one row per statement,
    --    driven by a loop over an already-sorted key list, exactly like the
    --    per-line fn_post_stock_movement calls below already do correctly.
    FOR v_po_key IN
        SELECT DISTINCT gl.source_po_order_no, gl.source_po_order_date, gl.source_po_line_serial
        FROM rid_grn_lines gl
        WHERE gl.client_id = p_client_id AND gl.company_id = p_company_id
          AND gl.grn_no = p_grn_no AND gl.grn_date = p_grn_date
          AND gl.source_po_order_no IS NOT NULL
        ORDER BY gl.source_po_order_no, gl.source_po_order_date, gl.source_po_line_serial
    LOOP
        PERFORM 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = v_po_key.source_po_order_no AND order_date = v_po_key.source_po_order_date
          AND serial_no = v_po_key.source_po_line_serial
        FOR UPDATE;
    END LOOP;

    -- 4. Resolve currency codes needed for the exchange-rate bridge
    --    (rim_currencies.id UUID -> rim_currencies.currency_id TEXT code).
    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = p_company_id;
    SELECT currency_id INTO v_grn_ccy FROM rim_currencies WHERE id = v_header.grn_currency_id;

    v_voucher_lines := '[]'::jsonb;

    -- 5. Post stock (+ cost history) per line — sorted by product_id, the
    --    second half of the fixed lock-ordering rule — then accumulate this
    --    line's GL contributions.
    FOR v_line IN
        SELECT * FROM rid_grn_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = p_grn_no AND grn_date = p_grn_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT currency_id INTO v_product_ccy
        FROM rim_currencies WHERE id = (SELECT cost_currency_id FROM rim_products WHERE id = v_line.product_id);

        v_rate_to_base     := fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_base_ccy, p_grn_date);
        v_rate_to_specific := CASE WHEN v_product_ccy IS NULL THEN v_rate_to_base
                                    ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_product_ccy, p_grn_date) END;
        v_unit_cost_base     := v_line.rate * v_rate_to_base;
        v_unit_cost_specific := v_line.rate * v_rate_to_specific;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_grn_date, 'GRN', v_batch.base_qty,
                    v_unit_cost_base, v_unit_cost_specific,
                    v_batch.batch_no, v_batch.expiry_date, NULL,
                    'GRN', p_grn_no, p_grn_date, p_approved_by,
                    v_rate_to_base
                );
            END LOOP;
        ELSIF v_has_serials THEN
            -- One ledger row per unit — unifies serial tracking with the
            -- batch mechanism above instead of a separate audit-only table.
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'GRN' AND source_doc_no = p_grn_no AND source_doc_date = p_grn_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_grn_date, 'GRN', 1,
                    v_unit_cost_base, v_unit_cost_specific,
                    NULL, NULL, v_serial_row.serial_no,
                    'GRN', p_grn_no, p_grn_date, p_approved_by,
                    v_rate_to_base
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_grn_date, 'GRN', v_line.base_qty,
                v_unit_cost_base, v_unit_cost_specific,
                NULL, NULL, NULL,
                'GRN', p_grn_no, p_grn_date, p_approved_by,
                v_rate_to_base
            );
        END IF;

        -- GL: Stock Dr = net-of-tax item value + apportioned charge (see
        -- migration header comment for the full balance proof).
        v_taxable_amount := v_line.final_amount - v_line.tax_amount;
        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_stock_account, 'trans_nature', 'DR',
            'trans_amount', v_taxable_amount + v_line.charge_amount, 'trans_currency', v_base_ccy,
            'base_amount', v_taxable_amount + v_line.charge_amount, 'base_rate', 1,
            'local_amount', (v_taxable_amount + v_line.charge_amount) * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_taxable_amount + v_line.charge_amount, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        -- GL: Purchase Accrual Cr = tax-inclusive item value (never the
        -- supplier account directly, never with inv_bill_no — that
        -- linkage belongs to the future Purchase Invoice, not GRN).
        v_accrual_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'PURCHASE_ACCRUAL_ACCOUNT');
        IF v_accrual_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Purchase Accrual Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_accrual_account, 'trans_nature', 'CR',
            'trans_amount', v_line.final_amount, 'trans_currency', v_base_ccy,
            'base_amount', v_line.final_amount, 'base_rate', 1,
            'local_amount', v_line.final_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_line.final_amount, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        -- GL: Input Tax Dr, apportioned across the tax group's member taxes
        -- by their effective rate weight, each to its own gl_input_account_id.
        IF v_line.tax_group_id IS NOT NULL AND v_line.tax_amount <> 0 THEN
            SELECT coalesce(sum(fn_get_active_tax_rate(tgm.tax_id, p_grn_date)), 0) INTO v_rate_sum
            FROM rim_tax_group_members tgm
            WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id AND tgm.tax_group_id = v_line.tax_group_id;

            IF v_rate_sum > 0 THEN
                FOR v_tax_row IN
                    SELECT tgm.tax_id, t.gl_input_account_id, t.tax_code, t.tax_name,
                           fn_get_active_tax_rate(tgm.tax_id, p_grn_date) AS rate
                    FROM rim_tax_group_members tgm
                    JOIN rim_taxes t ON t.id = tgm.tax_id
                    WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id AND tgm.tax_group_id = v_line.tax_group_id
                LOOP
                    IF v_tax_row.gl_input_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Tax [%s] %s has no Input GL account configured.',
                                v_tax_row.tax_code, v_tax_row.tax_name);
                    END IF;
                    v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'DR',
                        'trans_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum, 'trans_currency', v_base_ccy,
                        'base_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum, 'base_rate', 1,
                        'local_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line.tax_amount * v_tax_row.rate / v_rate_sum, 'party_currency', v_base_ccy, 'party_rate', 1
                    ));
                END LOOP;
            END IF;
        END IF;

        -- 6. Roll qty_received forward onto the referenced PO line, if any.
        IF v_line.source_po_order_no IS NOT NULL THEN
            UPDATE rid_purchase_order_lines SET
                qty_received = qty_received + v_line.base_qty,
                updated_at = now(), updated_by = p_approved_by
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = v_line.source_po_order_no AND order_date = v_line.source_po_order_date
              AND serial_no = v_line.source_po_line_serial;
        END IF;
    END LOOP;

    -- 7. Charges: Cr the charge's own account (tax-inclusive), Dr its tax
    --    (if taxable) to that tax's gl_input_account_id — the line-level
    --    charge_amount above already captured the NET charge inside Stock Dr.
    FOR v_charge IN
        SELECT * FROM rid_grn_charge_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = p_grn_no AND grn_date = p_grn_date AND is_deleted = false
    LOOP
        IF v_charge.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
        END IF;
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_charge.gl_account_id, 'trans_nature', 'CR',
            'trans_amount', v_charge.amount + v_charge.tax_amount, 'trans_currency', v_base_ccy,
            'base_amount', v_charge.amount + v_charge.tax_amount, 'base_rate', 1,
            'local_amount', (v_charge.amount + v_charge.tax_amount) * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_charge.amount + v_charge.tax_amount, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        IF v_charge.is_taxable AND v_charge.tax_id IS NOT NULL AND v_charge.tax_amount <> 0 THEN
            SELECT gl_input_account_id, '[' || tax_code || '] ' || tax_name
              INTO v_charge_tax_account, v_charge_tax_label
              FROM rim_taxes WHERE id = v_charge.tax_id;
            IF v_charge_tax_account IS NULL THEN
                RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                    USING DETAIL = format('Charge tax %s has no Input GL account configured.', v_charge_tax_label);
            END IF;
            v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge_tax_account, 'trans_nature', 'DR',
                'trans_amount', v_charge.tax_amount, 'trans_currency', v_base_ccy,
                'base_amount', v_charge.tax_amount, 'base_rate', 1,
                'local_amount', v_charge.tax_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                'party_amount', v_charge.tax_amount, 'party_currency', v_base_ccy, 'party_rate', 1
            ));
        END IF;
    END LOOP;

    -- 8. One fn_post_voucher call for the whole GRN, not per line.
    SELECT * INTO v_voucher_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'JV', p_grn_date,
        v_voucher_lines, 'GRN', p_grn_no, p_grn_date, p_approved_by
    );

    -- 9. Recompute status of every PO referenced by this GRN, re-reading ALL
    --    of that PO's lines (not just the ones this GRN touched) for a
    --    consistent snapshot.
    FOR v_po_line IN
        SELECT DISTINCT source_po_order_no, source_po_order_date
        FROM rid_grn_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = p_grn_no AND grn_date = p_grn_date
          AND source_po_order_no IS NOT NULL
    LOOP
        SELECT coalesce(sum(base_qty), 0), coalesce(sum(qty_received), 0)
        INTO v_po_total_ordered, v_po_total_received
        FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = v_po_line.source_po_order_no AND order_date = v_po_line.source_po_order_date
          AND is_deleted = false;

        v_po_any_short := v_po_total_received < v_po_total_ordered;

        UPDATE rih_purchase_orders SET
            status = CASE WHEN v_po_any_short THEN 'PARTIALLY_RECEIVED' ELSE 'CLOSED' END,
            closed_by = CASE WHEN v_po_any_short THEN closed_by ELSE p_approved_by END,
            closed_at = CASE WHEN v_po_any_short THEN closed_at ELSE now() END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = v_po_line.source_po_order_no AND order_date = v_po_line.source_po_order_date
          AND status IN ('APPROVED', 'PARTIALLY_RECEIVED');
    END LOOP;

    -- 10. Mark GRN approved, store the GL traceability.
    UPDATE rih_grn_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_voucher_result.trans_no,
        posted_voucher_date = v_voucher_result.trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND grn_no = p_grn_no AND grn_date = p_grn_date;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_grn(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
