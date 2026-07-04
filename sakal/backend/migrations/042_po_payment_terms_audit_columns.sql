-- ============================================================
-- Migration 042: rid_po_payment_terms audit-column consistency
-- ============================================================
-- rid_po_payment_terms (040) was missing updated_at/updated_by, unlike its
-- sibling line tables rid_purchase_order_lines and rid_po_charge_lines
-- (both of which set created_by = updated_by at insert time, even though —
-- like payment terms — they are only ever delete+reinserted on edit, never
-- UPDATEd in place). This migration brings it in line with that pattern.
--
-- Deliberately NOT adding an is_active column to rid_purchase_order_lines /
-- rid_po_charge_lines / rid_po_payment_terms: "is_active" is a MASTER-DATA
-- concept (an entity toggled off without deleting it, e.g. a product or
-- account). No transaction-detail/line table anywhere in this schema has
-- one — rid_grn_lines (038), rid_finance_lines (019) don't either — a line
-- within a specific document is only ever "current" or is_deleted, there is
-- no independent notion of a line being "inactive." Adding it here would be
-- schema noise with no code path that would ever set it. is_deleted +
-- is_deleted-driven delete/reinsert on edit already covers this table's
-- actual lifecycle.
-- ============================================================

ALTER TABLE rid_po_payment_terms
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES rim_users(id);

