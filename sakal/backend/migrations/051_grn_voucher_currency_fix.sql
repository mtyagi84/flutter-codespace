-- ============================================================
-- Migration 051: fn_approve_grn — post the GRN's own transaction currency
-- ============================================================
-- Bug reported live: a GRN raised in EUR (base=USD) posted its finance
-- lines with trans_currency='USD' — the raw EUR-denominated line amounts
-- were being labeled as if they were already in base currency, with
-- base_rate hardcoded to 1 (no conversion at all) and only local_amount
-- was ever correctly computed (× rate_to_local). party_amount/
-- party_currency had the identical defect — always base currency, never
-- each account's own ledger currency.
--
-- Fix, matching the existing Payment/Receipt Voucher convention (rid_
-- finance_lines' own column comment: "Transaction currency = currency of
-- Cash/Bank account (locked from line 1)" — one shared trans_currency
-- for every line of a voucher, not silently swapped to base):
--   trans_currency = the GRN's own currency (v_grn_ccy) — not v_base_ccy.
--   base_amount     = trans_amount * v_header.rate_to_base (was × 1)
--   base_rate       = v_header.rate_to_base                (was hardcoded 1)
--   local_amount/local_rate — unchanged, this part was already correct.
--   party_amount/party_currency/party_rate — resolved PER ACCOUNT: if that
--     account's own ledger currency (rim_accounts.account_currency_id)
--     equals the GRN's currency, party_rate=1 (same-currency shortcut,
--     matching the project's existing multicurrency convention); otherwise
--     a real fn_get_exchange_rate lookup from GRN currency to that
--     account's currency.
--
-- New migration, not an edit to 037/046-050 — any may already be deployed.
-- ============================================================

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
    v_has_batches                                        BOOLEAN;
    v_has_serials                                          BOOLEAN;
    v_voucher_lines                                        JSONB;
    v_voucher_result                                        RECORD;
    v_po_total_ordered                                        NUMERIC;
    v_po_total_received                                         NUMERIC;
    v_po_any_short                                                BOOLEAN;
    v_trans_amt                                                    NUMERIC;
    v_account_ccy                                                   TEXT;
    v_party_rate                                                     NUMERIC;
    v_party_ccy                                                       TEXT;
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

        -- GL: Stock Dr = net-of-VAT item value + apportioned charge, in the
        -- GRN's OWN transaction currency — converted to base/local/party the
        -- same way a Payment/Receipt Voucher line would be (see migration
        -- header). VAT is a recoverable asset, never part of inventory cost.
        v_taxable_amount := v_line.final_amount - v_line.tax_amount;
        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_trans_amt := v_taxable_amount + v_line.charge_amount;
        SELECT c.currency_id INTO v_account_ccy
        FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
        WHERE a.id = v_stock_account;
        IF v_account_ccy IS NULL OR v_account_ccy = v_grn_ccy THEN
            v_party_rate := 1; v_party_ccy := v_grn_ccy;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_account_ccy, p_grn_date);
            v_party_ccy := v_account_ccy;
        END IF;

        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_stock_account, 'trans_nature', 'DR',
            'trans_amount', v_trans_amt, 'trans_currency', v_grn_ccy,
            'base_amount', v_trans_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_trans_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_trans_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'source_line_type', 'STOCK', 'source_line_no', v_line.serial_no
        ));

        -- GL: Purchase Accrual Cr = tax-EXCLUSIVE item value — a provisional/
        -- clearing liability (never the supplier account directly, never
        -- with inv_bill_no — that linkage belongs to the future Purchase
        -- Invoice, not GRN). VAT is deliberately NOT booked here: it isn't a
        -- real input-tax credit until the actual supplier tax invoice
        -- exists, so it's recognized (together with the real supplier
        -- liability) only when the future Purchase Invoice clears this same
        -- account — see migration 050's header for the full worked example.
        v_accrual_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'PURCHASE_ACCRUAL_ACCOUNT');
        IF v_accrual_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Purchase Accrual Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_trans_amt := v_taxable_amount;
        SELECT c.currency_id INTO v_account_ccy
        FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
        WHERE a.id = v_accrual_account;
        IF v_account_ccy IS NULL OR v_account_ccy = v_grn_ccy THEN
            v_party_rate := 1; v_party_ccy := v_grn_ccy;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_account_ccy, p_grn_date);
            v_party_ccy := v_account_ccy;
        END IF;

        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_accrual_account, 'trans_nature', 'CR',
            'trans_amount', v_trans_amt, 'trans_currency', v_grn_ccy,
            'base_amount', v_trans_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_trans_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_trans_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'source_line_type', 'ACCRUAL', 'source_line_no', v_line.serial_no
        ));

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

    -- 7. Charges: Cr (ADD) or Dr (DEDUCT) the charge's own provisional/
    --    clearing account — tax-EXCLUSIVE amount only, same VAT-deferral
    --    rationale as the item lines above, in the GRN's OWN transaction
    --    currency (same conversion treatment as the item lines).
    FOR v_charge IN
        SELECT * FROM rid_grn_charge_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = p_grn_no AND grn_date = p_grn_date AND is_deleted = false
    LOOP
        IF v_charge.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
        END IF;

        v_trans_amt := v_charge.amount;
        SELECT c.currency_id INTO v_account_ccy
        FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
        WHERE a.id = v_charge.gl_account_id;
        IF v_account_ccy IS NULL OR v_account_ccy = v_grn_ccy THEN
            v_party_rate := 1; v_party_ccy := v_grn_ccy;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_account_ccy, p_grn_date);
            v_party_ccy := v_account_ccy;
        END IF;

        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_charge.gl_account_id,
            'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
            'trans_amount', v_trans_amt, 'trans_currency', v_grn_ccy,
            'base_amount', v_trans_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_trans_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_trans_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'source_line_type', 'CHARGE', 'source_line_no', v_charge.serial_no
        ));
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
