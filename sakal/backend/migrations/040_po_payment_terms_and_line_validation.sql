-- ============================================================
-- Migration 040: PO Payment Terms (multi-select) + line validation
-- ============================================================
-- Two independent changes bundled because both touch
-- fn_save_purchase_order/fn_approve_purchase_order and 031 is already
-- deployed (so, like 039, this ships as CREATE OR REPLACE, not an edit to
-- 031 in place):
--
-- 1. Payment Terms moves from a single free-text column on the PO header
--    to a common-master-driven multi-select: a PO can carry several terms,
--    each with its own free-text description (e.g. "50% Advance" ->
--    "Due before dispatch", "Balance NET 30" -> "From GRN date"). Same
--    relational shape as rid_po_charge_lines (frozen term_name snapshot +
--    per-row description), not a jsonb/array column, to stay consistent
--    with how every other PO-level multi-row concept in this schema works.
--    rih_purchase_orders.payment_terms (plain text) is dropped — nothing
--    reads it besides the screen being replaced in this same change.
--
-- 2. fn_approve_purchase_order gains line-completeness validation
--    (qty > 0, rate > 0, uom_id set, at least one line) — closes a real
--    gap where a PO could be approved with an empty/placeholder line.
--    Enforced at Approve only, never at Draft save, per the project's
--    standing rule that drafts may be incomplete.
--
-- fn_save_purchase_order's signature changes (JSONB,JSONB,JSONB,UUID) ->
-- (JSONB,JSONB,JSONB,JSONB,UUID) — the old 4-arg overload is dropped
-- explicitly so Supabase/PostgREST never ends up with two overloads that
-- could both match a given RPC call.
-- ============================================================

-- ── rim_common_master_types — new type_key for payment terms ────────────────
INSERT INTO rim_common_master_types (type_key, type_name) VALUES
    ('PAYMENT_TERMS', 'Payment Terms')
ON CONFLICT (type_key) DO NOTHING;

-- ── rih_purchase_orders — drop the old free-text column ──────────────────────
ALTER TABLE rih_purchase_orders DROP COLUMN IF EXISTS payment_terms;

-- ── rid_po_payment_terms ──────────────────────────────────────────────────────
-- Same shape/pattern as rid_po_charge_lines: term_name is a frozen snapshot
-- of the common-master label at save time (so a later rename of the master
-- term doesn't retroactively change historical POs); description is
-- free-text per row (e.g. the actual days/percentage agreed for this PO).
CREATE TABLE IF NOT EXISTS rid_po_payment_terms (
    id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id    UUID          NOT NULL REFERENCES ric_clients(id),
    company_id   UUID          NOT NULL REFERENCES ric_companies(id),
    order_no     TEXT          NOT NULL,
    order_date   DATE          NOT NULL,
    serial_no    INTEGER       NOT NULL,
    term_id      UUID          NOT NULL REFERENCES rim_common_masters(id),
    term_name    TEXT          NOT NULL,
    description  TEXT,
    is_deleted   BOOLEAN       NOT NULL DEFAULT false,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by   UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rid_po_payment_terms UNIQUE (client_id, company_id, order_no, order_date, serial_no),
    CONSTRAINT rid_po_payment_terms_header_fk
        FOREIGN KEY (client_id, company_id, order_no, order_date)
        REFERENCES  rih_purchase_orders (client_id, company_id, order_no, order_date)
);

CREATE INDEX IF NOT EXISTS idx_rid_po_payment_terms_header
    ON rid_po_payment_terms (client_id, company_id, order_no, order_date);

ALTER TABLE rid_po_payment_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_po_payment_terms" ON rid_po_payment_terms
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_po_payment_terms FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_po_payment_terms TO authenticated;

-- ── fn_save_purchase_order — new signature, adds p_payment_terms ────────────
-- Drop the old 4-arg overload first so Supabase never carries two versions
-- of this function that could both match an RPC call.
DROP FUNCTION IF EXISTS fn_save_purchase_order(JSONB, JSONB, JSONB, UUID);

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
            term_id, term_name, description, created_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date, v_term_serial,
            (v_term->>'term_id')::uuid,
            v_term->>'term_name',
            nullif(v_term->>'description', ''),
            p_user_id
        );
    END LOOP;

    RETURN v_order_no;
END;
$$;

-- ── fn_approve_purchase_order — adds line-completeness validation ──────────
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

    -- NEW: at least one line, and every line must be complete — closes the
    -- gap where a PO could be approved with an empty or placeholder line
    -- (no qty, no rate, no UOM). Enforced only here, never at Draft save.
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

GRANT EXECUTE ON FUNCTION fn_save_purchase_order(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_approve_purchase_order(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
