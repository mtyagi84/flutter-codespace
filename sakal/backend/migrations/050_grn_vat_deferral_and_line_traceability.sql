-- ============================================================
-- Migration 050: defer VAT off GRN posting + finance-line traceability
-- ============================================================
-- User-specified design (a GR/IR provisional-liability pattern): VAT is
-- recoverable, not part of inventory cost, and isn't yours to claim until
-- the actual supplier tax invoice exists. GRN only knows an ESTIMATED tax
-- (from the tax group assigned at GRN entry) — booking it as Input Tax at
-- GRN time recognizes a credit before the document that actually entitles
-- you to it exists.
--
-- Worked example supplied (qty×price=110, discount=10, after-discount=100,
-- VAT 16%=16, transport(vatable)=50 + VAT 8, freight(non-vatable)=50):
--
--   At GRN:
--     Dr Stock Account              200   (100 + 50 + 50 — all net of VAT)
--       Cr Purchase Account               100   (provisional/clearing)
--       Cr Transport Charges Account       50   (provisional/clearing)
--       Cr Freight Charges Account         50   (provisional/clearing)
--
--   At Purchase Invoice (goods supplier) — future module, not this one:
--     Dr Purchase Account            100   (clears what GRN credited)
--     Dr Input VAT                    16
--       Cr Supplier A                       116
--
--   At Transport supplier's invoice:
--     Dr Transport Charges Account    50
--     Dr Input VAT                     8
--       Cr Transport Supplier               58
--
--   At Freight supplier's invoice (not vatable):
--     Dr Freight Charges Account      50
--       Cr Freight Supplier                 50
--
-- Changes to fn_approve_grn:
--   1. Purchase Accrual Cr drops from final_amount (tax-inclusive) to
--      taxable_amount (tax-exclusive) — matches Stock Dr's own basis.
--   2. The Input Tax Dr block is removed entirely — no VAT posted at GRN.
--   3. Each charge's own account posts trans_amount = charge.amount
--      (already tax-exclusive) instead of amount+tax_amount; the Charge
--      Tax Dr block is removed entirely.
--   4. Real bug fixed while here: a charge's nature (ADD/DEDUCT) was never
--      applied to its own account posting — every charge posted Cr
--      regardless. A DEDUCT charge (e.g. a supplier rebate) now posts Dr
--      instead — same unsigned amount, opposite direction, since it
--      reduces the landed cost rather than adding to the provisional
--      liability. (Line-level Stock Dr already applied the sign correctly
--      via the Flutter screen's signed allocation_factor — only the
--      charge's own account posting had the bug.)
--   tax_amount/tax_group_id (item) and tax_id/tax_amount (charge) are
--   untouched on rid_grn_lines/rid_grn_charge_lines and the GRN's own
--   printed totals — they remain the stored ESTIMATE for the future
--   Purchase Invoice screen to book for real and reconcile against.
--
-- Also adds finance-line traceability: rid_finance_lines gains
-- source_line_type/source_line_no (mirrors the header's existing
-- source_doc_type/no pattern from migration 037), so any GRN line/charge's
-- exact Stock/Accrual/Charge posting can be found and, if the GRN is ever
-- corrected via reversal+re-entry, matched precisely — not just "somewhere
-- in this voucher". Generic on fn_save_finance_voucher/fn_post_voucher (both
-- already pass through whatever extra keys a caller puts on a line object),
-- so every future auto-posting module gets this for free, not just GRN.
--
-- New migration, not an edit to 021/037/046/047/048/049 — any of those may
-- already be deployed.
-- ============================================================

ALTER TABLE rid_finance_lines
    ADD COLUMN IF NOT EXISTS source_line_type TEXT,
    ADD COLUMN IF NOT EXISTS source_line_no   INTEGER;

CREATE INDEX IF NOT EXISTS idx_finance_lines_source_line
    ON rid_finance_lines (trans_no, trans_date, source_line_type, source_line_no);

