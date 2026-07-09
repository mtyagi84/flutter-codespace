-- ============================================================
-- Migration 080: manufacturing_date alongside expiry_date
-- ============================================================
-- Regulatory/traceability requirement (DRC/Zambia labels/invoices/reports):
-- batch-tracked products store batch_no + expiry_date everywhere already,
-- but no manufacturing date. This migration adds it end-to-end, mirroring
-- expiry_date's own exact footprint: the shared draft-staging table
-- (rid_transaction_line_batches), the permanent posted ledger
-- (ril_stock_ledger), the one-line-per-lot Opening Stock table
-- (rid_opening_stock_lines), the shared posting engine
-- (fn_post_stock_movement), every fn_save_*/fn_approve_* pair that
-- currently threads batch_no/expiry_date, and the Stock Count Review
-- variance/compose path.
--
-- Gating in Flutter is the existing product-level rim_products.tracking_type
-- (isBatchTracked: BATCH or BATCH_WITH_EXPIRY) — no new company-level
-- toggle, since a manufacturing date is meaningful for any batch, not only
-- ones with a formal expiry (a narrower gate than expiry_date's own
-- BATCH_WITH_EXPIRY-only UI condition).
--
-- Purely additive, nullable, no backfill, no new CHECK constraints (e.g.
-- manufacturing_date <= expiry_date) — matches expiry_date's own status
-- today as a pure stored/display value with zero business-logic
-- consumption (no FEFO, no near-expiry alerts).
--
-- fn_post_stock_movement's new parameter is appended as the 18th
-- (p_manufacturing_date DATE DEFAULT NULL, after the existing
-- p_rate_to_base DEFAULT NULL added by 049/063) so every existing
-- positional call site across every fn_approve_* stays valid untouched
-- unless explicitly updated below to actually pass the value through.
-- ============================================================

ALTER TABLE rid_transaction_line_batches ADD COLUMN IF NOT EXISTS manufacturing_date DATE;
ALTER TABLE ril_stock_ledger             ADD COLUMN IF NOT EXISTS manufacturing_date DATE;
ALTER TABLE rid_opening_stock_lines      ADD COLUMN IF NOT EXISTS manufacturing_date DATE;


-- ── 1. fn_post_stock_movement + read-side balance view ───────────────────────
-- CREATE OR REPLACE only replaces a function whose parameter list is
-- byte-identical — adding a new (18th) parameter makes Postgres treat this
-- as a distinct OVERLOAD, silently leaving the old 17-param version in
-- place alongside it. Any caller relying on defaults for the tail params
-- then becomes ambiguous between the two ("function ... is not unique").
-- Must drop the old signature explicitly first.
DROP FUNCTION IF EXISTS fn_post_stock_movement(
    UUID, UUID, UUID, UUID, DATE, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT, TEXT, TEXT, DATE, UUID, NUMERIC
);

