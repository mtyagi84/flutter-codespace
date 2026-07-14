-- ============================================================
-- Migration 084: fn_approve_opening_stock — fix false
-- OPENING_STOCK_ALREADY_ESTABLISHED on a multi-lot batch/serial product
-- ============================================================
-- Bug caught live by CI (the first time this function has ever actually
-- been exercised end-to-end with a multi-lot batch product): Opening
-- Stock is explicitly designed as "one line per physical LOT/UNIT, not
-- one line per product" (see docs/screens — a batch-tracked product with
-- two lots is legitimately two lines, a serial-tracked product with two
-- units is legitimately two lines, all in the SAME document).
--
-- The per-line guard in 077/080's fn_approve_opening_stock re-read
-- rim_product_location LIVE inside the same loop that posts each line's
-- own movement. For a product with two lines in one document: line 1
-- posts (via fn_post_stock_movement), which updates current_stock/
-- cost_price for that (location, product) — then when the loop reaches
-- line 2 for the SAME product, it re-reads rim_product_location and now
-- sees the stock/cost line 1 JUST created, and wrongly raises
-- OPENING_STOCK_ALREADY_ESTABLISHED against the document's own earlier
-- line, not genuinely pre-existing external stock.
--
-- Fix: split into two passes over the DISTINCT products referenced by
-- this document. Pass 1 validates every distinct product's PRE-EXISTING
-- state (locking each row FOR UPDATE, held for the rest of the
-- transaction) before any line is processed at all — so the check can
-- never see state this same document created. Pass 2 processes every
-- line exactly as before (INSERT/lock rim_product_location, derive
-- unit_cost_specific, post the movement) with no guard re-check, since
-- pass 1 already validated every product this document touches.
--
-- Same signature as 080's version (no new parameter) — CREATE OR REPLACE
-- replaces in place, no DROP FUNCTION needed.
-- ============================================================

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
    v_product          RECORD;
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

    -- 3. Pass 1: validate every DISTINCT product's PRE-EXISTING state
    --    before this document touches anything. Locks each row (held for
    --    the rest of the transaction) so pass 2's own lock below is a
    --    harmless re-lock on the same row, same transaction.
    FOR v_product IN
        SELECT DISTINCT product_id FROM rid_opening_stock_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND opening_no = p_opening_no AND opening_date = p_opening_date AND is_deleted = false
        ORDER BY product_id
    LOOP
        INSERT INTO rim_product_location (
            client_id, company_id, location_id, product_id, current_stock, cost_price, cost_price_specific, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.location_id, v_product.product_id, 0, 0, NULL, p_approved_by
        ) ON CONFLICT (client_id, company_id, location_id, product_id) DO NOTHING;

        SELECT current_stock, cost_price INTO v_current_stock, v_current_cost
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_product.product_id
        FOR UPDATE;

        IF coalesce(v_current_stock, 0) <> 0 OR coalesce(v_current_cost, 0) <> 0 THEN
            RAISE EXCEPTION 'OPENING_STOCK_ALREADY_ESTABLISHED'
                USING DETAIL = format(
                    '[%s] %s already has stock/cost established at this location (qty %s, cost %s) — Opening Stock can only be used before any other stock movement.',
                    (SELECT product_code FROM rim_products WHERE id = v_product.product_id),
                    (SELECT product_name FROM rim_products WHERE id = v_product.product_id),
                    v_current_stock, v_current_cost);
        END IF;
    END LOOP;

    -- 4. Pass 2: process every line — every product referenced here has
    --    already been validated as having no pre-existing stock/cost in
    --    pass 1, so no guard re-check is needed (and re-checking here
    --    would reintroduce the exact bug this migration fixes).
    FOR v_line IN
        SELECT * FROM rid_opening_stock_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND opening_no = p_opening_no AND opening_date = p_opening_date AND is_deleted = false
        ORDER BY product_id, line_no
    LOOP
        SELECT id INTO v_pl_id
        FROM rim_product_location
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = v_header.location_id AND product_id = v_line.product_id
        FOR UPDATE;

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

        -- 5. Post the movement. One call per line — no v_has_batches/
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

    -- 6. No fn_post_voucher call — this document never posts to GL.

    -- 7. Mark the entry approved.
    UPDATE rih_opening_stock_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_opening_stock(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
