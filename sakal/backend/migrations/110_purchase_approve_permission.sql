-- ============================================================
-- 110_purchase_approve_permission.sql
--
-- Batch 1 of extending fn_check_approve_permission (built in migration
-- 108, already covering all of Finance) across the rest of the app.
-- None of Purchase's 4 approve functions currently re-check approve
-- permission server-side — only the Flutter UI's canApprove gates them.
-- Same fix, same helper, same feature_code mapping confirmed against
-- fn_seed_client_modules.sql:
--   fn_approve_purchase_order    -> PR-PO
--   fn_approve_grn                -> PR-GRN
--   fn_approve_purchase_invoice   -> PR-INV
--   fn_approve_purchase_return    -> PR-RET
--
-- Every function body below is reproduced verbatim from its current live
-- definition (041/080/059/080 respectively) with exactly one new
-- PERFORM fn_check_approve_permission(...) line inserted immediately
-- after the existing status-check block, before period/backdate checks.
-- ============================================================

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_purchase_order — verbatim from 041_po_approve_period_backdate_check.sql
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_purchase_order(
    p_client_id   UUID,
    p_company_id  UUID,
    p_order_no    TEXT,
    p_order_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_purchase_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_header FROM rih_purchase_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Order % dated % not found', p_order_no, p_order_date;
    END IF;

    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Purchase Order % is % and cannot be approved again', p_order_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'PR-PO');

    -- NEW: period/backdate checks — closes the gap where a PO could be
    -- approved with a future-dated or period-locked order_date with no
    -- validation at all, unlike every other approve/post function.
    PERFORM fn_check_period_open(p_company_id, p_order_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'PURCHASE_ORDER', p_order_date);

    -- At least one line, and every line must be complete (qty/rate/UOM) —
    -- added in migration 040, unchanged here.
    IF NOT EXISTS (
        SELECT 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
    ) THEN
        RAISE EXCEPTION 'PO_NO_LINES'
            USING DETAIL = 'A Purchase Order needs at least one item line before it can be approved.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
          AND (base_qty <= 0 OR rate <= 0 OR uom_id IS NULL)
    ) THEN
        RAISE EXCEPTION 'PO_LINE_INCOMPLETE'
            USING DETAIL = 'Every line needs a quantity greater than zero, a rate greater than zero, and a UOM selected before the Purchase Order can be approved.';
    END IF;

    UPDATE rih_purchase_orders SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(),
        updated_by  = p_approved_by
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date;
END;
$$;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_grn — verbatim from 080_manufacturing_date.sql
-- ════════════════════════════════════════════════════════════════════
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
    v_local_ccy                      TEXT;
    v_grn_ccy                         TEXT;
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'PR-GRN');

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_grn_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'GRN', p_grn_date);

    -- 3. Lock referenced PO lines FOR UPDATE, one at a time in a fixed sort
    --    order, BEFORE any product-row lock below — fixed inter-type
    --    ordering rule from migration 036.
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
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
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

        -- FIX (057): this IS the GRN-currency-to-base-currency conversion
        -- the user already confirmed on the header — reuse it, don't
        -- re-derive it from a live rate lookup that might not exist, or
        -- might silently disagree with what the ledger below posts.
        v_rate_to_base := v_header.rate_to_base;

        -- Reuse the header's own confirmed rate wherever the product's cost
        -- currency matches a currency that already has one on this document
        -- (GRN/base/local) — same shortcut as party_rate (052). Only a
        -- genuine third currency, with no rate field on the document at
        -- all, needs a real fn_get_exchange_rate lookup.
        IF v_product_ccy IS NULL THEN
            v_rate_to_specific := v_rate_to_base;
        ELSIF v_product_ccy = v_grn_ccy THEN
            v_rate_to_specific := 1;
        ELSIF v_product_ccy = v_base_ccy THEN
            v_rate_to_specific := v_header.rate_to_base;
        ELSIF v_product_ccy = v_local_ccy THEN
            v_rate_to_specific := v_header.rate_to_local;
        ELSE
            v_rate_to_specific := fn_get_exchange_rate(p_company_id, v_header.location_id, v_grn_ccy, v_product_ccy, p_grn_date);
        END IF;

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
                    v_rate_to_base, p_manufacturing_date => v_batch.manufacturing_date
                );
            END LOOP;
        ELSIF v_has_serials THEN
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
        -- GRN's OWN transaction currency.
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
        ELSIF v_account_ccy = v_base_ccy THEN
            v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
        ELSIF v_account_ccy = v_local_ccy THEN
            v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
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

        -- GL: Purchase Accrual Cr = tax-EXCLUSIVE item value.
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
        ELSIF v_account_ccy = v_base_ccy THEN
            v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
        ELSIF v_account_ccy = v_local_ccy THEN
            v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
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
    --    clearing account — tax-EXCLUSIVE amount only.
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
        ELSIF v_account_ccy = v_base_ccy THEN
            v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
        ELSIF v_account_ccy = v_local_ccy THEN
            v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
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
    --    of that PO's lines for a consistent snapshot.
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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_purchase_invoice — verbatim from 059_purchase_invoice_exchange_voucher_split.sql
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_purchase_invoice(
    p_client_id   UUID,
    p_company_id  UUID,
    p_invoice_no  TEXT,
    p_invoice_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header           rih_purchase_invoices%ROWTYPE;
    v_grn              RECORD;
    v_grn_line         RECORD;
    v_tax_row          RECORD;
    v_invoice_ccy      TEXT;
    v_base_ccy         TEXT;
    v_local_ccy        TEXT;
    v_account_ccy      TEXT;
    v_party_rate       NUMERIC;
    v_party_ccy        TEXT;
    v_anchor_product_id UUID;
    v_total_est_tax    NUMERIC := 0;
    v_line_share       NUMERIC;
    v_rate_sum         NUMERIC;
    v_voucher_lines    JSONB := '[]'::jsonb;
    v_exc_lines        JSONB := '[]'::jsonb;
    v_dr_total         NUMERIC := 0;
    v_fx_account       UUID;
    v_supplier_base_rate NUMERIC;
    v_supplier_true_base NUMERIC;
    v_restate_diff     NUMERIC;
    v_voucher_result   RECORD;
    v_exc_result       RECORD;
    v_supplier_trans_amt NUMERIC;
    v_grn_count        INTEGER := 0;
    v_tax_account_ccy  TEXT;
    v_tax_party_rate   NUMERIC;
    v_tax_party_ccy    TEXT;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_purchase_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Bill % dated % not found', p_invoice_no, p_invoice_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Purchase Bill % is % and cannot be approved again', p_invoice_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'PR-INV');

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_invoice_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'PURCHASE_INVOICE', p_invoice_date);

    -- 3. Lock every linked GRN, one row per statement in a fixed sort order
    --    (same rule as fn_save_purchase_invoice / fn_approve_grn).
    FOR v_grn IN
        SELECT * FROM rih_grn_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND billed_invoice_no = p_invoice_no AND billed_invoice_date = p_invoice_date
          AND is_deleted = false
        ORDER BY grn_no, grn_date
    LOOP
        PERFORM 1 FROM rih_grn_headers WHERE id = v_grn.id FOR UPDATE;
        v_grn_count := v_grn_count + 1;
    END LOOP;

    IF v_grn_count = 0 THEN
        RAISE EXCEPTION 'No GRNs are linked to Purchase Bill %.', p_invoice_no;
    END IF;

    SELECT currency_id INTO v_invoice_ccy FROM rim_currencies WHERE id = v_header.invoice_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- 4. DR Purchase Accrual — replicate each linked GRN's own ACCRUAL lines
    --    exactly (account + base_amount), never a lump sum: PURCHASE_ACCRUAL_
    --    ACCOUNT can resolve differently per product/category, so only
    --    replaying the exact original lines guarantees an exact clearing.
    FOR v_grn_line IN
        SELECT l.account_id, l.trans_amount, l.trans_currency, l.base_amount, l.base_rate,
               l.local_amount, l.local_rate, l.party_amount, l.party_currency, l.party_rate
        FROM rih_grn_headers g
        JOIN rih_finance_headers h
          ON h.client_id = g.client_id AND h.company_id = g.company_id
         AND h.source_doc_type = 'GRN' AND h.source_doc_no = g.grn_no AND h.source_doc_date = g.grn_date
        JOIN rid_finance_lines l
          ON l.client_id = h.client_id AND l.company_id = h.company_id
         AND l.location_id = h.location_id AND l.trans_no = h.trans_no
         AND l.source_line_type = 'ACCRUAL' AND l.is_deleted = false
        WHERE g.client_id = p_client_id AND g.company_id = p_company_id
          AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
          AND g.is_deleted = false
    LOOP
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_grn_line.account_id, 'trans_nature', 'DR',
            'trans_amount', v_grn_line.trans_amount, 'trans_currency', v_grn_line.trans_currency,
            'base_amount', v_grn_line.base_amount, 'base_rate', v_grn_line.base_rate,
            'local_amount', v_grn_line.local_amount, 'local_rate', v_grn_line.local_rate,
            'party_amount', v_grn_line.party_amount, 'party_currency', v_grn_line.party_currency, 'party_rate', v_grn_line.party_rate,
            'source_line_type', 'ACCRUAL_CLEARING'
        ));
        v_dr_total := v_dr_total + v_grn_line.base_amount;
    END LOOP;

    -- 5. DR Input VAT — apportion the REAL lump-sum tax_amount across the
    --    linked GRNs' own lines by each line's share of the ESTIMATED tax
    --    that was never posted (rid_grn_lines.tax_amount), then within each
    --    line across its tax_group's member taxes by rate weight — same
    --    weighting fn_approve_grn used before VAT deferral (049), now
    --    applied to the real figure instead of the estimate.
    --
    -- Anchor product for the Exchange Gain/Loss resolution below — decoupled
    -- from the tax-only query beneath it (not filtered to taxed lines), so a
    -- bill whose GRN lines are entirely VAT-exempt still has an anchor.
    SELECT gl.product_id INTO v_anchor_product_id
    FROM rih_grn_headers g
    JOIN rid_grn_lines gl
      ON gl.client_id = g.client_id AND gl.company_id = g.company_id
     AND gl.grn_no = g.grn_no AND gl.grn_date = g.grn_date
     AND gl.is_deleted = false
    WHERE g.client_id = p_client_id AND g.company_id = p_company_id
      AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
      AND g.is_deleted = false
    LIMIT 1;

    SELECT coalesce(sum(gl.tax_amount), 0) INTO v_total_est_tax
    FROM rih_grn_headers g
    JOIN rid_grn_lines gl
      ON gl.client_id = g.client_id AND gl.company_id = g.company_id
     AND gl.grn_no = g.grn_no AND gl.grn_date = g.grn_date
     AND gl.is_deleted = false AND gl.tax_group_id IS NOT NULL AND gl.tax_amount <> 0
    WHERE g.client_id = p_client_id AND g.company_id = p_company_id
      AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
      AND g.is_deleted = false;

    IF v_header.tax_amount <> 0 THEN
        IF v_total_est_tax = 0 THEN
            RAISE EXCEPTION 'NO_TAXABLE_GRN_LINES'
                USING DETAIL = 'None of the linked GRN lines had a tax group / estimated tax to apportion the real VAT against.';
        END IF;

        FOR v_grn_line IN
            SELECT gl.tax_group_id, gl.tax_amount AS est_tax
            FROM rih_grn_headers g
            JOIN rid_grn_lines gl
              ON gl.client_id = g.client_id AND gl.company_id = g.company_id
             AND gl.grn_no = g.grn_no AND gl.grn_date = g.grn_date
             AND gl.is_deleted = false AND gl.tax_group_id IS NOT NULL AND gl.tax_amount <> 0
            WHERE g.client_id = p_client_id AND g.company_id = p_company_id
              AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
              AND g.is_deleted = false
        LOOP
            v_line_share := v_header.tax_amount * (v_grn_line.est_tax / v_total_est_tax);

            SELECT coalesce(sum(fn_get_active_tax_rate(tgm.tax_id, p_invoice_date)), 0) INTO v_rate_sum
            FROM rim_tax_group_members tgm
            WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
              AND tgm.tax_group_id = v_grn_line.tax_group_id;

            IF v_rate_sum > 0 THEN
                FOR v_tax_row IN
                    SELECT tgm.tax_id, t.gl_input_account_id, t.tax_code, t.tax_name,
                           fn_get_active_tax_rate(tgm.tax_id, p_invoice_date) AS rate
                    FROM rim_tax_group_members tgm
                    JOIN rim_taxes t ON t.id = tgm.tax_id
                    WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                      AND tgm.tax_group_id = v_grn_line.tax_group_id
                LOOP
                    IF v_tax_row.gl_input_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Tax [%s] %s has no Input GL account configured.',
                                v_tax_row.tax_code, v_tax_row.tax_name);
                    END IF;

                    -- Same account-currency shortcut as every other line in
                    -- this function / GRN's own posting — never a bare
                    -- trans-currency assumption.
                    SELECT c.currency_id INTO v_tax_account_ccy
                    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
                    WHERE a.id = v_tax_row.gl_input_account_id;
                    IF v_tax_account_ccy IS NULL OR v_tax_account_ccy = v_invoice_ccy THEN
                        v_tax_party_rate := 1; v_tax_party_ccy := v_invoice_ccy;
                    ELSIF v_tax_account_ccy = v_base_ccy THEN
                        v_tax_party_rate := v_header.rate_to_base; v_tax_party_ccy := v_base_ccy;
                    ELSIF v_tax_account_ccy = v_local_ccy THEN
                        v_tax_party_rate := v_header.rate_to_local; v_tax_party_ccy := v_local_ccy;
                    ELSE
                        v_tax_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_invoice_ccy, v_tax_account_ccy, p_invoice_date);
                        v_tax_party_ccy := v_tax_account_ccy;
                    END IF;

                    v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'DR',
                        'trans_amount', v_line_share * v_tax_row.rate / v_rate_sum, 'trans_currency', v_invoice_ccy,
                        'base_amount', v_line_share * v_tax_row.rate / v_rate_sum * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_line_share * v_tax_row.rate / v_rate_sum * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line_share * v_tax_row.rate / v_rate_sum * v_tax_party_rate, 'party_currency', v_tax_party_ccy, 'party_rate', v_tax_party_rate,
                        'source_line_type', 'INPUT_VAT'
                    ));
                    v_dr_total := v_dr_total + (v_line_share * v_tax_row.rate / v_rate_sum * v_header.rate_to_base);
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    -- 6. CR Supplier Account — this line's base_amount is FORCED to exactly
    --    balance the PUR voucher on its own (= v_dr_total, the Accrual+VAT
    --    total) rather than independently computed from the bill's own
    --    rate. Its trans_amount/party_amount/party_currency are UNCHANGED —
    --    still the real invoice amount and the real party-ledger amount;
    --    only base_amount/base_rate are a derived, balance-forcing figure
    --    for THIS voucher. Whatever gap this leaves vs. the TRUE payable
    --    (at the bill's own confirmed rate) is reconciled separately below
    --    via the EXC voucher (059) — every voucher posted through
    --    fn_post_voucher must balance on its own, so the PUR voucher cannot
    --    carry an FX-driven imbalance itself.
    v_supplier_trans_amt := v_header.taxable_amount + v_header.tax_amount;
    SELECT c.currency_id INTO v_account_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.supplier_id;
    IF v_account_ccy IS NULL OR v_account_ccy = v_invoice_ccy THEN
        v_party_rate := 1; v_party_ccy := v_invoice_ccy;
    ELSIF v_account_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_account_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_invoice_ccy, v_account_ccy, p_invoice_date);
        v_party_ccy := v_account_ccy;
    END IF;

    v_supplier_base_rate := v_dr_total / nullif(v_supplier_trans_amt, 0);

    v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_header.supplier_id, 'trans_nature', 'CR',
        'trans_amount', v_supplier_trans_amt, 'trans_currency', v_invoice_ccy,
        'base_amount', v_dr_total, 'base_rate', coalesce(v_supplier_base_rate, v_header.rate_to_base),
        'local_amount', v_supplier_trans_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_supplier_trans_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', v_header.supplier_invoice_no, 'inv_bill_date', v_header.supplier_invoice_date,
        'source_line_type', 'SUPPLIER'
    ));

    -- 7. One fn_post_voucher call for the PUR voucher — always balanced by
    --    construction now (Supplier's base_amount was forced to v_dr_total
    --    above), so this can never raise VOUCHER_POSTING_IMBALANCE.
    SELECT * INTO v_voucher_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'PUR', p_invoice_date,
        v_voucher_lines, 'PURCHASE_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
    );

    -- 8. Exchange restatement — the TRUE payable at the bill's own
    --    confirmed rate vs. what the PUR voucher's forced-balance figure
    --    already credited. Posted as its OWN separate EXC voucher, both
    --    lines natively in the company's base currency (trans_currency =
    --    base_ccy here IS this voucher's real transaction currency — no
    --    back-derivation needed, unlike the invoice-currency lines above).
    --    No inv_bill_no on the Supplier line: this is a pure GL valuation
    --    adjustment, invisible to the party-currency pending-bills view —
    --    correct, since the party is still owed exactly the same amount in
    --    their own currency regardless of how the base-currency translation
    --    moves between GRN time and Bill time.
    v_supplier_true_base := v_supplier_trans_amt * v_header.rate_to_base;
    v_restate_diff := v_supplier_true_base - v_dr_total;

    IF abs(v_restate_diff) > 0.0001 THEN
        v_fx_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_anchor_product_id, 'EXCHANGE_GAIN_LOSS_ACCOUNT');
        IF v_fx_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = 'No Exchange Gain/Loss Account configured.';
        END IF;

        -- restate_diff > 0: true payable exceeds what PUR credited — a
        -- LOSS (DR Exchange Loss, CR Supplier to top up the payable).
        -- restate_diff < 0: true payable is less — a GAIN (CR Exchange
        -- Gain, DR Supplier to bring the payable back down).
        v_exc_lines := jsonb_build_array(
            jsonb_build_object(
                'account_id', v_fx_account,
                'trans_nature', CASE WHEN v_restate_diff > 0 THEN 'DR' ELSE 'CR' END,
                'trans_amount', abs(v_restate_diff), 'trans_currency', v_base_ccy,
                'base_amount', abs(v_restate_diff), 'base_rate', 1,
                'local_amount', abs(v_restate_diff) * (v_header.rate_to_local / v_header.rate_to_base),
                'local_rate', v_header.rate_to_local / v_header.rate_to_base,
                'party_amount', abs(v_restate_diff), 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'EXCHANGE_DIFF'
            ),
            jsonb_build_object(
                'account_id', v_header.supplier_id,
                'trans_nature', CASE WHEN v_restate_diff > 0 THEN 'CR' ELSE 'DR' END,
                'trans_amount', abs(v_restate_diff), 'trans_currency', v_base_ccy,
                'base_amount', abs(v_restate_diff), 'base_rate', 1,
                'local_amount', abs(v_restate_diff) * (v_header.rate_to_local / v_header.rate_to_base),
                'local_rate', v_header.rate_to_local / v_header.rate_to_base,
                'party_amount', abs(v_restate_diff), 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'EXCHANGE_DIFF'
            )
        );

        SELECT * INTO v_exc_result FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'EXC', p_invoice_date,
            v_exc_lines, 'PURCHASE_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
        );
    END IF;

    UPDATE rih_purchase_invoices SET exchange_diff_base = coalesce(v_restate_diff, 0) WHERE id = v_header.id;

    -- 9. Mark the bill approved, store GL traceability (PUR voucher is the
    --    primary reference; the EXC voucher, if any, is discoverable via
    --    source_doc_type/source_doc_no, which both vouchers share).
    UPDATE rih_purchase_invoices SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_voucher_result.trans_no,
        posted_voucher_date = v_voucher_result.trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_purchase_return — verbatim from 080_manufacturing_date.sql
-- (6-param signature — extra p_reopen_po BOOLEAN before p_approved_by —
-- preserved exactly)
-- ════════════════════════════════════════════════════════════════════
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'PR-RET');

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
                        'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by,
                        p_manufacturing_date => v_batch.manufacturing_date
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
