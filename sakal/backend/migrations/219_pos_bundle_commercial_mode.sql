-- ============================================================================
-- Migration 219: COMMERCIAL-mode bundle component explosion at sale time
-- ============================================================================
-- Closes the one deliberately-deferred gap from migration 216: a
-- COMMERCIAL bundle's own product_id is never itself stocked/cost-tracked
-- (no GRN ever receives it), so it needs real changes to BOTH functions
-- that assumed every sold product has its own cost/stock:
--
-- 1. fn_save_sales_invoice — its per-line cost-price check
--    (COST_PRICE_NOT_AVAILABLE) would always fire for a bundle product
--    (it has no cost_price of its own), so it must be skipped for one.
-- 2. fn_approve_sales_invoice — its stock-dispatch loop resolves STOCK_
--    ACCOUNT/COST_OF_SALES_ACCOUNT for the LINE's own product_id and
--    requires v_line.cost_price to be non-null; neither holds for a
--    bundle. A COMMERCIAL bundle line is detected FIRST, before any of
--    that existing per-line logic runs, and handled by looping over
--    rim_bundle_components instead: one fn_post_stock_movement call per
--    component (scaled by the bundle line's own qty, per CLAUDE.md's "no
--    aggregation across lines sharing an account" precedent — same shape
--    GRN/Material Issue already use), one Dr COGS/Cr Stock pair per
--    component (each resolved against ITS OWN product_id), and one
--    rid_sales_invoice_line_bundle_components row per component for
--    traceability (schema already existed, unused until now). A non-
--    bundle product's processing is completely untouched — this whole
--    branch only ever runs when rim_product_bundles has a matching
--    bundle_mode='COMMERCIAL' row, a table that was empty until this
--    session's own Bundle admin UI.
--
-- A batch/serial-tracked component is explicitly NOT supported yet (no
-- allocation UI exists for a bundle's own components) — raises a clear
-- BUNDLE_COMPONENT_TRACKING_NOT_SUPPORTED error rather than silently
-- mis-posting, same "deliberately not built, fail loudly" convention used
-- throughout this schema.
--
-- Both function bodies below are reproduced verbatim from their latest
-- definitions (fn_save_sales_invoice from migration 213, fn_approve_sales_
-- invoice from migration 146) per CLAUDE.md's "Check Latest Function
-- Signature" rule, with only the additive changes described above.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_save_sales_invoice(
    p_header  JSONB,
    p_lines   JSONB,
    p_charges JSONB,
    p_batches JSONB,
    p_serials JSONB,
    p_user_id UUID,
    p_enforce_cost_check BOOLEAN DEFAULT true,
    p_credit_invoice_screen BOOLEAN DEFAULT false
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
    v_pos_shift_id        UUID;
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
    v_base_ccy               TEXT;
    v_product_cost_ccy       TEXT;
    v_cost_price             NUMERIC;
    v_cost_base              NUMERIC;
    v_cost_source            TEXT;
    v_category_id            UUID;
    v_scheme                 RECORD;
    v_is_commercial_bundle   BOOLEAN; -- NEW (219)
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_invoice_no   := nullif(trim(p_header->>'invoice_no'), '');
    v_invoice_date := (p_header->>'invoice_date')::date;
    v_invoice_mode := coalesce(p_header->>'invoice_mode', 'DIRECT');
    v_sale_type    := coalesce(p_header->>'sale_type', 'CASH');
    v_pos_shift_id := (nullif(p_header->>'pos_shift_id', ''))::uuid;
    v_is_new       := v_invoice_no IS NULL;

    IF p_credit_invoice_screen AND v_invoice_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Invoice date %s cannot be in the future.', v_invoice_date);
    END IF;

    IF v_invoice_mode = 'DIRECT' AND jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Sales Invoice.';
    END IF;

    SELECT quick_invoice_dispatch_stock, quick_invoice_collect_cash
      INTO v_dispatch_stock, v_collect_cash
    FROM ric_companies WHERE id = v_company_id;

    IF p_credit_invoice_screen THEN
        v_dispatch_stock := false;
    END IF;

    SELECT can_override_price, can_give_discount, max_discount_percent
      INTO v_can_override, v_can_discount, v_max_discount
    FROM ric_user_sales_controls
    WHERE client_id = v_client_id AND company_id = v_company_id
      AND user_id = p_user_id AND is_deleted = false;
    v_can_override := coalesce(v_can_override, false);
    v_can_discount := coalesce(v_can_discount, false);

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
        IF v_customer_id IS NULL AND v_invoice_mode = 'DIRECT' THEN
            RAISE EXCEPTION 'Select a customer.';
        END IF;
    END IF;

    SELECT currency_id INTO v_order_currency_code
    FROM rim_currencies WHERE id = (p_header->>'invoice_currency_id')::uuid;

    SELECT base_currency INTO v_base_ccy FROM ric_companies WHERE id = v_company_id;

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

        IF p_credit_invoice_screen AND v_invoice_date <> v_old_invoice_date THEN
            RAISE EXCEPTION 'INVOICE_DATE_LOCKED_AFTER_FIRST_SAVE'
                USING DETAIL = format('Invoice date cannot be changed once saved (originally %s).', v_old_invoice_date);
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
            pos_shift_id,
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
            v_pos_shift_id,
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
            pos_shift_id      = v_pos_shift_id,
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

            SELECT c.currency_id INTO v_product_cost_ccy
            FROM rim_products p LEFT JOIN rim_currencies c ON c.id = p.cost_currency_id
            WHERE p.id = (v_line->>'product_id')::uuid;

            IF v_order_currency_code = v_base_ccy THEN
                SELECT g.cost_price, g.cost_source INTO v_cost_price, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, (v_line->>'product_id')::uuid, 'B', v_invoice_date) g;
            ELSIF v_product_cost_ccy IS NOT NULL AND v_order_currency_code = v_product_cost_ccy THEN
                SELECT g.cost_price, g.cost_source INTO v_cost_price, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, (v_line->>'product_id')::uuid, 'S', v_invoice_date) g;
            ELSE
                SELECT g.cost_price, g.cost_source INTO v_cost_base, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, (v_line->>'product_id')::uuid, 'B', v_invoice_date) g;
                v_cost_price := v_cost_base * fn_get_exchange_rate(v_company_id, v_location_id, v_base_ccy, v_order_currency_code, v_invoice_date);
            END IF;

            -- NEW (219): a COMMERCIAL bundle's own product_id is never
            -- itself cost-tracked (no GRN ever receives it) — its real
            -- cost is the sum of its components, computed later at
            -- approve time. Skip the cost-price requirement for one.
            SELECT EXISTS (
                SELECT 1 FROM rim_product_bundles
                WHERE bundle_product_id = (v_line->>'product_id')::uuid
                  AND bundle_mode = 'COMMERCIAL' AND is_deleted = false
            ) INTO v_is_commercial_bundle;

            IF p_enforce_cost_check AND v_cost_source = 'NONE' AND NOT v_is_commercial_bundle THEN
                RAISE EXCEPTION 'COST_PRICE_NOT_AVAILABLE'
                    USING DETAIL = format('Line %s: [%s] %s has no cost price established — it must be received (GRN) or given a Standard Cost on the product master before it can be sold.',
                        v_serial,
                        (SELECT product_code FROM rim_products WHERE id = (v_line->>'product_id')::uuid),
                        (SELECT product_name FROM rim_products WHERE id = (v_line->>'product_id')::uuid));
            END IF;

            -- NEW (213): resolve the best-matching POS scheme for this line,
            -- purely as an audit/reporting snapshot — see migration 213's
            -- own header comment for why this does not alter gross/final/tax.
            SELECT category_id INTO v_category_id FROM rim_products WHERE id = (v_line->>'product_id')::uuid;
            SELECT * INTO v_scheme FROM fn_resolve_pos_schemes_for_line(
                v_client_id, v_company_id, v_location_id,
                (v_line->>'product_id')::uuid, v_category_id,
                coalesce((v_line->>'base_qty')::numeric, 0),
                coalesce((v_line->>'gross_amount')::numeric, 0),
                v_invoice_date
            );

            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source, price_override_reason, price_source_entry_no,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount, cost_price,
                applied_scheme_id, scheme_discount_amount, scheme_name_snapshot,
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
                v_cost_price,
                v_scheme.scheme_id, coalesce(v_scheme.discount_amount, 0), v_scheme.scheme_name,
                nullif(v_line->>'remarks', ''),
                p_user_id, p_user_id
            );
        END LOOP;

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
            SELECT c.currency_id INTO v_product_cost_ccy
            FROM rim_products p LEFT JOIN rim_currencies c ON c.id = p.cost_currency_id
            WHERE p.id = v_source_line.product_id;

            IF v_order_currency_code = v_base_ccy THEN
                SELECT g.cost_price, g.cost_source INTO v_cost_price, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, v_source_line.product_id, 'B', v_invoice_date) g;
            ELSIF v_product_cost_ccy IS NOT NULL AND v_order_currency_code = v_product_cost_ccy THEN
                SELECT g.cost_price, g.cost_source INTO v_cost_price, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, v_source_line.product_id, 'S', v_invoice_date) g;
            ELSE
                SELECT g.cost_price, g.cost_source INTO v_cost_base, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, v_source_line.product_id, 'B', v_invoice_date) g;
                v_cost_price := v_cost_base * fn_get_exchange_rate(v_company_id, v_location_id, v_base_ccy, v_order_currency_code, v_invoice_date);
            END IF;

            IF p_enforce_cost_check AND v_cost_source = 'NONE' THEN
                RAISE EXCEPTION 'COST_PRICE_NOT_AVAILABLE'
                    USING DETAIL = format('Line %s: [%s] %s has no cost price established — it must be received (GRN) or given a Standard Cost on the product master before it can be sold.',
                        v_source_line.serial_no,
                        (SELECT product_code FROM rim_products WHERE id = v_source_line.product_id),
                        (SELECT product_name FROM rim_products WHERE id = v_source_line.product_id));
            END IF;

            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount, cost_price,
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
                v_source_line.charge_amount, v_source_line.landed_amount, v_cost_price,
                v_source_line.serial_no, p_user_id, p_user_id
            );
        END LOOP;

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
            SELECT c.currency_id INTO v_product_cost_ccy
            FROM rim_products p LEFT JOIN rim_currencies c ON c.id = p.cost_currency_id
            WHERE p.id = v_source_order_line.product_id;

            IF v_order_currency_code = v_base_ccy THEN
                SELECT g.cost_price, g.cost_source INTO v_cost_price, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, v_source_order_line.product_id, 'B', v_invoice_date) g;
            ELSIF v_product_cost_ccy IS NOT NULL AND v_order_currency_code = v_product_cost_ccy THEN
                SELECT g.cost_price, g.cost_source INTO v_cost_price, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, v_source_order_line.product_id, 'S', v_invoice_date) g;
            ELSE
                SELECT g.cost_price, g.cost_source INTO v_cost_base, v_cost_source
                FROM fn_get_cost_price(v_client_id, v_company_id, v_location_id, v_source_order_line.product_id, 'B', v_invoice_date) g;
                v_cost_price := v_cost_base * fn_get_exchange_rate(v_company_id, v_location_id, v_base_ccy, v_order_currency_code, v_invoice_date);
            END IF;

            IF p_enforce_cost_check AND v_cost_source = 'NONE' THEN
                RAISE EXCEPTION 'COST_PRICE_NOT_AVAILABLE'
                    USING DETAIL = format('Line %s: [%s] %s has no cost price established — it must be received (GRN) or given a Standard Cost on the product master before it can be sold.',
                        v_source_order_line.serial_no,
                        (SELECT product_code FROM rim_products WHERE id = v_source_order_line.product_id),
                        (SELECT product_name FROM rim_products WHERE id = v_source_order_line.product_id));
            END IF;

            INSERT INTO rid_sales_invoice_lines (
                client_id, company_id, invoice_no, invoice_date, serial_no,
                product_id, item_description, barcode, uom_id, uom_conversion_factor,
                qty_pack, qty_loose, base_qty, rate, price_source,
                gross_amount, discount_percent, discount_amount, discount_given_by,
                tax_group_id, tax_amount, final_amount, base_amount, local_amount,
                charge_amount, landed_amount, cost_price,
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
                v_source_order_line.charge_amount, v_source_order_line.landed_amount, v_cost_price,
                v_source_order_line.serial_no, p_user_id, p_user_id
            );
        END LOOP;

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

