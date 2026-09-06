-- ============================================================
-- 178_purchase_return_charge_reversal.sql
--
-- Real gap found live: a Purchase Return's own "Additional Charges" section
-- (rid_purchase_return_charge_lines, pre-filled proportionally from the
-- source GRN's own charges and editable) was being saved correctly by
-- fn_save_purchase_return, but fn_approve_purchase_return never read that
-- table at all -- confirmed by grep, zero references to
-- rid_purchase_return_charge_lines anywhere in the function. A Transport
-- charge entered on a return (even a full return of everything the GRN
-- received) never got reversed, leaving that charge's own provisional/
-- clearing account (e.g. "Provision for Transport") permanently non-zero
-- in the Trial Balance even after the goods themselves were fully returned.
--
-- Fix: for each of the return's own charge lines, post a self-balancing
-- pair mirroring exactly how fn_approve_grn originally funded that charge:
--   - ADD-nature charge (GRN posted CR to the charge's own account, with
--     the matching DR silently absorbed into that line's own inflated
--     Stock Dr): reversed here as DR the charge account, CR Stock back
--     down by the same amount.
--   - DEDUCT-nature charge (GRN posted DR, which had REDUCED the Stock Dr):
--     reversed here as CR the charge account, DR Stock back up.
-- A charge has no product_id of its own to resolve a Stock account from --
-- resolved via the same anchor-product convention this function already
-- uses for v_returns_account. Routed into the JV or SDN voucher matching
-- THAT CHARGE's own source GRN's billed status (LEFT JOIN, defaulting to
-- the unbilled/JV path if a source GRN somehow can't be found, rather than
-- silently dropping the reversal) -- same split already used for the item
-- lines. Uses v_header.rate_to_base/rate_to_local, now populated correctly
-- for every new return since migration bb6c5cf's Flutter-side fix.
--
-- Verbatim reproduction of fn_approve_purchase_return's current live body
-- (from migration 110), same signature, every other line unchanged -- only
-- the new charge-reversal loop is inserted, per the "grep every migration
-- for the current definition" rule.
-- ============================================================

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
    v_charge            RECORD;
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

    -- Server-side re-check of approve permission, resolved from the JWT
    -- (never a client-supplied parameter) — see migration 108.
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
    -- Purchase Bill's Exchange Gain/Loss anchor (059). Also reused below to
    -- resolve a Stock account for reversing Additional Charges, which have
    -- no product_id of their own either.
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

    -- 5b. Additional Charges — reverse each charge's own provisional/
    --     clearing account exactly as GRN originally funded it. NEW in
    --     this migration; see the header comment above for the full
    --     reasoning. LEFT JOIN + coalesce so a charge whose source GRN
    --     can't be found for some reason still gets reversed (routed to
    --     the unbilled/JV path) rather than silently dropped.
    FOR v_charge IN
        SELECT rc.*, g.billed_invoice_no
        FROM rid_purchase_return_charge_lines rc
        LEFT JOIN rih_grn_headers g
          ON g.client_id = rc.client_id AND g.company_id = rc.company_id
         AND g.grn_no = rc.source_grn_no AND g.grn_date = rc.source_grn_date
        WHERE rc.client_id = p_client_id AND rc.company_id = p_company_id
          AND rc.return_no = p_return_no AND rc.return_date = p_return_date
          AND rc.is_deleted = false
    LOOP
        IF v_charge.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
        END IF;

        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_anchor_product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = 'No Stock Account resolved to reverse this return''s additional charges.';
        END IF;

        DECLARE
            v_charge_account_ccy TEXT;
            v_charge_party_rate  NUMERIC;
            v_charge_party_ccy   TEXT;
            v_stock_account_ccy  TEXT;
            v_stock_party_rate   NUMERIC;
            v_stock_party_ccy    TEXT;
            v_charge_lines       JSONB;
        BEGIN
            SELECT c.currency_id INTO v_charge_account_ccy
            FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
            WHERE a.id = v_charge.gl_account_id;
            IF v_charge_account_ccy IS NULL OR v_charge_account_ccy = v_return_ccy THEN
                v_charge_party_rate := 1; v_charge_party_ccy := v_return_ccy;
            ELSIF v_charge_account_ccy = v_base_ccy THEN
                v_charge_party_rate := v_header.rate_to_base; v_charge_party_ccy := v_base_ccy;
            ELSIF v_charge_account_ccy = v_local_ccy THEN
                v_charge_party_rate := v_header.rate_to_local; v_charge_party_ccy := v_local_ccy;
            ELSE
                v_charge_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_return_ccy, v_charge_account_ccy, p_return_date);
                v_charge_party_ccy := v_charge_account_ccy;
            END IF;

            SELECT c.currency_id INTO v_stock_account_ccy
            FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
            WHERE a.id = v_stock_account;
            IF v_stock_account_ccy IS NULL OR v_stock_account_ccy = v_return_ccy THEN
                v_stock_party_rate := 1; v_stock_party_ccy := v_return_ccy;
            ELSIF v_stock_account_ccy = v_base_ccy THEN
                v_stock_party_rate := v_header.rate_to_base; v_stock_party_ccy := v_base_ccy;
            ELSIF v_stock_account_ccy = v_local_ccy THEN
                v_stock_party_rate := v_header.rate_to_local; v_stock_party_ccy := v_local_ccy;
            ELSE
                v_stock_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_return_ccy, v_stock_account_ccy, p_return_date);
                v_stock_party_ccy := v_stock_account_ccy;
            END IF;

            -- ADD-nature: GRN posted CR to the charge account (funded by a
            -- bigger Stock Dr) — reverse as DR charge / CR Stock.
            -- DEDUCT-nature: GRN posted DR (which had shrunk the Stock Dr)
            -- — reverse as CR charge / DR Stock.
            v_charge_lines := jsonb_build_array(
                jsonb_build_object(
                    'account_id', v_charge.gl_account_id,
                    'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'CR' ELSE 'DR' END,
                    'trans_amount', v_charge.amount, 'trans_currency', v_return_ccy,
                    'base_amount', v_charge.amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_charge.amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_charge.amount * v_charge_party_rate, 'party_currency', v_charge_party_ccy, 'party_rate', v_charge_party_rate,
                    'source_line_type', 'CHARGE_REVERSAL', 'source_line_no', v_charge.serial_no
                ),
                jsonb_build_object(
                    'account_id', v_stock_account,
                    'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
                    'trans_amount', v_charge.amount, 'trans_currency', v_return_ccy,
                    'base_amount', v_charge.amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_charge.amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_charge.amount * v_stock_party_rate, 'party_currency', v_stock_party_ccy, 'party_rate', v_stock_party_rate,
                    'source_line_type', 'CHARGE_STOCK_OFFSET', 'source_line_no', v_charge.serial_no
                )
            );

            IF v_charge.billed_invoice_no IS NULL THEN
                v_jv_lines := v_jv_lines || v_charge_lines;
            ELSE
                v_sdn_lines := v_sdn_lines || v_charge_lines;
            END IF;
        END;
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
