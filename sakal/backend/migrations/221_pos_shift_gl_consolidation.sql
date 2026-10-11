-- ============================================================================
-- Migration 221: consolidate POS cash-sale Sales/Tax/COGS GL to ONE voucher
-- pair per shift (at close), instead of one pair per invoice
-- ============================================================================
-- Per the user's own explicit decision (2026-10-11, after being shown the
-- real trade-off): matches how Odoo POS handles high-volume till sales —
-- stock moves in real time per sale (inventory can't wait), but the
-- *accounting* entry is posted once per session, grouped by account/tax,
-- to avoid GL row growth multiplying by every single till receipt.
--
-- SCOPE, deliberately narrow (every exclusion below keeps today's proven,
-- already-correct immediate-posting path completely untouched):
--   - Only a POS sale (pos_shift_id IS NOT NULL) — back-office Quick
--     Invoice (pos_shift_id IS NULL) ALWAYS posts immediately, unchanged.
--   - Only CASH sale_type — CREDIT always posts immediately (a real
--     receivable must hit the ledger the moment it's created).
--   - Only a sale FULLY covered by cash (collected_amount_local >=
--     grand_total) — a split-tender sale with ANY card/mobile/voucher/
--     gift-card/store-credit portion posts immediately. Reason: non-cash
--     settlement (fn_settle_pos_non_cash_tenders, migration 218) finds
--     its Customer DR line by this SPECIFIC invoice's own source_doc_no
--     — a line that would no longer exist per-invoice if consolidated.
--     A 100%-cash sale has no such dependency: its Customer DR and the
--     Cash settlement CR are a complete, immediate wash (money in =
--     money owed, same amount, same moment), so this design skips that
--     round-trip ENTIRELY for a deferred sale and goes straight to one
--     Cash DR line instead — not an approximation, the literal net effect
--     of what today's two-voucher dance (SLS's Customer DR + a separate
--     CRV's Cash DR/Customer CR) already nets to for a 100%-cash sale.
--
-- Deferred lines are stored as JSONB directly on the invoice itself
-- (deferred_si_lines/deferred_cos_lines) rather than a new staging table
-- — keeps the computation (account resolution, tax apportionment, cost
-- lookup — all unchanged, still computed once, right here) as the single
-- source of truth; consolidation is a pure, dumb SQL aggregation over
-- those same already-computed lines, never a second, divergent
-- computation path.
-- ============================================================================

ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS gl_consolidated BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS deferred_si_lines JSONB;
ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS deferred_cos_lines JSONB;

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
    v_bundle_id                UUID;
    v_bundle_component          RECORD;
    v_component_tracked          BOOLEAN;
    v_component_stock_account      UUID;
    v_component_cos_account         UUID;
    v_component_cost_price            NUMERIC;
    v_component_cost_source            TEXT;
    v_component_qty                      NUMERIC;
    v_component_cost_total                NUMERIC;
    v_defer_gl              BOOLEAN; -- NEW (221)
    -- NEW (221): plain scalars for the final UPDATE, set explicitly inside
    -- whichever branch actually runs — never a CASE expression touching a
    -- field of v_si_result, which errors as "not-yet-assigned" the moment
    -- that expression is evaluated AT ALL when v_si_result was never
    -- assigned in this execution (a RECORD's row type is only known once
    -- assigned; PL/pgSQL can't resolve a field reference on it even
    -- inside a CASE branch that won't execute at runtime) — caught live.
    v_final_sales_voucher_no   TEXT;
    v_final_sales_voucher_date DATE;
    v_final_cos_voucher_no     TEXT;
    v_final_cos_voucher_date   DATE;
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

    PERFORM fn_check_approve_permission(p_client_id, p_company_id, CASE WHEN v_header.sale_type = 'CREDIT' THEN 'SL-CINV' ELSE 'SL-INV' END);

    PERFORM fn_check_period_open(p_company_id, p_invoice_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'SALES_INVOICE', p_invoice_date);

    SELECT currency_id INTO v_invoice_ccy FROM rim_currencies WHERE id = v_header.invoice_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- NEW (221): see this migration's own header comment for the exact
    -- scope — only a 100%-cash POS sale with no non-cash tender portion.
    v_defer_gl := v_header.pos_shift_id IS NOT NULL
        AND v_header.sale_type = 'CASH'
        AND coalesce(v_header.collected_amount_local, 0) >= v_header.grand_total - 0.01
        AND coalesce(v_header.collected_amount_base, 0) = 0;

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

    IF v_defer_gl THEN
        -- Skip the Customer DR entirely — see header comment: a 100%-cash
        -- sale's Customer DR + its own cash-settlement CR are a complete,
        -- immediate wash, so go straight to one Cash DR line instead.
        v_cash_account_local := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
        IF v_cash_account_local IS NULL THEN
            RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                USING DETAIL = 'The user who created this invoice has no Quick Invoice Setup (Local Cash Account) — cannot collect cash.';
        END IF;
        v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_cash_account_local, 'trans_nature', 'DR',
            'trans_amount', v_header.collected_amount_local, 'trans_currency', v_invoice_ccy,
            'base_amount', v_header.collected_amount_local * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_header.collected_amount_local * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_header.collected_amount_local, 'party_currency', v_invoice_ccy, 'party_rate', 1,
            'source_line_type', 'POS_CASH', 'source_line_no', 0
        ));
    ELSE
        v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_header.customer_id, 'trans_nature', 'DR',
            'trans_amount', v_header.grand_total, 'trans_currency', v_invoice_ccy,
            'base_amount', v_header.grand_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_header.grand_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_header.grand_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'inv_bill_no', p_invoice_no, 'inv_bill_date', p_invoice_date,
            'source_line_type', 'CUSTOMER', 'source_line_no', 0
        ));
    END IF;

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

    -- NEW (221): post the SLS voucher immediately only when NOT deferring.
    IF NOT v_defer_gl THEN
        SELECT * INTO v_si_result FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'SLS', p_invoice_date,
            v_si_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
        );
        v_final_sales_voucher_no := v_si_result.trans_no;
        v_final_sales_voucher_date := v_si_result.trans_date;

        UPDATE rid_finance_lines SET
            inv_bill_no   = v_si_result.trans_no,
            inv_bill_date = v_si_result.trans_date
        WHERE client_id       = p_client_id
          AND company_id      = p_company_id
          AND location_id     = v_header.location_id
          AND trans_no        = v_si_result.trans_no
          AND trans_date      = v_si_result.trans_date
          AND source_line_type = 'CUSTOMER' AND source_line_no = 0;
    END IF;

    -- Stock dispatch + COGS line computation — UNCHANGED, unconditional
    -- regardless of v_defer_gl: inventory moves in real time per sale
    -- either way. Only the FINAL fn_post_voucher('COS') call at the very
    -- end of this block is skipped when deferring.
    IF v_header.stock_dispatch_mode = 'IMMEDIATE' THEN
        v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date);

        FOR v_line IN
            SELECT * FROM rid_sales_invoice_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
            ORDER BY product_id
        LOOP
            SELECT id INTO v_bundle_id FROM rim_product_bundles
            WHERE bundle_product_id = v_line.product_id AND bundle_mode = 'COMMERCIAL' AND is_deleted = false;

            IF v_bundle_id IS NOT NULL THEN
                FOR v_bundle_component IN
                    SELECT * FROM rim_bundle_components WHERE bundle_id = v_bundle_id AND is_deleted = false
                LOOP
                    SELECT tracking_type != 'NONE' INTO v_component_tracked
                    FROM rim_products WHERE id = v_bundle_component.component_product_id;
                    IF v_component_tracked THEN
                        RAISE EXCEPTION 'BUNDLE_COMPONENT_TRACKING_NOT_SUPPORTED'
                            USING DETAIL = format('Line %s: bundle component %s is batch/serial-tracked — not yet supported for a Commercial bundle sale.',
                                v_line.serial_no,
                                (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_bundle_component.component_product_id));
                    END IF;

                    v_component_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_bundle_component.component_product_id, 'STOCK_ACCOUNT');
                    v_component_cos_account   := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_bundle_component.component_product_id, 'COST_OF_SALES_ACCOUNT');
                    IF v_component_stock_account IS NULL OR v_component_cos_account IS NULL THEN
                        RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                            USING DETAIL = format('Line %s: bundle component %s has no Stock/Cost of Sales account configured.',
                                v_line.serial_no,
                                (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_bundle_component.component_product_id));
                    END IF;

                    PERFORM 1 FROM rim_product_location
                    WHERE client_id = p_client_id AND company_id = p_company_id
                      AND location_id = v_header.location_id AND product_id = v_bundle_component.component_product_id
                    FOR UPDATE;

                    SELECT g.cost_price, g.cost_source INTO v_component_cost_price, v_component_cost_source
                    FROM fn_get_cost_price(p_client_id, p_company_id, v_header.location_id, v_bundle_component.component_product_id, 'B', p_invoice_date) g;
                    IF v_component_cost_source = 'NONE' THEN
                        RAISE EXCEPTION 'COST_PRICE_NOT_AVAILABLE'
                            USING DETAIL = format('Line %s: bundle component %s has no cost price established.',
                                v_line.serial_no,
                                (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_bundle_component.component_product_id));
                    END IF;

                    v_component_qty := v_line.base_qty * v_bundle_component.component_qty;
                    v_component_cost_total := v_component_qty * coalesce(v_component_cost_price, 0);

                    PERFORM fn_post_stock_movement(
                        p_client_id, p_company_id, v_header.location_id, v_bundle_component.component_product_id,
                        p_invoice_date, 'SALES_INVOICE', -v_component_qty,
                        NULL, NULL, NULL, NULL, NULL,
                        'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
                    );

                    INSERT INTO rid_sales_invoice_line_bundle_components (
                        client_id, company_id, invoice_no, invoice_date, line_serial,
                        component_product_id, component_qty, component_cost_price
                    ) VALUES (
                        p_client_id, p_company_id, p_invoice_no, p_invoice_date, v_line.serial_no,
                        v_bundle_component.component_product_id, v_component_qty, v_component_cost_price
                    );

                    v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_component_cos_account, 'trans_nature', 'DR',
                        'trans_amount', v_component_cost_total, 'trans_currency', v_base_ccy,
                        'base_amount', v_component_cost_total, 'base_rate', 1,
                        'local_amount', v_component_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                        'party_amount', v_component_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                        'source_line_type', 'COGS_BUNDLE', 'source_line_no', v_line.serial_no
                    ));
                    v_cos_lines := v_cos_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_component_stock_account, 'trans_nature', 'CR',
                        'trans_amount', v_component_cost_total, 'trans_currency', v_base_ccy,
                        'base_amount', v_component_cost_total, 'base_rate', 1,
                        'local_amount', v_component_cost_total * v_base_to_local_rate, 'local_rate', v_base_to_local_rate,
                        'party_amount', v_component_cost_total, 'party_currency', v_base_ccy, 'party_rate', 1,
                        'source_line_type', 'STOCK_BUNDLE', 'source_line_no', v_line.serial_no
                    ));
                END LOOP;
                CONTINUE;
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

            IF v_line.cost_price IS NULL THEN
                RAISE EXCEPTION 'COST_PRICE_NOT_AVAILABLE'
                    USING DETAIL = format('Line %s: [%s] %s has no cost price recorded — it must be received (GRN) or given a Standard Cost before this invoice can be approved.',
                        v_line.serial_no,
                        (SELECT product_code FROM rim_products WHERE id = v_line.product_id),
                        (SELECT product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;

            PERFORM 1 FROM rim_product_location
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND location_id = v_header.location_id AND product_id = v_line.product_id
            FOR UPDATE;

            v_unit_cost := v_line.cost_price * v_header.rate_to_base;

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

        -- NEW (221): post the COS voucher immediately only when NOT deferring.
        IF NOT v_defer_gl THEN
            SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
                p_client_id, p_company_id, v_header.location_id, 'COS', p_invoice_date,
                v_cos_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
            );
            v_final_cos_voucher_no := v_cos_voucher_no;
            v_final_cos_voucher_date := v_cos_voucher_date;
        END IF;
    END IF;

    -- NEW (221): the "cash collection" settlement block is skipped
    -- entirely when deferring — its Cash DR is already embedded in
    -- v_si_lines above (see the v_defer_gl branch near the top), and its
    -- Customer CR has no counterpart to settle against (there is no
    -- Customer DR on a deferred invoice at all).
    IF v_header.cash_collection_mode = 'IMMEDIATE' AND NOT v_defer_gl THEN
        IF coalesce(v_header.collected_amount_local, 0) > 0 OR coalesce(v_header.collected_amount_base, 0) > 0 THEN
            v_cash_account_local := fn_quick_cash_account_local(p_client_id, p_company_id, v_header.created_by);
            v_cash_account_base  := fn_quick_cash_account_base(p_client_id, p_company_id, v_header.created_by);
        END IF;

        IF coalesce(v_header.collected_amount_local, 0) > 0 THEN
            IF v_cash_account_local IS NULL THEN
                RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                    USING DETAIL = 'The user who created this invoice has no Quick Invoice Setup (Local Cash Account) — cannot collect cash.';
            END IF;

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
            UPDATE rih_finance_headers SET
                source_doc_type = 'SALES_INVOICE', source_doc_no = p_invoice_no, source_doc_date = p_invoice_date
            WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
              AND trans_no = v_receipt_no AND trans_date = p_invoice_date;
            PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_invoice_date, p_approved_by);
            UPDATE rih_sales_invoices SET base_receipt_voucher_no = v_receipt_no, base_receipt_voucher_date = p_invoice_date WHERE id = v_header.id;
        END IF;
    END IF;

    -- NEW (221): when deferred, store the computed lines for later
    -- shift-close consolidation instead of real voucher numbers.
    UPDATE rih_sales_invoices SET
        status              = 'APPROVED',
        approved_by         = p_approved_by,
        approved_at         = now(),
        sales_voucher_no    = v_final_sales_voucher_no,
        sales_voucher_date  = v_final_sales_voucher_date,
        cos_voucher_no      = v_final_cos_voucher_no,
        cos_voucher_date    = v_final_cos_voucher_date,
        gl_consolidated     = NOT v_defer_gl,
        deferred_si_lines   = CASE WHEN v_defer_gl THEN v_si_lines ELSE NULL END,
        deferred_cos_lines  = CASE WHEN v_defer_gl THEN v_cos_lines ELSE NULL END,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_sales_invoice(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ============================================================================
-- fn_consolidate_pos_shift_finance — the aggregator. Pure SQL: groups every
-- qualifying invoice's own already-computed deferred_si_lines/deferred_cos_
-- lines by (account_id, trans_nature, trans_currency) and posts ONE SLS +
-- (if any stock dispatched) ONE COS voucher for the whole shift. Called by
-- fn_close_pos_shift (migration 222) right before it finalizes the shift —
-- never called standalone from the client, so it always runs inside the
-- same transaction as the close itself.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_consolidate_pos_shift_finance(
    p_client_id   UUID,
    p_company_id  UUID,
    p_shift_id    UUID,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_shift          rih_pos_shifts%ROWTYPE;
    v_agg_si         JSONB;
    v_agg_cos        JSONB;
    v_sls_result     RECORD;
    v_cos_voucher_no TEXT;
    v_cos_voucher_date DATE;
    v_today          DATE := CURRENT_DATE;
BEGIN
    SELECT * INTO v_shift FROM rih_pos_shifts WHERE id = p_shift_id;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT jsonb_agg(jsonb_build_object(
        'serial_no', rn,
        'account_id', account_id, 'trans_nature', trans_nature,
        'trans_amount', total_trans, 'trans_currency', trans_currency,
        'base_amount', total_base, 'base_rate', 1,
        'local_amount', total_local, 'local_rate', 1,
        'party_amount', total_trans, 'party_currency', trans_currency, 'party_rate', 1
    )) INTO v_agg_si
    FROM (
        SELECT row_number() OVER () AS rn, account_id, trans_nature, trans_currency, total_trans, total_base, total_local
        FROM (
            SELECT line.account_id, line.trans_nature, line.trans_currency,
                   sum(line.trans_amount) AS total_trans, sum(line.base_amount) AS total_base, sum(line.local_amount) AS total_local
            FROM rih_sales_invoices si
            CROSS JOIN LATERAL jsonb_to_recordset(si.deferred_si_lines)
                AS line(account_id uuid, trans_nature text, trans_currency text, trans_amount numeric, base_amount numeric, local_amount numeric)
            WHERE si.client_id = p_client_id AND si.company_id = p_company_id
              AND si.pos_shift_id = p_shift_id AND si.gl_consolidated = false AND si.status = 'APPROVED'
              AND si.deferred_si_lines IS NOT NULL
            GROUP BY line.account_id, line.trans_nature, line.trans_currency
        ) grouped
    ) agg;

    IF v_agg_si IS NULL OR jsonb_array_length(v_agg_si) = 0 THEN
        RETURN; -- no deferred cash sales this shift — nothing to consolidate
    END IF;

    SELECT jsonb_agg(jsonb_build_object(
        'serial_no', rn,
        'account_id', account_id, 'trans_nature', trans_nature,
        'trans_amount', total_trans, 'trans_currency', trans_currency,
        'base_amount', total_base, 'base_rate', 1,
        'local_amount', total_local, 'local_rate', 1,
        'party_amount', total_trans, 'party_currency', trans_currency, 'party_rate', 1
    )) INTO v_agg_cos
    FROM (
        SELECT row_number() OVER () AS rn, account_id, trans_nature, trans_currency, total_trans, total_base, total_local
        FROM (
            SELECT line.account_id, line.trans_nature, line.trans_currency,
                   sum(line.trans_amount) AS total_trans, sum(line.base_amount) AS total_base, sum(line.local_amount) AS total_local
            FROM rih_sales_invoices si
            CROSS JOIN LATERAL jsonb_to_recordset(si.deferred_cos_lines)
                AS line(account_id uuid, trans_nature text, trans_currency text, trans_amount numeric, base_amount numeric, local_amount numeric)
            WHERE si.client_id = p_client_id AND si.company_id = p_company_id
              AND si.pos_shift_id = p_shift_id AND si.gl_consolidated = false AND si.status = 'APPROVED'
              AND si.deferred_cos_lines IS NOT NULL
            GROUP BY line.account_id, line.trans_nature, line.trans_currency
        ) grouped
    ) agg;

    SELECT * INTO v_sls_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_shift.location_id, 'SLS', v_today,
        v_agg_si, 'POS_SHIFT', v_shift.shift_no, v_today, p_approved_by
    );

    IF v_agg_cos IS NOT NULL AND jsonb_array_length(v_agg_cos) > 0 THEN
        SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_shift.location_id, 'COS', v_today,
            v_agg_cos, 'POS_SHIFT', v_shift.shift_no, v_today, p_approved_by
        );
    END IF;

    UPDATE rih_sales_invoices SET
        gl_consolidated    = true,
        sales_voucher_no   = v_sls_result.trans_no,
        sales_voucher_date = v_sls_result.trans_date,
        cos_voucher_no     = v_cos_voucher_no,
        cos_voucher_date   = v_cos_voucher_date,
        deferred_si_lines  = NULL,
        deferred_cos_lines = NULL
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND pos_shift_id = p_shift_id AND gl_consolidated = false AND status = 'APPROVED';
END;
$$;
GRANT EXECUTE ON FUNCTION fn_consolidate_pos_shift_finance(UUID, UUID, UUID, UUID) TO authenticated;