-- fn_save_purchase_order — same signature as 040, only the payment-terms
-- INSERT changes (adds updated_by = p_user_id, matching lines/charges).
CREATE OR REPLACE FUNCTION fn_save_purchase_order(
    p_header         JSONB,
    p_lines          JSONB,
    p_charges        JSONB,
    p_payment_terms  JSONB,
    p_user_id        UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_order_no       TEXT;
    v_order_date     DATE;
    v_old_order_date DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_voucher_type   TEXT;
    v_line           JSONB;
    v_charge         JSONB;
    v_term           JSONB;
    v_term_serial    INTEGER;
BEGIN
    v_client_id  := (p_header->>'client_id')::uuid;
    v_company_id := (p_header->>'company_id')::uuid;
    v_order_no   := nullif(trim(p_header->>'order_no'), '');
    v_order_date := (p_header->>'order_date')::date;
    v_is_new     := v_order_no IS NULL;

    v_voucher_type := CASE WHEN p_header->>'po_type' = 'IMPORT' THEN 'PO-IMP' ELSE 'PO-LOC' END;

    IF v_is_new THEN
        v_order_no := fn_next_company_doc_no(v_client_id, v_company_id, v_voucher_type);
    ELSE
        -- Lock the header row before checking status — a plain SELECT here
        -- would leave a window where a concurrent fn_approve_purchase_order
        -- commits between this check and the deletes below.
        SELECT order_date, status INTO v_old_order_date, v_old_status
        FROM   rih_purchase_orders
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  order_no = v_order_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Purchase Order % is % and cannot be edited.', v_order_no, v_old_status;
        END IF;

        DELETE FROM rid_purchase_order_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;

        DELETE FROM rid_po_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;

        DELETE FROM rid_po_payment_terms
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_purchase_orders (
            client_id, company_id, location_id, order_no, order_date, po_type,
            supplier_id, supplier_ref_no, supplier_ref_date,
            indent_no, indent_date, rfq_no, rfq_date, quotation_no, quotation_date,
            po_currency_id, rate_to_base, rate_to_local,
            gross_amount, discount_amount, charges_amount, item_tax_amount, charge_tax_amount, grand_total,
            buyer_id, order_subject, bill_to, ship_to, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, (p_header->>'location_id')::uuid, v_order_no, v_order_date,
            coalesce(p_header->>'po_type', 'LOCAL'),
            (p_header->>'supplier_id')::uuid,
            nullif(p_header->>'supplier_ref_no', ''), (nullif(p_header->>'supplier_ref_date', ''))::date,
            nullif(p_header->>'indent_no', ''), (nullif(p_header->>'indent_date', ''))::date,
            nullif(p_header->>'rfq_no', ''), (nullif(p_header->>'rfq_date', ''))::date,
            nullif(p_header->>'quotation_no', ''), (nullif(p_header->>'quotation_date', ''))::date,
            (p_header->>'po_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'item_tax_amount')::numeric, 0),
            coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            (nullif(p_header->>'buyer_id', ''))::uuid,
            nullif(p_header->>'order_subject', ''),
            nullif(p_header->>'bill_to', ''), nullif(p_header->>'ship_to', ''),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_purchase_orders SET
            location_id        = (p_header->>'location_id')::uuid,
            order_date          = v_order_date,
            po_type              = coalesce(p_header->>'po_type', 'LOCAL'),
            supplier_id           = (p_header->>'supplier_id')::uuid,
            supplier_ref_no        = nullif(p_header->>'supplier_ref_no', ''),
            supplier_ref_date       = (nullif(p_header->>'supplier_ref_date', ''))::date,
            indent_no                = nullif(p_header->>'indent_no', ''),
            indent_date               = (nullif(p_header->>'indent_date', ''))::date,
            rfq_no                     = nullif(p_header->>'rfq_no', ''),
            rfq_date                    = (nullif(p_header->>'rfq_date', ''))::date,
            quotation_no                 = nullif(p_header->>'quotation_no', ''),
            quotation_date                = (nullif(p_header->>'quotation_date', ''))::date,
            po_currency_id                   = (p_header->>'po_currency_id')::uuid,
            rate_to_base                      = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local                       = coalesce((p_header->>'rate_to_local')::numeric, 1),
            gross_amount                          = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount                         = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount                            = coalesce((p_header->>'charges_amount')::numeric, 0),
            item_tax_amount                             = coalesce((p_header->>'item_tax_amount')::numeric, 0),
            charge_tax_amount                            = coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            grand_total                                   = coalesce((p_header->>'grand_total')::numeric, 0),
            buyer_id                                        = (nullif(p_header->>'buyer_id', ''))::uuid,
            order_subject                                     = nullif(p_header->>'order_subject', ''),
            bill_to                                             = nullif(p_header->>'bill_to', ''),
            ship_to                                               = nullif(p_header->>'ship_to', ''),
            remarks                                                = nullif(p_header->>'remarks', ''),
            updated_at                                               = now(),
            updated_by                                                 = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_purchase_order_lines (
            client_id, company_id, order_no, order_date, serial_no,
            product_id, item_description, barcode, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, gross_amount,
            discount_percent, discount_amount, tax_group_id, tax_amount,
            final_amount, base_amount, local_amount, charge_amount, landed_amount,
            department_id, consumption_area_id,
            qty_on_hand_at_order, reorder_level_at_order,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'item_description', ''),
            nullif(v_line->>'barcode', ''),
            (v_line->>'uom_id')::uuid,
            coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0),
            coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            coalesce((v_line->>'rate')::numeric, 0),
            coalesce((v_line->>'gross_amount')::numeric, 0),
            coalesce((v_line->>'discount_percent')::numeric, 0),
            coalesce((v_line->>'discount_amount')::numeric, 0),
            (nullif(v_line->>'tax_group_id', ''))::uuid,
            coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            coalesce((v_line->>'base_amount')::numeric, 0),
            coalesce((v_line->>'local_amount')::numeric, 0),
            coalesce((v_line->>'charge_amount')::numeric, 0),
            coalesce((v_line->>'landed_amount')::numeric, 0),
            (nullif(v_line->>'department_id', ''))::uuid,
            (nullif(v_line->>'consumption_area_id', ''))::uuid,
            (v_line->>'qty_on_hand_at_order')::numeric,
            (v_line->>'reorder_level_at_order')::numeric,
            p_user_id, p_user_id
        );
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_po_charge_lines (
            client_id, company_id, order_no, order_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount_or_percent, percent, amount, tax_amount, allocation_factor,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date,
            (v_charge->>'serial_no')::integer,
            (v_charge->>'charge_id')::uuid,
            v_charge->>'charge_name',
            coalesce((v_charge->>'is_taxable')::boolean, false),
            (nullif(v_charge->>'tax_id', ''))::uuid,
            coalesce(v_charge->>'nature', 'ADD'),
            (nullif(v_charge->>'gl_account_id', ''))::uuid,
            coalesce(v_charge->>'amount_or_percent', 'AMOUNT'),
            (v_charge->>'percent')::numeric,
            coalesce((v_charge->>'amount')::numeric, 0),
            coalesce((v_charge->>'tax_amount')::numeric, 0),
            (v_charge->>'allocation_factor')::numeric,
            p_user_id, p_user_id
        );
    END LOOP;

    v_term_serial := 0;
    FOR v_term IN SELECT * FROM jsonb_array_elements(coalesce(p_payment_terms, '[]'::jsonb))
    LOOP
        v_term_serial := v_term_serial + 1;
        INSERT INTO rid_po_payment_terms (
            client_id, company_id, order_no, order_date, serial_no,
            term_id, term_name, description, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date, v_term_serial,
            (v_term->>'term_id')::uuid,
            v_term->>'term_name',
            nullif(v_term->>'description', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_order_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_purchase_order(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;
