-- ============================================================
-- Migration 059: Purchase Invoice's Exchange Gain/Loss becomes its own
-- separate EXC voucher, not a plug line inside the PUR voucher
-- ============================================================
-- Found via review: 054/055/058's Exchange Gain/Loss line posted
-- trans_currency = base currency while every other line of the SAME
-- voucher posted trans_currency = the bill's own invoice currency —
-- violating the schema's own documented rule (rid_finance_lines.
-- trans_currency: "locked from line 1" — one common transaction currency
-- per voucher, see 019_finance_vouchers.sql). Migration 058 fixed the
-- *balance check* (base_amount instead of trans_amount) but that alone
-- doesn't fix the underlying currency-mixing bug in how the line itself
-- was built.
--
-- Matches how real ERPs handle GR/IR clearing + FX restatement (Tally
-- posts a separate Journal voucher for realized exchange gain/loss; SAP's
-- underlying accounting logic decomposes the same way even when bundled
-- into one document): the transaction genuinely decomposes into two
-- independently-balancing pieces —
--   1. Clearing the accrual at its OWN historical rate (a wash, no FX
--      impact) — this is the PUR voucher.
--   2. A currency restatement of the resulting payable to the bill's
--      current rate — a distinct adjustment, purely in base currency,
--      touching only Supplier and Exchange Gain/Loss — this is the new
--      EXC voucher.
-- Every voucher posted through fn_post_voucher/fn_post_finance_voucher
-- MUST balance on its own (that's fundamental to the engine and to
-- double-entry itself) — so this can't be "one imbalanced voucher plus a
-- compensating one"; each piece has to genuinely balance independently.
--
-- PUR voucher: DR Accrual (unchanged) + DR Input VAT (unchanged) = CR
-- Supplier, where Supplier's base_amount is now FORCED to exactly balance
-- this voucher (= accrual + VAT base total) rather than independently
-- computed from the bill's own rate. Supplier's trans_amount/party_amount/
-- party_currency are UNCHANGED — still the real invoice amount in the
-- bill's own currency and the real party-ledger amount — only base_amount/
-- base_rate for this one line are a derived, balance-forcing figure
-- (base_rate := base_amount / trans_amount, so the trans*rate=base
-- invariant still holds arithmetically, it's just not literally the GRN
-- rate or the bill rate).
--
-- EXC voucher (new voucher type, seeded below): whatever the Supplier's
-- forced base_amount in the PUR voucher doesn't yet reflect vs. the TRUE
-- payable at the bill's own confirmed rate (supplier_trans_amt *
-- header.rate_to_base). Two lines, both natively in the company's base
-- currency (trans_currency = base_ccy, trans_amount = base_amount, no
-- artificial back-derivation needed since this voucher's OWN transaction
-- currency genuinely IS base currency) — DR/CR Exchange Gain/Loss vs CR/DR
-- Supplier. No inv_bill_no on the Supplier line here — this is a pure GL
-- valuation adjustment, invisible to the party-currency pending-bills
-- view (v_pending_bills), which is correct: the party is still owed
-- exactly the same amount in their own currency regardless of how the
-- base-currency translation moves.
--
-- Both vouchers tag the same source_doc_type='PURCHASE_INVOICE'/
-- source_doc_no — the Purchase Bill screen's Posted Journal Entries
-- section already queries by source doc, not a single stored voucher
-- number, so both show up automatically with no Flutter change needed.
-- rih_purchase_invoices.posted_voucher_no/date still stores the PUR
-- voucher's own number (the primary reference).
-- ============================================================

-- ── Seed 'EXC' voucher type ───────────────────────────────────────────────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('EXC', 'Exchange Voucher', 'JOURNAL', NULL, 'YEARLY', 'EXC/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;

-- ── fn_approve_purchase_invoice ───────────────────────────────────────────────
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

GRANT EXECUTE ON FUNCTION fn_approve_purchase_invoice(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