-- ── fn_save_finance_voucher — insert the 2 new optional columns ─────────────
-- Identical to the 021 version except the INSERT gains source_line_type/
-- source_line_no, read the same optional-with-no-default way as inv_bill_no/
-- line_remarks — NULL when the caller's line object doesn't set them (every
-- manual voucher entry today never will).
CREATE OR REPLACE FUNCTION fn_save_finance_voucher(
    p_header    jsonb,
    p_lines     jsonb,
    p_user_id   uuid
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      uuid;
    v_company_id     uuid;
    v_location_id    uuid;
    v_trans_no       text;
    v_trans_date     date;
    v_old_trans_date date;
    v_is_new         boolean;
    v_line           jsonb;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_trans_no    := nullif(trim(p_header->>'trans_no'), '');
    v_trans_date  := (p_header->>'trans_date')::date;
    v_is_new      := v_trans_no IS NULL;

    IF v_is_new THEN
        v_trans_no := fn_next_trans_no(
            v_client_id, v_company_id, v_location_id,
            p_header->>'voucher_type_code'
        );
    ELSE
        IF EXISTS (
            SELECT 1 FROM rih_finance_headers
            WHERE client_id   = v_client_id
              AND company_id  = v_company_id
              AND location_id = v_location_id
              AND trans_no    = v_trans_no
              AND is_posted   = true
        ) THEN
            RAISE EXCEPTION
                'Voucher % is already posted and cannot be modified. Use Reversal to correct.',
                v_trans_no;
        END IF;
    END IF;

    -- Delete existing draft lines using the composite (trans_no, trans_date) key.
    -- For edits we look up the current stored date first so that if the user
    -- changes the voucher date we still delete the correct lines (same trans_no
    -- can legitimately exist on a different date after a period reset).
    IF NOT v_is_new THEN
        SELECT trans_date INTO v_old_trans_date
        FROM rih_finance_headers
        WHERE client_id   = v_client_id
          AND company_id  = v_company_id
          AND location_id = v_location_id
          AND trans_no    = v_trans_no
          AND is_deleted  = false;

        DELETE FROM rid_finance_lines
        WHERE client_id   = v_client_id
          AND company_id  = v_company_id
          AND location_id = v_location_id
          AND trans_no    = v_trans_no
          AND trans_date  = v_old_trans_date;
    END IF;

    -- Insert or update header
    IF v_is_new THEN
        INSERT INTO rih_finance_headers (
            client_id, company_id, location_id, trans_no, trans_date,
            voucher_type_code, payment_mode_code, is_on_account,
            reference_no, reference_date,
            cheque_no, cheque_date,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id,
            v_trans_no, v_trans_date,
            p_header->>'voucher_type_code',
            nullif(p_header->>'payment_mode_code', ''),
            coalesce((p_header->>'is_on_account')::boolean, false),
            nullif(p_header->>'reference_no', ''),
            (nullif(p_header->>'reference_date', ''))::date,
            nullif(p_header->>'cheque_no', ''),
            (nullif(p_header->>'cheque_date', ''))::date,
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        -- Update existing unposted draft; trans_date may legitimately change
        UPDATE rih_finance_headers SET
            trans_date        = v_trans_date,
            payment_mode_code = nullif(p_header->>'payment_mode_code', ''),
            is_on_account     = coalesce((p_header->>'is_on_account')::boolean, false),
            reference_no      = nullif(p_header->>'reference_no', ''),
            reference_date    = (nullif(p_header->>'reference_date', ''))::date,
            cheque_no         = nullif(p_header->>'cheque_no', ''),
            cheque_date       = (nullif(p_header->>'cheque_date', ''))::date,
            remarks           = nullif(p_header->>'remarks', ''),
            updated_at        = now(),
            updated_by        = p_user_id
        WHERE client_id   = v_client_id
          AND company_id  = v_company_id
          AND location_id = v_location_id
          AND trans_no    = v_trans_no
          AND is_posted   = false
          AND is_deleted  = false;
    END IF;

    -- Re-insert lines with trans_date carried from the header
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_finance_lines (
            client_id, company_id, location_id, trans_no, trans_date,
            serial_no, account_id, trans_nature,
            trans_amount, trans_currency,
            base_amount,  base_rate,
            local_amount, local_rate,
            party_amount, party_currency, party_rate,
            inv_bill_no, inv_bill_date,
            line_remarks, created_by, updated_by,
            source_line_type, source_line_no
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_trans_no, v_trans_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'account_id')::uuid,
            v_line->>'trans_nature',
            coalesce((v_line->>'trans_amount')::numeric,  0),
            v_line->>'trans_currency',
            coalesce((v_line->>'base_amount')::numeric,   0),
            coalesce((v_line->>'base_rate')::numeric,     1),
            coalesce((v_line->>'local_amount')::numeric,  0),
            coalesce((v_line->>'local_rate')::numeric,    1),
            coalesce((v_line->>'party_amount')::numeric,  0),
            v_line->>'party_currency',
            coalesce((v_line->>'party_rate')::numeric,    1),
            nullif(v_line->>'inv_bill_no', ''),
            (nullif(v_line->>'inv_bill_date', ''))::date,
            nullif(v_line->>'line_remarks', ''),
            p_user_id, p_user_id,
            nullif(v_line->>'source_line_type', ''),
            (v_line->>'source_line_no')::integer
        );
    END LOOP;

    RETURN v_trans_no;
END;
$$;

-- ── fn_approve_grn — VAT deferred, DEDUCT-nature charges fixed, traced ───────
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

        -- GL: Stock Dr = net-of-VAT item value + apportioned charge (net of
        -- charge VAT too — VAT is a recoverable asset, never part of
        -- inventory cost; see migration header for the full worked example).
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
            'party_amount', v_taxable_amount + v_line.charge_amount, 'party_currency', v_base_ccy, 'party_rate', 1,
            'source_line_type', 'STOCK', 'source_line_no', v_line.serial_no
        ));

        -- GL: Purchase Accrual Cr = tax-EXCLUSIVE item value — a provisional/
        -- clearing liability (never the supplier account directly, never
        -- with inv_bill_no — that linkage belongs to the future Purchase
        -- Invoice, not GRN). VAT is deliberately NOT booked here: it isn't a
        -- real input-tax credit until the actual supplier tax invoice
        -- exists, so it's recognized (together with the real supplier
        -- liability) only when the future Purchase Invoice clears this same
        -- account — see migration header for the full worked example.
        v_accrual_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'PURCHASE_ACCRUAL_ACCOUNT');
        IF v_accrual_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Purchase Accrual Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_accrual_account, 'trans_nature', 'CR',
            'trans_amount', v_taxable_amount, 'trans_currency', v_base_ccy,
            'base_amount', v_taxable_amount, 'base_rate', 1,
            'local_amount', v_taxable_amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_taxable_amount, 'party_currency', v_base_ccy, 'party_rate', 1,
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
    --    rationale as the item lines above. A DEDUCT charge reduces the
    --    landed cost, so it posts the opposite direction of an ADD charge —
    --    Dr instead of Cr, same unsigned amount — matching how the
    --    line-level Stock Dr above already applies the sign via its own
    --    signed allocation_factor.
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
            'account_id', v_charge.gl_account_id,
            'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
            'trans_amount', v_charge.amount, 'trans_currency', v_base_ccy,
            'base_amount', v_charge.amount, 'base_rate', 1,
            'local_amount', v_charge.amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_charge.amount, 'party_currency', v_base_ccy, 'party_rate', 1,
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