CREATE OR REPLACE FUNCTION fn_post_stock_movement(
    p_client_id         UUID,
    p_company_id        UUID,
    p_location_id       UUID,
    p_product_id        UUID,
    p_trans_date        DATE,
    p_trans_type        TEXT,
    p_qty_change        NUMERIC,                -- signed: positive = IN, negative = OUT
    p_unit_cost_base     NUMERIC DEFAULT NULL,   -- required (NOT NULL) when p_qty_change > 0
    p_unit_cost_specific NUMERIC DEFAULT NULL,   -- required (NOT NULL) when p_qty_change > 0
    p_batch_no           TEXT    DEFAULT NULL,
    p_expiry_date        DATE    DEFAULT NULL,
    p_serial_no          TEXT    DEFAULT NULL,   -- SERIAL-tracked products: caller loops one unit (qty=+/-1) per serial
    p_source_doc_type    TEXT    DEFAULT NULL,
    p_source_doc_no      TEXT    DEFAULT NULL,
    p_source_doc_date    DATE    DEFAULT NULL,
    p_user_id            UUID    DEFAULT NULL,
    p_rate_to_base       NUMERIC DEFAULT NULL,   -- FX rate (trans currency -> base) used for p_unit_cost_base, stored for audit (049)
    p_manufacturing_date DATE    DEFAULT NULL    -- regulatory/traceability only (080) — never validated against p_expiry_date, purely stored
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_pl_id           UUID;
    v_qty_before      NUMERIC(18,4);
    v_cost_before      NUMERIC(18,4);
    v_cost_before_spec NUMERIC(18,4);
    v_qty_after       NUMERIC(18,4);
    v_cost_after       NUMERIC(18,4);
    v_cost_after_spec  NUMERIC(18,4);
    v_item_allows_negative BOOLEAN;
    v_location_allows_negative BOOLEAN;
    v_batch_balance    NUMERIC;
    v_serial_balance   NUMERIC;
BEGIN
    PERFORM fn_check_period_open(p_company_id, p_trans_date);

    IF p_qty_change > 0 AND p_unit_cost_base IS NULL THEN
        RAISE EXCEPTION 'UNIT_COST_REQUIRED'
            USING DETAIL = 'p_unit_cost_base is required for inward stock movements.';
    END IF;

    -- Get-or-create then lock the balance row for the duration of this transaction.
    INSERT INTO rim_product_location (
        client_id, company_id, location_id, product_id,
        current_stock, cost_price, cost_price_specific, created_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id, p_product_id,
        0, 0, NULL, p_user_id
    )
    ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

    SELECT id, current_stock, cost_price, cost_price_specific
    INTO v_pl_id, v_qty_before, v_cost_before, v_cost_before_spec
    FROM rim_product_location
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND location_id = p_location_id AND product_id = p_product_id
    FOR UPDATE;

    v_qty_after := v_qty_before + p_qty_change;

    -- NEW (063): a batch or serial is a specific identifiable unit/lot —
    -- its own balance must cover the outward movement, unconditionally
    -- (allow_negative_stock flags never apply here, unlike the aggregate
    -- check below).
    IF p_qty_change < 0 AND p_batch_no IS NOT NULL THEN
        SELECT coalesce(sum(qty_change), 0) INTO v_batch_balance
        FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = p_location_id AND product_id = p_product_id
          AND batch_no = p_batch_no;

        IF v_batch_balance + p_qty_change < 0 THEN
            RAISE EXCEPTION 'BATCH_INSUFFICIENT_STOCK'
                USING DETAIL = format(
                    'Batch %s of [%s] %s has %s on hand at this location, %s requested. Batch-tracked stock can never go negative.',
                    p_batch_no,
                    (SELECT product_code FROM rim_products WHERE id = p_product_id),
                    (SELECT product_name FROM rim_products WHERE id = p_product_id),
                    v_batch_balance, abs(p_qty_change));
        END IF;
    ELSIF p_qty_change < 0 AND p_serial_no IS NOT NULL THEN
        SELECT coalesce(sum(qty_change), 0) INTO v_serial_balance
        FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = p_location_id AND product_id = p_product_id
          AND serial_no = p_serial_no;

        IF v_serial_balance + p_qty_change < 0 THEN
            RAISE EXCEPTION 'SERIAL_NOT_IN_STOCK'
                USING DETAIL = format(
                    'Serial %s of [%s] %s is not currently in stock at this location. Serial-tracked stock can never go negative.',
                    p_serial_no,
                    (SELECT product_code FROM rim_products WHERE id = p_product_id),
                    (SELECT product_name FROM rim_products WHERE id = p_product_id));
        END IF;
    ELSIF p_qty_change < 0 AND v_qty_after < 0 THEN
        -- Untracked (aggregate) products only — existing 060 flag-gated check.
        SELECT coalesce((flags->>'allow_negative_stock')::boolean, false) INTO v_item_allows_negative
        FROM rim_products WHERE id = p_product_id;

        SELECT is_negative_stock_allowed INTO v_location_allows_negative
        FROM ric_locations WHERE id = p_location_id;

        IF NOT (coalesce(v_item_allows_negative, false) AND coalesce(v_location_allows_negative, false)) THEN
            RAISE EXCEPTION 'NEGATIVE_STOCK_NOT_ALLOWED'
                USING DETAIL = format(
                    'Not enough stock: [%s] %s has %s on hand at this location, %s requested. Enable "Allow Negative Stock" on both the item and the location to override.',
                    (SELECT product_code FROM rim_products WHERE id = p_product_id),
                    (SELECT product_name FROM rim_products WHERE id = p_product_id),
                    v_qty_before, abs(p_qty_change));
        END IF;
    END IF;

    IF p_qty_change > 0 THEN
        -- Independent weighted-average in each currency: before+/current-in formula
        -- run twice, never cost_price_after ÷ today's rate.
        v_cost_after := (v_qty_before * v_cost_before + p_qty_change * p_unit_cost_base) / v_qty_after;
        v_cost_after_spec := (v_qty_before * COALESCE(v_cost_before_spec, 0)
                               + p_qty_change * COALESCE(p_unit_cost_specific, 0)) / v_qty_after;

        INSERT INTO ril_cost_price_history (
            client_id, company_id, location_id, product_id, trans_date,
            source_doc_type, source_doc_no, source_doc_date,
            qty_before, cost_price_before, cost_price_before_specific,
            qty_in, cost_price_in, cost_price_in_specific,
            qty_after, cost_price_after, cost_price_after_specific,
            rate_to_base,
            created_by
        ) VALUES (
            p_client_id, p_company_id, p_location_id, p_product_id, p_trans_date,
            p_source_doc_type, p_source_doc_no, p_source_doc_date,
            v_qty_before, v_cost_before, v_cost_before_spec,
            p_qty_change, p_unit_cost_base, p_unit_cost_specific,
            v_qty_after, v_cost_after, v_cost_after_spec,
            p_rate_to_base,
            p_user_id
        );
    ELSE
        -- Outward movement: cost never changes, only current_stock. Snapshot the
        -- CURRENT average cost onto the ledger row for COGS — never caller-supplied.
        v_cost_after := v_cost_before;
        v_cost_after_spec := v_cost_before_spec;
    END IF;

    UPDATE rim_product_location
    SET current_stock = v_qty_after,
        cost_price = v_cost_after,
        cost_price_specific = v_cost_after_spec,
        updated_at = now(),
        updated_by = p_user_id
    WHERE id = v_pl_id;

    INSERT INTO ril_stock_ledger (
        client_id, company_id, location_id, product_id, trans_date, trans_type,
        qty_change, base_qty, batch_no, expiry_date, manufacturing_date, serial_no, unit_cost,
        source_doc_type, source_doc_no, source_doc_date, created_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id, p_product_id, p_trans_date, p_trans_type,
        p_qty_change, abs(p_qty_change), p_batch_no, p_expiry_date, p_manufacturing_date, p_serial_no, v_cost_after,
        p_source_doc_type, p_source_doc_no, p_source_doc_date, p_user_id
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_post_stock_movement(
    UUID, UUID, UUID, UUID, DATE, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT, TEXT, TEXT, DATE, UUID, NUMERIC, DATE
) TO authenticated;


-- ── 2. Read-side balance views for the Flutter picker ────────────────────────
CREATE OR REPLACE VIEW v_batch_stock_balance AS
SELECT client_id, company_id, location_id, product_id, batch_no,
       max(expiry_date) AS expiry_date,
       sum(qty_change)  AS balance,
       max(manufacturing_date) AS manufacturing_date
FROM ril_stock_ledger
WHERE batch_no IS NOT NULL
GROUP BY client_id, company_id, location_id, product_id, batch_no;

CREATE OR REPLACE VIEW v_serial_stock_status AS
SELECT client_id, company_id, location_id, product_id, serial_no,
       sum(qty_change) AS balance,
       CASE WHEN sum(qty_change) > 0 THEN 'IN_STOCK' ELSE 'OUT' END AS status
FROM ril_stock_ledger
WHERE serial_no IS NOT NULL
GROUP BY client_id, company_id, location_id, product_id, serial_no;


-- ── 2. fn_save_grn ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_grn(
    p_header  JSONB,
    p_lines   JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_charges JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id    UUID;
    v_company_id   UUID;
    v_location_id  UUID;
    v_grn_no       TEXT;
    v_grn_date     DATE;
    v_old_grn_date DATE;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
    v_batch        JSONB;
    v_serial       JSONB;
    v_charge       JSONB;
    v_line_qty     NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_grn_no      := nullif(trim(p_header->>'grn_no'), '');
    v_grn_date    := (p_header->>'grn_date')::date;
    v_is_new      := v_grn_no IS NULL;

    IF v_is_new THEN
        v_grn_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'GRN');
    ELSE
        -- Lock the header row before checking status — a plain SELECT here
        -- would leave a window where a concurrent fn_approve_grn commits
        -- between this check and the deletes below.
        SELECT grn_date, status INTO v_old_grn_date, v_old_status
        FROM rih_grn_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'GRN % is % and cannot be edited.', v_grn_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'GRN' AND source_doc_no = v_grn_no AND source_doc_date = v_old_grn_date;

        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'GRN' AND source_doc_no = v_grn_no AND source_doc_date = v_old_grn_date;

        DELETE FROM rid_grn_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND grn_date = v_old_grn_date;

        DELETE FROM rid_grn_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND grn_date = v_old_grn_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_grn_headers (
            client_id, company_id, location_id, grn_no, grn_date,
            supplier_id, receipt_mode, supplier_delivery_no, supplier_delivery_date,
            grn_currency_id, rate_to_base, rate_to_local,
            gross_amount, discount_amount, charges_amount, item_tax_amount, charge_tax_amount, grand_total,
            bill_to, ship_to, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_grn_no, v_grn_date,
            (p_header->>'supplier_id')::uuid,
            coalesce(p_header->>'receipt_mode', 'DIRECT'),
            nullif(p_header->>'supplier_delivery_no', ''), (nullif(p_header->>'supplier_delivery_date', ''))::date,
            (nullif(p_header->>'grn_currency_id', ''))::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'item_tax_amount')::numeric, 0),
            coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            nullif(p_header->>'bill_to', ''), nullif(p_header->>'ship_to', ''),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_grn_headers SET
            location_id             = v_location_id,
            grn_date                = v_grn_date,
            supplier_id              = (p_header->>'supplier_id')::uuid,
            receipt_mode              = coalesce(p_header->>'receipt_mode', 'DIRECT'),
            supplier_delivery_no       = nullif(p_header->>'supplier_delivery_no', ''),
            supplier_delivery_date      = (nullif(p_header->>'supplier_delivery_date', ''))::date,
            grn_currency_id               = (nullif(p_header->>'grn_currency_id', ''))::uuid,
            rate_to_base                   = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local                    = coalesce((p_header->>'rate_to_local')::numeric, 1),
            gross_amount                      = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount                    = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount                       = coalesce((p_header->>'charges_amount')::numeric, 0),
            item_tax_amount                        = coalesce((p_header->>'item_tax_amount')::numeric, 0),
            charge_tax_amount                        = coalesce((p_header->>'charge_tax_amount')::numeric, 0),
            grand_total                                = coalesce((p_header->>'grand_total')::numeric, 0),
            bill_to                                      = nullif(p_header->>'bill_to', ''),
            ship_to                                        = nullif(p_header->>'ship_to', ''),
            remarks                                          = nullif(p_header->>'remarks', ''),
            updated_at                                         = now(),
            updated_by                                           = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_grn_lines (
            client_id, company_id, grn_no, grn_date, serial_no,
            product_id, source_po_order_no, source_po_order_date, source_po_line_serial,
            item_description, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, gross_amount,
            discount_percent, discount_amount, tax_group_id, tax_amount,
            final_amount, base_amount, local_amount, charge_amount, landed_amount,
            department_id, consumption_area_id, barcode, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_grn_no, v_grn_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'source_po_order_no', ''), (nullif(v_line->>'source_po_order_date', ''))::date,
            (v_line->>'source_po_line_serial')::integer,
            nullif(v_line->>'item_description', ''),
            (nullif(v_line->>'uom_id', ''))::uuid,
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
            nullif(v_line->>'barcode', ''),
            p_user_id, p_user_id
        );

        -- Batch/serial children for this line, if any were provided
        v_line_qty := coalesce((v_line->>'base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'GRN', v_grn_no, v_grn_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the line quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        FOR v_serial IN
            SELECT * FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_serials (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
            ) VALUES (
                v_client_id, v_company_id, 'GRN', v_grn_no, v_grn_date, (v_line->>'serial_no')::integer,
                v_serial->>'serial_no', p_user_id
            );
        END LOOP;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_grn_charge_lines (
            client_id, company_id, grn_no, grn_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount_or_percent, percent, amount, tax_amount, allocation_factor,
            source_po_order_no, source_po_order_date, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_grn_no, v_grn_date,
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
            nullif(v_charge->>'source_po_order_no', ''), (nullif(v_charge->>'source_po_order_date', ''))::date,
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_grn_no;
END;
$$;


-- ── 3. fn_approve_grn ─────────────────────────────────────────────────────────
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

GRANT EXECUTE ON FUNCTION fn_approve_grn(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── 4. fn_save_purchase_return ────────────────────────────────────────────────
-- ── fn_save_purchase_return ───────────────────────────────────────────────────
DROP FUNCTION IF EXISTS fn_save_purchase_return(JSONB, JSONB, JSONB, JSONB, JSONB, UUID);

CREATE OR REPLACE FUNCTION fn_save_purchase_return(
    p_header    JSONB,
    p_lines     JSONB,   -- [{serial_no, source_grn_no, source_grn_date, source_grn_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate, tax_group_id, gross_amount, tax_amount, final_amount, barcode}, ...]
    p_batches   JSONB,   -- [{line_serial, batch_no, expiry_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials   JSONB,   -- [{line_serial, serial_no}, ...]
    p_charges   JSONB,   -- [{serial_no, charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id, amount, tax_amount, source_grn_no, source_grn_date}, ...]
    p_user_id   UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     UUID;
    v_company_id    UUID;
    v_location_id   UUID;
    v_supplier_id   UUID;
    v_return_no     TEXT;
    v_return_date   DATE;
    v_old_status    TEXT;
    v_is_new        BOOLEAN;
    v_line          JSONB;
    v_charge        JSONB;
    v_batch         JSONB;
    v_grn_ref       RECORD;
    v_grn           rih_grn_headers%ROWTYPE;
    v_charges_total NUMERIC := 0;
    v_line_qty      NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_supplier_id := (p_header->>'supplier_id')::uuid;
    v_return_no   := nullif(trim(p_header->>'return_no'), '');
    v_return_date := (p_header->>'return_date')::date;
    v_is_new      := v_return_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Purchase Return.';
    END IF;

    IF v_is_new THEN
        v_return_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'PRET');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_purchase_return_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Purchase Return % is % and cannot be edited.', v_return_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = v_return_no AND source_doc_date = v_return_date;

        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'PURCHASE_RETURN' AND source_doc_no = v_return_no AND source_doc_date = v_return_date;

        DELETE FROM rid_purchase_return_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
        DELETE FROM rid_purchase_return_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
    END IF;

    -- Validate every referenced GRN: same supplier, APPROVED. One row per
    -- statement in a fixed sort order (deadlock-avoidance rule from 036/038).
    FOR v_grn_ref IN
        SELECT DISTINCT value->>'source_grn_no' AS grn_no, value->>'source_grn_date' AS grn_date
        FROM jsonb_array_elements(p_lines)
        ORDER BY 1, 2
    LOOP
        SELECT * INTO v_grn FROM rih_grn_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_ref.grn_no AND grn_date = v_grn_ref.grn_date::date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'GRN % not found.', v_grn_ref.grn_no;
        END IF;
        IF v_grn.status != 'APPROVED' THEN
            RAISE EXCEPTION 'GRN % is % — only APPROVED GRNs can be returned against.', v_grn.grn_no, v_grn.status;
        END IF;
        IF v_grn.supplier_id != v_supplier_id THEN
            RAISE EXCEPTION 'GRN % does not belong to the selected supplier.', v_grn.grn_no;
        END IF;
    END LOOP;

    IF v_is_new THEN
        INSERT INTO rih_purchase_return_headers (
            client_id, company_id, location_id, return_no, return_date, supplier_id,
            return_currency_id, rate_to_base, rate_to_local,
            taxable_amount, tax_amount, charges_amount, return_total,
            reason, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_return_no, v_return_date, v_supplier_id,
            (p_header->>'return_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'taxable_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'return_total')::numeric, 0),
            nullif(p_header->>'reason', ''), nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_purchase_return_headers SET
            location_id          = v_location_id,
            return_date          = v_return_date,
            supplier_id          = v_supplier_id,
            return_currency_id  = (p_header->>'return_currency_id')::uuid,
            rate_to_base        = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local       = coalesce((p_header->>'rate_to_local')::numeric, 1),
            taxable_amount      = coalesce((p_header->>'taxable_amount')::numeric, 0),
            tax_amount          = coalesce((p_header->>'tax_amount')::numeric, 0),
            charges_amount      = coalesce((p_header->>'charges_amount')::numeric, 0),
            return_total        = coalesce((p_header->>'return_total')::numeric, 0),
            reason              = nullif(p_header->>'reason', ''),
            remarks             = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_purchase_return_lines (
            client_id, company_id, return_no, return_date, serial_no,
            source_grn_no, source_grn_date, source_grn_line_serial, product_id,
            uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate,
            tax_group_id, gross_amount, tax_amount, final_amount, barcode,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_line->>'serial_no')::integer,
            v_line->>'source_grn_no', (v_line->>'source_grn_date')::date, (v_line->>'source_grn_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0), coalesce((v_line->>'rate')::numeric, 0),
            nullif(v_line->>'tax_group_id', '')::uuid,
            coalesce((v_line->>'gross_amount')::numeric, 0), coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            p_user_id, p_user_id
        );

        -- Batch children for this line, if any were provided — same
        -- BATCH_QTY_MISMATCH rule as fn_save_grn.
        v_line_qty := coalesce((v_line->>'base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'PURCHASE_RETURN', v_return_no, v_return_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the return quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'PURCHASE_RETURN', v_return_no, v_return_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_purchase_return_charge_lines (
            client_id, company_id, return_no, return_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount, tax_amount, source_grn_no, source_grn_date,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_charge->>'serial_no')::integer,
            (v_charge->>'charge_id')::uuid, v_charge->>'charge_name',
            coalesce((v_charge->>'is_taxable')::boolean, false), nullif(v_charge->>'tax_id', '')::uuid,
            coalesce(v_charge->>'nature', 'ADD'), nullif(v_charge->>'gl_account_id', '')::uuid,
            coalesce((v_charge->>'amount')::numeric, 0), coalesce((v_charge->>'tax_amount')::numeric, 0),
            nullif(v_charge->>'source_grn_no', ''), nullif(v_charge->>'source_grn_date', '')::date,
            p_user_id, p_user_id
        );
        v_charges_total := v_charges_total + coalesce((v_charge->>'amount')::numeric, 0);
    END LOOP;

    UPDATE rih_purchase_return_headers SET charges_amount = v_charges_total
    WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;

    RETURN v_return_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_purchase_return(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ── 5. fn_approve_purchase_return ─────────────────────────────────────────────
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

GRANT EXECUTE ON FUNCTION fn_approve_purchase_return(UUID, UUID, TEXT, DATE, BOOLEAN, UUID) TO authenticated;


-- ── 6. fn_save_material_issue ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_material_issue(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_requisition_no, source_requisition_date, source_requisition_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, department_id, consumption_area_id, barcode, remarks}, ...]
    p_batches JSONB,   -- [{line_serial, batch_no, expiry_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials JSONB,   -- [{line_serial, serial_no}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id    UUID;
    v_company_id   UUID;
    v_location_id  UUID;
    v_issue_no     TEXT;
    v_issue_date   DATE;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
    v_batch        JSONB;
    v_req_ref      RECORD;
    v_req          rih_material_requisition_headers%ROWTYPE;
    v_line_qty     NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_issue_no    := nullif(trim(p_header->>'issue_no'), '');
    v_issue_date  := (p_header->>'issue_date')::date;
    v_is_new      := v_issue_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Material Issue.';
    END IF;

    IF v_is_new THEN
        v_issue_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'MISS');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_material_issue_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND issue_no = v_issue_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Material Issue % is % and cannot be edited.', v_issue_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = v_issue_no AND source_doc_date = v_issue_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = v_issue_no AND source_doc_date = v_issue_date;

        DELETE FROM rid_material_issue_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND issue_no = v_issue_no;
    END IF;

    -- Validate every referenced requisition: same location, APPROVED or
    -- already PARTIALLY_ISSUED (a requisition can be fulfilled across
    -- several separate Issues over time). One row per statement in a fixed
    -- sort order (deadlock-avoidance rule from 036/038).
    FOR v_req_ref IN
        SELECT DISTINCT value->>'source_requisition_no' AS req_no, value->>'source_requisition_date' AS req_date
        FROM jsonb_array_elements(p_lines)
        ORDER BY 1, 2
    LOOP
        SELECT * INTO v_req FROM rih_material_requisition_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND requisition_no = v_req_ref.req_no AND requisition_date = v_req_ref.req_date::date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Material Requisition % not found.', v_req_ref.req_no;
        END IF;
        IF v_req.status NOT IN ('APPROVED', 'PARTIALLY_ISSUED') THEN
            RAISE EXCEPTION 'Material Requisition % is % — only APPROVED or PARTIALLY_ISSUED requisitions can be issued against.', v_req.requisition_no, v_req.status;
        END IF;
        IF v_req.location_id != v_location_id THEN
            RAISE EXCEPTION 'Material Requisition % is from a different location than this Issue.', v_req.requisition_no;
        END IF;
    END LOOP;

    IF v_is_new THEN
        INSERT INTO rih_material_issue_headers (
            client_id, company_id, location_id, issue_no, issue_date, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_issue_no, v_issue_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_material_issue_headers SET
            location_id = v_location_id,
            issue_date  = v_issue_date,
            remarks     = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND issue_no = v_issue_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_material_issue_lines (
            client_id, company_id, issue_no, issue_date, serial_no,
            source_requisition_no, source_requisition_date, source_requisition_line_serial,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            department_id, consumption_area_id, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_issue_no, v_issue_date, (v_line->>'serial_no')::integer,
            v_line->>'source_requisition_no', (v_line->>'source_requisition_date')::date, (v_line->>'source_requisition_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'department_id', '')::uuid, nullif(v_line->>'consumption_area_id', '')::uuid,
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        -- Batch children for this line, if any were provided — same
        -- BATCH_QTY_MISMATCH rule as fn_save_grn/fn_save_purchase_return.
        v_line_qty := coalesce((v_line->>'base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'MATERIAL_ISSUE', v_issue_no, v_issue_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the issue quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'MATERIAL_ISSUE', v_issue_no, v_issue_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    RETURN v_issue_no;
END;
$$;


-- ── 7. fn_approve_material_issue ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_material_issue(
    p_client_id   UUID,
    p_company_id  UUID,
    p_issue_no    TEXT,
    p_issue_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header          rih_material_issue_headers%ROWTYPE;
    v_base_ccy        TEXT;
    v_local_ccy       TEXT;
    v_rate_to_local   NUMERIC;
    v_req_key         RECORD;
    v_line            RECORD;
    v_req_line        rid_material_requisition_lines%ROWTYPE;
    v_batch           rid_transaction_line_batches%ROWTYPE;
    v_serial_row      rid_transaction_line_serials%ROWTYPE;
    v_has_batches     BOOLEAN;
    v_has_serials     BOOLEAN;
    v_cost_price      NUMERIC;
    v_line_value      NUMERIC;
    v_stock_account   UUID;
    v_expense_account UUID;
    v_mic_lines       JSONB := '[]'::jsonb;
    v_mic_trans_no    TEXT;
    v_mic_trans_date  DATE;
    v_req_total_ordered  NUMERIC;
    v_req_total_issued   NUMERIC;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_material_issue_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND issue_no = p_issue_no AND issue_date = p_issue_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Material Issue % dated % not found', p_issue_no, p_issue_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Material Issue % is % and cannot be approved again', p_issue_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_issue_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'MATERIAL_ISSUE', p_issue_date);

    IF p_issue_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Issue date %s is in the future — a Material Issue cannot be dated ahead of today.', p_issue_date);
    END IF;

    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_rate_to_local := CASE WHEN v_base_ccy = v_local_ccy THEN 1
                            ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_issue_date) END;

    -- 3. Lock every referenced requisition header, one row per statement in
    --    a fixed sort order (same rule as fn_save_material_issue / fn_approve_grn).
    FOR v_req_key IN
        SELECT DISTINCT source_requisition_no, source_requisition_date FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND issue_no = p_issue_no AND issue_date = p_issue_date AND is_deleted = false
        ORDER BY source_requisition_no, source_requisition_date
    LOOP
        PERFORM 1 FROM rih_material_requisition_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_req_key.source_requisition_no AND requisition_date = v_req_key.source_requisition_date
        FOR UPDATE;
    END LOOP;

    -- 4. Per line: lock+cap the requisition line, post stock (batch/serial
    --    branch), resolve accounts, accumulate GL lines. Sorted by
    --    product_id — second half of the fixed lock-ordering rule.
    FOR v_line IN
        SELECT * FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND issue_no = p_issue_no AND issue_date = p_issue_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        -- Lock + cap the source requisition line (rollup column, same
        -- pattern as rid_purchase_order_lines.qty_received).
        SELECT * INTO v_req_line FROM rid_material_requisition_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_line.source_requisition_no AND requisition_date = v_line.source_requisition_date
          AND serial_no = v_line.source_requisition_line_serial
        FOR UPDATE;

        IF v_req_line.issued_qty + v_line.base_qty > v_req_line.base_qty THEN
            RAISE EXCEPTION 'ISSUE_QTY_EXCEEDS_REQUESTED'
                USING DETAIL = format(
                    'Requisition %s line %s: already issued %s of %s requested, this issue adds %s more.',
                    v_line.source_requisition_no, v_line.source_requisition_line_serial,
                    v_req_line.issued_qty, v_req_line.base_qty, v_line.base_qty);
        END IF;

        UPDATE rid_material_requisition_lines SET
            issued_qty = issued_qty + v_line.base_qty,
            updated_at = now(), updated_by = p_approved_by
        WHERE id = v_req_line.id;

        -- Snapshot the CURRENT moving-average cost for this product+location
        -- BEFORE the movement — fn_post_stock_movement itself never returns
        -- it, and an outward movement doesn't change cost_price anyway, so
        -- reading it now (under the same row lock fn_post_stock_movement
        -- re-acquires internally) is safe and matches the value that will
        -- actually be snapshotted onto the ledger row.
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_line.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT cost_price INTO v_cost_price
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

        v_line_value := v_line.base_qty * coalesce(v_cost_price, 0);

        -- Stock: batch/serial-tracked lines post one row per batch/unit so
        -- each one's own strict, flag-independent balance check (063)
        -- fires — mirrors fn_approve_grn's/fn_approve_purchase_return's
        -- v_has_batches/v_has_serials pattern exactly.
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_issue_date, 'MATERIAL_ISSUE', -v_batch.base_qty,
                    NULL, NULL, v_batch.batch_no, v_batch.expiry_date, NULL,
                    'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'MATERIAL_ISSUE' AND source_doc_no = p_issue_no AND source_doc_date = p_issue_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_issue_date, 'MATERIAL_ISSUE', -1,
                    NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                    'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_issue_date, 'MATERIAL_ISSUE', -v_line.base_qty,
                NULL, NULL, NULL, NULL, NULL,
                'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by
            );
        END IF;

        -- Resolve the consumption expense account for this line's
        -- department + consumption area — hard error with human labels,
        -- never a raw ID, if the pair isn't configured.
        SELECT account_id INTO v_expense_account
        FROM rim_department_consumption_areas
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND consumption_area_id = v_line.consumption_area_id AND department_id = v_line.department_id
          AND is_deleted = false;

        IF v_expense_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format(
                    'Line %s: no expense account configured for consumption area "%s" under department "%s". Set it up in Consumption Area Setup first.',
                    v_line.serial_no,
                    (SELECT description FROM rim_common_masters WHERE id = v_line.consumption_area_id),
                    (SELECT description FROM rim_common_masters WHERE id = v_line.department_id));
        END IF;

        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_mic_lines := v_mic_lines || jsonb_build_array(
            jsonb_build_object(
                'account_id', v_expense_account, 'trans_nature', 'DR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'CONSUMPTION_EXPENSE', 'source_line_no', v_line.serial_no
            ),
            jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'CR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_REDUCTION', 'source_line_no', v_line.serial_no
            )
        );
    END LOOP;

    -- 5. Post the MIC voucher (skipped only if every line valued at zero,
    --    which would mean nothing to post — treated as a hard error since
    --    that always indicates an unconfigured/zero-cost product, not a
    --    legitimate zero-value consumption).
    IF jsonb_array_length(v_mic_lines) = 0 THEN
        RAISE EXCEPTION 'NO_ISSUE_LINES'
            USING DETAIL = 'This issue has no lines to post.';
    END IF;

    SELECT trans_no, trans_date INTO v_mic_trans_no, v_mic_trans_date FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'MIC', p_issue_date,
        v_mic_lines, 'MATERIAL_ISSUE', p_issue_no, p_issue_date, p_approved_by
    );

    -- 6. Recompute status of every requisition touched by this issue —
    --    unconditional (no reopen flag, unlike Purchase Return/PO, since
    --    Material Issue has no reversal concept yet).
    FOR v_req_key IN
        SELECT DISTINCT source_requisition_no, source_requisition_date FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND issue_no = p_issue_no AND issue_date = p_issue_date AND is_deleted = false
        ORDER BY source_requisition_no, source_requisition_date
    LOOP
        SELECT coalesce(sum(base_qty), 0), coalesce(sum(issued_qty), 0)
        INTO v_req_total_ordered, v_req_total_issued
        FROM rid_material_requisition_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_req_key.source_requisition_no AND requisition_date = v_req_key.source_requisition_date
          AND is_deleted = false;

        UPDATE rih_material_requisition_headers SET
            status = CASE WHEN v_req_total_issued >= v_req_total_ordered THEN 'CLOSED' ELSE 'PARTIALLY_ISSUED' END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND requisition_no = v_req_key.source_requisition_no AND requisition_date = v_req_key.source_requisition_date
          AND status IN ('APPROVED', 'PARTIALLY_ISSUED');
    END LOOP;

    -- 7. Mark the issue approved.
    UPDATE rih_material_issue_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_mic_trans_no,
        posted_voucher_date = v_mic_trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_material_issue(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── 8. fn_save_stock_transfer ─────────────────────────────────────────────────
-- ── fn_save_stock_transfer ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_stock_transfer(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_request_no, source_request_date, source_request_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, sales_price, barcode, remarks}, ...]
    p_batches JSONB,
    p_serials JSONB,
    p_charges JSONB,   -- [{serial_no, charge_id, charge_name, nature, gl_account_id, amount_or_percent, percent, amount}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_from_location  UUID;
    v_to_location    UUID;
    v_transfer_no    TEXT;
    v_transfer_date  DATE;
    v_against_request BOOLEAN;
    v_source_request_no TEXT;
    v_source_request_date DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
    v_charge         JSONB;
    v_batch          JSONB;
    v_req            rih_stock_transfer_requests%ROWTYPE;
    v_line_qty       NUMERIC;
    v_batch_qty_sum  NUMERIC;
    v_charges_total  NUMERIC := 0;
BEGIN
    v_client_id     := (p_header->>'client_id')::uuid;
    v_company_id    := (p_header->>'company_id')::uuid;
    v_from_location := (p_header->>'from_location_id')::uuid;
    v_to_location   := (p_header->>'to_location_id')::uuid;
    v_transfer_no   := nullif(trim(p_header->>'transfer_no'), '');
    v_transfer_date := (p_header->>'transfer_date')::date;
    v_against_request := coalesce((p_header->>'against_request')::boolean, false);
    v_source_request_no := nullif(p_header->>'source_request_no', '');
    v_source_request_date := (nullif(p_header->>'source_request_date', ''))::date;
    v_is_new        := v_transfer_no IS NULL;

    IF v_from_location = v_to_location THEN
        RAISE EXCEPTION 'FROM_TO_LOCATION_SAME'
            USING DETAIL = 'From Location and To Location cannot be the same.';
    END IF;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Stock Transfer.';
    END IF;

    IF v_against_request THEN
        SELECT * INTO v_req FROM rih_stock_transfer_requests
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND request_no = v_source_request_no AND request_date = v_source_request_date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Stock Transfer Request % not found.', v_source_request_no;
        END IF;
        IF v_req.status NOT IN ('APPROVED', 'PARTIALLY_TRANSFERRED') THEN
            RAISE EXCEPTION 'Stock Transfer Request % is % — only APPROVED or PARTIALLY_TRANSFERRED requests can be transferred against.', v_req.request_no, v_req.status;
        END IF;
        IF v_req.from_location_id != v_from_location OR v_req.to_location_id != v_to_location THEN
            RAISE EXCEPTION 'Stock Transfer Request % is for a different From/To Location pair.', v_req.request_no;
        END IF;
    END IF;

    IF v_is_new THEN
        v_transfer_no := fn_next_trans_no(v_client_id, v_company_id, v_from_location, 'STXF');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_transfers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND transfer_no = v_transfer_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Transfer % is % and cannot be edited.', v_transfer_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = v_transfer_no AND source_doc_date = v_transfer_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = v_transfer_no AND source_doc_date = v_transfer_date;

        DELETE FROM rid_stock_transfer_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND transfer_no = v_transfer_no;
        DELETE FROM rid_stock_transfer_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND transfer_no = v_transfer_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_transfers (
            client_id, company_id, from_location_id, to_location_id, transfer_no, transfer_date,
            against_request, source_request_no, source_request_date, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_from_location, v_to_location, v_transfer_no, v_transfer_date,
            v_against_request, v_source_request_no, v_source_request_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_transfers SET
            from_location_id    = v_from_location,
            to_location_id      = v_to_location,
            transfer_date       = v_transfer_date,
            against_request     = v_against_request,
            source_request_no   = v_source_request_no,
            source_request_date = v_source_request_date,
            remarks             = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND transfer_no = v_transfer_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_stock_transfer_lines (
            client_id, company_id, transfer_no, transfer_date, serial_no,
            source_request_no, source_request_date, source_request_line_serial,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            sales_price, charge_amount, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_transfer_no, v_transfer_date, (v_line->>'serial_no')::integer,
            nullif(v_line->>'source_request_no', ''), (nullif(v_line->>'source_request_date', ''))::date,
            (nullif(v_line->>'source_request_line_serial', ''))::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            (nullif(v_line->>'sales_price', ''))::numeric,
            coalesce((v_line->>'charge_amount')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        v_line_qty := coalesce((v_line->>'base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'STOCK_TRANSFER', v_transfer_no, v_transfer_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the transfer quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'STOCK_TRANSFER', v_transfer_no, v_transfer_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_stock_transfer_charge_lines (
            client_id, company_id, transfer_no, transfer_date, serial_no,
            charge_id, charge_name, nature, gl_account_id,
            amount_or_percent, percent, amount,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_transfer_no, v_transfer_date, (v_charge->>'serial_no')::integer,
            (v_charge->>'charge_id')::uuid, v_charge->>'charge_name',
            coalesce(v_charge->>'nature', 'ADD'), nullif(v_charge->>'gl_account_id', '')::uuid,
            coalesce(v_charge->>'amount_or_percent', 'AMOUNT'),
            (v_charge->>'percent')::numeric,
            coalesce((v_charge->>'amount')::numeric, 0),
            p_user_id, p_user_id
        );
        v_charges_total := v_charges_total + coalesce((v_charge->>'amount')::numeric, 0);
    END LOOP;

    UPDATE rih_stock_transfers SET charges_amount = v_charges_total
    WHERE client_id = v_client_id AND company_id = v_company_id AND transfer_no = v_transfer_no;

    RETURN v_transfer_no;
END;
$$;


-- ── 9. fn_approve_stock_transfer ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_stock_transfer(
    p_client_id    UUID,
    p_company_id   UUID,
    p_transfer_no  TEXT,
    p_transfer_date DATE,
    p_approved_by  UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header             rih_stock_transfers%ROWTYPE;
    v_from_group_id      UUID;
    v_to_group_id        UUID;
    v_inter_location_model TEXT;
    v_posting_mode       TEXT;
    v_from_group_name    TEXT;
    v_to_group_name      TEXT;
    v_req                rih_stock_transfer_requests%ROWTYPE;
    v_req_line           rid_stock_transfer_request_lines%ROWTYPE;
    v_line               RECORD;
    v_batch              rid_transaction_line_batches%ROWTYPE;
    v_serial_row         rid_transaction_line_serials%ROWTYPE;
    v_charge             RECORD;
    v_has_batches        BOOLEAN;
    v_has_serials        BOOLEAN;
    v_cost_price         NUMERIC;
    v_sales_price         NUMERIC;
    v_stock_account       UUID;
    v_transit_account      UUID;
    v_customer_account      UUID;
    v_ie_sales_account        UUID;
    v_ie_cogs_account          UUID;
    v_stxj_lines          JSONB := '[]'::jsonb;
    v_stxs_lines          JSONB := '[]'::jsonb;
    v_stxc_lines          JSONB := '[]'::jsonb;
    v_sales_total         NUMERIC := 0;
    v_cogs_total          NUMERIC := 0;
    v_stxj_trans_no       TEXT; v_stxj_trans_date DATE;
    v_stxs_trans_no       TEXT; v_stxs_trans_date DATE;
    v_stxc_trans_no       TEXT; v_stxc_trans_date DATE;
    v_req_total_ordered   NUMERIC;
    v_req_total_transferred NUMERIC;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_stock_transfers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND transfer_no = p_transfer_no AND transfer_date = p_transfer_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Transfer % dated % not found', p_transfer_no, p_transfer_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Transfer % is % and cannot be approved again', p_transfer_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_transfer_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_TRANSFER', p_transfer_date);

    IF p_transfer_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Transfer date %s is in the future — a stock transfer cannot be dated ahead of today.', p_transfer_date);
    END IF;

    IF v_header.from_location_id = v_header.to_location_id THEN
        RAISE EXCEPTION 'FROM_TO_LOCATION_SAME'
            USING DETAIL = 'From Location and To Location cannot be the same.';
    END IF;

    -- 3. Resolve posting_mode: INTER_ENTITY only if the company model says
    --    so AND both locations have a group assigned AND those groups
    --    differ — NULL group on either side always falls back to SAME_BOOK.
    SELECT group_id INTO v_from_group_id FROM ric_locations WHERE id = v_header.from_location_id;
    SELECT group_id INTO v_to_group_id   FROM ric_locations WHERE id = v_header.to_location_id;
    SELECT inter_location_model INTO v_inter_location_model FROM ric_companies WHERE id = p_company_id;

    v_posting_mode := CASE
        WHEN v_inter_location_model = 'INTER_ENTITY'
         AND v_from_group_id IS NOT NULL AND v_to_group_id IS NOT NULL
         AND v_from_group_id != v_to_group_id
        THEN 'INTER_ENTITY'
        ELSE 'SAME_BOOK'
    END;

    -- 4. Lock the referenced request, one row per statement (its lines are
    --    locked inside the main line loop below, in product_id order).
    IF v_header.against_request THEN
        SELECT * INTO v_req FROM rih_stock_transfer_requests
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND request_no = v_header.source_request_no AND request_date = v_header.source_request_date
        FOR UPDATE;
    END IF;

    -- 5. Resolve inter-entity accounts up front (once), if needed.
    IF v_posting_mode = 'INTER_ENTITY' THEN
        SELECT customer_account_id, group_name INTO v_customer_account, v_to_group_name
        FROM ric_location_groups WHERE id = v_to_group_id;
        SELECT inter_entity_sales_account_id, inter_entity_cogs_account_id, group_name
        INTO v_ie_sales_account, v_ie_cogs_account, v_from_group_name
        FROM ric_location_groups WHERE id = v_from_group_id;

        IF v_customer_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Location group "%s" has no Customer Account configured — set it up in Location Groups first.', v_to_group_name);
        END IF;
        IF v_ie_sales_account IS NULL OR v_ie_cogs_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Location group "%s" has no Inter-Entity Sales/COGS account configured — set it up in Location Groups first.', v_from_group_name);
        END IF;
    END IF;
    -- v_transit_account is resolved PER LINE inside the loop below, with
    -- that line's real product_id — fn_resolve_account_link's own cache
    -- (rim_account_links) requires a NOT NULL product_id, so it can never
    -- be called with NULL here even for a COMPANY-granularity setup.

    -- 6. Per line: lock+cap the request line (if any), validate cost price,
    --    post stock (batch/serial branch), accumulate GL. Sorted by
    --    product_id — fixed lock-ordering rule.
    FOR v_line IN
        SELECT * FROM rid_stock_transfer_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND transfer_no = p_transfer_no AND transfer_date = p_transfer_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        IF v_line.source_request_no IS NOT NULL THEN
            SELECT * INTO v_req_line FROM rid_stock_transfer_request_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND request_no = v_line.source_request_no AND request_date = v_line.source_request_date
              AND serial_no = v_line.source_request_line_serial
            FOR UPDATE;

            IF v_req_line.transferred_qty + v_line.base_qty > v_req_line.base_qty THEN
                RAISE EXCEPTION 'TRANSFER_QTY_EXCEEDS_REQUESTED'
                    USING DETAIL = format(
                        'Request %s line %s: already transferred %s of %s requested, this transfer adds %s more.',
                        v_line.source_request_no, v_line.source_request_line_serial,
                        v_req_line.transferred_qty, v_req_line.base_qty, v_line.base_qty);
            END IF;

            UPDATE rid_stock_transfer_request_lines SET
                transferred_qty = transferred_qty + v_line.base_qty,
                updated_at = now(), updated_by = p_approved_by
            WHERE id = v_req_line.id;
        END IF;

        -- Cost price: lock + snapshot FROM's current moving average. Hard
        -- block if unavailable — you cannot transfer stock with no known
        -- value, and Receipt has no way to fix this after the fact.
        SELECT cost_price INTO v_cost_price
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.from_location_id AND product_id = v_line.product_id
        FOR UPDATE;

        IF v_cost_price IS NULL OR v_cost_price <= 0 THEN
            RAISE EXCEPTION 'COST_PRICE_NOT_AVAILABLE'
                USING DETAIL = format('No cost price available for [%s] %s at %s — it has no prior stock movement to derive a value from.',
                    (SELECT product_code FROM rim_products WHERE id = v_line.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_line.product_id),
                    (SELECT location_name FROM ric_locations WHERE id = v_header.from_location_id));
        END IF;

        v_sales_price := CASE WHEN v_posting_mode = 'INTER_ENTITY'
                               THEN coalesce(v_line.sales_price, v_cost_price)
                               ELSE NULL END;

        UPDATE rid_stock_transfer_lines SET cost_price = v_cost_price, sales_price = v_sales_price
        WHERE id = v_line.id;

        -- Stock: always leaves FROM immediately (TRANSFER_OUT), batch/serial
        -- branch mirrors fn_approve_grn's/fn_approve_purchase_return's
        -- v_has_batches/v_has_serials pattern exactly.
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.from_location_id, v_line.product_id,
                    p_transfer_date, 'TRANSFER_OUT', -v_batch.base_qty,
                    NULL, NULL, v_batch.batch_no, v_batch.expiry_date, NULL,
                    'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_TRANSFER' AND source_doc_no = p_transfer_no AND source_doc_date = p_transfer_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.from_location_id, v_line.product_id,
                    p_transfer_date, 'TRANSFER_OUT', -1,
                    NULL, NULL, NULL, NULL, v_serial_row.serial_no,
                    'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.from_location_id, v_line.product_id,
                p_transfer_date, 'TRANSFER_OUT', -v_line.base_qty,
                NULL, NULL, NULL, NULL, NULL,
                'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
            );
        END IF;

        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.from_location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        IF v_posting_mode = 'SAME_BOOK' THEN
            -- Resolved fresh per line (never cached across iterations) —
            -- a CATEGORY/ITEM-granularity setup could legitimately resolve
            -- a different transit account per product.
            v_transit_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.from_location_id, v_line.product_id, 'STOCK_IN_TRANSIT_ACCOUNT');
            IF v_transit_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Stock in Transit Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;

            v_stxj_lines := v_stxj_lines || jsonb_build_array(
                jsonb_build_object(
                    'account_id', v_transit_account, 'trans_nature', 'DR',
                    'trans_amount', v_cost_price * v_line.base_qty + v_line.charge_amount, 'trans_currency',
                        (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                    'base_amount', v_cost_price * v_line.base_qty + v_line.charge_amount, 'base_rate', 1,
                    'local_amount', (v_cost_price * v_line.base_qty + v_line.charge_amount), 'local_rate', 1,
                    'party_amount', v_cost_price * v_line.base_qty + v_line.charge_amount,
                        'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                    'source_line_type', 'STOCK_IN_TRANSIT', 'source_line_no', v_line.serial_no
                ),
                jsonb_build_object(
                    'account_id', v_stock_account, 'trans_nature', 'CR',
                    'trans_amount', v_cost_price * v_line.base_qty, 'trans_currency',
                        (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                    'base_amount', v_cost_price * v_line.base_qty, 'base_rate', 1,
                    'local_amount', v_cost_price * v_line.base_qty, 'local_rate', 1,
                    'party_amount', v_cost_price * v_line.base_qty,
                        'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                    'source_line_type', 'STOCK_REDUCTION', 'source_line_no', v_line.serial_no
                )
            );
        ELSE
            v_sales_total := v_sales_total + (v_sales_price * v_line.base_qty);
            v_cogs_total  := v_cogs_total + (v_cost_price * v_line.base_qty);

            v_stxc_lines := v_stxc_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'CR',
                'trans_amount', v_cost_price * v_line.base_qty, 'trans_currency',
                    (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_cost_price * v_line.base_qty, 'base_rate', 1,
                'local_amount', v_cost_price * v_line.base_qty, 'local_rate', 1,
                'party_amount', v_cost_price * v_line.base_qty,
                    'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'source_line_type', 'STOCK_REDUCTION', 'source_line_no', v_line.serial_no
            ));
        END IF;
    END LOOP;

    -- 7. Charges — SAME_BOOK only (inter-entity defers these to Receipt).
    IF v_posting_mode = 'SAME_BOOK' THEN
        FOR v_charge IN
            SELECT * FROM rid_stock_transfer_charge_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND transfer_no = p_transfer_no AND transfer_date = p_transfer_date AND is_deleted = false
        LOOP
            IF v_charge.gl_account_id IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
            END IF;
            v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge.gl_account_id,
                'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
                'trans_amount', v_charge.amount, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_charge.amount, 'base_rate', 1,
                'local_amount', v_charge.amount, 'local_rate', 1,
                'party_amount', v_charge.amount, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'source_line_type', 'CHARGE', 'source_line_no', v_charge.serial_no
            ));
        END LOOP;

        SELECT trans_no, trans_date INTO v_stxj_trans_no, v_stxj_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.from_location_id, 'STXJ', p_transfer_date,
            v_stxj_lines, 'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
        );
    ELSE
        v_stxs_lines := jsonb_build_array(
            jsonb_build_object(
                'account_id', v_customer_account, 'trans_nature', 'DR',
                'trans_amount', v_sales_total, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_sales_total, 'base_rate', 1,
                'local_amount', v_sales_total, 'local_rate', 1,
                'party_amount', v_sales_total, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'inv_bill_no', p_transfer_no, 'inv_bill_date', p_transfer_date,
                'source_line_type', 'INTER_ENTITY_RECEIVABLE'
            ),
            jsonb_build_object(
                'account_id', v_ie_sales_account, 'trans_nature', 'CR',
                'trans_amount', v_sales_total, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
                'base_amount', v_sales_total, 'base_rate', 1,
                'local_amount', v_sales_total, 'local_rate', 1,
                'party_amount', v_sales_total, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
                'source_line_type', 'INTER_ENTITY_SALES'
            )
        );
        SELECT trans_no, trans_date INTO v_stxs_trans_no, v_stxs_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.from_location_id, 'STXS', p_transfer_date,
            v_stxs_lines, 'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
        );

        v_stxc_lines := jsonb_build_array(jsonb_build_object(
            'account_id', v_ie_cogs_account, 'trans_nature', 'DR',
            'trans_amount', v_cogs_total, 'trans_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id),
            'base_amount', v_cogs_total, 'base_rate', 1,
            'local_amount', v_cogs_total, 'local_rate', 1,
            'party_amount', v_cogs_total, 'party_currency', (SELECT base_currency FROM ric_companies WHERE id = p_company_id), 'party_rate', 1,
            'source_line_type', 'INTER_ENTITY_COGS'
        )) || v_stxc_lines;
        SELECT trans_no, trans_date INTO v_stxc_trans_no, v_stxc_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.from_location_id, 'STXC', p_transfer_date,
            v_stxc_lines, 'STOCK_TRANSFER', p_transfer_no, p_transfer_date, p_approved_by
        );
    END IF;

    -- 8. Recompute status of the referenced request, if any — unconditional,
    --    same rollup pattern as Material Requisition/Issue.
    IF v_header.against_request THEN
        SELECT coalesce(sum(base_qty), 0), coalesce(sum(transferred_qty), 0)
        INTO v_req_total_ordered, v_req_total_transferred
        FROM rid_stock_transfer_request_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND request_no = v_header.source_request_no AND request_date = v_header.source_request_date
          AND is_deleted = false;

        UPDATE rih_stock_transfer_requests SET
            status = CASE WHEN v_req_total_transferred >= v_req_total_ordered THEN 'CLOSED' ELSE 'PARTIALLY_TRANSFERRED' END,
            updated_at = now(), updated_by = p_approved_by
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND request_no = v_header.source_request_no AND request_date = v_header.source_request_date
          AND status IN ('APPROVED', 'PARTIALLY_TRANSFERRED');
    END IF;

    -- 9. Mark the transfer approved.
    UPDATE rih_stock_transfers SET
        status = 'APPROVED',
        posting_mode = v_posting_mode,
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no   = coalesce(v_stxc_trans_no, v_stxj_trans_no),
        posted_voucher_date = coalesce(v_stxc_trans_date, v_stxj_trans_date),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_transfer(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── 10. fn_save_stock_receipt ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_stock_receipt(
    p_header  JSONB,
    p_lines   JSONB,   -- [{serial_no, source_transfer_line_serial, product_id, uom_id, uom_conversion_factor, received_qty_pack, received_qty_loose, received_base_qty, barcode, remarks}, ...]
    p_batches JSONB,
    p_serials JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     UUID;
    v_company_id    UUID;
    v_receipt_no    TEXT;
    v_receipt_date  DATE;
    v_transfer_no   TEXT;
    v_transfer_date DATE;
    v_old_status    TEXT;
    v_is_new        BOOLEAN;
    v_line          JSONB;
    v_batch         JSONB;
    v_transfer      rih_stock_transfers%ROWTYPE;
    v_line_qty      NUMERIC;
    v_batch_qty_sum NUMERIC;
BEGIN
    v_client_id     := (p_header->>'client_id')::uuid;
    v_company_id    := (p_header->>'company_id')::uuid;
    v_receipt_no    := nullif(trim(p_header->>'receipt_no'), '');
    v_receipt_date  := (p_header->>'receipt_date')::date;
    v_transfer_no   := p_header->>'source_transfer_no';
    v_transfer_date := (p_header->>'source_transfer_date')::date;
    v_is_new        := v_receipt_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Stock Receipt.';
    END IF;

    SELECT * INTO v_transfer FROM rih_stock_transfers
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND transfer_no = v_transfer_no AND transfer_date = v_transfer_date
      AND is_deleted = false
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Transfer % not found.', v_transfer_no;
    END IF;
    IF v_transfer.status != 'APPROVED' THEN
        RAISE EXCEPTION 'Stock Transfer % is % — only an APPROVED transfer can be received.', v_transfer.transfer_no, v_transfer.status;
    END IF;

    IF v_is_new THEN
        v_receipt_no := fn_next_trans_no(v_client_id, v_company_id, v_transfer.to_location_id, 'SRCP');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_receipts
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND receipt_no = v_receipt_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Receipt % is % and cannot be edited.', v_receipt_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = v_receipt_no AND source_doc_date = v_receipt_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = v_receipt_no AND source_doc_date = v_receipt_date;

        DELETE FROM rid_stock_receipt_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND receipt_no = v_receipt_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_receipts (
            client_id, company_id, from_location_id, to_location_id,
            source_transfer_no, source_transfer_date, receipt_no, receipt_date, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_transfer.from_location_id, v_transfer.to_location_id,
            v_transfer_no, v_transfer_date, v_receipt_no, v_receipt_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_receipts SET
            receipt_date = v_receipt_date,
            remarks      = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND receipt_no = v_receipt_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_stock_receipt_lines (
            client_id, company_id, receipt_no, receipt_date, serial_no,
            source_transfer_line_serial, product_id, uom_id, uom_conversion_factor,
            received_qty_pack, received_qty_loose, received_base_qty, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_receipt_no, v_receipt_date, (v_line->>'serial_no')::integer,
            (v_line->>'source_transfer_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'received_qty_pack')::numeric, 0), coalesce((v_line->>'received_qty_loose')::numeric, 0),
            coalesce((v_line->>'received_base_qty')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        v_line_qty := coalesce((v_line->>'received_base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'STOCK_RECEIPT', v_receipt_no, v_receipt_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the received quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'STOCK_RECEIPT', v_receipt_no, v_receipt_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    RETURN v_receipt_no;
END;
$$;


-- ── 11. fn_approve_stock_receipt ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_stock_receipt(
    p_client_id   UUID,
    p_company_id  UUID,
    p_receipt_no  TEXT,
    p_receipt_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header           rih_stock_receipts%ROWTYPE;
    v_transfer         rih_stock_transfers%ROWTYPE;
    v_from_group_id    UUID;
    v_supplier_account UUID;
    v_from_group_name  TEXT;
    v_line             RECORD;
    v_transfer_line    rid_stock_transfer_lines%ROWTYPE;
    v_batch            rid_transaction_line_batches%ROWTYPE;
    v_serial_row       rid_transaction_line_serials%ROWTYPE;
    v_charge           RECORD;
    v_has_batches      BOOLEAN;
    v_has_serials      BOOLEAN;
    v_shortfall_qty    NUMERIC;
    v_unit_value       NUMERIC;
    v_stock_account    UUID;
    v_loss_account     UUID;
    v_stxj_lines       JSONB := '[]'::jsonb;
    v_stxp_lines       JSONB := '[]'::jsonb;
    v_stxp_total       NUMERIC := 0;
    v_trans_no         TEXT; v_trans_date DATE;
    v_base_ccy         TEXT;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_stock_receipts
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Receipt % dated % not found', p_receipt_no, p_receipt_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Receipt % is % and cannot be approved again', p_receipt_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_receipt_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_RECEIPT', p_receipt_date);

    IF p_receipt_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Receipt date %s is in the future — a stock receipt cannot be dated ahead of today.', p_receipt_date);
    END IF;

    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = p_company_id;

    -- 3. Lock the Transfer header, read its stored posting_mode.
    SELECT * INTO v_transfer FROM rih_stock_transfers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND transfer_no = v_header.source_transfer_no AND transfer_date = v_header.source_transfer_date
    FOR UPDATE;

    IF v_transfer.status != 'APPROVED' THEN
        RAISE EXCEPTION 'Stock Transfer % is % — only an APPROVED transfer can be received.', v_transfer.transfer_no, v_transfer.status;
    END IF;

    IF v_transfer.posting_mode = 'INTER_ENTITY' THEN
        SELECT group_id INTO v_from_group_id FROM ric_locations WHERE id = v_transfer.from_location_id;
        SELECT supplier_account_id, group_name INTO v_supplier_account, v_from_group_name
        FROM ric_location_groups WHERE id = v_from_group_id;

        IF v_supplier_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('Location group "%s" has no Supplier Account configured — set it up in Location Groups first.', v_from_group_name);
        END IF;
    END IF;

    -- 4. Per line: lock the transfer line, post stock IN for what was
    --    actually received, write off any shortfall, accumulate GL.
    --    Sorted by product_id — fixed lock-ordering rule.
    FOR v_line IN
        SELECT * FROM rid_stock_receipt_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND receipt_no = p_receipt_no AND receipt_date = p_receipt_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        SELECT * INTO v_transfer_line FROM rid_stock_transfer_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND transfer_no = v_transfer.transfer_no AND transfer_date = v_transfer.transfer_date
          AND serial_no = v_line.source_transfer_line_serial
        FOR UPDATE;

        IF v_line.received_base_qty > v_transfer_line.base_qty THEN
            RAISE EXCEPTION 'RECEIPT_QTY_EXCEEDS_TRANSFERRED'
                USING DETAIL = format('Line %s: received qty %s exceeds the transferred qty %s.',
                    v_line.serial_no, v_line.received_base_qty, v_transfer_line.base_qty);
        END IF;

        v_shortfall_qty := v_transfer_line.base_qty - v_line.received_base_qty;

        -- Stock: IN at TO for what actually arrived — batch/serial branch
        -- mirrors fn_approve_grn's v_has_batches/v_has_serials pattern,
        -- using THIS RECEIPT's own allocation (a subset of what the
        -- transfer originally dispatched).
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_transfer.posting_mode = 'SAME_BOOK' THEN
            v_unit_value := (v_transfer_line.cost_price * v_transfer_line.base_qty + v_transfer_line.charge_amount)
                            / NULLIF(v_transfer_line.base_qty, 0);
        ELSE
            v_unit_value := (v_transfer_line.sales_price * v_transfer_line.base_qty + v_transfer_line.charge_amount)
                            / NULLIF(v_transfer_line.base_qty, 0);
        END IF;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id,
                    p_receipt_date, 'TRANSFER_IN', v_batch.base_qty,
                    v_unit_value, v_unit_value, v_batch.batch_no, v_batch.expiry_date, NULL,
                    'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_RECEIPT' AND source_doc_no = p_receipt_no AND source_doc_date = p_receipt_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id,
                    p_receipt_date, 'TRANSFER_IN', 1,
                    v_unit_value, v_unit_value, NULL, NULL, v_serial_row.serial_no,
                    'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
                );
            END LOOP;
        ELSIF v_line.received_base_qty > 0 THEN
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id,
                p_receipt_date, 'TRANSFER_IN', v_line.received_base_qty,
                v_unit_value, v_unit_value, NULL, NULL, NULL,
                'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
            );
        END IF;

        v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id, 'STOCK_ACCOUNT');
        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        IF v_shortfall_qty > 0 THEN
            v_loss_account := fn_resolve_account_link(p_client_id, p_company_id, v_transfer.to_location_id, v_line.product_id, 'STOCK_TRANSFER_LOSS_ACCOUNT');
            IF v_loss_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Stock Transfer Loss Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;
        END IF;

        IF v_transfer.posting_mode = 'SAME_BOOK' THEN
            v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'DR',
                'trans_amount', v_line.received_base_qty * v_unit_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line.received_base_qty * v_unit_value, 'base_rate', 1,
                'local_amount', v_line.received_base_qty * v_unit_value, 'local_rate', 1,
                'party_amount', v_line.received_base_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_RECEIVED', 'source_line_no', v_line.serial_no
            ));
            IF v_shortfall_qty > 0 THEN
                v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_loss_account, 'trans_nature', 'DR',
                    'trans_amount', v_shortfall_qty * v_unit_value, 'trans_currency', v_base_ccy,
                    'base_amount', v_shortfall_qty * v_unit_value, 'base_rate', 1,
                    'local_amount', v_shortfall_qty * v_unit_value, 'local_rate', 1,
                    'party_amount', v_shortfall_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                    'source_line_type', 'TRANSFER_LOSS', 'source_line_no', v_line.serial_no
                ));
            END IF;
            v_stxj_lines := v_stxj_lines || jsonb_build_array(jsonb_build_object(
                'account_id', fn_resolve_account_link(p_client_id, p_company_id, v_transfer.from_location_id, v_line.product_id, 'STOCK_IN_TRANSIT_ACCOUNT'),
                'trans_nature', 'CR',
                'trans_amount', v_transfer_line.base_qty * v_unit_value, 'trans_currency', v_base_ccy,
                'base_amount', v_transfer_line.base_qty * v_unit_value, 'base_rate', 1,
                'local_amount', v_transfer_line.base_qty * v_unit_value, 'local_rate', 1,
                'party_amount', v_transfer_line.base_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_IN_TRANSIT_CLEARED', 'source_line_no', v_line.serial_no
            ));
        ELSE
            v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_stock_account, 'trans_nature', 'DR',
                'trans_amount', v_line.received_base_qty * v_unit_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line.received_base_qty * v_unit_value, 'base_rate', 1,
                'local_amount', v_line.received_base_qty * v_unit_value, 'local_rate', 1,
                'party_amount', v_line.received_base_qty * v_unit_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'STOCK_RECEIVED', 'source_line_no', v_line.serial_no
            ));
            IF v_shortfall_qty > 0 THEN
                v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_loss_account, 'trans_nature', 'DR',
                    'trans_amount', v_shortfall_qty * v_transfer_line.sales_price, 'trans_currency', v_base_ccy,
                    'base_amount', v_shortfall_qty * v_transfer_line.sales_price, 'base_rate', 1,
                    'local_amount', v_shortfall_qty * v_transfer_line.sales_price, 'local_rate', 1,
                    'party_amount', v_shortfall_qty * v_transfer_line.sales_price, 'party_currency', v_base_ccy, 'party_rate', 1,
                    'source_line_type', 'TRANSFER_LOSS', 'source_line_no', v_line.serial_no
                ));
            END IF;
            v_stxp_total := v_stxp_total + (v_transfer_line.base_qty * v_transfer_line.sales_price);
        END IF;
    END LOOP;

    -- 5. Inter-entity only: aggregate Supplier Cr (full transferred value,
    --    tagged with the transfer's own number so it rides the existing
    --    pending-bills mechanism) + each charge's own account (deferred
    --    from Transfer, per 073's design — posted here, once per charge,
    --    full amount, nature-aware).
    IF v_transfer.posting_mode = 'INTER_ENTITY' THEN
        v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_supplier_account, 'trans_nature', 'CR',
            'trans_amount', v_stxp_total, 'trans_currency', v_base_ccy,
            'base_amount', v_stxp_total, 'base_rate', 1,
            'local_amount', v_stxp_total, 'local_rate', 1,
            'party_amount', v_stxp_total, 'party_currency', v_base_ccy, 'party_rate', 1,
            'inv_bill_no', v_transfer.transfer_no, 'inv_bill_date', v_transfer.transfer_date,
            'source_line_type', 'INTER_ENTITY_PAYABLE'
        ));

        FOR v_charge IN
            SELECT * FROM rid_stock_transfer_charge_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND transfer_no = v_transfer.transfer_no AND transfer_date = v_transfer.transfer_date AND is_deleted = false
        LOOP
            IF v_charge.gl_account_id IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('Charge %s has no GL account configured.', v_charge.charge_name);
            END IF;
            v_stxp_lines := v_stxp_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_charge.gl_account_id,
                'trans_nature', CASE WHEN v_charge.nature = 'DEDUCT' THEN 'DR' ELSE 'CR' END,
                'trans_amount', v_charge.amount, 'trans_currency', v_base_ccy,
                'base_amount', v_charge.amount, 'base_rate', 1,
                'local_amount', v_charge.amount, 'local_rate', 1,
                'party_amount', v_charge.amount, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'CHARGE', 'source_line_no', v_charge.serial_no
            ));
        END LOOP;
    END IF;

    -- 6. Post the one voucher for this receipt.
    IF v_transfer.posting_mode = 'SAME_BOOK' THEN
        SELECT trans_no, trans_date INTO v_trans_no, v_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_transfer.to_location_id, 'STXJ', p_receipt_date,
            v_stxj_lines, 'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
        );
    ELSE
        SELECT trans_no, trans_date INTO v_trans_no, v_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_transfer.to_location_id, 'STXP', p_receipt_date,
            v_stxp_lines, 'STOCK_RECEIPT', p_receipt_no, p_receipt_date, p_approved_by
        );
    END IF;

    -- 7. Close the transfer — one receipt per transfer, always final.
    UPDATE rih_stock_transfers SET
        status = 'CLOSED',
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_transfer.id;

    -- 8. Mark the receipt approved.
    UPDATE rih_stock_receipts SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_trans_no,
        posted_voucher_date = v_trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_receipt(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── 12. fn_save_stock_adjustment (latest, widened by 079) ───────────────────
CREATE OR REPLACE FUNCTION fn_save_stock_adjustment(
    p_header  JSONB,
    p_lines   JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_location_id    UUID;
    v_adjustment_no  TEXT;
    v_adjustment_date DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
    v_batch          JSONB;
    v_line_qty       NUMERIC;
    v_batch_qty_sum  NUMERIC;
BEGIN
    v_client_id       := (p_header->>'client_id')::uuid;
    v_company_id      := (p_header->>'company_id')::uuid;
    v_location_id     := (p_header->>'location_id')::uuid;
    v_adjustment_no   := nullif(trim(p_header->>'adjustment_no'), '');
    v_adjustment_date := (p_header->>'adjustment_date')::date;
    v_is_new          := v_adjustment_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Stock Adjustment.';
    END IF;

    IF v_is_new THEN
        v_adjustment_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'ADJ');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_adjustment_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND adjustment_no = v_adjustment_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Adjustment % is % and cannot be edited.', v_adjustment_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = v_adjustment_no AND source_doc_date = v_adjustment_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = v_adjustment_no AND source_doc_date = v_adjustment_date;

        DELETE FROM rid_stock_adjustment_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND adjustment_no = v_adjustment_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_adjustment_headers (
            client_id, company_id, location_id, adjustment_no, adjustment_date,
            reason_id, remarks, source_doc_type, source_doc_no, source_doc_date,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_adjustment_no, v_adjustment_date,
            nullif(p_header->>'reason_id', '')::uuid, nullif(p_header->>'remarks', ''),
            nullif(p_header->>'source_doc_type', ''), nullif(p_header->>'source_doc_no', ''),
            (nullif(p_header->>'source_doc_date', ''))::date,
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_stock_adjustment_headers SET
            location_id     = v_location_id,
            adjustment_date = v_adjustment_date,
            reason_id       = nullif(p_header->>'reason_id', '')::uuid,
            remarks         = nullif(p_header->>'remarks', ''),
            source_doc_type = nullif(p_header->>'source_doc_type', ''),
            source_doc_no   = nullif(p_header->>'source_doc_no', ''),
            source_doc_date = (nullif(p_header->>'source_doc_date', ''))::date,
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND adjustment_no = v_adjustment_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_stock_adjustment_lines (
            client_id, company_id, adjustment_no, adjustment_date, serial_no,
            product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty,
            adjust_flag, system_qty, barcode, reason_id, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_adjustment_no, v_adjustment_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            v_line->>'adjust_flag',
            nullif(v_line->>'system_qty', '')::numeric,
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'reason_id', '')::uuid,
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        v_line_qty := coalesce((v_line->>'base_qty')::numeric, 0);
        v_batch_qty_sum := 0;

        FOR v_batch IN
            SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
        LOOP
            INSERT INTO rid_transaction_line_batches (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
            ) VALUES (
                v_client_id, v_company_id, 'STOCK_ADJUSTMENT', v_adjustment_no, v_adjustment_date, (v_line->>'serial_no')::integer,
                v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
                coalesce((v_batch->>'qty_pack')::numeric, 0),
                coalesce((v_batch->>'qty_loose')::numeric, 0),
                coalesce((v_batch->>'base_qty')::numeric, 0),
                p_user_id
            );
            v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
        END LOOP;

        IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
            RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                USING DETAIL = format('Line %s: batch quantities sum to %s but the adjustment quantity is %s.',
                                       v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
        END IF;

        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        )
        SELECT
            v_client_id, v_company_id, 'STOCK_ADJUSTMENT', v_adjustment_no, v_adjustment_date, (v_line->>'serial_no')::integer,
            value->>'serial_no', p_user_id
        FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
        WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
    END LOOP;

    RETURN v_adjustment_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_stock_adjustment(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ── 13. fn_approve_stock_adjustment ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_stock_adjustment(
    p_client_id      UUID,
    p_company_id     UUID,
    p_adjustment_no  TEXT,
    p_adjustment_date DATE,
    p_approved_by    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header          rih_stock_adjustment_headers%ROWTYPE;
    v_base_ccy        TEXT;
    v_local_ccy       TEXT;
    v_rate_to_local   NUMERIC;
    v_line            RECORD;
    v_batch           rid_transaction_line_batches%ROWTYPE;
    v_serial_row      rid_transaction_line_serials%ROWTYPE;
    v_has_batches     BOOLEAN;
    v_has_serials     BOOLEAN;
    v_cost_price      NUMERIC;
    v_cost_price_spec NUMERIC;
    v_line_value      NUMERIC;
    v_signed_qty      NUMERIC;
    v_trans_type      TEXT;
    v_stock_account   UUID;
    v_adjustment_account UUID;
    v_adjv_lines      JSONB := '[]'::jsonb;
    v_adjv_trans_no   TEXT;
    v_adjv_trans_date DATE;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_stock_adjustment_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND adjustment_no = p_adjustment_no AND adjustment_date = p_adjustment_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Adjustment % dated % not found', p_adjustment_no, p_adjustment_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Adjustment % is % and cannot be approved again', p_adjustment_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_adjustment_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_ADJUSTMENT', p_adjustment_date);

    IF p_adjustment_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Adjustment date %s is in the future — a Stock Adjustment cannot be dated ahead of today.', p_adjustment_date);
    END IF;

    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_rate_to_local := CASE WHEN v_base_ccy = v_local_ccy THEN 1
                            ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_adjustment_date) END;

    -- 3. Per line: lock the balance row, fetch current cost, validate,
    --    branch batch/serial/aggregate posting, accumulate GL lines.
    --    Sorted by product_id — the only row-type here, so no multi-type
    --    lock-order concern like GRN/Material Issue have.
    FOR v_line IN
        SELECT * FROM rid_stock_adjustment_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND adjustment_no = p_adjustment_no AND adjustment_date = p_adjustment_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_line.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT cost_price, cost_price_specific INTO v_cost_price, v_cost_price_spec
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

        IF v_line.adjust_flag = '+' AND coalesce(v_cost_price, 0) = 0 THEN
            RAISE EXCEPTION 'COST_NOT_ESTABLISHED'
                USING DETAIL = format(
                    'Line %s: [%s] %s has no established cost at this location yet — receive it via GRN first, or set an opening cost, before adjusting it upward.',
                    v_line.serial_no,
                    (SELECT product_code FROM rim_products WHERE id = v_line.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        UPDATE rid_stock_adjustment_lines SET
            unit_cost = v_cost_price, unit_cost_specific = v_cost_price_spec,
            updated_at = now(), updated_by = p_approved_by
        WHERE id = v_line.id;

        v_line_value := v_line.base_qty * coalesce(v_cost_price, 0);
        v_signed_qty := CASE WHEN v_line.adjust_flag = '+' THEN v_line.base_qty ELSE -v_line.base_qty END;
        v_trans_type := CASE WHEN v_line.adjust_flag = '+' THEN 'ADJUSTMENT_IN' ELSE 'ADJUSTMENT_OUT' END;

        -- Stock movement: batch/serial-tracked lines post one row per
        -- batch/unit so each one's own strict, flag-independent balance
        -- check (063) fires — mirrors fn_approve_material_issue's
        -- v_has_batches/v_has_serials pattern exactly. Only inward ('+')
        -- movements pass a unit cost; outward ('-') movements let
        -- fn_post_stock_movement snapshot the current average itself.
        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_batches
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_batches;

        SELECT EXISTS (
            SELECT 1 FROM rid_transaction_line_serials
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
              AND line_serial = v_line.serial_no
        ) INTO v_has_serials;

        IF v_has_batches THEN
            FOR v_batch IN
                SELECT * FROM rid_transaction_line_batches
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_adjustment_date, v_trans_type,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_batch.base_qty ELSE -v_batch.base_qty END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price ELSE NULL END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price_spec ELSE NULL END,
                    v_batch.batch_no, v_batch.expiry_date, NULL,
                    'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by,
                    p_manufacturing_date => v_batch.manufacturing_date
                );
            END LOOP;
        ELSIF v_has_serials THEN
            FOR v_serial_row IN
                SELECT * FROM rid_transaction_line_serials
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND source_doc_type = 'STOCK_ADJUSTMENT' AND source_doc_no = p_adjustment_no AND source_doc_date = p_adjustment_date
                  AND line_serial = v_line.serial_no
            LOOP
                PERFORM fn_post_stock_movement(
                    p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                    p_adjustment_date, v_trans_type,
                    CASE WHEN v_line.adjust_flag = '+' THEN 1 ELSE -1 END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price ELSE NULL END,
                    CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price_spec ELSE NULL END,
                    NULL, NULL, v_serial_row.serial_no,
                    'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by
                );
            END LOOP;
        ELSE
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_adjustment_date, v_trans_type, v_signed_qty,
                CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price ELSE NULL END,
                CASE WHEN v_line.adjust_flag = '+' THEN v_cost_price_spec ELSE NULL END,
                NULL, NULL, NULL,
                'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by
            );
        END IF;

        -- GL: Dr/Cr direction flips with adjust_flag; both accounts
        -- resolved via the existing fn_resolve_account_link cascade.
        v_stock_account      := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
        v_adjustment_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ADJUSTMENT_ACCOUNT');

        IF v_stock_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;
        IF v_adjustment_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No Stock Adjustment Account resolved for product %s.',
                    (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
        END IF;

        v_adjv_lines := v_adjv_lines || jsonb_build_array(
            jsonb_build_object(
                'account_id', CASE WHEN v_line.adjust_flag = '+' THEN v_stock_account ELSE v_adjustment_account END,
                'trans_nature', 'DR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', CASE WHEN v_line.adjust_flag = '+' THEN 'STOCK_INCREASE' ELSE 'STOCK_ADJUSTMENT_CONTRA' END,
                'source_line_no', v_line.serial_no
            ),
            jsonb_build_object(
                'account_id', CASE WHEN v_line.adjust_flag = '+' THEN v_adjustment_account ELSE v_stock_account END,
                'trans_nature', 'CR',
                'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                'base_amount', v_line_value, 'base_rate', 1,
                'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', CASE WHEN v_line.adjust_flag = '+' THEN 'STOCK_ADJUSTMENT_CONTRA' ELSE 'STOCK_DECREASE' END,
                'source_line_no', v_line.serial_no
            )
        );
    END LOOP;

    -- 4. Post the ADJV voucher (skipped only if every line valued at zero,
    --    which would mean nothing to post — treated as a hard error since
    --    a '+' line already blocks on zero cost, and a '-' line valued at
    --    zero would still legitimately need a stock-quantity movement, so
    --    an all-zero document indicates no lines at all).
    IF jsonb_array_length(v_adjv_lines) = 0 THEN
        RAISE EXCEPTION 'NO_ADJUSTMENT_LINES'
            USING DETAIL = 'This adjustment has no lines to post.';
    END IF;

    SELECT trans_no, trans_date INTO v_adjv_trans_no, v_adjv_trans_date FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'ADJV', p_adjustment_date,
        v_adjv_lines, 'STOCK_ADJUSTMENT', p_adjustment_no, p_adjustment_date, p_approved_by
    );

    -- 5. Mark the adjustment approved.
    UPDATE rih_stock_adjustment_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_adjv_trans_no,
        posted_voucher_date = v_adjv_trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_adjustment(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── 14. fn_save_opening_stock ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_opening_stock(
    p_header  JSONB,
    p_lines   JSONB,   -- [{line_no, product_id, uom_id, uom_conversion_factor, pack_qty, loose_qty, base_qty, batch_no, expiry_date, serial_no, unit_cost, barcode, remarks}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id    UUID;
    v_company_id   UUID;
    v_location_id  UUID;
    v_opening_no   TEXT;
    v_opening_date DATE;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_opening_no   := nullif(trim(p_header->>'opening_no'), '');
    v_opening_date := (p_header->>'opening_date')::date;
    v_is_new       := v_opening_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise an Opening Stock entry.';
    END IF;

    IF v_is_new THEN
        v_opening_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'OPST');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_opening_stock_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND opening_no = v_opening_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Opening Stock % is % and cannot be edited.', v_opening_no, v_old_status;
        END IF;

        DELETE FROM rid_opening_stock_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND opening_no = v_opening_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_opening_stock_headers (
            client_id, company_id, location_id, opening_no, opening_date,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_opening_no, v_opening_date,
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_opening_stock_headers SET
            location_id  = v_location_id,
            opening_date = v_opening_date,
            remarks      = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND opening_no = v_opening_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_opening_stock_lines (
            client_id, company_id, opening_no, opening_date, line_no,
            product_id, uom_id, uom_conversion_factor, pack_qty, loose_qty, base_qty,
            batch_no, expiry_date, manufacturing_date, serial_no, unit_cost, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_opening_no, v_opening_date, (v_line->>'line_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'pack_qty')::numeric, 0), coalesce((v_line->>'loose_qty')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'batch_no', ''), (nullif(v_line->>'expiry_date', ''))::date, (nullif(v_line->>'manufacturing_date', ''))::date, nullif(v_line->>'serial_no', ''),
            coalesce((v_line->>'unit_cost')::numeric, 0),
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_opening_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_opening_stock(JSONB, JSONB, UUID) TO authenticated;


-- ── 15. fn_approve_opening_stock ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_opening_stock(
    p_client_id     UUID,
    p_company_id    UUID,
    p_opening_no    TEXT,
    p_opening_date  DATE,
    p_approved_by   UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header           rih_opening_stock_headers%ROWTYPE;
    v_line             RECORD;
    v_pl_id            UUID;
    v_current_stock    NUMERIC;
    v_current_cost     NUMERIC;
    v_base_ccy         TEXT;
    v_cost_ccy         TEXT;
    v_unit_cost_spec   NUMERIC;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_opening_stock_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND opening_no = p_opening_no AND opening_date = p_opening_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Opening Stock % dated % not found', p_opening_no, p_opening_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Opening Stock % is % and cannot be approved again', p_opening_no, v_header.status;
    END IF;

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_opening_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'OPENING_STOCK', p_opening_date);

    IF p_opening_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Opening date %s is in the future — an Opening Stock entry cannot be dated ahead of today.', p_opening_date);
    END IF;

    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = p_company_id;

    -- 3. Per line: lock the balance row, block on already-established
    --    stock/cost, derive unit_cost_specific, post the movement.
    --    Sorted by product_id — the only row-type here, so no multi-type
    --    lock-order concern like GRN/Material Issue have.
    FOR v_line IN
        SELECT * FROM rid_opening_stock_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND opening_no = p_opening_no AND opening_date = p_opening_date AND is_deleted = false
        ORDER BY product_id, line_no
    LOOP
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_line.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT id, current_stock, cost_price INTO v_pl_id, v_current_stock, v_current_cost
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

        IF coalesce(v_current_stock, 0) <> 0 OR coalesce(v_current_cost, 0) <> 0 THEN
            RAISE EXCEPTION 'OPENING_STOCK_ALREADY_ESTABLISHED'
                USING DETAIL = format(
                    'Line %s: [%s] %s already has stock/cost established at this location (qty %s, cost %s) — Opening Stock can only be used before any other stock movement.',
                    v_line.line_no,
                    (SELECT product_code FROM rim_products WHERE id = v_line.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_line.product_id),
                    v_current_stock, v_current_cost);
        END IF;

        -- Derive unit_cost_specific from the entered unit_cost — same-
        -- currency shortcut if the product's own cost_currency_id matches
        -- base, otherwise a real fn_get_exchange_rate lookup. Never left
        -- unset, or cost_price_specific's own weighted average (a no-op
        -- here, since this is the very first inward movement) would be
        -- silently wrong for every future movement that reads it.
        SELECT c.currency_id INTO v_cost_ccy
        FROM rim_products p LEFT JOIN rim_currencies c ON c.id = p.cost_currency_id
        WHERE p.id = v_line.product_id;

        IF v_cost_ccy IS NULL OR v_cost_ccy = v_base_ccy THEN
            v_unit_cost_spec := v_line.unit_cost;
        ELSE
            v_unit_cost_spec := v_line.unit_cost * fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_cost_ccy, p_opening_date);
        END IF;

        UPDATE rid_opening_stock_lines SET
            unit_cost_specific = v_unit_cost_spec,
            updated_at = now(), updated_by = p_approved_by
        WHERE id = v_line.id;

        -- 4. Post the movement. One call per line — no v_has_batches/
        --    v_has_serials branching needed since batch/serial identity
        --    is already resolved per-line, not nested in a child table.
        PERFORM fn_post_stock_movement(
            p_client_id, p_company_id, v_header.location_id, v_line.product_id,
            p_opening_date, 'OPENING_STOCK', v_line.base_qty,
            v_line.unit_cost, v_unit_cost_spec,
            v_line.batch_no, v_line.expiry_date, v_line.serial_no,
            'OPENING_STOCK', p_opening_no, p_opening_date, p_approved_by,
            p_manufacturing_date => v_line.manufacturing_date
        );
    END LOOP;

    -- 5. No fn_post_voucher call — this document never posts to GL.

    -- 6. Mark the entry approved.
    UPDATE rih_opening_stock_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_opening_stock(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── 16. fn_save_stock_count ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_save_stock_count(
    p_header  JSONB,   -- {client_id, company_id, location_id, count_no, count_date, category_filter_id, nature_filter, remarks}
    p_lines   JSONB,   -- [{serial_no, product_id, uom_id, uom_conversion_factor, is_counted, counted_qty_pack, counted_qty_loose, counted_base_qty, barcode, remarks}, ...]
    p_batches JSONB,   -- [{line_serial, batch_no, expiry_date, qty_pack, qty_loose, base_qty}, ...]
    p_serials JSONB,   -- [{line_serial, serial_no}, ...]
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id      UUID;
    v_company_id     UUID;
    v_location_id    UUID;
    v_count_no       TEXT;
    v_count_date     DATE;
    v_old_status     TEXT;
    v_is_new         BOOLEAN;
    v_line           JSONB;
    v_batch          JSONB;
    v_is_counted     BOOLEAN;
    v_line_qty       NUMERIC;
    v_batch_qty_sum  NUMERIC;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_count_no    := nullif(trim(p_header->>'count_no'), '');
    v_count_date  := (p_header->>'count_date')::date;
    v_is_new      := v_count_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'No products in scope for this count — check the category/nature filter.';
    END IF;

    IF v_is_new THEN
        v_count_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'CNT');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_stock_count_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND count_no = v_count_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Stock Count % is % and cannot be edited.', v_count_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_COUNT' AND source_doc_no = v_count_no AND source_doc_date = v_count_date;
        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'STOCK_COUNT' AND source_doc_no = v_count_no AND source_doc_date = v_count_date;
        DELETE FROM rid_stock_count_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND count_no = v_count_no;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_stock_count_headers (
            client_id, company_id, location_id, count_no, count_date,
            category_filter_id, nature_filter, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_count_no, v_count_date,
            nullif(p_header->>'category_filter_id', '')::uuid, nullif(p_header->>'nature_filter', ''),
            nullif(p_header->>'remarks', ''), p_user_id, p_user_id
        );
    ELSE
        -- category_filter_id/nature_filter are immutable after creation — the
        -- worksheet's scope is fixed at first save, only counted values change.
        UPDATE rih_stock_count_headers SET
            location_id = v_location_id,
            count_date  = v_count_date,
            remarks     = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND count_no = v_count_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_is_counted := coalesce((v_line->>'is_counted')::boolean, false);

        INSERT INTO rid_stock_count_lines (
            client_id, company_id, count_no, count_date, serial_no,
            product_id, uom_id, uom_conversion_factor,
            is_counted, counted_qty_pack, counted_qty_loose, counted_base_qty,
            barcode, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_count_no, v_count_date, (v_line->>'serial_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            v_is_counted,
            CASE WHEN v_is_counted THEN coalesce((v_line->>'counted_qty_pack')::numeric, 0) END,
            CASE WHEN v_is_counted THEN coalesce((v_line->>'counted_qty_loose')::numeric, 0) END,
            CASE WHEN v_is_counted THEN coalesce((v_line->>'counted_base_qty')::numeric, 0) END,
            nullif(v_line->>'barcode', ''), nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );

        IF v_is_counted THEN
            v_line_qty := coalesce((v_line->>'counted_base_qty')::numeric, 0);
            v_batch_qty_sum := 0;

            FOR v_batch IN
                SELECT value FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
                WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer
            LOOP
                INSERT INTO rid_transaction_line_batches (
                    client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
                    batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
                ) VALUES (
                    v_client_id, v_company_id, 'STOCK_COUNT', v_count_no, v_count_date, (v_line->>'serial_no')::integer,
                    v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
                    coalesce((v_batch->>'qty_pack')::numeric, 0), coalesce((v_batch->>'qty_loose')::numeric, 0),
                    coalesce((v_batch->>'base_qty')::numeric, 0), p_user_id
                );
                v_batch_qty_sum := v_batch_qty_sum + coalesce((v_batch->>'base_qty')::numeric, 0);
            END LOOP;

            IF v_batch_qty_sum <> 0 AND abs(v_batch_qty_sum - v_line_qty) > 0.0001 THEN
                RAISE EXCEPTION 'BATCH_QTY_MISMATCH'
                    USING DETAIL = format('Line %s: batch quantities sum to %s but the counted quantity is %s.',
                                           v_line->>'serial_no', v_batch_qty_sum, v_line_qty);
            END IF;

            INSERT INTO rid_transaction_line_serials (
                client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
            )
            SELECT v_client_id, v_company_id, 'STOCK_COUNT', v_count_no, v_count_date, (v_line->>'serial_no')::integer,
                   value->>'serial_no', p_user_id
            FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
            WHERE (value->>'line_serial')::integer = (v_line->>'serial_no')::integer;
        END IF;
    END LOOP;

    RETURN v_count_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_stock_count(JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ── 17. fn_compute_stock_count_variance ──────────────────────────────────────
-- RETURNS TABLE is implemented via OUT parameters — Postgres refuses to let
-- CREATE OR REPLACE change the shape/order of those, so the new
-- manufacturing_date column (inserted mid-list, to sit next to expiry_date)
-- requires an explicit drop first.
DROP FUNCTION IF EXISTS fn_compute_stock_count_variance(UUID, UUID, TEXT, DATE);

CREATE OR REPLACE FUNCTION fn_compute_stock_count_variance(
    p_client_id   UUID,
    p_company_id  UUID,
    p_review_no   TEXT,
    p_review_date DATE
)
RETURNS TABLE (
    product_id        UUID,
    product_code       TEXT,
    product_name       TEXT,
    tracking_type      TEXT,
    batch_no            TEXT,
    expiry_date          DATE,
    manufacturing_date    DATE,
    serial_no             TEXT,
    counted_qty            NUMERIC,
    system_qty             NUMERIC,   -- SUM(ril_stock_ledger.qty_change) as of review.as_of_date
    variance_qty            NUMERIC,   -- counted - system
    adjust_flag              TEXT,      -- '+' / '-' / NULL (zero variance OR unknown serial — either way, no line posted)
    is_unknown_serial         BOOLEAN,   -- serial physically found but system_qty <= 0 here — exception, never auto-posted
    unit_cost                 NUMERIC    -- informational only; fn_approve_stock_adjustment re-fetches the real cost under lock
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_location_id UUID;
    v_as_of_date  DATE;
BEGIN
    SELECT location_id, as_of_date INTO v_location_id, v_as_of_date
    FROM rih_stock_count_review_headers
    WHERE client_id = p_client_id AND company_id = p_company_id AND review_no = p_review_no AND review_date = p_review_date;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Count Review % dated % not found', p_review_no, p_review_date;
    END IF;

    RETURN QUERY
    WITH sources AS (
        SELECT rs.source_count_no, rs.source_count_date FROM rid_stock_count_review_sources rs
        WHERE rs.client_id = p_client_id AND rs.company_id = p_company_id
          AND rs.review_no = p_review_no AND rs.review_date = p_review_date
    ),
    -- untracked: SUM across sources — same product counted in different,
    -- non-overlapping zones by different counters is genuinely additive.
    untracked_counts AS (
        SELECT l.product_id AS product_id, NULL::text AS batch_no, NULL::date AS expiry_date, NULL::date AS manufacturing_date, NULL::text AS serial_no,
               SUM(l.counted_base_qty) AS counted_qty
        FROM rid_stock_count_lines l
        JOIN sources s ON s.source_count_no = l.count_no AND s.source_count_date = l.count_date
        JOIN rim_products p ON p.id = l.product_id
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id AND l.is_deleted = false
          AND l.is_counted = true AND p.tracking_type = 'NONE'
        GROUP BY l.product_id
    ),
    -- batch: club by product+batch_no across sources — additive.
    batch_counts AS (
        SELECT l.product_id AS product_id, b.batch_no AS batch_no, max(b.expiry_date) AS expiry_date, max(b.manufacturing_date) AS manufacturing_date, NULL::text AS serial_no,
               SUM(b.base_qty) AS counted_qty
        FROM rid_stock_count_lines l
        JOIN sources s ON s.source_count_no = l.count_no AND s.source_count_date = l.count_date
        JOIN rid_transaction_line_batches b
          ON b.client_id = l.client_id AND b.company_id = l.company_id
         AND b.source_doc_type = 'STOCK_COUNT' AND b.source_doc_no = l.count_no AND b.source_doc_date = l.count_date
         AND b.line_serial = l.serial_no
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id AND l.is_deleted = false AND l.is_counted = true
        GROUP BY l.product_id, b.batch_no
    ),
    -- serial: DISTINCT, not SUM — a serial found in two overlapping counts
    -- is the SAME physical unit, never double-counted.
    serial_counts AS (
        SELECT DISTINCT l.product_id AS product_id, NULL::text AS batch_no, NULL::date AS expiry_date, NULL::date AS manufacturing_date, sr.serial_no AS serial_no,
               1::numeric AS counted_qty
        FROM rid_stock_count_lines l
        JOIN sources s ON s.source_count_no = l.count_no AND s.source_count_date = l.count_date
        JOIN rid_transaction_line_serials sr
          ON sr.client_id = l.client_id AND sr.company_id = l.company_id
         AND sr.source_doc_type = 'STOCK_COUNT' AND sr.source_doc_no = l.count_no AND sr.source_doc_date = l.count_date
         AND sr.line_serial = l.serial_no
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id AND l.is_deleted = false AND l.is_counted = true
    ),
    all_counts AS (
        SELECT * FROM untracked_counts
        UNION ALL SELECT * FROM batch_counts
        UNION ALL SELECT * FROM serial_counts
    ),
    system_untracked AS (
        SELECT sl.product_id AS product_id, SUM(sl.qty_change) AS system_qty
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.location_id = v_location_id AND sl.trans_date <= v_as_of_date
          AND sl.batch_no IS NULL AND sl.serial_no IS NULL
        GROUP BY sl.product_id
    ),
    system_batch AS (
        SELECT sl.product_id AS product_id, sl.batch_no AS batch_no, SUM(sl.qty_change) AS system_qty
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.location_id = v_location_id AND sl.trans_date <= v_as_of_date AND sl.batch_no IS NOT NULL
        GROUP BY sl.product_id, sl.batch_no
    ),
    system_serial AS (
        SELECT sl.product_id AS product_id, sl.serial_no AS serial_no, SUM(sl.qty_change) AS system_qty
        FROM ril_stock_ledger sl
        WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
          AND sl.location_id = v_location_id AND sl.trans_date <= v_as_of_date AND sl.serial_no IS NOT NULL
        GROUP BY sl.product_id, sl.serial_no
    )
    SELECT
        c.product_id, p.product_code, p.product_name, p.tracking_type, c.batch_no, c.expiry_date, c.manufacturing_date, c.serial_no,
        c.counted_qty,
        coalesce(CASE WHEN c.serial_no IS NOT NULL THEN ss.system_qty
                       WHEN c.batch_no  IS NOT NULL THEN sb.system_qty
                       ELSE su.system_qty END, 0) AS system_qty,
        c.counted_qty - coalesce(CASE WHEN c.serial_no IS NOT NULL THEN ss.system_qty
                                        WHEN c.batch_no  IS NOT NULL THEN sb.system_qty
                                        ELSE su.system_qty END, 0) AS variance_qty,
        CASE
            WHEN c.serial_no IS NOT NULL AND coalesce(ss.system_qty, 0) <= 0 THEN NULL
            WHEN (c.counted_qty - coalesce(CASE WHEN c.batch_no IS NOT NULL THEN sb.system_qty ELSE su.system_qty END, 0)) > 0 THEN '+'
            WHEN (c.counted_qty - coalesce(CASE WHEN c.batch_no IS NOT NULL THEN sb.system_qty ELSE su.system_qty END, 0)) < 0 THEN '-'
            ELSE NULL
        END AS adjust_flag,
        (c.serial_no IS NOT NULL AND coalesce(ss.system_qty, 0) <= 0) AS is_unknown_serial,
        pl.cost_price AS unit_cost
    FROM all_counts c
    JOIN rim_products p ON p.id = c.product_id
    LEFT JOIN system_untracked su ON su.product_id = c.product_id AND c.batch_no IS NULL AND c.serial_no IS NULL
    LEFT JOIN system_batch     sb ON sb.product_id = c.product_id AND sb.batch_no = c.batch_no
    LEFT JOIN system_serial    ss ON ss.product_id = c.product_id AND ss.serial_no = c.serial_no
    LEFT JOIN rim_product_location pl
           ON pl.client_id = p_client_id AND pl.company_id = p_company_id
          AND pl.location_id = v_location_id AND pl.product_id = c.product_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_compute_stock_count_variance(UUID, UUID, TEXT, DATE) TO authenticated;


-- ── 18. fn_approve_stock_count_review ────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_stock_count_review(
    p_client_id   UUID,
    p_company_id  UUID,
    p_review_no   TEXT,
    p_review_date DATE,
    p_approved_by UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_header        rih_stock_count_review_headers%ROWTYPE;
    v_src           RECORD;
    v_row           RECORD;
    v_serial_no     INTEGER := 0;
    v_adj_header    JSONB;
    v_adj_lines     JSONB := '[]'::jsonb;
    v_adj_batches   JSONB := '[]'::jsonb;
    v_adj_serials   JSONB := '[]'::jsonb;
    v_uom_id        UUID;
    v_adjustment_no TEXT;
    v_unknown_count INTEGER := 0;
BEGIN
    SELECT * INTO v_header FROM rih_stock_count_review_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND review_no = p_review_no AND review_date = p_review_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock Count Review % dated % not found', p_review_no, p_review_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Stock Count Review % is % and cannot be approved again', p_review_no, v_header.status;
    END IF;

    -- Defensive fail-fast (fn_approve_stock_adjustment re-checks this on
    -- adjustment_date = as_of_date too, once it's called below).
    PERFORM fn_check_period_open(p_company_id, v_header.as_of_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'STOCK_COUNT_REVIEW', v_header.as_of_date);
    IF v_header.as_of_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('As of date %s is in the future.', v_header.as_of_date);
    END IF;
    IF v_header.reason_id IS NULL THEN
        RAISE EXCEPTION 'A reason must be selected before this Review can be approved.';
    END IF;

    -- Lock every source count, fixed sort order (deadlock rule).
    FOR v_src IN
        SELECT source_count_no, source_count_date FROM rid_stock_count_review_sources
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND review_no = p_review_no AND review_date = p_review_date
        ORDER BY source_count_no, source_count_date
    LOOP
        PERFORM 1 FROM rih_stock_count_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND count_no = v_src.source_count_no AND count_date = v_src.source_count_date
        FOR UPDATE;
    END LOOP;

    FOR v_row IN SELECT * FROM fn_compute_stock_count_variance(p_client_id, p_company_id, p_review_no, p_review_date)
    LOOP
        IF v_row.is_unknown_serial THEN
            v_unknown_count := v_unknown_count + 1;
            CONTINUE;   -- never auto-created — resolved manually outside this module
        END IF;
        IF v_row.adjust_flag IS NULL THEN
            CONTINUE;   -- zero variance — no line
        END IF;

        v_serial_no := v_serial_no + 1;
        SELECT base_uom_id INTO v_uom_id FROM rim_products WHERE id = v_row.product_id;

        v_adj_lines := v_adj_lines || jsonb_build_array(jsonb_build_object(
            'serial_no', v_serial_no, 'product_id', v_row.product_id,
            'uom_id', v_uom_id, 'uom_conversion_factor', 1,
            'qty_pack', abs(v_row.variance_qty), 'qty_loose', 0, 'base_qty', abs(v_row.variance_qty),
            'adjust_flag', v_row.adjust_flag, 'system_qty', v_row.system_qty,
            'reason_id', v_header.reason_id,
            'remarks', format('Stock Count Review %s (as of %s)', p_review_no, v_header.as_of_date)
        ));

        IF v_row.batch_no IS NOT NULL THEN
            v_adj_batches := v_adj_batches || jsonb_build_array(jsonb_build_object(
                'line_serial', v_serial_no, 'batch_no', v_row.batch_no, 'expiry_date', v_row.expiry_date,
                'manufacturing_date', v_row.manufacturing_date,
                'qty_pack', abs(v_row.variance_qty), 'qty_loose', 0, 'base_qty', abs(v_row.variance_qty)
            ));
        ELSIF v_row.serial_no IS NOT NULL THEN
            v_adj_serials := v_adj_serials || jsonb_build_array(jsonb_build_object(
                'line_serial', v_serial_no, 'serial_no', v_row.serial_no
            ));
        END IF;
    END LOOP;

    IF jsonb_array_length(v_adj_lines) = 0 THEN
        RAISE EXCEPTION 'NO_VARIANCE_LINES'
            USING DETAIL = format('No non-zero variance to post (%s unknown-serial exception(s) were skipped — resolve those separately).', v_unknown_count);
    END IF;

    v_adj_header := jsonb_build_object(
        'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
        'adjustment_date', v_header.as_of_date, 'reason_id', v_header.reason_id,
        'remarks', format('Auto-posted from Stock Count Review %s', p_review_no),
        'source_doc_type', 'STOCK_COUNT_REVIEW', 'source_doc_no', p_review_no, 'source_doc_date', p_review_date
    );

    -- Compose the EXISTING engine — never write ril_stock_ledger/
    -- rid_finance_lines directly.
    v_adjustment_no := fn_save_stock_adjustment(v_adj_header, v_adj_lines, v_adj_batches, v_adj_serials, p_approved_by);
    PERFORM fn_approve_stock_adjustment(p_client_id, p_company_id, v_adjustment_no, v_header.as_of_date, p_approved_by);

    UPDATE rih_stock_count_review_headers SET
        status = 'APPROVED', approved_by = p_approved_by, approved_at = now(),
        posted_adjustment_no = v_adjustment_no, posted_adjustment_date = v_header.as_of_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;

    RETURN v_adjustment_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_stock_count_review(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
