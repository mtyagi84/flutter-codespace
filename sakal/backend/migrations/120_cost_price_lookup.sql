-- ============================================================
-- Migration 120: fn_get_cost_price — single source of truth for cost lookups
-- ============================================================
-- User-specified single-source-of-truth utility, first consumed by Sales
-- Invoice (migration 121). Every future caller that needs an item's cost
-- (stock reports, Stock Transfer, Material Issue, ...) should go through
-- this function rather than reading rim_product_location.cost_price
-- directly — see sakal/docs/reporting_engine_design.md-adjacent design
-- discussion for the reasoning. Existing cost-price read sites are NOT
-- migrated in this pass — that's a separate, deliberate rollout, same
-- shape as every other shared-utility rollout in this codebase.
--
-- Deliberately non-throwing: NEVER raises, always returns a usable
-- number. Two-tier fallback:
--   1. ril_cost_price_history — most recent row with trans_date <=
--      p_as_on_date (point-in-time, matches fn_get_exchange_rate's own
--      "most recent rate on/before date" convention).
--   2. rim_products.standard_cost — a manually-set, base-currency-only
--      "initial cost" a user can enter before any purchase ever happens.
--      Confirmed via full-backend grep: standard_cost/average_cost/
--      last_purchase_cost are currently 100% dormant (migration 026
--      only, never read or written anywhere else) — standard_cost is
--      used here as the one semantically-matching fallback; the other
--      two stay dormant unless a future need for a cascade emerges.
--   3. Neither exists -> 0.
--
-- Returns (cost_price, cost_source) rather than a bare number so each
-- CALLER can decide whether cost_source = 'NONE' is acceptable for its
-- own use case — see the design discussion: virtually every caller that
-- WRITES a transaction (a new stock movement, or a financial posting)
-- must treat 'NONE' as a hard block (a 0-cost inward movement corrupts
-- the receiving location's future moving average; a 0-cost outward
-- movement silently misstates COGS/profit) — only pure read-only
-- reporting/display screens may reasonably tolerate showing a bare 0.
-- This function itself takes no position on that — it just reports the
-- truth (a real number, and where it came from).
-- ============================================================

CREATE OR REPLACE FUNCTION fn_get_cost_price(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID,
    p_product_id  UUID,
    p_cost_type   TEXT,   -- 'B' = base currency (cost_price_after), 'S' = product's own cost_currency_id (cost_price_after_specific)
    p_as_on_date  DATE
) RETURNS TABLE (
    cost_price  NUMERIC,
    cost_source TEXT      -- 'HISTORY' | 'MASTER_DEFAULT' | 'NONE'
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cost NUMERIC;
BEGIN
    IF p_cost_type = 'S' THEN
        SELECT h.cost_price_after_specific INTO v_cost
        FROM ril_cost_price_history h
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.location_id = p_location_id AND h.product_id = p_product_id
          AND h.trans_date <= p_as_on_date
        ORDER BY h.trans_date DESC, h.created_at DESC
        LIMIT 1;
    ELSE
        SELECT h.cost_price_after INTO v_cost
        FROM ril_cost_price_history h
        WHERE h.client_id = p_client_id AND h.company_id = p_company_id
          AND h.location_id = p_location_id AND h.product_id = p_product_id
          AND h.trans_date <= p_as_on_date
        ORDER BY h.trans_date DESC, h.created_at DESC
        LIMIT 1;
    END IF;

    IF v_cost IS NOT NULL THEN
        RETURN QUERY SELECT v_cost, 'HISTORY'::TEXT;
        RETURN;
    END IF;

    -- No movement history at all for this product/location — fall back
    -- to the product master's own manually-set standard_cost. Base
    -- currency only; 'S' (specific-currency) requests have no
    -- master-level equivalent to fall back to, so they fall straight
    -- through to the final NONE/0 below rather than attempting any
    -- conversion here (conversion, when needed, is the CALLER's own
    -- concern — see fn_save_sales_invoice's rule 4 for the pattern).
    IF p_cost_type = 'B' THEN
        SELECT p.standard_cost INTO v_cost
        FROM rim_products p
        WHERE p.id = p_product_id AND p.client_id = p_client_id AND p.company_id = p_company_id
          AND p.standard_cost > 0;
    END IF;

    IF v_cost IS NOT NULL THEN
        RETURN QUERY SELECT v_cost, 'MASTER_DEFAULT'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY SELECT 0::NUMERIC, 'NONE'::TEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_get_cost_price(UUID, UUID, UUID, UUID, TEXT, DATE) TO authenticated;


-- ------------------------------------------------------------
-- cost_price columns — Sales Invoice + Sales Return lines
-- ------------------------------------------------------------
-- Always stored in the DOCUMENT's own currency (invoice currency for
-- rid_sales_invoice_lines; the return always shares its invoice's
-- currency, so no conversion is ever needed there — see migration 121's
-- comment on fn_approve_sales_return for how the return line's own
-- cost_price gets populated, verbatim, from the invoice line).
ALTER TABLE rid_sales_invoice_lines ADD COLUMN IF NOT EXISTS cost_price NUMERIC(18,4);
ALTER TABLE rid_sales_return_lines  ADD COLUMN IF NOT EXISTS cost_price NUMERIC(18,4);
