-- ============================================================
-- 114_sales_approve_permission.sql
--
-- Batch 3 (final) of the fn_check_approve_permission rollout — Sales
-- module. Wires the same server-side approve-permission re-check into
-- all 6 Sales approve functions + 2 cancel functions:
--   fn_approve_sales_quotation  -> SL-QUO
--   fn_approve_sales_order      -> SL-SO
--   fn_cancel_sales_order       -> SL-SO   (no separate cancel flag)
--   fn_approve_sales_invoice    -> SL-INV
--   fn_cancel_sales_invoice     -> SL-INV
--   fn_approve_sales_return     -> SL-RET
--   fn_approve_sales_delivery   -> SL-DEL
--   fn_approve_cash_receipt     -> SL-RCP
-- Same insertion rule as every prior batch: PERFORM fn_check_approve_
-- permission(...) goes immediately after each function's existing
-- status-check block, before period/backdate checks. Every other line
-- of each function reproduced verbatim from its current live source
-- (098/098/087/090/089/099/102/104 respectively), never truncated.
--
-- ── A THIRD occurrence of the composition-guard pattern, found while
--    reading these bodies (not after a failed test — see
--    feedback_shared_engine_bugs_fix_once's 4th/5th/6th incidents for
--    the first three) ──
-- Three of these functions compose a CRV/CPV settlement voucher
-- DIRECTLY via fn_save_finance_voucher + fn_post_finance_voucher
-- (never through fn_post_voucher) whenever cash actually moves:
--   fn_approve_sales_invoice  -- immediate cash collection on a sale
--   fn_approve_sales_return   -- cash refund against a return
--   fn_approve_cash_receipt   -- cash collection against pending bills
-- None of the composed vouchers' headers were ever tagged with
-- source_doc_type — meaning fn_post_finance_voucher's FN-PRV check
-- (restored in migration 113, now guarded "AND source_doc_type IS
-- NULL") would treat every one of these exactly like a DIRECT Payment/
-- Receipt Voucher entry, silently requiring the Sales approver to ALSO
-- hold unrelated FN-PRV permission — the identical bug class fixed for
-- GRN/JV (111) and Stock Count Review/Stock Adjustment (112), now found
-- a third time by proactively asking the question before shipping.
-- Fixed here: immediately after each fn_save_finance_voucher call (and
-- BEFORE the matching fn_post_finance_voucher call), an UPDATE
-- rih_finance_headers tags source_doc_type/source_doc_no/source_doc_date
-- — 'SALES_INVOICE'/p_invoice_no/p_invoice_date,
-- 'SALES_RETURN'/p_return_no/p_return_date, or
-- 'CASH_RECEIPT'/p_receipt_no/p_receipt_date respectively — mirroring
-- fn_post_voucher's own convention exactly, and giving these vouchers
-- real traceability they never had. Six call sites total (each of the
-- three functions posts up to two such vouchers: a LOCAL-currency leg
-- and a BASE-currency leg).
-- ============================================================

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_sales_order — verbatim from 098_sales_order_quotation_period_check.sql
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_sales_order(
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
    v_header         rih_sales_orders%ROWTYPE;
    v_line           RECORD;
    v_source_line    rid_sales_quotation_lines%ROWTYPE;
    v_remaining      NUMERIC;
    v_all_converted  BOOLEAN;
    v_any_converted  BOOLEAN;
BEGIN
    SELECT * INTO v_header FROM rih_sales_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % dated % not found', p_order_no, p_order_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Order % is % and cannot be approved again', p_order_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-SO');

    PERFORM fn_check_period_open(p_company_id, p_order_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_ORDER', p_order_date);

    FOR v_line IN
        SELECT * FROM rid_sales_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;
        IF v_line.rate < 0 THEN
            RAISE EXCEPTION 'LINE_RATE_INVALID'
                USING DETAIL = format('Line %s: rate cannot be negative.', v_line.serial_no);
        END IF;
    END LOOP;

    IF v_header.order_mode = 'AGAINST_QUOTATION' THEN
        FOR v_line IN
            SELECT * FROM rid_sales_order_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
            ORDER BY source_quotation_line_serial
        LOOP
            SELECT * INTO v_source_line FROM rid_sales_quotation_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
              AND serial_no = v_line.source_quotation_line_serial
            FOR UPDATE;

            v_remaining := v_source_line.base_qty - v_source_line.converted_qty;
            IF v_line.base_qty > v_remaining THEN
                RAISE EXCEPTION 'QUOTATION_QTY_EXCEEDED'
                    USING DETAIL = format('Quotation %s line %s: only %s remains unconverted (another order may have consumed it since this draft was saved).',
                        v_header.source_quotation_no, v_source_line.serial_no, v_remaining);
            END IF;

            UPDATE rid_sales_quotation_lines SET
                converted_qty = converted_qty + v_line.base_qty,
                updated_at = now(), updated_by = p_approved_by
            WHERE id = v_source_line.id;
        END LOOP;

        SELECT
            bool_and(converted_qty >= base_qty),
            bool_or(converted_qty > 0)
        INTO v_all_converted, v_any_converted
        FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
          AND is_deleted = false;

        UPDATE rih_sales_quotations SET
            status = CASE WHEN v_all_converted THEN 'CONVERTED'
                          WHEN v_any_converted  THEN 'PARTIALLY_CONVERTED'
                          ELSE status END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date;
    END IF;

    UPDATE rih_sales_orders SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_order(UUID, UUID, TEXT, DATE, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_sales_quotation — verbatim from 098_sales_order_quotation_period_check.sql
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_sales_quotation(
    p_client_id      UUID,
    p_company_id     UUID,
    p_quotation_no   TEXT,
    p_quotation_date DATE,
    p_approved_by    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_sales_quotations%ROWTYPE;
    v_line   RECORD;
BEGIN
    SELECT * INTO v_header FROM rih_sales_quotations
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Quotation % dated % not found', p_quotation_no, p_quotation_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Quotation % is % and cannot be approved again', p_quotation_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-QUO');

    PERFORM fn_check_period_open(p_company_id, p_quotation_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_QUOTATION', p_quotation_date);

    FOR v_line IN
        SELECT * FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = p_quotation_no AND quotation_date = p_quotation_date AND is_deleted = false
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;
        IF v_line.rate < 0 THEN
            RAISE EXCEPTION 'LINE_RATE_INVALID'
                USING DETAIL = format('Line %s: rate cannot be negative.', v_line.serial_no);
        END IF;
    END LOOP;

    UPDATE rih_sales_quotations SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_quotation(UUID, UUID, TEXT, DATE, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_cancel_sales_order — verbatim from 087_sales_order.sql
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_cancel_sales_order(
    p_client_id  UUID,
    p_company_id UUID,
    p_order_no   TEXT,
    p_order_date DATE,
    p_reason     TEXT,
    p_user_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header        rih_sales_orders%ROWTYPE;
    v_line          RECORD;
    v_any_converted BOOLEAN;
BEGIN
    IF nullif(trim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Enter a reason for cancelling this order.';
    END IF;

    SELECT * INTO v_header FROM rih_sales_orders
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND order_no = p_order_no AND order_date = p_order_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Order % dated % not found', p_order_no, p_order_date;
    END IF;
    IF v_header.status NOT IN ('DRAFT', 'APPROVED') THEN
        RAISE EXCEPTION 'Sales Order % is % and cannot be cancelled', p_order_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — same feature_code as
    -- fn_approve_sales_order, since there is no separate "cancel"
    -- governance bit in this schema — see migration 108's own header
    -- comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-SO');

    IF EXISTS (
        SELECT 1 FROM rid_sales_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
          AND delivered_qty > 0
    ) THEN
        RAISE EXCEPTION 'DELIVERY_ALREADY_STARTED'
            USING DETAIL = format('Sales Order %s already has delivered quantity and cannot be cancelled.', p_order_no);
    END IF;

    IF v_header.order_mode = 'AGAINST_QUOTATION' AND v_header.status = 'APPROVED' THEN
        FOR v_line IN
            SELECT * FROM rid_sales_order_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = p_order_no AND order_date = p_order_date AND is_deleted = false
            ORDER BY source_quotation_line_serial
        LOOP
            UPDATE rid_sales_quotation_lines SET
                converted_qty = greatest(0, converted_qty - v_line.base_qty),
                updated_at = now(), updated_by = p_user_id
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
              AND serial_no = v_line.source_quotation_line_serial;
        END LOOP;

        SELECT bool_or(converted_qty > 0) INTO v_any_converted
        FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
          AND is_deleted = false;

        UPDATE rih_sales_quotations SET
            status = CASE WHEN NOT v_any_converted THEN 'APPROVED' ELSE 'PARTIALLY_CONVERTED' END,
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND quotation_no = v_header.source_quotation_no AND quotation_date = v_header.source_quotation_date
          AND status IN ('CONVERTED', 'PARTIALLY_CONVERTED');
    END IF;

    UPDATE rih_sales_orders SET
        status = 'CANCELLED',
        cancellation_reason = trim(p_reason),
        updated_at = now(), updated_by = p_user_id
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_cancel_sales_order(UUID, UUID, TEXT, DATE, TEXT, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_sales_invoice — verbatim from 090_sales_invoice_voucher_type_split.sql
--
-- Also carries the new source_doc_type tagging on both composed CRV
-- legs (local/base) — see this migration's own header comment.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_sales_invoice(
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
    v_header              rih_sales_invoices%ROWTYPE;
    v_line                rid_sales_invoice_lines%ROWTYPE;
    v_batch                rid_transaction_line_batches%ROWTYPE;
    v_serial_row             rid_transaction_line_serials%ROWTYPE;
    v_invoice_ccy              TEXT;
    v_base_ccy                  TEXT;
    v_local_ccy                   TEXT;
    v_sales_account                 UUID;
    v_cos_account                     UUID;
    v_stock_account                     UUID;
    v_taxable_amount                        NUMERIC;
    v_tax_line                                RECORD;
    v_charge_row                                rid_sales_invoice_charges%ROWTYPE;
    v_charge_amount                              NUMERIC;
    v_charge_tax_account                          UUID;
    v_customer_ccy                            TEXT;
    v_party_rate                                NUMERIC;
    v_party_ccy                                   TEXT;
    v_si_lines                                      JSONB := '[]'::jsonb;
    v_cos_lines                                       JSONB := '[]'::jsonb;
    v_si_result                                         RECORD;
    v_cos_voucher_no                                      TEXT;
    v_cos_voucher_date                                      DATE;
    v_has_batches                                           BOOLEAN;
    v_has_serials                                             BOOLEAN;
    v_unit_cost                                                 NUMERIC;
    v_line_cost_total                                             NUMERIC;
    v_receipt_header                                                    JSONB;
    v_receipt_lines                                                       JSONB;
    v_receipt_no                                                            TEXT;
    v_cash_account_local                                                      UUID;
    v_cash_account_base                                                        UUID;
    v_local_to_base_rate                                                        NUMERIC;
    v_base_to_local_rate                                                         NUMERIC;
    v_receipt_party_rate                                                          NUMERIC;
    v_receipt_party_ccy                                                            TEXT;
BEGIN
    SELECT * INTO v_header FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % dated % not found', p_invoice_no, p_invoice_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Invoice % is % and cannot be approved again', p_invoice_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-INV');

    PERFORM fn_check_period_open(p_company_id, p_invoice_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_INVOICE', p_invoice_date);

    SELECT currency_id INTO v_invoice_ccy FROM rim_currencies WHERE id = v_header.invoice_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- Customer line's own currency shortcut (same idiom as GRN's Supplier
    -- line / Purchase Bill's Supplier line: same-currency shortcut, else
    -- the header's own base/local rate, else a real exchange-rate lookup).
    SELECT c.currency_id INTO v_customer_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.customer_id;
    IF v_customer_ccy IS NULL OR v_customer_ccy = v_invoice_ccy THEN
        v_party_rate := 1; v_party_ccy := v_invoice_ccy;
    ELSIF v_customer_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_customer_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_invoice_ccy, v_customer_ccy, p_invoice_date);
        v_party_ccy := v_customer_ccy;
    END IF;

    -- Customer DR — one line for the whole invoice, tagged inv_bill_no=self
    -- so it appears in v_pending_bills regardless of collection mode.
    v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_header.customer_id, 'trans_nature', 'DR',
        'trans_amount', v_header.grand_total, 'trans_currency', v_invoice_ccy,
        'base_amount', v_header.grand_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_header.grand_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_header.grand_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', p_invoice_no, 'inv_bill_date', p_invoice_date,
        'source_line_type', 'CUSTOMER', 'source_line_no', 0
    ));

    -- Per-line Sales CR + per-tax Sales Tax CR.
    FOR v_line IN
        SELECT * FROM rid_sales_invoice_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        IF v_line.base_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_REQUIRED'
                USING DETAIL = format('Line %s: quantity must be greater than zero.', v_line.serial_no);
        END IF;

        v_sales_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'SALES_ACCOUNT');
        IF v_sales_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Sales Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_taxable_amount := v_line.final_amount - v_line.tax_amount;

        v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_sales_account, 'trans_nature', 'CR',
            'trans_amount', v_taxable_amount, 'trans_currency', v_invoice_ccy,
            'base_amount', v_taxable_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_taxable_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_taxable_amount, 'party_currency', v_invoice_ccy, 'party_rate', 1,
            'source_line_type', 'SALES', 'source_line_no', v_line.serial_no
        ));

        IF v_line.tax_amount > 0 THEN
            IF v_line.tax_group_id IS NULL THEN
                RAISE EXCEPTION 'LINE_TAX_GROUP_MISSING'
                    USING DETAIL = format('Line %s: has a tax amount but no tax group.', v_line.serial_no);
            END IF;

            -- One CR line per active tax in the line's tax group, weighted
            -- by rate (same apportionment idiom as GRN's own tax handling).
            -- A RECORD variable is required here — PL/pgSQL's `FOR a, b IN
            -- SELECT ...` (destructuring straight into two scalars) is not
            -- valid syntax, only `FOR rec IN SELECT ...` is.
            FOR v_tax_line IN
                SELECT t.gl_output_account_id AS tax_account,
                       v_line.tax_amount * (coalesce(r.tax_rate, 0) / NULLIF(sum(coalesce(r.tax_rate, 0)) OVER (), 0)) AS tax_portion
                FROM rim_tax_group_members gm
                JOIN rim_taxes t ON t.id = gm.tax_id
                JOIN LATERAL (SELECT fn_get_active_tax_rate(gm.tax_id, p_invoice_date) AS tax_rate) r ON true
                WHERE gm.tax_group_id = v_line.tax_group_id
            LOOP
                IF v_tax_line.tax_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('Line %s: a tax in its tax group has no Output GL account configured.', v_line.serial_no);
                END IF;

                v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_tax_line.tax_account, 'trans_nature', 'CR',
                    'trans_amount', v_tax_line.tax_portion, 'trans_currency', v_invoice_ccy,
                    'base_amount', v_tax_line.tax_portion * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_tax_line.tax_portion * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_tax_line.tax_portion, 'party_currency', v_invoice_ccy, 'party_rate', 1,
                    'source_line_type', 'SALES_TAX', 'source_line_no', v_line.serial_no
                ));
            END LOOP;
        END IF;
    END LOOP;

    -- Charges — one CR (ADD) or DR (DEDUCT) leg per charge, straight to
    -- that charge's own gl_account_id (never fn_resolve_account_link;
    -- unlike product lines, a charge's GL account is captured directly on
    -- the charge row at entry time, same as GRN/PO charges). This is the
    -- first place any Sales-module charge's gl_account_id actually posts
    -- — Quotation/Order never post GL at all. tax_amount is trusted as
    -- stored (client-computed, same idiom as the charge's own `amount`)
    -- rather than re-derived server-side: unlike a product line's tax
    -- group (multiple member taxes needing weighted apportionment), a
    -- charge references exactly one tax_id, so there is no apportionment
    -- ambiguity to protect against by recomputing.
    FOR v_charge_row IN
        SELECT * FROM rid_sales_invoice_charges
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        IF v_charge_row.gl_account_id IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Charge %s has no GL account configured.', v_charge_row.charge_name);
        END IF;

        v_charge_amount := v_charge_row.amount;

        v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_charge_row.gl_account_id,
            'trans_nature', CASE WHEN v_charge_row.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
            'trans_amount', v_charge_amount, 'trans_currency', v_invoice_ccy,
            'base_amount', v_charge_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_charge_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_charge_amount, 'party_currency', v_invoice_ccy, 'party_rate', 1,
            'source_line_type', 'SALES_CHARGE', 'source_line_no', v_charge_row.serial_no
        ));

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

            v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge_tax_account,
                'trans_nature', CASE WHEN v_charge_row.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
                'trans_amount', v_charge_row.tax_amount, 'trans_currency', v_invoice_ccy,
                'base_amount', v_charge_row.tax_amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                'local_amount', v_charge_row.tax_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                'party_amount', v_charge_row.tax_amount, 'party_currency', v_invoice_ccy, 'party_rate', 1,
                'source_line_type', 'SALES_CHARGE_TAX', 'source_line_no', v_charge_row.serial_no
            ));
        END IF;
    END LOOP;

    -- FIX (090): posts as SLS (Sales Voucher), not SI — SI is invoice_no's
    -- own numbering code (fn_next_trans_no at Save); reusing it here made
    -- every approval silently consume/skip a number from that sequence.
    -- See this migration's header comment for the full rationale.
    SELECT * INTO v_si_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'SLS', p_invoice_date,
        v_si_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
    );

    -- The Customer DR line above was tagged inv_bill_no=p_invoice_no as a
    -- stand-in, since the SLS voucher's own real trans_no isn't known
    -- until fn_post_voucher returns. fn_post_finance_voucher's settlement
    -- lookup joins the settling line's inv_bill_no against this line's
    -- real trans_no, so the self-reference must be corrected to the
    -- voucher's actual trans_no/trans_date here, or Cash-sale settlement
    -- silently never finds this line. Filtered by source_line_type/
    -- source_line_no (not inv_bill_no, which this statement also SETs).
    UPDATE rid_finance_lines SET
        inv_bill_no   = v_si_result.trans_no,
        inv_bill_date = v_si_result.trans_date
    WHERE client_id       = p_client_id
      AND company_id      = p_company_id
      AND location_id     = v_header.location_id
      AND trans_no        = v_si_result.trans_no
      AND trans_date      = v_si_result.trans_date
      AND source_line_type = 'CUSTOMER' AND source_line_no = 0;

    -- Stock dispatch + Cost of Sales — only when this invoice snapshotted
    -- IMMEDIATE at save time.
    IF v_header.stock_dispatch_mode = 'IMMEDIATE' THEN
        v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date);

        FOR v_line IN
            SELECT * FROM rid_sales_invoice_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
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

            -- Snapshot current moving-average cost under the SAME lock
            -- fn_post_stock_movement re-acquires internally (Stock-
            -- Adjustment-style pre-fetch) — that function never hands
            -- cost back to the caller.
            SELECT cost_price INTO v_unit_cost
            FROM rim_product_location
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND location_id = v_header.location_id AND product_id = v_line.product_id
            FOR UPDATE;
            v_unit_cost := coalesce(v_unit_cost, 0);

            v_has_batches := EXISTS (
                SELECT 1 FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                  AND line_serial = v_line.serial_no
            );
            v_has_serials := EXISTS (
                SELECT 1 FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                  AND line_serial = v_line.serial_no
            );

            v_line_cost_total := 0;

            IF v_has_batches THEN
                FOR v_batch IN
                    SELECT * FROM rid_transaction_line_batches
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_invoice_date, 'SALES_INVOICE', -v_batch.base_qty,
                        NULL, NULL, v_batch.batch_no, NULL, NULL,
                        'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_batch.base_qty * v_unit_cost;
                END LOOP;
            ELSIF v_has_serials THEN
                FOR v_serial_row IN
                    SELECT * FROM rid_transaction_line_serials
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no AND source_doc_date = p_invoice_date
                      AND line_serial = v_line.serial_no
                LOOP
                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                        p_invoice_date, 'SALES_INVOICE', -1,
                        NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                        'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
                    );
                    v_line_cost_total := v_line_cost_total + v_unit_cost;
                END LOOP;
            ELSE
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_invoice_date, 'SALES_INVOICE', -v_line.base_qty,
                    NULL, NULL, NULL, NULL, NULL,
                    'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
                );
                v_line_cost_total := v_line.base_qty * v_unit_cost;
            END IF;

            -- COS voucher: pure internal costing, always base currency,
            -- base_rate=1. No real external party, but rid_finance_lines
            -- requires party_currency NOT NULL regardless — same
            -- self-referential convention every other purely-internal
            -- voucher already uses (e.g. Material Issue's MIC lines,
            -- 068_material_issue.sql): party_amount/party_currency mirror
            -- trans_amount/trans_currency, party_rate=1.
            v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_cos_account, 'trans_nature', 'DR',
                'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
                'base_amount', v_line_cost_total, 'base_rate', 1,
                'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'COGS', 'source_line_no', v_line.serial_no
            ));
            v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'CR',
                'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
                'base_amount', v_line_cost_total, 'base_rate', 1,
                'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK', 'source_line_no', v_line.serial_no
            ));
        END LOOP;

        SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'COS', p_invoice_date,
            v_cos_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
        );
    END IF;

    -- Cash collection — settle up to two Receipt Vouchers against this
    -- invoice's own bill, via fn_save_finance_voucher +
    -- fn_post_finance_voucher DIRECTLY (never fn_post_voucher, which
    -- hardcodes is_on_account=true). Resolved from the ORIGINAL cashier's
    -- (v_header.created_by) own Quick Invoice Setup row, never
    -- p_approved_by — a manager posting this later via Manager Review
    -- didn't personally collect the cash, and may not even have a Quick
    -- Invoice Setup row of their own. A cashier with no such row at all
    -- (e.g. a Credit-only user who nonetheless collected cash on this
    -- sale) is a clear, explicit error rather than a silently-null
    -- account_id surfacing as a confusing constraint failure deep inside
    -- fn_save_finance_voucher.
    --
    -- IMPORTANT: each receipt voucher's own trans_currency is LOCAL or
    -- BASE respectively — NOT the invoice's own currency — so
    -- v_header.rate_to_base/rate_to_local (which convert FROM the
    -- invoice's currency) and the earlier v_party_rate/v_party_ccy (also
    -- resolved against the invoice's currency) are the WRONG basis here
    -- and must not be reused. Each receipt needs its own fresh
    -- local<->base rate and its own fresh customer-party rate resolved
    -- against ITS OWN trans_currency.
    IF v_header.cash_collection_mode = 'IMMEDIATE' THEN
        IF coalesce(v_header.collected_amount_local, 0) > 0 OR coalesce(v_header.collected_amount_base, 0) > 0 THEN
            v_cash_account_local := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
            v_cash_account_base  := fn_quick_cash_account_base(p_client_id, p_company_id, v_header.created_by);
        END IF;

        IF coalesce(v_header.collected_amount_local, 0) > 0 THEN
            IF v_cash_account_local IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user who created this invoice has no Quick Invoice Setup (Local Cash Account) — cannot collect cash.';
            END IF;

            -- Resolve local->base and this customer's party rate, both
            -- against LOCAL currency (this receipt's own trans_currency).
            IF v_customer_ccy IS NULL OR v_customer_ccy = v_local_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_local_ccy;
            ELSIF v_customer_ccy = v_base_ccy THEN
                v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_invoice_date));
                v_receipt_party_rate := v_local_to_base_rate; v_receipt_party_ccy := v_base_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_customer_ccy, p_invoice_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_local_to_base_rate := coalesce(v_local_to_base_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_invoice_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_invoice_date,
                'voucher_type_code', 'CRV', 'is_on_account', false,
                'remarks', format('Collection against Sales Invoice %s', p_invoice_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_cash_account_local,
                    'trans_nature', 'DR', 'trans_amount', v_header.collected_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.collected_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.collected_amount_local, 'local_rate', 1,
                    'party_amount', v_header.collected_amount_local, 'party_currency', v_local_ccy, 'party_rate', 1
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_header.customer_id,
                    'trans_nature', 'CR', 'trans_amount', v_header.collected_amount_local, 'trans_currency', v_local_ccy,
                    'base_amount', v_header.collected_amount_local * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                    'local_amount', v_header.collected_amount_local, 'local_rate', 1,
                    'party_amount', v_header.collected_amount_local * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_si_result.trans_no, 'inv_bill_date', v_si_result.trans_date
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            -- NEW (114): tag this composed CRV's header — see this
            -- migration's own header comment for the full reasoning.
            UPDATE rih_finance_headers SET
                source_doc_type = 'SALES_INVOICE', source_doc_no = p_invoice_no, source_doc_date = p_invoice_date
            WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
              AND trans_no = v_receipt_no AND trans_date = p_invoice_date;
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_invoice_date, p_approved_by);
            UPDATE rih_sales_invoices SET local_receipt_voucher_no = v_receipt_no, local_receipt_voucher_date = p_invoice_date WHERE id = v_header.id;
        END IF;

        IF coalesce(v_header.collected_amount_base, 0) > 0 THEN
            IF v_cash_account_base IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user who created this invoice has no Quick Invoice Setup (Base Cash Account) — cannot collect cash.';
            END IF;

            -- Resolve base->local and this customer's party rate, both
            -- against BASE currency (this receipt's own trans_currency).
            IF v_customer_ccy IS NULL OR v_customer_ccy = v_base_ccy THEN
                v_receipt_party_rate := 1; v_receipt_party_ccy := v_base_ccy;
            ELSIF v_customer_ccy = v_local_ccy THEN
                v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date));
                v_receipt_party_rate := v_base_to_local_rate; v_receipt_party_ccy := v_local_ccy;
            ELSE
                v_receipt_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_customer_ccy, p_invoice_date);
                v_receipt_party_ccy := v_customer_ccy;
            END IF;
            v_base_to_local_rate := coalesce(v_base_to_local_rate, fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date));

            v_receipt_header := jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_invoice_date,
                'voucher_type_code', 'CRV', 'is_on_account', false,
                'remarks', format('Collection against Sales Invoice %s', p_invoice_no)
            );
            v_receipt_lines := jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_cash_account_base,
                    'trans_nature', 'DR', 'trans_amount', v_header.collected_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.collected_amount_base, 'base_rate', 1,
                    'local_amount', v_header.collected_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.collected_amount_base, 'party_currency', v_base_ccy, 'party_rate', 1
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_header.customer_id,
                    'trans_nature', 'CR', 'trans_amount', v_header.collected_amount_base, 'trans_currency', v_base_ccy,
                    'base_amount', v_header.collected_amount_base, 'base_rate', 1,
                    'local_amount', v_header.collected_amount_base * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', v_header.collected_amount_base * v_receipt_party_rate, 'party_currency', v_receipt_party_ccy, 'party_rate', v_receipt_party_rate,
                    'inv_bill_no', v_si_result.trans_no, 'inv_bill_date', v_si_result.trans_date
                )
            );
            v_receipt_no := fn_save_finance_voucher(v_receipt_header, v_receipt_lines, p_approved_by);
            -- NEW (114): tag this composed CRV's header — see this
            -- migration's own header comment for the full reasoning.
            UPDATE rih_finance_headers SET
                source_doc_type = 'SALES_INVOICE', source_doc_no = p_invoice_no, source_doc_date = p_invoice_date
            WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
              AND trans_no = v_receipt_no AND trans_date = p_invoice_date;
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_invoice_date, p_approved_by);
            UPDATE rih_sales_invoices SET base_receipt_voucher_no = v_receipt_no, base_receipt_voucher_date = p_invoice_date WHERE id = v_header.id;
        END IF;
    END IF;

    UPDATE rih_sales_invoices SET
        status              = 'APPROVED',
        approved_by         = p_approved_by,
        approved_at         = now(),
        sales_voucher_no    = v_si_result.trans_no,
        sales_voucher_date  = v_si_result.trans_date,
        cos_voucher_no      = v_cos_voucher_no,
        cos_voucher_date    = v_cos_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_invoice(UUID, UUID, TEXT, DATE, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_cancel_sales_invoice — verbatim from 089_sales_invoice.sql
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_cancel_sales_invoice(
    p_client_id  UUID,
    p_company_id UUID,
    p_invoice_no TEXT,
    p_invoice_date DATE,
    p_reason     TEXT,
    p_user_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_sales_invoices%ROWTYPE;
BEGIN
    IF nullif(trim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Enter a reason for cancelling this invoice.';
    END IF;

    SELECT * INTO v_header FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % dated % not found', p_invoice_no, p_invoice_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Invoice % is % and cannot be cancelled — once approved, a correction can only be made through a future Sales Return.', p_invoice_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — same feature_code as
    -- fn_approve_sales_invoice, since there is no separate "cancel"
    -- governance bit in this schema — see migration 108's own header
    -- comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-INV');

    UPDATE rih_sales_invoices SET
        status = 'CANCELLED',
        cancellation_reason = trim(p_reason),
        updated_at = now(), updated_by = p_user_id
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_cancel_sales_invoice(UUID, UUID, TEXT, DATE, TEXT, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_sales_return — verbatim from 099_sales_return.sql
--
-- Also carries the new source_doc_type tagging on both composed CPV
-- refund legs (local/base) — see this migration's own header comment.
-- ════════════════════════════════════════════════════════════════════
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
    v_orig_line_base_qty NUMERIC;
    v_orig_line_cost     NUMERIC;
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
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
    --    actually dispatched stock. Unit cost is the ORIGINAL invoice's
    --    own historical per-unit COGS, read back from its already-posted
    --    COS voucher — never a fresh current-average lookup, to keep this
    --    reversal symmetric with what the invoice itself posted.
    IF v_invoice.stock_dispatch_mode = 'IMMEDIATE' THEN
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

            -- Historical unit cost: original invoice line's own posted
            -- COS voucher STOCK line (base_amount) divided by that line's
            -- own original base_qty. source_doc_type/no/date live on
            -- rih_finance_headers (migration 037), NOT on rid_finance_lines
            -- itself (which only carries source_line_type/source_line_no,
            -- migration 050) — a join is required, not a direct filter.
            SELECT fl.base_amount INTO v_orig_line_cost
            FROM rid_finance_lines fl
            JOIN rih_finance_headers fh
              ON fh.client_id = fl.client_id AND fh.company_id = fl.company_id
             AND fh.location_id = fl.location_id AND fh.trans_no = fl.trans_no AND fh.trans_date = fl.trans_date
            WHERE fl.client_id = p_client_id AND fl.company_id = p_company_id
              AND fh.source_doc_type = 'SALES_INVOICE' AND fh.source_doc_no = v_header.invoice_no AND fh.source_doc_date = v_header.invoice_date
              AND fl.source_line_type = 'STOCK' AND fl.source_line_no = v_line.invoice_line_serial;

            SELECT base_qty INTO v_orig_line_base_qty
            FROM rid_sales_invoice_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
              AND serial_no = v_line.invoice_line_serial;

            IF v_orig_line_cost IS NULL OR coalesce(v_orig_line_base_qty, 0) = 0 THEN
                RAISE EXCEPTION 'ORIGINAL_COST_NOT_FOUND'
                    USING DETAIL = format('Line %s: could not find the original invoice line''s posted cost to reverse against.', v_line.serial_no);
            END IF;
            v_unit_cost := v_orig_line_cost / v_orig_line_base_qty;

            -- p_unit_cost_specific has no historical equivalent to read
            -- back (the invoice's own OUTWARD movement never needed a cost
            -- at all, let alone a specific-currency one) — it only feeds
            -- rim_product_location's own specific-currency weighted
            -- average (a secondary reporting field, never part of the GL
            -- amounts above, which use v_unit_cost/v_line_cost_total
            -- exclusively), so the CURRENT average is an acceptable
            -- approximation here, unlike the base cost which must be
            -- historical for Stock-DR/COGS-CR symmetry.
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

            -- Reverse of the invoice's own DR COGS / CR Stock: here
            -- DR Stock / CR COGS. Base currency throughout, party
            -- self-referential (same convention as every other purely-
            -- internal voucher, e.g. Material Issue's MIC lines).
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

        v_remaining_local := coalesce(v_invoice.collected_amount_local, 0) - v_already_refunded_local;
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
            -- NEW (114): tag this composed CPV's header — see this
            -- migration's own header comment for the full reasoning.
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
            -- NEW (114): tag this composed CPV's header — see this
            -- migration's own header comment for the full reasoning.
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

GRANT EXECUTE ON FUNCTION fn_approve_sales_return(UUID, UUID, TEXT, DATE, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_sales_delivery — verbatim from 102_sales_delivery.sql
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_sales_delivery(
    p_client_id    UUID,
    p_company_id   UUID,
    p_delivery_no  TEXT,
    p_delivery_date DATE,
    p_approved_by  UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_sales_delivery_headers%ROWTYPE;
    v_invoice            rih_sales_invoices%ROWTYPE;
    v_invoice_line       rid_sales_invoice_lines%ROWTYPE;
    v_base_ccy           TEXT;
    v_local_ccy          TEXT;
    v_base_to_local_rate NUMERIC;
    v_line               RECORD;
    v_stock_account      UUID;
    v_cos_account        UUID;
    v_unit_cost          NUMERIC;
    v_line_cost_total    NUMERIC;
    v_cos_lines          JSONB := '[]'::jsonb;
    v_cos_voucher_no     TEXT;
    v_cos_voucher_date   DATE;
    v_batch              rid_transaction_line_batches%ROWTYPE;
    v_serial_row         rid_transaction_line_serials%ROWTYPE;
    v_has_batches        BOOLEAN;
    v_has_serials        BOOLEAN;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_sales_delivery_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND delivery_no = p_delivery_no AND delivery_date = p_delivery_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Delivery % dated % not found', p_delivery_no, p_delivery_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Sales Delivery % is % and cannot be approved again', p_delivery_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-DEL');

    -- 2. Period + backdate + future-date checks. Req: future-date lock
    --    is a HARD rule, not a company-configurable opt-in — mirrors
    --    Material Issue's belt-and-suspenders pattern (both the soft
    --    config check AND the unconditional guard), not Sales Return's
    --    config-only check.
    PERFORM fn_check_period_open(p_company_id, p_delivery_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_DELIVERY', p_delivery_date);

    IF p_delivery_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Delivery date %s is in the future — a Sales Delivery cannot be dated ahead of today.', p_delivery_date);
    END IF;

    -- 3. Lock the source invoice — this single lock is what serializes
    --    every concurrent Delivery-approval against this invoice,
    --    regardless of which draft Delivery document they come from.
    SELECT * INTO v_invoice FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sales Invoice % not found', v_header.invoice_no;
    END IF;

    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_delivery_date);

    -- 4. Per line: cap check (fresh, under the invoice lock above) +
    --    stock dispatch + COS lines.
    FOR v_line IN
        SELECT * FROM rid_sales_delivery_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND delivery_no = p_delivery_no AND delivery_date = p_delivery_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT * INTO v_invoice_line
        FROM rid_sales_invoice_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND serial_no = v_line.invoice_line_serial
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'INVOICE_LINE_NOT_FOUND'
                USING DETAIL = format('Invoice %s has no line %s.', v_header.invoice_no, v_line.invoice_line_serial);
        END IF;

        IF v_invoice_line.delivered_qty + v_line.base_qty > v_invoice_line.base_qty THEN
            RAISE EXCEPTION 'DELIVERY_QTY_EXCEEDS_PENDING'
                USING DETAIL = format(
                    'Invoice %s line %s: already delivered %s of %s invoiced, this delivery adds %s more.',
                    v_header.invoice_no, v_line.invoice_line_serial,
                    v_invoice_line.delivered_qty, v_invoice_line.base_qty, v_line.base_qty);
        END IF;

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

        -- Current moving-average cost — a fresh outward movement, not a
        -- reversal, so unlike Sales Return there is no historical cost
        -- to stay symmetric with. Same lock pattern fn_approve_sales_
        -- invoice's own IMMEDIATE-mode block and fn_approve_material_
        -- issue already use.
        SELECT cost_price INTO v_unit_cost
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;
        v_unit_cost := coalesce(v_unit_cost, 0);

        v_has_batches := EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
              AND line_serial = v_line.serial_no
        );
        v_has_serials := EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
              AND line_serial = v_line.serial_no
        );

        v_line_cost_total := 0;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_delivery_date, 'SALES_DELIVERY', -v_batch.base_qty,
                    NULL, NULL, v_batch.batch_no, NULL, NULL,
                    'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
                );
                v_line_cost_total := v_line_cost_total + v_batch.base_qty * v_unit_cost;
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'SALES_DELIVERY' AND source_doc_no = p_delivery_no AND source_doc_date = p_delivery_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_delivery_date, 'SALES_DELIVERY', -1,
                    NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                    'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
                );
                v_line_cost_total := v_line_cost_total + v_unit_cost;
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_delivery_date, 'SALES_DELIVERY', -v_line.base_qty,
                NULL, NULL, NULL, NULL, NULL,
                'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
            );
            v_line_cost_total := v_line.base_qty * v_unit_cost;
        END IF;

        -- DR Cost of Sales / CR Stock — same purely-internal-voucher
        -- convention as every prior COS/MIC-style entry: base currency
        -- throughout, party self-referential.
        v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_cos_account, 'trans_nature', 'DR',
            'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
            'base_amount', v_line_cost_total, 'base_rate', 1,
            'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
            'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
            'source_line_type', 'COGS', 'source_line_no', v_line.serial_no
        ));
        v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_stock_account, 'trans_nature', 'CR',
            'trans_amount', v_line_cost_total, 'trans_currency', v_base_ccy,
            'base_amount', v_line_cost_total, 'base_rate', 1,
            'local_amount', v_line_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
            'party_amount', v_line_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
            'source_line_type', 'STOCK', 'source_line_no', v_line.serial_no
        ));

        -- Safe increment — under the invoice lock held since step 3, so
        -- there is no window for drift between the cap check above and
        -- this write.
        UPDATE rid_sales_invoice_lines SET delivered_qty = delivered_qty + v_line.base_qty
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = v_header.invoice_no AND invoice_date = v_header.invoice_date
          AND serial_no = v_line.invoice_line_serial;
    END LOOP;

    SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'COS', p_delivery_date,
        v_cos_lines, 'SALES_DELIVERY', p_delivery_no, p_delivery_date, p_approved_by
    );

    -- 5. Mark the delivery approved.
    UPDATE rih_sales_delivery_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        cos_voucher_no   = v_cos_voucher_no,
        cos_voucher_date = v_cos_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_delivery(UUID, UUID, TEXT, DATE, UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_cash_receipt — verbatim from 104_cash_receipt.sql
--
-- Also carries the new source_doc_type tagging on both composed CRV
-- legs (local/base) — see this migration's own header comment.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_cash_receipt(
    p_client_id    UUID,
    p_company_id   UUID,
    p_receipt_no   TEXT,
    p_receipt_date DATE,
    p_approved_by  UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header                     rih_cash_receipt_headers%ROWTYPE;
    v_base_ccy                   TEXT;
    v_local_ccy                  TEXT;
    v_local_to_base_rate         NUMERIC;
    v_base_to_local_rate         NUMERIC;
    v_local_cash_account         UUID;
    v_base_cash_account          UUID;
    v_line                       RECORD;
    v_bill                       rid_finance_lines%ROWTYPE;
    v_party_rate                 NUMERIC;
    v_party_amount_line          NUMERIC;
    v_live_balance                NUMERIC;
    v_proportional_base_line     NUMERIC;
    v_remaining_local             NUMERIC;
    v_remaining_base_local_equiv  NUMERIC;
    v_local_portion               NUMERIC;
    v_base_portion                NUMERIC;
    v_local_fragments             JSONB := '[]'::jsonb;
    v_base_fragments              JSONB := '[]'::jsonb;
    v_frag                        JSONB;
    v_crv_local_lines             JSONB;
    v_crv_base_lines              JSONB;
    v_serial                      INTEGER;
    v_trans_amt                   NUMERIC;
    v_base_amt                    NUMERIC;
    v_crv_local_no                TEXT;
    v_crv_local_date              DATE;
    v_crv_base_no                 TEXT;
    v_crv_base_date               DATE;
    v_net_fx_diff                 NUMERIC := 0;
    v_exc_lines                   JSONB;
    v_exc_voucher_no              TEXT;
    v_exc_voucher_date            DATE;
    v_fx_account                  UUID;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_cash_receipt_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cash Receipt % dated % not found', p_receipt_no, p_receipt_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Cash Receipt % is % and cannot be approved again', p_receipt_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never a client-supplied parameter) — see migration 108's own
    -- header comment for the full reasoning.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'SL-RCP');

    -- 2. Period + backdate + future-date checks. Future-date lock is a
    --    HARD rule, not a company-configurable opt-in — belt-and-
    --    suspenders pair (soft config check + unconditional guard),
    --    same as Sales Delivery/Material Issue.
    PERFORM fn_check_period_open(p_company_id, p_receipt_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'CASH_RECEIPT', p_receipt_date);

    IF p_receipt_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Receipt date %s is in the future — a Cash Receipt cannot be dated ahead of today.', p_receipt_date);
    END IF;

    -- 3. Resolve currencies, rates, cash accounts (from the CREATOR —
    --    cash sits in that cashier's drawer, same reasoning already
    --    established for Quick Invoice).
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_local_to_base_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_base_ccy, p_receipt_date);
    v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_receipt_date);

    v_local_cash_account := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
    v_base_cash_account  := fn_quick_cash_account_base(p_client_id, p_company_id, v_header.created_by);

    IF v_header.local_amount > 0 AND v_local_cash_account IS NULL THEN
        RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
            USING DETAIL = 'The user who created this receipt has no Quick Invoice Setup (Local Cash Account) — cannot collect cash.';
    END IF;
    IF v_header.base_amount > 0 AND v_base_cash_account IS NULL THEN
        RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
            USING DETAIL = 'The user who created this receipt has no Quick Invoice Setup (Base Cash Account) — cannot collect cash.';
    END IF;

    -- 4. Per line — lock+re-validate each bill (one row per statement,
    --    over a pre-sorted key list, never ORDER BY ... FOR UPDATE),
    --    compute settlement amounts, and waterfall-split this line's
    --    applied_amount_local across the local pool (first) then the
    --    base pool (remainder) into "fragments" — a single bill can
    --    straddle both pools.
    v_remaining_local            := v_header.local_amount;
    v_remaining_base_local_equiv := v_header.base_amount * v_base_to_local_rate;

    FOR v_line IN
        SELECT * FROM rid_cash_receipt_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date AND is_deleted = false
        ORDER BY inv_bill_no, inv_bill_date
    LOOP
        SELECT * INTO v_bill FROM rid_finance_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id
          AND trans_no = v_line.inv_bill_no AND trans_date = v_line.inv_bill_date
          AND account_id = v_header.customer_id AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'PENDING_BILL_NOT_FOUND'
                USING DETAIL = format('Invoice/bill %s dated %s was not found for this customer at this location — it may have been reassigned since this receipt was saved.', v_line.inv_bill_no, v_line.inv_bill_date);
        END IF;

        -- Convert this line's LOCAL-currency applied amount into the
        -- bill's own party currency, fresh at approve time (never trust
        -- save-time values) — this is what actually settles the bill.
        v_party_rate        := fn_get_exchange_rate(p_company_id, v_header.location_id, v_local_ccy, v_bill.party_currency, p_receipt_date);
        v_party_amount_line := v_line.applied_amount_local * v_party_rate;

        v_live_balance := v_bill.party_amount - v_bill.settled_amount;
        IF v_party_amount_line > v_live_balance + 0.01 THEN
            RAISE EXCEPTION 'RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE'
                USING DETAIL = format('Invoice %s: remaining balance is %s %s but this receipt applies %s %s — it may have been partly settled by another receipt since this one was saved.',
                                       v_line.inv_bill_no, v_live_balance, v_bill.party_currency, v_party_amount_line, v_bill.party_currency);
        END IF;

        -- Proportional ORIGINAL base share — uses the bill's ORIGINAL
        -- total party_amount (never the remaining balance), which fixes
        -- the "per party-currency-unit" originally-booked rate,
        -- consistent across however many receipts eventually clear this
        -- one bill over time.
        v_proportional_base_line := v_bill.base_amount * (v_party_amount_line / NULLIF(v_bill.party_amount, 0));

        v_local_portion := LEAST(v_line.applied_amount_local, GREATEST(v_remaining_local, 0));
        v_base_portion  := v_line.applied_amount_local - v_local_portion;

        IF v_base_portion > v_remaining_base_local_equiv + 0.01 THEN
            RAISE EXCEPTION 'RECEIPT_AMOUNT_MISMATCH'
                USING DETAIL = 'Applied amounts exceed the cash pools entered on this receipt — save the receipt again to re-validate.';
        END IF;

        v_remaining_local            := v_remaining_local - v_local_portion;
        v_remaining_base_local_equiv := v_remaining_base_local_equiv - v_base_portion;

        IF v_local_portion > 0.0001 THEN
            v_local_fragments := v_local_fragments || jsonb_build_array(jsonb_build_object(
                'inv_bill_no', v_line.inv_bill_no, 'inv_bill_date', v_line.inv_bill_date,
                'party_currency', v_bill.party_currency,
                'local_equiv', v_local_portion,
                'party_amount', v_party_amount_line * (v_local_portion / v_line.applied_amount_local),
                'proportional_original_base', v_proportional_base_line * (v_local_portion / v_line.applied_amount_local)
            ));
        END IF;
        IF v_base_portion > 0.0001 THEN
            v_base_fragments := v_base_fragments || jsonb_build_array(jsonb_build_object(
                'inv_bill_no', v_line.inv_bill_no, 'inv_bill_date', v_line.inv_bill_date,
                'party_currency', v_bill.party_currency,
                'local_equiv', v_base_portion,
                'party_amount', v_party_amount_line * (v_base_portion / v_line.applied_amount_local),
                'proportional_original_base', v_proportional_base_line * (v_base_portion / v_line.applied_amount_local)
            ));
        END IF;
    END LOOP;

    -- 5. Build + post CRV-LOCAL, if any fragments were funded from the
    --    local pool. Line 1 = Cash DR; lines 2+ = one Customer CR per
    --    fragment, account_id/inv_bill_no/inv_bill_date taken EXACTLY
    --    from the bill's own row — never re-derived, or
    --    fn_post_finance_voucher's settlement lookup silently fails to
    --    find a match.
    IF jsonb_array_length(v_local_fragments) > 0 THEN
        v_trans_amt := 0;
        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_local_fragments) LOOP
            v_trans_amt := v_trans_amt + (v_frag->>'local_equiv')::numeric;
        END LOOP;

        v_serial := 1;
        v_crv_local_lines := jsonb_build_array(jsonb_build_object(
            'serial_no', v_serial, 'account_id', v_local_cash_account, 'trans_nature', 'DR',
            'trans_amount', v_trans_amt, 'trans_currency', v_local_ccy,
            'base_amount', v_trans_amt * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
            'local_amount', v_trans_amt, 'local_rate', 1,
            'party_amount', v_trans_amt, 'party_currency', v_local_ccy, 'party_rate', 1
        ));

        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_local_fragments) LOOP
            v_serial := v_serial + 1;
            v_crv_local_lines := v_crv_local_lines || jsonb_build_array(jsonb_build_object(
                'serial_no', v_serial, 'account_id', v_header.customer_id, 'trans_nature', 'CR',
                'trans_amount', (v_frag->>'local_equiv')::numeric, 'trans_currency', v_local_ccy,
                'base_amount', (v_frag->>'local_equiv')::numeric * v_local_to_base_rate, 'base_rate', v_local_to_base_rate,
                'local_amount', (v_frag->>'local_equiv')::numeric, 'local_rate', 1,
                'party_amount', (v_frag->>'party_amount')::numeric, 'party_currency', v_frag->>'party_currency',
                'party_rate', CASE WHEN (v_frag->>'local_equiv')::numeric = 0 THEN 1 ELSE (v_frag->>'party_amount')::numeric / (v_frag->>'local_equiv')::numeric END,
                'inv_bill_no', v_frag->>'inv_bill_no', 'inv_bill_date', v_frag->>'inv_bill_date'
            ));

            v_net_fx_diff := v_net_fx_diff + (
                (v_frag->>'local_equiv')::numeric * v_local_to_base_rate - (v_frag->>'proportional_original_base')::numeric
            );
        END LOOP;

        v_crv_local_no := fn_save_finance_voucher(
            jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_receipt_date,
                'voucher_type_code', 'CRV', 'payment_mode_code', 'CASH', 'is_on_account', false,
                'remarks', format('Cash Collection %s', p_receipt_no)
            ),
            v_crv_local_lines, p_approved_by
        );
        -- NEW (114): tag this composed CRV's header — see this
        -- migration's own header comment for the full reasoning.
        UPDATE rih_finance_headers SET
            source_doc_type = 'CASH_RECEIPT', source_doc_no = p_receipt_no, source_doc_date = p_receipt_date
        WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
          AND trans_no = v_crv_local_no AND trans_date = p_receipt_date;
        PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_crv_local_no, p_receipt_date, p_approved_by);
        v_crv_local_date := p_receipt_date;
    END IF;

    -- 6. Build + post CRV-BASE identically, if any fragments were
    --    funded from the base pool. A fragment's actual base-currency
    --    trans_amount is its local-equivalent portion divided by the
    --    SAME base->local rate that produced that local-equivalent
    --    value in step 4 — the precise algebraic inverse, not a fresh
    --    (and potentially non-reciprocal-by-rounding) lookup.
    IF jsonb_array_length(v_base_fragments) > 0 THEN
        v_trans_amt := 0;
        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_base_fragments) LOOP
            v_trans_amt := v_trans_amt + (v_frag->>'local_equiv')::numeric / v_base_to_local_rate;
        END LOOP;

        v_serial := 1;
        v_crv_base_lines := jsonb_build_array(jsonb_build_object(
            'serial_no', v_serial, 'account_id', v_base_cash_account, 'trans_nature', 'DR',
            'trans_amount', v_trans_amt, 'trans_currency', v_base_ccy,
            'base_amount', v_trans_amt, 'base_rate', 1,
            'local_amount', v_trans_amt * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
            'party_amount', v_trans_amt, 'party_currency', v_base_ccy, 'party_rate', 1
        ));

        FOR v_frag IN SELECT * FROM jsonb_array_elements(v_base_fragments) LOOP
            v_serial   := v_serial + 1;
            v_base_amt := (v_frag->>'local_equiv')::numeric / v_base_to_local_rate;
            v_crv_base_lines := v_crv_base_lines || jsonb_build_array(jsonb_build_object(
                'serial_no', v_serial, 'account_id', v_header.customer_id, 'trans_nature', 'CR',
                'trans_amount', v_base_amt, 'trans_currency', v_base_ccy,
                'base_amount', v_base_amt, 'base_rate', 1,
                'local_amount', v_base_amt * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                'party_amount', (v_frag->>'party_amount')::numeric, 'party_currency', v_frag->>'party_currency',
                'party_rate', CASE WHEN v_base_amt = 0 THEN 1 ELSE (v_frag->>'party_amount')::numeric / v_base_amt END,
                'inv_bill_no', v_frag->>'inv_bill_no', 'inv_bill_date', v_frag->>'inv_bill_date'
            ));

            v_net_fx_diff := v_net_fx_diff + (v_base_amt - (v_frag->>'proportional_original_base')::numeric);
        END LOOP;

        v_crv_base_no := fn_save_finance_voucher(
            jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_receipt_date,
                'voucher_type_code', 'CRV', 'payment_mode_code', 'CASH', 'is_on_account', false,
                'remarks', format('Cash Collection %s', p_receipt_no)
            ),
            v_crv_base_lines, p_approved_by
        );
        -- NEW (114): tag this composed CRV's header — see this
        -- migration's own header comment for the full reasoning.
        UPDATE rih_finance_headers SET
            source_doc_type = 'CASH_RECEIPT', source_doc_no = p_receipt_no, source_doc_date = p_receipt_date
        WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
          AND trans_no = v_crv_base_no AND trans_date = p_receipt_date;
        PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_crv_base_no, p_receipt_date, p_approved_by);
        v_crv_base_date := p_receipt_date;
    END IF;

    -- 7. FX gain/loss — company-level EXCHANGE_GAIN_LOSS_ACCOUNT, no
    --    product anchor exists for this document. Both lines natively
    --    in base currency (mirrors Purchase Bill's EXC pattern exactly)
    --    — no inv_bill_no on the customer line, pure GL valuation
    --    adjustment, invisible to v_pending_bills.
    IF abs(v_net_fx_diff) > 0.0001 THEN
        v_fx_account := fn_resolve_company_account_link(p_client_id, p_company_id, 'EXCHANGE_GAIN_LOSS_ACCOUNT');
        IF v_fx_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = 'No Exchange Gain/Loss Account configured at Company level — cannot post the currency revaluation on this receipt.';
        END IF;

        IF v_net_fx_diff < 0 THEN
            -- Collected less base value than proportionally booked: LOSS
            v_exc_lines := jsonb_build_array(
                jsonb_build_object('account_id', v_fx_account, 'trans_nature', 'DR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1),
                jsonb_build_object('account_id', v_header.customer_id, 'trans_nature', 'CR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1)
            );
        ELSE
            -- Collected more base value than proportionally booked: GAIN
            v_exc_lines := jsonb_build_array(
                jsonb_build_object('account_id', v_header.customer_id, 'trans_nature', 'DR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1),
                jsonb_build_object('account_id', v_fx_account, 'trans_nature', 'CR',
                    'trans_amount', abs(v_net_fx_diff), 'trans_currency', v_base_ccy,
                    'base_amount', abs(v_net_fx_diff), 'base_rate', 1,
                    'local_amount', abs(v_net_fx_diff) * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                    'party_amount', abs(v_net_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1)
            );
        END IF;

        SELECT trans_no, trans_date INTO v_exc_voucher_no, v_exc_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'EXC', p_receipt_date,
            v_exc_lines, 'CASH_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
        );
    END IF;

    -- 8. Mark receipt approved.
    UPDATE rih_cash_receipt_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        crv_local_voucher_no = v_crv_local_no,   crv_local_voucher_date = v_crv_local_date,
        crv_base_voucher_no  = v_crv_base_no,    crv_base_voucher_date  = v_crv_base_date,
        exc_voucher_no       = v_exc_voucher_no, exc_voucher_date       = v_exc_voucher_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_cash_receipt(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
