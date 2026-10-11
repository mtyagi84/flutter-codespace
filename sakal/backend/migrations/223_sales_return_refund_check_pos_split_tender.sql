-- ============================================================
-- Migration 223: fn_approve_sales_return — refund-limit check now
-- recognizes multi-method (split) POS tender, not just the cash leg
-- ============================================================
-- Real bug reported live 2026-10-11: a POS cash sale paid via 3 split
-- tender methods (e.g. Cash 20,000 + Mobile Money + Gift Card, grand
-- total 41,207.62 CDF) could never be fully refunded — Sales Return's
-- own Refund Value auto-filled the full invoice total, but Approve
-- always failed with REFUND_EXCEEDS_COLLECTED ("...exceeds what remains
-- collected...local 20000.0000...remaining"), even though the full
-- amount genuinely was collected, across methods.
--
-- Root cause: `rih_sales_invoices.collected_amount_local` is
-- DELIBERATELY set to the CASH-ONLY portion of a split-tender POS sale
-- (see pos_new_sale_screen.dart's own `_cashTenderTotalLocal` / the
-- comment above it) — that narrowing is correct and must stay, because
-- it's what the shift-close cash-drawer reconciliation formula
-- (fn_close_pos_shift) needs: only physical cash affects the drawer
-- count, a card/mobile-money/voucher/gift-card/store-credit leg never
-- does. This function (fn_approve_sales_return) was reading that SAME
-- column to mean something different — "the total amount the customer
-- actually paid on this invoice" — which is only true when there is no
-- split tender. The two meanings silently coincide for every invoice
-- type this schema had until POS split tender (migration 211/218)
-- introduced a case where they diverge.
--
-- Fix: when the invoice has rid_pos_tender_lines rows (only ever
-- written for a split-tender POS sale — see _saveTenderLines, called
-- only when `_saleType == 'CASH' && _splitTender`), the "what was
-- collected" figure used for the refund cap is the sum of EVERY tender
-- line's own `amount_local` (cash + non-cash), not just
-- collected_amount_local. A non-split invoice (POS or back-office) has
-- zero tender-line rows, so GREATEST(...) falls back to
-- collected_amount_local unchanged — zero behavior change for every
-- existing invoice type.
--
-- Known, deliberately out-of-scope gap this does NOT fix: the actual
-- cash refund below (step 8) always pays out of the LOCAL cash account
-- (fn_quick_cash_account_local) regardless of how the original sale was
-- collected — refunding a split-tender sale in full still moves the
-- WHOLE amount out of the physical cash drawer, even the portion
-- originally collected via card/mobile money/gift card. Reversing a
-- non-cash tender's own settlement on return (mirroring
-- fn_settle_pos_non_cash_tenders at sale time) is a separate, real
-- feature not yet built — flagged here, not silently left unaddressed.
-- Full function body reproduced verbatim from migration 187 (the
-- latest definition) per this project's own "grep every migration for
-- the current signature" rule — only step 8's v_remaining_local
-- calculation changes.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_approve_sales_return(
    p_client_id   UUID,
    p_company_id  UUID,
    p_return_no   TEXT,
    p_return_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_sales_return_headers%ROWTYPE;
    v_invoice            rih_sales_invoices%ROWTYPE;
    v_return_ccy         TEXT;
    v_base_ccy           TEXT;
    v_local_ccy          TEXT;
    v_line               RECORD;
    v_tax_line           RECORD;
    v_charge_row         rid_sales_return_charges%ROWTYPE;
    v_charge_amount      NUMERIC;
    v_charge_tax_account UUID;
    v_charge_dir         TEXT;
    v_returns_account    UUID;
    v_stock_account      UUID;
    v_cos_account        UUID;
    v_customer_ccy       TEXT;
    v_party_rate         NUMERIC;
    v_party_ccy          TEXT;
    v_crn_lines          JSONB := '[]'::jsonb;
    v_cos_lines          JSONB := '[]'::jsonb;
    v_crn_result         RECORD;
    v_cos_voucher_no     TEXT;
    v_cos_voucher_date   DATE;
    v_already_returned   NUMERIC;
    v_invoice_line_qty   NUMERIC;
    v_customer_cr_total  NUMERIC := 0;
    v_batch              rid_transaction_line_batches%ROWTYPE;
    v_serial_row         rid_transaction_line_serials%ROWTYPE;
    v_has_batches        BOOLEAN;
    v_has_serials        BOOLEAN;
    v_unit_cost          NUMERIC;
    v_unit_cost_specific NUMERIC;
    v_line_cost_total    NUMERIC;
    v_base_to_local_rate NUMERIC;
    v_local_to_base_rate NUMERIC;
    v_already_refunded_local NUMERIC;
    v_already_refunded_base  NUMERIC;
    v_remaining_local    NUMERIC;
    v_remaining_base     NUMERIC;
    v_cash_account_local UUID;
    v_cash_account_base  UUID;
    v_receipt_party_rate NUMERIC;
    v_receipt_party_ccy  TEXT;
    v_receipt_header     JSONB;
    v_receipt_lines      JSONB;
    v_receipt_no         TEXT;
    v_stock_was_dispatched BOOLEAN;
    v_pos_tender_total_local NUMERIC;  -- NEW (223)
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_sales_return_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND return_no = p_return_no AND return_date = p_return_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Return % dated % not found', p_return_no, p_return_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Return % is % and cannot be approved again', p_return_no, v_header.status;
    END IF;

    -- Server-side re-check of approve permission, resolved from the JWT
    -- (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-RET');

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_return_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_RETURN', p_return_date);

    -- 3. Lock the source invoice
    SELECT * INTO v_invoice FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % not found', v_header.invoice_no;
    END IF;

    SELECT currency_id INTO v_return_ccy FROM rim_currencies WHERE id = v_header.return_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- Customer's own currency shortcut — same idiom fn_approve_sales_invoice
    -- uses for its Customer DR line, reused here for the Customer CR line.
    SELECT c.currency_id INTO v_customer_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.customer_id;
    IF v_customer_ccy IS NULL OR v_customer_ccy = v_return_ccy THEN
        v_party_rate := 1; v_party_ccy := v_return_ccy;
    ELSIF v_customer_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_customer_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_return_ccy, v_customer_ccy, p_return_date);
        v_party_ccy := v_customer_ccy;
    END IF;

    -- 4. Per-line: cap check + Sales-Returns-contra DR + tax DR (reversed
    --    from the invoice's own CR — each line's own stored figures are
    --    used directly, no header-total apportionment needed, see this
    --    migration's header comment for why).
    FOR v_line IN
        SELECT * FROM rid_sales_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT base_qty INTO v_invoice_line_qty
        FROM rid_sales_invoice_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND serial_no = v_line.invoice_line_serial;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'INVOICE_LINE_NOT_FOUND'
                USING DETAIL = format('Invoice %s has no line %s.', v_header.invoice_no, v_line.invoice_line_serial);
        END IF;

        -- Cumulative cap: every OTHER already-APPROVED Sales Return
        -- against this same invoice line (this return itself is still
        -- DRAFT during this check, naturally excluded) — a line can be
        -- partially returned across several separate Sales Return
        -- documents over time.
        SELECT coalesce(sum(rl.base_qty), 0) INTO v_already_returned
        FROM rid_sales_return_lines rl
        JOIN rih_sales_return_headers rh
          ON rh.client_id = rl.client_id AND rh.company_id = rl.company_id
         AND rh.return_no = rl.return_no AND rh.return_date = rl.return_date
        WHERE rl.client_id = p_client_id AND rl.company_id = p_company_id
          AND rh.invoice_no = v_header.invoice_no AND rh.invoice_date = v_header.invoice_date
          AND rl.invoice_line_serial = v_line.invoice_line_serial
          AND rl.is_deleted = false AND rh.status = 'APPROVED';

        IF v_already_returned + v_line.base_qty > v_invoice_line_qty THEN
            RAISE EXCEPTION 'RETURN_QTY_EXCEEDS_INVOICED'
                USING DETAIL = format(
                    'Invoice %s line %s: already returned %s of %s invoiced, this return adds %s more.',
                    v_header.invoice_no, v_line.invoice_line_serial,
                    v_already_returned, v_invoice_line_qty, v_line.base_qty);
        END IF;

        v_returns_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'SALES_RETURNS_ACCOUNT');
        IF v_returns_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Sales Returns Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_returns_account, 'trans_nature', 'DR',
            'trans_amount', v_line.final_amount - v_line.tax_amount, 'trans_currency', v_return_ccy,
            'base_amount', (v_line.final_amount - v_line.tax_amount) * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', (v_line.final_amount - v_line.tax_amount) * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_line.final_amount - v_line.tax_amount, 'party_currency', v_return_ccy, 'party_rate', 1,
            'source_line_type', 'SALES_RETURN', 'source_line_no', v_line.serial_no
        ));
        v_customer_cr_total := v_customer_cr_total + v_line.final_amount;

        IF v_line.tax_amount > 0 THEN
            IF v_line.tax_group_id IS NULL THEN
                RAISE EXCEPTION 'LINE_TAX_GROUP_MISSING'
                    USING DETAIL = format('Line %s: has a tax amount but no tax group.', v_line.serial_no);
            END IF;

            FOR v_tax_line IN
                SELECT t.gl_output_account_id AS tax_account,
                       v_line.tax_amount * (coalesce(r.tax_rate, 0) / NULLIF(sum(coalesce(r.tax_rate, 0)) OVER (), 0)) AS tax_portion
                FROM rim_tax_group_members gm
                JOIN rim_taxes t ON t.id = gm.tax_id
                JOIN LATERAL (SELECT fn_get_active_tax_rate(gm.tax_id, p_return_date) AS tax_rate) r ON true
                WHERE gm.tax_group_id = v_line.tax_group_id
            LOOP
                IF v_tax_line.tax_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('Line %s: a tax in its tax group has no Output GL account configured.', v_line.serial_no);
                END IF;

                v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_tax_line.tax_account, 'trans_nature', 'DR',
                    'trans_amount', v_tax_line.tax_portion, 'trans_currency', v_return_ccy,
                    'base_amount', v_tax_line.tax_portion * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_tax_line.tax_portion * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_tax_line.tax_portion, 'party_currency', v_return_ccy, 'party_rate', 1,
                    'source_line_type', 'SALES_RETURN_TAX', 'source_line_no', v_line.serial_no
                ));
            END LOOP;
        END IF;
    END LOOP;

    -- 5. Charges — reversed direction from the invoice's own posting
    --    (ADD reversed -> DR, DEDUCT reversed -> CR), straight to the
    --    charge's own gl_account_id, trusted as stored (same idiom
    --    fn_approve_sales_invoice uses for its own charge tax_amount).
    FOR v_charge_row IN
        SELECT * FROM rid_sales_return_charges
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        IF v_charge_row.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge_row.charge_name);
        END IF;

        v_charge_amount := v_charge_row.amount;
        v_charge_dir := CASE WHEN v_charge_row.nature = 'DEDUCT' THEN 'CR' ELSE 'DR' END;

        v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_charge_row.gl_account_id, 'trans_nature', v_charge_dir,
            'trans_amount', v_charge_amount, 'trans_currency', v_return_ccy,
            'base_amount', v_charge_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_charge_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_charge_amount, 'party_currency', v_return_ccy, 'party_rate', 1,
            'source_line_type', 'SALES_RETURN_CHARGE', 'source_line_no', v_charge_row.serial_no
        ));
        v_customer_cr_total := v_customer_cr_total + (CASE WHEN v_charge_row.nature = 'DEDUCT' THEN -1 ELSE 1 END) * v_charge_amount;

        IF v_charge_row.is_taxable AND coalesce(v_charge_row.tax_amount, 0) > 0 THEN
            IF v_charge_row.tax_id IS NULL THEN
                RAISE EXCEPTION 'LINE_TAX_GROUP_MISSING'
                    USING DETAIL = format('Charge %s has a tax amount but no tax configured.', v_charge_row.charge_name);
            END IF;
            SELECT gl_output_account_id INTO v_charge_tax_account FROM rim_taxes WHERE id = v_charge_row.tax_id;
            IF v_charge_tax_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('Charge %s: its tax has no Output GL account configured.', v_charge_row.charge_name);
            END IF;

            v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge_tax_account, 'trans_nature', v_charge_dir,
                'trans_amount', v_charge_row.tax_amount, 'trans_currency', v_return_ccy,
                'base_amount', v_charge_row.tax_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                'local_amount', v_charge_row.tax_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                'party_amount', v_charge_row.tax_amount, 'party_currency', v_return_ccy, 'party_rate', 1,
                'source_line_type', 'SALES_RETURN_CHARGE_TAX', 'source_line_no', v_charge_row.serial_no
            ));
            v_customer_cr_total := v_customer_cr_total + (CASE WHEN v_charge_row.nature = 'DEDUCT' THEN -1 ELSE 1 END) * v_charge_row.tax_amount;
        END IF;
    END LOOP;

    -- 6. Customer CR — one aggregate line, self-tagged inv_bill_no
    --    (corrected below once the real trans_no is known) so the refund
    --    below (or any future manual settlement) can settle directly
    --    against this bill via the existing Against-Bill mechanism.
    v_crn_lines := v_crn_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_header.customer_id, 'trans_nature', 'CR',
        'trans_amount', v_customer_cr_total, 'trans_currency', v_return_ccy,
        'base_amount', v_customer_cr_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_customer_cr_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_customer_cr_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', p_return_no, 'inv_bill_date', p_return_date,
        'source_line_type', 'CUSTOMER', 'source_line_no', 0
    ));

    SELECT * INTO v_crn_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'CRN', p_return_date,
        v_crn_lines, 'SALES_RETURN', p_return_no, p_return_date, p_approved_by
    );

    UPDATE rid_finance_lines SET
        inv_bill_no   = v_crn_result.trans_no,
        inv_bill_date = v_crn_result.trans_date
    WHERE client_id       = p_client_id
      AND company_id      = p_company_id
      AND location_id     = v_header.location_id
      AND trans_no        = v_crn_result.trans_no
      AND trans_date      = v_crn_result.trans_date
      AND source_line_type = 'CUSTOMER' AND source_line_no = 0;

    -- 7. Stock + Cost of Sales reversal — only if the source invoice
    --    actually dispatched stock. Unit cost is the ORIGINAL invoice
    --    line's own cost_price (migration 121, carried onto this return
    --    line verbatim at save time — migration 123's fn_save_sales_return)
    --    — never a fresh current-average lookup, to keep this reversal
    --    symmetric with what the invoice itself posted.
    v_stock_was_dispatched := v_invoice.stock_dispatch_mode = 'IMMEDIATE'
        OR EXISTS (
            SELECT 1 FROM rih_sales_delivery_headers dh
            WHERE dh.client_id = p_client_id AND dh.company_id = p_company_id
              AND dh.invoice_no = v_header.invoice_no AND dh.invoice_date = v_header.invoice_date
              AND dh.status = 'APPROVED'
        );

    IF v_stock_was_dispatched THEN
        v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_return_date);

        FOR v_line IN
            SELECT * FROM rid_sales_return_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
            ORDER BY product_id
        LOOP
            v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
            v_cos_account   := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'COST_OF_SALES_ACCOUNT');
            IF v_stock_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Stock Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;
            IF v_cos_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Cost of Sales Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;

            IF v_line.cost_price IS NULL THEN
                RAISE EXCEPTION 'ORIGINAL_COST_NOT_FOUND'
                    USING DETAIL = format('Line %s: the original invoice line has no recorded cost price to reverse against.', v_line.serial_no);
            END IF;

            v_unit_cost := v_line.cost_price * v_invoice.rate_to_base;

            SELECT cost_price_specific INTO v_unit_cost_specific
            FROM rim_product_location
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND location_id = v_header.location_id AND product_id = v_line.product_id
            FOR UPDATE;
            v_unit_cost_specific := coalesce(v_unit_cost_specific, v_unit_cost);

            v_has_batches := EXISTS (
                SELECT 1 FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                  AND line_serial = v_line.serial_no
            );
            v_has_serials := EXISTS (
                SELECT 1 FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                  AND line_serial = v_line.serial_no
            );

            v_line_cost_total := 0;

            IF v_has_batches THEN
                FOR v_batch IN
                    SELECT * FROM rid_transaction_line_batches
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_return_date, 'SALES_RETURN', v_batch.base_qty,
                        v_unit_cost, v_unit_cost_specific, v_batch.batch_no, v_batch.expiry_date, NULL,
                        'SALES_RETURN', p_return_no, p_return_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_batch.base_qty * v_unit_cost;
                END LOOP;
            ELSIF v_has_serials THEN
                FOR v_serial_row IN
                    SELECT * FROM rid_transaction_line_serials
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_RETURN' AND source_doc_no = p_return_no AND source_doc_date = p_return_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_return_date, 'SALES_RETURN', 1,
                        v_unit_cost, v_unit_cost_specific, NULL, NULL, v_serial_row.serial_no,
                        'SALES_RETURN', p_return_no, p_return_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_unit_cost;
                END LOOP;
            ELSE
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_return_date, 'SALES_RETURN', v_line.base_qty,
                    v_unit_cost, v_unit_cost_specific, NULL, NULL, NULL,
                    'SALES_RETURN', p_return_no, p_return_date, p_approved_by
                );
                v_line_cost_total := v_line.base_qty * v_unit_cost;
            END IF;

            v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'DR',
                'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
                'base_amount', v_line_cost_total, 'base_rate', 1,
                'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK', 'source_line_no', v_line.serial_no
            ));
            v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_cos_account, 'trans_nature', 'CR',
                'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
                'base_amount', v_line_cost_total, 'base_rate', 1,
                'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'COGS', 'source_line_no', v_line.serial_no
            ));
        END LOOP;

        SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'COS', p_return_date,
            v_cos_lines, 'SALES_RETURN', p_return_no, p_return_date, p_approved_by
        );
    END IF;

    -- 8. Cash refund — only when the source invoice was CASH and actually
    --    collected. Capped cumulative per invoice, per currency leg,
    --    against what that invoice actually collected minus what prior
    --    approved Sales Returns against it already refunded. A confirmed
    --    header amount exceeding the remaining pool is a hard error, never
    --    a silent clamp.
    IF v_invoice.sale_type = 'CASH' AND v_invoice.cash_collection_mode = 'IMMEDIATE' THEN
        SELECT coalesce(sum(refund_amount_local), 0), coalesce(sum(refund_amount_base), 0)
        INTO v_already_refunded_local, v_already_refunded_base
        FROM rih_sales_return_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND is_deleted = false AND status = 'APPROVED';

        -- NEW (223): a split-tender POS sale recorded every payment
        -- method's own local-currency amount on rid_pos_tender_lines at
        -- save time (migration 211/218) — collected_amount_local itself
        -- is deliberately narrowed to the CASH-only portion for the
        -- shift cash-drawer reconciliation formula (fn_close_pos_shift),
        -- so it understates "what was actually collected" the moment a
        -- non-cash leg is involved. Use the larger of the two: for a
        -- non-split invoice there are no tender-line rows at all (sum is
        -- 0), so this is byte-for-byte the old behavior; for a
        -- split-tender sale, the full cross-method total is recognized.
        SELECT coalesce(sum(amount_local), 0) INTO v_pos_tender_total_local
        FROM rid_pos_tender_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date;

        v_remaining_local := GREATEST(coalesce(v_invoice.collected_amount_local, 0), v_pos_tender_total_local) - v_already_refunded_local;
        v_remaining_base  := coalesce(v_invoice.collected_amount_base, 0)  - v_already_refunded_base;

        IF v_header.refund_amount_local > v_remaining_local + 0.0001 OR v_header.refund_amount_base > v_remaining_base + 0.0001 THEN
            RAISE EXCEPTION 'REFUND_EXCEEDS_COLLECTED'
                USING DETAIL = format(
                    'Requested refund (local %s, base %s) exceeds what remains collected on invoice %s (local %s, base %s remaining).',
                    v_header.refund_amount_local, v_header.refund_amount_base, v_header.invoice_no, v_remaining_local, v_remaining_base);
        END IF;

        IF v_header.refund_amount_local > 0 THEN
            v_cash_account_local := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
            IF v_cash_account_local IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user processing this return has no Quick Invoice Setup (Local Cash Account) — cannot refund cash.';
            END IF;

            IF v_customer_ccy IS NULL OR v_customer_ccy = v_local_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_local_ccy;
            ELSIF v_customer_ccy = v_base_ccy THEN
                v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_return_date));
                v_receipt_party_rate := v_local_to_base_rate; v_receipt_party_ccy := v_base_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_customer_ccy, p_return_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_return_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_return_date,
                'voucher_type_code', 'CPV', 'is_on_account', false,
                'remarks', format('Refund against Sales Return %s', p_return_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_header.customer_id,
                    'trans_nature', 'DR', 'trans_amount', v_header.refund_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.refund_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.refund_amount_local, 'local_rate', 1,
                    'party_amount', v_header.refund_amount_local * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_crn_result.trans_no, 'inv_bill_date', v_crn_result.trans_date
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_cash_account_local,
                    'trans_nature', 'CR', 'trans_amount', v_header.refund_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.refund_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.refund_amount_local, 'local_rate', 1,
                    'party_amount', v_header.refund_amount_local, 'party_currency', v_local_ccy, 'party_rate', 1
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            UPDATE rih_finance_headers SET
                source_doc_type = 'SALES_RETURN', source_doc_no = p_return_no, source_doc_date = p_return_date
            WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
              AND trans_no = v_receipt_no AND trans_date = p_return_date;
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_return_date, p_approved_by);
            UPDATE rih_sales_return_headers SET refund_voucher_no_local = v_receipt_no, refund_voucher_date_local = p_return_date WHERE id = v_header.id;
        END IF;

        IF v_header.refund_amount_base > 0 THEN
            v_cash_account_base := fn_quick_cash_account_base(p_client_id, p_company_id, v_header.created_by);
            IF v_cash_account_base IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user processing this return has no Quick Invoice Setup (Base Cash Account) — cannot refund cash.';
            END IF;

            IF v_customer_ccy IS NULL OR v_customer_ccy = v_base_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_base_ccy;
            ELSIF v_customer_ccy = v_local_ccy THEN
                v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_return_date));
                v_receipt_party_rate := v_base_to_local_rate; v_receipt_party_ccy := v_local_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_customer_ccy, p_return_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_return_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_return_date,
                'voucher_type_code', 'CPV', 'is_on_account', false,
                'remarks', format('Refund against Sales Return %s', p_return_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_header.customer_id,
                    'trans_nature', 'DR', 'trans_amount', v_header.refund_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.refund_amount_base, 'base_rate', 1,
                    'local_amount', v_header.refund_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.refund_amount_base * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_crn_result.trans_no, 'inv_bill_date', v_crn_result.trans_date
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_cash_account_base,
                    'trans_nature', 'CR', 'trans_amount', v_header.refund_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.refund_amount_base, 'base_rate', 1,
                    'local_amount', v_header.refund_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.refund_amount_base, 'party_currency', v_base_ccy, 'party_rate', 1
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            UPDATE rih_finance_headers SET
                source_doc_type = 'SALES_RETURN', source_doc_no = p_return_no, source_doc_date = p_return_date
            WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
              AND trans_no = v_receipt_no AND trans_date = p_return_date;
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_return_date, p_approved_by);
            UPDATE rih_sales_return_headers SET refund_voucher_no_base = v_receipt_no, refund_voucher_date_base = p_return_date WHERE id = v_header.id;
        END IF;
    END IF;

    -- 9. Mark the return approved.
    UPDATE rih_sales_return_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        credit_note_voucher_no   = v_crn_result.trans_no,
        credit_note_voucher_date = v_crn_result.trans_date,
        cos_voucher_no   = v_cos_voucher_no,
        cos_voucher_date = v_cos_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;
