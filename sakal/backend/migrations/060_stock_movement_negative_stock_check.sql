-- ============================================================
-- Migration 060: fn_post_stock_movement — enforce negative-stock check
-- ============================================================
-- Both rim_products.flags['allow_negative_stock'] (item-level) and
-- ric_locations.is_negative_stock_allowed (location-level) have existed in
-- the schema/UI since 026/028, but fn_post_stock_movement — the ONE shared
-- entry point for every stock movement (GRN today; Purchase Return, Sales
-- Invoice, Transfer, Adjustment in future) — has never actually checked
-- either of them. Every outward movement has always been allowed to drive
-- current_stock negative unconditionally.
--
-- Found while designing Purchase Return: a return needs to validate that
-- the returned quantity doesn't exceed what's actually on hand, unless the
-- item AND location both explicitly permit negative stock. This is a
-- general gap, not specific to Purchase Return, so it belongs in the
-- shared engine (fixed once, here) rather than duplicated per caller.
--
-- Combination rule (discussed live): BOTH must allow it (AND) — negative
-- stock is permitted only when the item's own flag AND the location's own
-- flag both say yes. A location can restrict negative stock even for items
-- that would otherwise allow it, and vice versa.
--
-- Only checked for OUTWARD movements (p_qty_change < 0) — inward movements
-- can never make current_stock more negative.
--
-- CORRECTION: the first version of this migration was written by copying
-- fn_post_stock_movement's signature from its ORIGINAL definition (036),
-- missing that migration 049 had since added a trailing p_rate_to_base
-- parameter (and explicitly DROPPED the old 16-param signature when doing
-- so — see 049's own header comment). Recreating the stale 16-param shape
-- didn't replace 049's 17-param version in place (different signature =
-- a distinct overload to Postgres); it created a SECOND, incomplete
-- overload alongside it, which made every call using untyped NULL
-- arguments ambiguous ("function ... is not unique"). That ambiguity was
-- then made worse live: the diagnostic at the time misread the 17-param
-- version as the stale one and it was dropped, breaking fn_approve_grn
-- (which needs p_rate_to_base) entirely. This version restores the full
-- 17-param signature from 049 and layers the negative-stock check onto
-- it — the CREATE OR REPLACE below now matches 049's signature exactly,
-- so it replaces cleanly in place. If your database still has a leftover
-- 16-param overload from the first version of this migration, drop it
-- first:
--   DROP FUNCTION IF EXISTS fn_post_stock_movement(
--       UUID, UUID, UUID, UUID, DATE, TEXT, NUMERIC, NUMERIC, NUMERIC,
--       TEXT, DATE, TEXT, TEXT, TEXT, DATE, UUID
--   );
-- ============================================================

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
    p_rate_to_base       NUMERIC DEFAULT NULL    -- FX rate (trans currency -> base) used for p_unit_cost_base, stored for audit (049)
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

    -- NEW (060): block a negative resulting balance unless BOTH the item
    -- and the location explicitly allow it.
    IF p_qty_change < 0 AND v_qty_after < 0 THEN
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
        qty_change, base_qty, batch_no, expiry_date, serial_no, unit_cost,
        source_doc_type, source_doc_no, source_doc_date, created_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id, p_product_id, p_trans_date, p_trans_type,
        p_qty_change, abs(p_qty_change), p_batch_no, p_expiry_date, p_serial_no, v_cost_after,
        p_source_doc_type, p_source_doc_no, p_source_doc_date, p_user_id
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_post_stock_movement(
    UUID, UUID, UUID, UUID, DATE, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT, TEXT, TEXT, DATE, UUID, NUMERIC
) TO authenticated;