GRANT EXECUTE ON FUNCTION fn_save_sales_invoice(jsonb, jsonb, jsonb, jsonb, jsonb, uuid, boolean, boolean) TO authenticated;


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
    -- NEW (219): COMMERCIAL bundle component explosion.
    v_bundle_id                UUID;
    v_bundle_component          RECORD;
    v_component_tracked          BOOLEAN;
    v_component_stock_account      UUID;
    v_component_cos_account         UUID;
    v_component_cost_price            NUMERIC;
    v_component_cost_source            TEXT;
    v_component_qty                      NUMERIC;
    v_component_cost_total                NUMERIC;
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

    v_si_lines := v_si_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_header.customer_id, 'trans_nature', 'DR',
        'trans_amount', v_header.grand_total, 'trans_currency', v_invoice_ccy,
        'base_amount', v_header.grand_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_header.grand_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_header.grand_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', p_invoice_no, 'inv_bill_date', p_invoice_date,
        'source_line_type', 'CUSTOMER', 'source_line_no', 0
    ));

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

    SELECT * INTO v_si_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'SLS', p_invoice_date,
        v_si_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
    );

    UPDATE rid_finance_lines SET
        inv_bill_no   = v_si_result.trans_no,
        inv_bill_date = v_si_result.trans_date
    WHERE client_id       = p_client_id
      AND company_id      = p_company_id
      AND location_id     = v_header.location_id
      AND trans_no        = v_si_result.trans_no
      AND trans_date      = v_si_result.trans_date
      AND source_line_type = 'CUSTOMER' AND source_line_no = 0;

    IF v_header.stock_dispatch_mode = 'IMMEDIATE' THEN
        v_base_to_local_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_invoice_date);

        FOR v_line IN
            SELECT * FROM rid_sales_invoice_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
            ORDER BY product_id
        LOOP
            -- NEW (219): COMMERCIAL bundle — detected FIRST, before any
            -- of the ordinary per-line logic below, since a bundle's own
            -- product_id has neither a STOCK_ACCOUNT/COST_OF_SALES_ACCOUNT
            -- link nor a cost_price of its own. Explodes into one stock
            -- movement + one Dr/Cr GL pair PER COMPONENT instead, scaled
            -- by this line's own base_qty, then skips straight to the
            -- next line.
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

        SELECT trans_no, trans_date INTO v_cos_voucher_no, v_cos_voucher_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'COS', p_invoice_date,
            v_cos_lines, 'SALES_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
        );
    END IF;

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
