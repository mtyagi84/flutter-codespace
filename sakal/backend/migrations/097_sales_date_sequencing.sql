-- ============================================================
-- Fix: date-sequencing checks missing across the Quotation -> Order ->
-- Invoice chain
--
-- Real gaps found in live testing: nothing stopped a Sales Order being
-- dated before the Quotation it was raised against, or a Sales Invoice
-- being dated before the Order/Quotation it was raised against. Both
-- fixes are added at the exact point each function already locks and
-- validates the source document -- no new lookups needed.
--
-- Both functions' signatures are unchanged (same params, same RETURNS
-- shape) -- safe CREATE OR REPLACE, no DROP FUNCTION needed. Full
-- bodies reproduced verbatim from 087_sales_order.sql/089_sales_invoice.sql
-- with only the two new date checks inserted.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_save_sales_order(
    p_header  JSONB,
    p_lines   JSONB,
    p_charges JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id         UUID;
    v_company_id        UUID;
    v_location_id       UUID;
    v_order_no          TEXT;
    v_order_date        DATE;
    v_old_order_date    DATE;
    v_old_status        TEXT;
    v_is_new            BOOLEAN;
    v_order_mode        TEXT;
    v_customer_id       UUID;
    v_quotation         rih_sales_quotations%ROWTYPE;
    v_can_override      BOOLEAN;
    v_can_discount      BOOLEAN;
    v_max_discount      NUMERIC;
    v_line              JSONB;
    v_serial            INTEGER;
    v_price             RECORD;
    v_rate              NUMERIC;
    v_price_source      TEXT;
    v_override_reason   TEXT;
    v_discount_pct      NUMERIC;
    v_source_line       rid_sales_quotation_lines%ROWTYPE;
    v_source_serial     INTEGER;
    v_remaining         NUMERIC;
    v_convert_qty       NUMERIC;
    v_charge            JSONB;
    v_order_currency_code TEXT;
    v_price_entry_no    TEXT;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_order_no    := nullif(trim(p_header->>'order_no'), '');
    v_order_date  := (p_header->>'order_date')::date;
    v_order_mode  := coalesce(p_header->>'order_mode', 'DIRECT');
    v_is_new      := v_order_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Order.';
    END IF;

    -- Resolve the acting user's Sales Controls fresh every save. A
    -- missing row leaves every SELECT'd column NULL; coalesce turns that
    -- into the safe all-false/0 default — never a separate IF NOT FOUND
    -- branch that could be forgotten.
    SELECT can_override_price, can_give_discount, max_discount_percent
      INTO v_can_override, v_can_discount, v_max_discount
    FROM ric_user_sales_controls
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND user_id = p_user_id AND is_deleted = false;
    v_can_override := coalesce(v_can_override, false);
    v_can_discount := coalesce(v_can_discount, false);

    v_customer_id := (nullif(p_header->>'customer_id', ''))::uuid;

    -- fn_get_active_price (086) needs the order's own currency as an ISO
    -- code, not the UUID, to know what to convert TO.
    SELECT currency_id INTO v_order_currency_code
    FROM rim_currencies WHERE id = (p_header->>'order_currency_id')::uuid;

    IF v_order_mode = 'AGAINST_QUOTATION' THEN
        SELECT * INTO v_quotation FROM rih_sales_quotations
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND quotation_no = p_header->>'source_quotation_no'
          AND quotation_date = (p_header->>'source_quotation_date')::date;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source Sales Quotation not found.';
        END IF;
        IF v_quotation.status NOT IN ('APPROVED','SENT','ACCEPTED','PARTIALLY_CONVERTED') THEN
            RAISE EXCEPTION 'QUOTATION_NOT_CONVERTIBLE'
                USING DETAIL = format('Sales Quotation %s is %s and cannot be converted.', v_quotation.quotation_no, v_quotation.status);
        END IF;
        IF v_quotation.valid_until_date < CURRENT_DATE THEN
            RAISE EXCEPTION 'QUOTATION_EXPIRED'
                USING DETAIL = format('Sales Quotation %s expired on %s.', v_quotation.quotation_no, v_quotation.valid_until_date);
        END IF;
        IF v_quotation.customer_type != 'CUSTOMER' THEN
            RAISE EXCEPTION 'PROSPECT_NOT_CONVERTED'
                USING DETAIL = format('Sales Quotation %s is still linked to a Prospect — convert it to a Customer first.', v_quotation.quotation_no);
        END IF;
        -- Real gap found live: nothing stopped an order being dated
        -- before the quotation it was raised against.
        IF v_order_date < v_quotation.quotation_date THEN
            RAISE EXCEPTION 'ORDER_DATE_BEFORE_QUOTATION'
                USING DETAIL = format('Order date %s cannot be before source Quotation %s''s date %s.',
                    v_order_date, v_quotation.quotation_no, v_quotation.quotation_date);
        END IF;
        -- Never trust the client's own customer_id for an Against-
        -- Quotation order — always force it to the quotation's own.
        v_customer_id := v_quotation.customer_id;
    END IF;

    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Select a customer.';
    END IF;

    IF v_is_new THEN
        v_order_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'SO');
    ELSE
        SELECT order_date, status INTO v_old_order_date, v_old_status
        FROM   rih_sales_orders
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  order_no = v_order_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Sales Order % not found', v_order_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Sales Order % is % and cannot be edited.', v_order_no, v_old_status;
        END IF;

        DELETE FROM rid_sales_order_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;

        DELETE FROM rid_sales_order_charges
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND order_date = v_old_order_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_sales_orders (
            client_id, company_id, location_id, order_no, order_date, order_mode,
            source_quotation_no, source_quotation_date, customer_id, customer_po_ref,
            ship_to, bill_to, expected_delivery_date,
            sales_person_id, order_currency_id, rate_to_base, rate_to_local,
            payment_term_id, incoterm_id, delivery_instructions,
            gross_amount, discount_amount, charges_amount, tax_amount, grand_total,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_order_no, v_order_date, v_order_mode,
            nullif(p_header->>'source_quotation_no', ''), (nullif(p_header->>'source_quotation_date', ''))::date,
            v_customer_id, nullif(p_header->>'customer_po_ref', ''),
            nullif(p_header->>'ship_to', ''), nullif(p_header->>'bill_to', ''),
            (nullif(p_header->>'expected_delivery_date', ''))::date,
            (nullif(p_header->>'sales_person_id', ''))::uuid,
            (p_header->>'order_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            (nullif(p_header->>'payment_term_id', ''))::uuid, (nullif(p_header->>'incoterm_id', ''))::uuid,
            nullif(p_header->>'delivery_instructions', ''),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_sales_orders SET
            location_id       = v_location_id,
            order_date        = v_order_date,
            customer_id       = v_customer_id,
            customer_po_ref   = nullif(p_header->>'customer_po_ref', ''),
            ship_to           = nullif(p_header->>'ship_to', ''),
            bill_to           = nullif(p_header->>'bill_to', ''),
            expected_delivery_date = (nullif(p_header->>'expected_delivery_date', ''))::date,
            sales_person_id   = (nullif(p_header->>'sales_person_id', ''))::uuid,
            order_currency_id = (p_header->>'order_currency_id')::uuid,
            rate_to_base      = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local     = coalesce((p_header->>'rate_to_local')::numeric, 1),
            payment_term_id   = (nullif(p_header->>'payment_term_id', ''))::uuid,
            incoterm_id       = (nullif(p_header->>'incoterm_id', ''))::uuid,
            delivery_instructions = nullif(p_header->>'delivery_instructions', ''),
            gross_amount      = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount   = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount    = coalesce((p_header->>'charges_amount')::numeric, 0),
            tax_amount        = coalesce((p_header->>'tax_amount')::numeric, 0),
            grand_total       = coalesce((p_header->>'grand_total')::numeric, 0),
            remarks           = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = v_order_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    -- Sorted by source_quotation_line_serial (NULL-safe — DIRECT-mode
    -- payloads have no such key, and ordering is a no-op there since no
    -- rid_sales_quotation_lines lock is taken in that branch) — AGAINST_
    -- QUOTATION mode locks rid_sales_quotation_lines rows below, and must
    -- do so in a fixed, deterministic order across concurrent saves to
    -- avoid the exact deadlock class documented for GRN/Material Issue
    -- (SELECT ... ORDER BY ... FOR UPDATE does not itself guarantee lock-
    -- acquisition order — only looping over an already-sorted key list does).
    FOR v_line IN
        SELECT value FROM jsonb_array_elements(p_lines) AS t(value)
        ORDER BY (value->>'source_quotation_line_serial')::integer NULLS LAST, (value->>'serial_no')::integer
    LOOP
        v_serial := (v_line->>'serial_no')::integer;

        IF v_order_mode = 'DIRECT' THEN
            -- fn_get_active_price (086) converts internally TO
            -- v_order_currency_code — never trust a Price Master batch's
            -- own currency to already match this order's currency.
            SELECT selling_price, price_type, entry_no INTO v_price
            FROM fn_get_active_price(
                v_client_id, v_company_id, v_location_id,
                (v_line->>'product_id')::uuid, (v_line->>'uom_id')::uuid,
                v_customer_id, v_order_date, v_order_currency_code
            );
            v_price_entry_no := NULL; -- only set below when price_source ends up PRICE_MASTER

            v_override_reason := nullif(v_line->>'price_override_reason', '');

            IF FOUND AND (nullif(v_line->>'rate', '')::numeric IS NULL
                          OR (v_line->>'rate')::numeric = v_price.selling_price) THEN
                v_rate := v_price.selling_price;
                v_price_source := 'PRICE_MASTER';
                v_price_entry_no := v_price.entry_no;
            ELSIF NOT FOUND AND NOT v_can_override THEN
                RAISE EXCEPTION 'PRICE_NOT_CONFIGURED'
                    USING DETAIL = format('Line %s: [%s] %s has no active price configured for this customer/date.',
                        v_serial,
                        (SELECT product_code FROM rim_products WHERE id = (v_line->>'product_id')::uuid),
                        (SELECT product_name FROM rim_products WHERE id = (v_line->>'product_id')::uuid));
            ELSE
                IF NOT v_can_override THEN
                    RAISE EXCEPTION 'PRICE_OVERRIDE_NOT_ALLOWED'
                        USING DETAIL = format('Line %s: you are not authorized to change the resolved price.', v_serial);
                END IF;
                IF v_override_reason IS NULL THEN
                    RAISE EXCEPTION 'OVERRIDE_REASON_REQUIRED'
                        USING DETAIL = format('Line %s: enter a reason for overriding the price.', v_serial);
                END IF;
                v_rate := coalesce((v_line->>'rate')::numeric, 0);
                v_price_source := 'MANUAL_OVERRIDE';
            END IF;

            v_discount_pct := coalesce((v_line->>'discount_percent')::numeric, 0);
            IF v_discount_pct > 0 THEN
                IF NOT v_can_discount THEN
                    RAISE EXCEPTION 'DISCOUNT_NOT_ALLOWED'
                        USING DETAIL = format('Line %s: you are not authorized to give a discount.', v_serial);
                END IF;
                IF v_max_discount IS NOT NULL AND v_discount_pct > v_max_discount THEN
                    RAISE EXCEPTION 'DISCOUNT_EXCEEDS_LIMIT'
                        USING DETAIL = format('Line %s: discount %s%% exceeds your authorized maximum of %s%%.', v_serial, v_discount_pct, v_max_discount);
                END IF;
            END IF;

            v_source_serial := NULL;
        ELSE
            -- AGAINST_QUOTATION: copy every priced field VERBATIM from the
            -- source line, never from the client payload.
            v_source_serial := (v_line->>'source_quotation_line_serial')::integer;

            SELECT * INTO v_source_line FROM rid_sales_quotation_lines
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND serial_no = v_source_serial AND is_deleted = false
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Quotation line % not found.', v_source_serial;
            END IF;

            v_remaining := v_source_line.base_qty - v_source_line.converted_qty;
            v_convert_qty := coalesce((v_line->>'base_qty')::numeric, 0);
            IF v_convert_qty <= 0 OR v_convert_qty > v_remaining THEN
                RAISE EXCEPTION 'QUOTATION_QTY_EXCEEDED'
                    USING DETAIL = format('Line %s: only %s remains unconverted on quotation %s.', v_serial, v_remaining, v_quotation.quotation_no);
            END IF;

            v_rate         := v_source_line.rate;
            v_price_source := 'QUOTATION';
            v_override_reason := NULL;
            v_discount_pct := v_source_line.discount_percent;
        END IF;

        INSERT INTO rid_sales_order_lines (
            client_id, company_id, order_no, order_date, serial_no,
            product_id, item_description, barcode, uom_id, uom_conversion_factor,
            qty_pack, qty_loose, base_qty, rate, price_source, price_override_reason, price_source_entry_no,
            gross_amount, discount_percent, discount_amount,
            tax_group_id, tax_amount, final_amount, base_amount, local_amount,
            charge_amount, landed_amount, source_quotation_line_serial, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_order_no, v_order_date, v_serial,
            CASE WHEN v_order_mode = 'DIRECT' THEN (v_line->>'product_id')::uuid ELSE v_source_line.product_id END,
            nullif(v_line->>'item_description', ''),
            nullif(v_line->>'barcode', ''),
            CASE WHEN v_order_mode = 'DIRECT' THEN (v_line->>'uom_id')::uuid ELSE v_source_line.uom_id END,
            CASE WHEN v_order_mode = 'DIRECT' THEN coalesce((v_line->>'uom_conversion_factor')::numeric, 1) ELSE v_source_line.uom_conversion_factor END,
            coalesce((v_line->>'qty_pack')::numeric, 0),
            coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            v_rate, v_price_source, v_override_reason, v_price_entry_no,
            coalesce((v_line->>'gross_amount')::numeric, 0),
            v_discount_pct,
            coalesce((v_line->>'discount_amount')::numeric, 0),
            CASE WHEN v_order_mode = 'DIRECT' THEN (nullif(v_line->>'tax_group_id', ''))::uuid ELSE v_source_line.tax_group_id END,
            coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            coalesce((v_line->>'base_amount')::numeric, 0),
            coalesce((v_line->>'local_amount')::numeric, 0),
            coalesce((v_line->>'charge_amount')::numeric, 0),
            coalesce((v_line->>'landed_amount')::numeric, 0),
            v_source_serial,
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_sales_order_charges (
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

    RETURN v_order_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_sales_order(JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ------------------------------------------------------------
-- fn_save_sales_invoice — same fix, two source-document branches
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_save_sales_invoice(
    p_header  JSONB,
    p_lines   JSONB,
    p_charges JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id           UUID;
    v_company_id          UUID;
    v_location_id         UUID;
    v_invoice_no          TEXT;
    v_invoice_date        DATE;
    v_old_invoice_date    DATE;
    v_old_status          TEXT;
    v_is_new              BOOLEAN;
    v_invoice_mode        TEXT;
    v_sale_type           TEXT;
    v_customer_id         UUID;
    v_quotation           rih_sales_quotations%ROWTYPE;
    v_order                rih_sales_orders%ROWTYPE;
    v_quick_setup           ric_user_quick_invoice_setup%ROWTYPE;
    v_can_override         BOOLEAN;
    v_can_discount          BOOLEAN;
    v_max_discount           NUMERIC;
    v_dispatch_stock          BOOLEAN;
    v_collect_cash              BOOLEAN;
    v_line                       JSONB;
    v_serial                      INTEGER;
    v_price                        RECORD;
    v_rate                          NUMERIC;
    v_price_source                   TEXT;
    v_override_reason                 TEXT;
    v_discount_pct                     NUMERIC;
    v_discount_given_by                 UUID;
    v_sup_can_discount                   BOOLEAN;
    v_sup_max_discount                    NUMERIC;
    v_source_line                          rid_sales_quotation_lines%ROWTYPE;
    v_source_order_line                     rid_sales_order_lines%ROWTYPE;
    v_order_currency_code                    TEXT;
    v_price_entry_no                          TEXT;
    v_charge                                   JSONB;
    v_source_charge                             rid_sales_quotation_charges%ROWTYPE;
    v_source_order_charge                        rid_sales_order_charges%ROWTYPE;
    v_batch                                    JSONB;
    v_serial_row                                JSONB;
    v_is_batch_tracked                           BOOLEAN;
    v_is_serial_tracked                           BOOLEAN;
    v_has_batches                                  BOOLEAN;
    v_has_serials                                   BOOLEAN;
    v_check_line                                     RECORD;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_invoice_no   := nullif(trim(p_header->>'invoice_no'), '');
    v_invoice_date := (p_header->>'invoice_date')::date;
    v_invoice_mode := coalesce(p_header->>'invoice_mode', 'DIRECT');
    v_sale_type    := coalesce(p_header->>'sale_type', 'CASH');
    v_is_new       := v_invoice_no IS NULL;

    IF v_invoice_mode = 'DIRECT' AND jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Invoice.';
    END IF;

    -- Company-level immediate/deferred flags, snapshotted onto the header.
    SELECT quick_invoice_dispatch_stock, quick_invoice_collect_cash
      INTO v_dispatch_stock, v_collect_cash
    FROM ric_companies WHERE id = v_company_id;

    -- Sales Controls, same coalesce-to-safe-default resolution as
    -- fn_save_sales_order — a missing row is never permissive.
    SELECT can_override_price, can_give_discount, max_discount_percent
      INTO v_can_override, v_can_discount, v_max_discount
    FROM ric_user_sales_controls
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND user_id = p_user_id AND is_deleted = false;
    v_can_override := coalesce(v_can_override, false);
    v_can_discount := coalesce(v_can_discount, false);

    -- Resolve customer + party snapshot.
    IF v_sale_type = 'CASH' THEN
        SELECT * INTO v_quick_setup FROM ric_user_quick_invoice_setup
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND user_id = p_user_id AND is_deleted = false AND is_active = true;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'QUICK_INVOICE_NOT_CONFIGURED'
                USING DETAIL = 'This user has no Quick Invoice Setup — ask an admin to assign a location, cash customer, and cash accounts first.';
        END IF;
        v_customer_id := v_quick_setup.cash_customer_id;
    ELSE
        v_customer_id := (nullif(p_header->>'customer_id', ''))::uuid;
        -- AGAINST_QUOTATION/AGAINST_ORDER derive v_customer_id from the
        -- locked source document further below (v_quotation.customer_id /
        -- v_order.customer_id) — the client-supplied payload legitimately
        -- omits customer_id in these two modes, so this check only
        -- applies to DIRECT.
        IF v_customer_id IS NULL AND v_invoice_mode = 'DIRECT' THEN
            RAISE EXCEPTION 'Select a customer.';
        END IF;
    END IF;

    SELECT currency_id INTO v_order_currency_code
    FROM rim_currencies WHERE id = (p_header->>'invoice_currency_id')::uuid;

    -- Lock + validate + (for AGAINST_* modes) re-derive from the source
    -- document. The row lock here is what makes the live "already
    -- invoiced?" check below race-safe — a second concurrent save on the
    -- same source document blocks until this transaction commits.
    IF v_invoice_mode = 'AGAINST_QUOTATION' THEN
        SELECT * INTO v_quotation FROM rih_sales_quotations
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND quotation_no = p_header->>'quotation_no'
          AND quotation_date = (p_header->>'quotation_date')::date
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source Sales Quotation not found.';
        END IF;
        IF v_quotation.status NOT IN ('APPROVED','SENT','ACCEPTED') THEN
            RAISE EXCEPTION 'QUOTATION_NOT_INVOICEABLE'
                USING DETAIL = format('Sales Quotation %s is %s and cannot be invoiced.', v_quotation.quotation_no, v_quotation.status);
        END IF;
        IF v_quotation.customer_type != 'CUSTOMER' THEN
            RAISE EXCEPTION 'PROSPECT_NOT_CONVERTED'
                USING DETAIL = format('Sales Quotation %s is still linked to a Prospect — it must be converted (via a Sales Order) before it can be invoiced.', v_quotation.quotation_no);
        END IF;
        IF EXISTS (
            -- rih_sales_orders' OWN reference-to-its-source-quotation columns
            -- (source_quotation_no/date, from 087) — deliberately NOT renamed
            -- by this migration's quotation_no/order_no cleanup, since that
            -- only touched rih_sales_invoices' own columns.
            SELECT 1 FROM rih_sales_orders
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND source_quotation_no = v_quotation.quotation_no AND source_quotation_date = v_quotation.quotation_date
              AND status != 'CANCELLED'
        ) THEN
            RAISE EXCEPTION 'QUOTATION_HAS_ORDER'
                USING DETAIL = format('Sales Quotation %s already has a Sales Order raised against it — invoice that Order instead.', v_quotation.quotation_no);
        END IF;
        IF EXISTS (
            SELECT 1 FROM rih_sales_invoices
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND status != 'CANCELLED'
              AND (v_is_new OR invoice_no != v_invoice_no)
        ) THEN
            RAISE EXCEPTION 'QUOTATION_ALREADY_INVOICED'
                USING DETAIL = format('Sales Quotation %s has already been invoiced.', v_quotation.quotation_no);
        END IF;
        -- Real gap found live: nothing stopped an invoice being dated
        -- before the quotation it was raised against.
        IF v_invoice_date < v_quotation.quotation_date THEN
            RAISE EXCEPTION 'INVOICE_DATE_BEFORE_QUOTATION'
                USING DETAIL = format('Invoice date %s cannot be before source Quotation %s''s date %s.',
                    v_invoice_date, v_quotation.quotation_no, v_quotation.quotation_date);
        END IF;

        v_customer_id := v_quotation.customer_id;
    ELSIF v_invoice_mode = 'AGAINST_ORDER' THEN
        SELECT * INTO v_order FROM rih_sales_orders
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND order_no = p_header->>'order_no'
          AND order_date = (p_header->>'order_date')::date
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Source Sales Order not found.';
        END IF;
        IF v_order.status != 'APPROVED' THEN
            RAISE EXCEPTION 'ORDER_NOT_INVOICEABLE'
                USING DETAIL = format('Sales Order %s is %s and cannot be invoiced.', v_order.order_no, v_order.status);
        END IF;
        IF EXISTS (
            SELECT 1 FROM rih_sales_invoices
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND order_no = v_order.order_no AND order_date = v_order.order_date
              AND status != 'CANCELLED'
              AND (v_is_new OR invoice_no != v_invoice_no)
        ) THEN
            RAISE EXCEPTION 'ORDER_ALREADY_INVOICED'
                USING DETAIL = format('Sales Order %s has already been invoiced.', v_order.order_no);
        END IF;
        -- Real gap found live: nothing stopped an invoice being dated
        -- before the order it was raised against.
        IF v_invoice_date < v_order.order_date THEN
            RAISE EXCEPTION 'INVOICE_DATE_BEFORE_ORDER'
                USING DETAIL = format('Invoice date %s cannot be before source Order %s''s date %s.',
                    v_invoice_date, v_order.order_no, v_order.order_date);
        END IF;

        v_customer_id := v_order.customer_id;
    END IF;

    IF v_is_new THEN
        v_invoice_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'SI');
    ELSE
        SELECT invoice_date, status INTO v_old_invoice_date, v_old_status
        FROM   rih_sales_invoices
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  invoice_no = v_invoice_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Sales Invoice % not found', v_invoice_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Sales Invoice % is % and cannot be edited.', v_invoice_no, v_old_status;
        END IF;

        DELETE FROM rid_transaction_line_batches
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_old_invoice_date;

        DELETE FROM rid_transaction_line_serials
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_old_invoice_date;

        DELETE FROM rid_sales_invoice_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND invoice_date = v_old_invoice_date;

        DELETE FROM rid_sales_invoice_charges
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND invoice_date = v_old_invoice_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_sales_invoices (
            client_id, company_id, location_id, invoice_no, invoice_date, invoice_mode,
            quotation_no, quotation_date, order_no, order_date,
            sale_type, customer_id, party_name, party_phone, party_address, sales_person_id,
            invoice_currency_id, rate_to_base, rate_to_local, discount_percent,
            gross_amount, discount_amount, charges_amount, tax_amount, grand_total,
            stock_dispatch_mode, cash_collection_mode,
            collected_amount_local, collected_amount_base,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_invoice_no, v_invoice_date, v_invoice_mode,
            nullif(p_header->>'quotation_no', ''), (nullif(p_header->>'quotation_date', ''))::date,
            nullif(p_header->>'order_no', ''), (nullif(p_header->>'order_date', ''))::date,
            v_sale_type, v_customer_id,
            CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_name', '') END,
            CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_phone', '') END,
            CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_address', '') END,
            coalesce((nullif(p_header->>'sales_person_id', ''))::uuid,
                     CASE WHEN v_sale_type = 'CASH' THEN v_quick_setup.default_sales_person_id END),
            (p_header->>'invoice_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'discount_percent')::numeric, 0),
            coalesce((p_header->>'gross_amount')::numeric, 0),
            coalesce((p_header->>'discount_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'grand_total')::numeric, 0),
            CASE WHEN coalesce(v_dispatch_stock, true) THEN 'IMMEDIATE' ELSE 'DEFERRED' END,
            CASE WHEN coalesce(v_collect_cash, true)   THEN 'IMMEDIATE' ELSE 'DEFERRED' END,
            (nullif(p_header->>'collected_amount_local', ''))::numeric,
            (nullif(p_header->>'collected_amount_base', ''))::numeric,
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_sales_invoices SET
            location_id       = v_location_id,
            invoice_date      = v_invoice_date,
            sale_type         = v_sale_type,
            customer_id       = v_customer_id,
            party_name        = CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_name', '') END,
            party_phone       = CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_phone', '') END,
            party_address     = CASE WHEN v_sale_type = 'CASH' THEN nullif(p_header->>'party_address', '') END,
            sales_person_id   = (nullif(p_header->>'sales_person_id', ''))::uuid,
            invoice_currency_id = (p_header->>'invoice_currency_id')::uuid,
            rate_to_base      = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local     = coalesce((p_header->>'rate_to_local')::numeric, 1),
            discount_percent  = coalesce((p_header->>'discount_percent')::numeric, 0),
            gross_amount      = coalesce((p_header->>'gross_amount')::numeric, 0),
            discount_amount   = coalesce((p_header->>'discount_amount')::numeric, 0),
            charges_amount    = coalesce((p_header->>'charges_amount')::numeric, 0),
            tax_amount        = coalesce((p_header->>'tax_amount')::numeric, 0),
            grand_total       = coalesce((p_header->>'grand_total')::numeric, 0),
            collected_amount_local = (nullif(p_header->>'collected_amount_local', ''))::numeric,
            collected_amount_base  = (nullif(p_header->>'collected_amount_base', ''))::numeric,
            remarks           = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    IF v_invoice_mode = 'DIRECT' THEN
        FOR v_line IN
            SELECT value FROM jsonb_array_elements(p_lines) AS t(value)
            ORDER BY (value->>'serial_no')::integer
        LOOP
            v_serial := (v_line->>'serial_no')::integer;

            SELECT selling_price, price_type, entry_no INTO v_price
            FROM fn_get_active_price(
                v_client_id, v_company_id, v_location_id,
                (v_line->>'product_id')::uuid, (v_line->>'uom_id')::uuid,
                v_customer_id, v_invoice_date, v_order_currency_code
            );
            v_price_entry_no := NULL;
            v_override_reason := nullif(v_line->>'price_override_reason', '');

            IF FOUND AND (nullif(v_line->>'rate', '')::numeric IS NULL
                          OR (v_line->>'rate')::numeric = v_price.selling_price) THEN
                v_rate := v_price.selling_price;
                v_price_source := 'PRICE_MASTER';
                v_price_entry_no := v_price.entry_no;
            ELSIF NOT FOUND AND NOT v_can_override THEN
                RAISE EXCEPTION 'PRICE_NOT_CONFIGURED'
                    USING DETAIL = format('Line %s: [%s] %s has no active price configured for this customer/date.',
                        v_serial,
                        (SELECT product_code FROM rim_products WHERE id = (v_line->>'product_id')::uuid),
                        (SELECT product_name FROM rim_products WHERE id = (v_line->>'product_id')::uuid));
            ELSE
                IF NOT v_can_override THEN
                    RAISE EXCEPTION 'PRICE_OVERRIDE_NOT_ALLOWED'
                        USING DETAIL = format('Line %s: you are not authorized to change the resolved price.', v_serial);
                END IF;
                IF v_override_reason IS NULL THEN
                    RAISE EXCEPTION 'OVERRIDE_REASON_REQUIRED'
                        USING DETAIL = format('Line %s: enter a reason for overriding the price.', v_serial);
                END IF;
                v_rate := coalesce((v_line->>'rate')::numeric, 0);
                v_price_source := 'MANUAL_OVERRIDE';
            END IF;

            -- Discount governance + mandatory discount_given_by attribution
            -- (header comment point 2) — always populated when a discount
            -- was actually given, never just an "override" marker.
            v_discount_pct := coalesce((v_line->>'discount_percent')::numeric, 0);
            IF v_discount_pct > 0 THEN
                IF v_can_discount AND (v_max_discount IS NULL OR v_discount_pct <= v_max_discount) THEN
                    v_discount_given_by := p_user_id;
                ELSE
                    v_discount_given_by := (nullif(v_line->>'discount_given_by', ''))::uuid;
                    IF v_discount_given_by IS NULL OR v_discount_given_by = p_user_id THEN
                        RAISE EXCEPTION 'DISCOUNT_OVERRIDE_REQUIRED'
                            USING DETAIL = format('Line %s: discount %s%% exceeds your authorized limit — get a supervisor override first.', v_serial, v_discount_pct);
                    END IF;
                    SELECT can_give_discount, max_discount_percent
                      INTO v_sup_can_discount, v_sup_max_discount
                    FROM ric_user_sales_controls
                    WHERE client_id = v_client_id AND company_id = v_company_id
                      AND user_id = v_discount_given_by AND is_deleted = false;
                    IF NOT coalesce(v_sup_can_discount, false)
                       OR (v_sup_max_discount IS NOT NULL AND v_discount_pct > v_sup_max_discount) THEN
                        RAISE EXCEPTION 'DISCOUNT_OVERRIDE_INVALID'
                            USING DETAIL = format('Line %s: the supervisor who authorized this discount is not currently eligible to approve %s%%.', v_serial, v_discount_pct);
                    END IF;
                END IF;
            ELSE
                v_discount_given_by := NULL;
            END IF;

            SELECT tracking_type IN ('BATCH','BATCH_WITH_EXPIRY'), tracking_type = 'SERIAL'
              INTO v_is_batch_tracked, v_is_serial_tracked
            FROM rim_products WHERE id = (v_line->>'product_id')::uuid;

            v_has_batches := EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
                                      WHERE (value->>'line_serial')::integer = v_serial);
            v_has_serials := EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
                                      WHERE (value->>'line_serial')::integer = v_serial);

            IF coalesce(v_dispatch_stock, true) THEN
                IF v_is_batch_tracked AND NOT v_has_batches THEN
                    RAISE EXCEPTION 'BATCH_ALLOCATION_REQUIRED'
                        USING DETAIL = format('Line %s: select which batch(es) this sale is dispatching from.', v_serial);
                END IF;
                IF v_is_serial_tracked AND NOT v_has_serials THEN
                    RAISE EXCEPTION 'SERIAL_ALLOCATION_REQUIRED'
                        USING DETAIL = format('Line %s: select which serial(s) this sale is dispatching.', v_serial);
                END IF;
            END IF;

            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source, price_override_reason, price_source_entry_no,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount,
                remarks, created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_serial,
                (v_line->>'product_id')::uuid,
                nullif(v_line->>'item_description', ''),
                nullif(v_line->>'barcode', ''),
                (v_line->>'uom_id')::uuid,
                coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
                coalesce((v_line->>'qty_pack')::numeric, 0),
                coalesce((v_line->>'qty_loose')::numeric, 0),
                coalesce((v_line->>'base_qty')::numeric, 0),
                v_rate, v_price_source, v_override_reason, v_price_entry_no,
                coalesce((v_line->>'gross_amount')::numeric, 0),
                v_discount_pct,
                coalesce((v_line->>'discount_amount')::numeric, 0),
                v_discount_given_by,
                (nullif(v_line->>'tax_group_id', ''))::uuid,
                coalesce((v_line->>'tax_amount')::numeric, 0),
                coalesce((v_line->>'final_amount')::numeric, 0),
                coalesce((v_line->>'base_amount')::numeric, 0),
                coalesce((v_line->>'local_amount')::numeric, 0),
                coalesce((v_line->>'charge_amount')::numeric, 0),
                coalesce((v_line->>'landed_amount')::numeric, 0),
                nullif(v_line->>'remarks', ''),
                p_user_id, p_user_id
            );
        END LOOP;

        -- DIRECT mode only: charges are freshly client-supplied every
        -- save (same "always editable" convention as Sales Order) — see
        -- the header comment on rid_sales_invoice_charges for why
        -- AGAINST_QUOTATION/AGAINST_ORDER modes never reach this branch.
        FOR v_charge IN SELECT * FROM jsonb_array_elements(coalesce(p_charges, '[]'::jsonb))
        LOOP
            INSERT INTO rid_sales_invoice_charges (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
                amount_or_percent, percent, amount, tax_amount, allocation_factor,
                created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date,
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
    ELSIF v_invoice_mode = 'AGAINST_QUOTATION' THEN
        FOR v_source_line IN
            SELECT * FROM rid_sales_quotation_lines
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount,
                source_quotation_line_serial, created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_line.serial_no,
                v_source_line.product_id, v_source_line.item_description, v_source_line.barcode,
                v_source_line.uom_id, v_source_line.uom_conversion_factor,
                v_source_line.qty_pack, v_source_line.qty_loose, v_source_line.base_qty,
                v_source_line.rate, 'QUOTATION',
                v_source_line.gross_amount, v_source_line.discount_percent, v_source_line.discount_amount,
                CASE WHEN v_source_line.discount_percent > 0 THEN p_user_id END,
                v_source_line.tax_group_id, v_source_line.tax_amount, v_source_line.final_amount,
                v_source_line.base_amount, v_source_line.local_amount,
                v_source_line.charge_amount, v_source_line.landed_amount,
                v_source_line.serial_no, p_user_id, p_user_id
            );
        END LOOP;

        -- Charges copied VERBATIM from the source quotation's own charges
        -- — the client's own p_charges is ignored here, same rule as the
        -- line copy just above.
        FOR v_source_charge IN
            SELECT * FROM rid_sales_quotation_charges
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND quotation_no = v_quotation.quotation_no AND quotation_date = v_quotation.quotation_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_charges (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
                amount_or_percent, percent, amount, tax_amount, allocation_factor,
                created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_charge.serial_no,
                v_source_charge.charge_id, v_source_charge.charge_name, v_source_charge.is_taxable,
                v_source_charge.tax_id, v_source_charge.nature, v_source_charge.gl_account_id,
                v_source_charge.amount_or_percent, v_source_charge.percent, v_source_charge.amount,
                v_source_charge.tax_amount, v_source_charge.allocation_factor,
                p_user_id, p_user_id
            );
        END LOOP;
    ELSIF v_invoice_mode = 'AGAINST_ORDER' THEN
        FOR v_source_order_line IN
            SELECT * FROM rid_sales_order_lines
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND order_no = v_order.order_no AND order_date = v_order.order_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount,
                source_order_line_serial, created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_order_line.serial_no,
                v_source_order_line.product_id, v_source_order_line.item_description, v_source_order_line.barcode,
                v_source_order_line.uom_id, v_source_order_line.uom_conversion_factor,
                v_source_order_line.qty_pack, v_source_order_line.qty_loose, v_source_order_line.base_qty,
                v_source_order_line.rate, 'ORDER',
                v_source_order_line.gross_amount, v_source_order_line.discount_percent, v_source_order_line.discount_amount,
                CASE WHEN v_source_order_line.discount_percent > 0 THEN p_user_id END,
                v_source_order_line.tax_group_id, v_source_order_line.tax_amount, v_source_order_line.final_amount,
                v_source_order_line.base_amount, v_source_order_line.local_amount,
                v_source_order_line.charge_amount, v_source_order_line.landed_amount,
                v_source_order_line.serial_no, p_user_id, p_user_id
            );
        END LOOP;

        -- Charges copied VERBATIM from the source order's own charges —
        -- same rule as AGAINST_QUOTATION mode above.
        FOR v_source_order_charge IN
            SELECT * FROM rid_sales_order_charges
            WHERE client_id = v_client_id AND company_id = v_company_id
              AND order_no = v_order.order_no AND order_date = v_order.order_date
              AND is_deleted = false
            ORDER BY serial_no
        LOOP
            INSERT INTO rid_sales_invoice_charges (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
                amount_or_percent, percent, amount, tax_amount, allocation_factor,
                created_by, updated_by
            ) VALUES (
                v_client_id, v_company_id, v_invoice_no, v_invoice_date, v_source_order_charge.serial_no,
                v_source_order_charge.charge_id, v_source_order_charge.charge_name, v_source_order_charge.is_taxable,
                v_source_order_charge.tax_id, v_source_order_charge.nature, v_source_order_charge.gl_account_id,
                v_source_order_charge.amount_or_percent, v_source_order_charge.percent, v_source_order_charge.amount,
                v_source_order_charge.tax_amount, v_source_order_charge.allocation_factor,
                p_user_id, p_user_id
            );
        END LOOP;
    END IF;

    -- Batch/serial staging — same generic tables/shape as GRN/Material
    -- Issue/Purchase Return, keyed by this invoice as source_doc_*.
    -- Populated from the client in every mode (a Quotation/Order never
    -- carries batch/serial, since neither ever touches stock).
    FOR v_batch IN SELECT * FROM jsonb_array_elements(coalesce(p_batches, '[]'::jsonb))
    LOOP
        INSERT INTO rid_transaction_line_batches (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial,
            batch_no, expiry_date, manufacturing_date, qty_pack, qty_loose, base_qty, created_by
        ) VALUES (
            v_client_id, v_company_id, 'SALES_INVOICE', v_invoice_no, v_invoice_date,
            (v_batch->>'line_serial')::integer,
            v_batch->>'batch_no', (nullif(v_batch->>'expiry_date', ''))::date, (nullif(v_batch->>'manufacturing_date', ''))::date,
            coalesce((v_batch->>'qty_pack')::numeric, 0),
            coalesce((v_batch->>'qty_loose')::numeric, 0),
            coalesce((v_batch->>'base_qty')::numeric, 0),
            p_user_id
        );
    END LOOP;

    FOR v_serial_row IN SELECT * FROM jsonb_array_elements(coalesce(p_serials, '[]'::jsonb))
    LOOP
        INSERT INTO rid_transaction_line_serials (
            client_id, company_id, source_doc_type, source_doc_no, source_doc_date, line_serial, serial_no, created_by
        ) VALUES (
            v_client_id, v_company_id, 'SALES_INVOICE', v_invoice_no, v_invoice_date,
            (v_serial_row->>'line_serial')::integer, v_serial_row->>'serial_no', p_user_id
        );
    END LOOP;

    -- Mandatory batch/serial allocation, checked UNIFORMLY across all
    -- three modes (not just DIRECT) whenever dispatch will be immediate —
    -- AGAINST_QUOTATION/AGAINST_ORDER lines are re-derived server-side
    -- above and never went through DIRECT's own per-line check, so this
    -- final pass re-reads every line just inserted for THIS invoice and
    -- validates it against what was actually staged into
    -- rid_transaction_line_batches/rid_transaction_line_serials.
    IF coalesce(v_dispatch_stock, true) THEN
        FOR v_check_line IN
            SELECT l.serial_no, l.product_id,
                   p.tracking_type IN ('BATCH','BATCH_WITH_EXPIRY') AS is_batch_tracked,
                   p.tracking_type = 'SERIAL' AS is_serial_tracked
            FROM rid_sales_invoice_lines l
            JOIN rim_products p ON p.id = l.product_id
            WHERE l.client_id = v_client_id AND l.company_id = v_company_id
              AND l.invoice_no = v_invoice_no AND l.invoice_date = v_invoice_date AND l.is_deleted = false
        LOOP
            IF v_check_line.is_batch_tracked AND NOT EXISTS (
                SELECT 1 FROM rid_transaction_line_batches
                WHERE client_id = v_client_id AND company_id = v_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_invoice_date
                  AND line_serial = v_check_line.serial_no
            ) THEN
                RAISE EXCEPTION 'BATCH_ALLOCATION_REQUIRED'
                    USING DETAIL = format('Line %s: select which batch(es) this sale is dispatching from.', v_check_line.serial_no);
            END IF;
            IF v_check_line.is_serial_tracked AND NOT EXISTS (
                SELECT 1 FROM rid_transaction_line_serials
                WHERE client_id = v_client_id AND company_id = v_company_id
                  AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = v_invoice_no AND source_doc_date = v_invoice_date
                  AND line_serial = v_check_line.serial_no
            ) THEN
                RAISE EXCEPTION 'SERIAL_ALLOCATION_REQUIRED'
                    USING DETAIL = format('Line %s: select which serial(s) this sale is dispatching.', v_check_line.serial_no);
            END IF;
        END LOOP;
    END IF;

    RETURN v_invoice_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_sales_invoice(JSONB, JSONB, JSONB, JSONB, JSONB, UUID) TO authenticated;
