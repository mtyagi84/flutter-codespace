-- ============================================================
-- Migration 090: Sales Invoice numbering/posting voucher-code split
-- ============================================================
-- Real gap flagged in docs/screens/sales_invoice.md §6 bug 17 (found
-- 2026-07-17, deferred at the time as "cosmetic, not a money-math bug"):
-- 'SI' was used for BOTH invoice_no numbering (fn_next_trans_no, at Save,
-- 089 line 591) AND the Sales GL voucher's own trans_no (fn_post_voucher,
-- at Approve, 089 line 1253). ril_trans_no_seq keys its counter purely on
-- (company, location, voucher_type_code), so every approval silently
-- consumed/skipped a number from the invoice_no sequence, and the printed
-- invoice_no never matched its own GL voucher's trans_no. Same
-- "numbering code must differ from posting code" anti-pattern already
-- fixed for Purchase Bill (PINV/PUR, 055) and Material Issue (MISS/MIC,
-- 068) — this migration applies the identical fix to Sales Invoice.
--
-- 'SI' stays the numbering code (invoice_no keeps its existing format —
-- no reprint/relabel of anything already issued). 'SLS' (Sales Voucher)
-- is a brand-new voucher_type_code used ONLY by fn_approve_sales_invoice's
-- fn_post_voucher call for the SI/Customer/Sales/Tax/Charges lines —
-- mirrors 055's PUR exactly, reusing the same voucher_nature ('SALES',
-- already widened onto the CHECK constraint by 081) and the same
-- '{TYPE}/{LOC}/{YYYY}/{SEQ5}' format. The COS voucher already had its
-- own distinct 'COS' code from day one and is untouched here.
--
-- Forward-only, per user decision: already-APPROVED invoices keep their
-- existing sales_voucher_no (drawn from the old shared 'SI' counter)
-- untouched — Immutability principle, never edit a posted voucher's
-- trans_no in place. Only invoices approved AFTER this migration runs
-- draw a voucher number from the new, independent 'SLS' counter.
--
-- fn_approve_sales_invoice is reproduced here verbatim from 089 with
-- exactly one literal changed (the fn_post_voucher call's
-- voucher_type_code, 'SI' -> 'SLS') — CREATE OR REPLACE FUNCTION on an
-- unchanged parameter list is safe to re-run (see CLAUDE.md's migration-
-- idempotency notes), but every other line must match 089 exactly or
-- this migration would silently regress an already-tested function.
-- ============================================================

INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('SLS', 'Sales Voucher', 'SALES', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;

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
