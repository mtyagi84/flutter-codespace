-- ============================================================================
-- Migration 212: POS promotion/scheme engine — schema + deterministic resolver
-- ============================================================================
-- Per docs/pos/01_data_model.md §5 and docs/pos/02_pricing_promotions_loyalty.md
-- §2. A scheme applies automatically at the line level, same as a tax group —
-- never a manual cashier step. Deterministic overlap resolution: priority ASC,
-- first match wins unless is_stackable=true (then continue applying further
-- stackable matches in priority order). Never depends on insertion/query
-- order with no ORDER BY.
-- ============================================================================

CREATE TABLE IF NOT EXISTS rim_pos_schemes (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id               UUID NOT NULL REFERENCES ric_clients(id),
    company_id              UUID NOT NULL REFERENCES ric_companies(id),
    scheme_code             TEXT NOT NULL,
    scheme_name             TEXT NOT NULL,
    scheme_type             TEXT NOT NULL CHECK (scheme_type IN (
                                'PERCENT_OFF','AMOUNT_OFF','BUY_X_GET_Y','BUY_X_GET_DISCOUNT',
                                'FIXED_PRICE_QTY','MIX_AND_MATCH','SLAB_QUANTITY','FREE_ITEM',
                                'BILL_THRESHOLD','COUPON')),
    scope                   TEXT NOT NULL CHECK (scope IN ('PRODUCT','CATEGORY','CUSTOMER_TIER','BILL')),
    priority                INTEGER NOT NULL DEFAULT 100,
    is_stackable            BOOLEAN NOT NULL DEFAULT false,
    start_date              DATE,
    end_date                DATE,
    start_time              TIME,
    end_time                TIME,
    location_ids            UUID[],
    max_discount_amount     NUMERIC(18,4),
    usage_limit_total       INTEGER,
    usage_limit_per_customer INTEGER,
    coupon_code             TEXT,
    is_active               BOOLEAN NOT NULL DEFAULT true,
    is_deleted              BOOLEAN NOT NULL DEFAULT false,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_pos_scheme_code UNIQUE (client_id, company_id, scheme_code)
);
CREATE INDEX IF NOT EXISTS idx_pos_schemes_active ON rim_pos_schemes (client_id, company_id, is_active) WHERE is_deleted = false;

CREATE TABLE IF NOT EXISTS rim_pos_scheme_rules (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id               UUID NOT NULL REFERENCES ric_clients(id),
    company_id              UUID NOT NULL REFERENCES ric_companies(id),
    scheme_id               UUID NOT NULL REFERENCES rim_pos_schemes(id),
    applies_to_product_id   UUID REFERENCES rim_products(id),
    applies_to_category_id  UUID REFERENCES rim_item_categories(id),
    min_qty                 NUMERIC(18,4) NOT NULL DEFAULT 0,
    max_qty                 NUMERIC(18,4),
    benefit_type            TEXT NOT NULL CHECK (benefit_type IN ('PERCENT','FIXED_AMOUNT','FIXED_PRICE','FREE_QTY')),
    benefit_value           NUMERIC(18,4) NOT NULL DEFAULT 0,
    free_product_id         UUID REFERENCES rim_products(id),
    is_deleted              BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_pos_scheme_rules_scheme ON rim_pos_scheme_rules (scheme_id) WHERE is_deleted = false;

DROP POLICY IF EXISTS "auth_rw_rim_pos_schemes" ON rim_pos_schemes;
CREATE POLICY "auth_rw_rim_pos_schemes" ON rim_pos_schemes
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rim_pos_schemes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rim_pos_schemes FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_pos_schemes TO authenticated;

DROP POLICY IF EXISTS "auth_rw_rim_pos_scheme_rules" ON rim_pos_scheme_rules;
CREATE POLICY "auth_rw_rim_pos_scheme_rules" ON rim_pos_scheme_rules
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rim_pos_scheme_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rim_pos_scheme_rules FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_pos_scheme_rules TO authenticated;

-- Snapshot columns on the sales invoice line — "snapshot what was applied,
-- never recompute from current config" (per the design doc §2).
ALTER TABLE rid_sales_invoice_lines ADD COLUMN IF NOT EXISTS applied_scheme_id UUID REFERENCES rim_pos_schemes(id);
ALTER TABLE rid_sales_invoice_lines ADD COLUMN IF NOT EXISTS scheme_discount_amount NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE rid_sales_invoice_lines ADD COLUMN IF NOT EXISTS scheme_name_snapshot TEXT;

-- ============================================================================
-- fn_resolve_pos_schemes_for_line — pure computation, no writes. Called once
-- per line from fn_save_sales_invoice (migration 213). Returns the best
-- matching scheme's discount for a given product/qty/gross_amount, resolved
-- deterministically by priority ASC. Only PRODUCT/CATEGORY-scoped,
-- line-level scheme types are resolved here (PERCENT_OFF, AMOUNT_OFF,
-- BUY_X_GET_Y via FREE_QTY benefit on the same line, BUY_X_GET_DISCOUNT,
-- FIXED_PRICE_QTY, SLAB_QUANTITY, FREE_ITEM). BILL_THRESHOLD (header-level)
-- and COUPON (requires an explicit code) are resolved separately in 213's
-- header-level pass, not here — a bill-threshold or coupon isn't a property
-- of any one line.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_resolve_pos_schemes_for_line(
    p_client_id     UUID,
    p_company_id    UUID,
    p_location_id   UUID,
    p_product_id    UUID,
    p_category_id   UUID,
    p_qty           NUMERIC,
    p_gross_amount  NUMERIC,
    p_trans_date    DATE
)
RETURNS TABLE (scheme_id UUID, scheme_name TEXT, discount_amount NUMERIC, free_product_id UUID, free_qty NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_rule      RECORD;
    v_total_discount NUMERIC := 0;
    v_last_scheme_id UUID;
    v_last_scheme_name TEXT;
    v_free_product_id UUID;
    v_free_qty NUMERIC := 0;
    v_stop BOOLEAN := false;
BEGIN
    FOR v_rule IN
        SELECT s.id AS s_id, s.scheme_name AS s_name, s.is_stackable, s.max_discount_amount,
               r.id AS r_id, r.benefit_type, r.benefit_value, r.free_product_id AS r_free_product_id,
               r.min_qty, r.max_qty
        FROM rim_pos_schemes s
        JOIN rim_pos_scheme_rules r ON r.scheme_id = s.id AND r.is_deleted = false
        WHERE s.client_id = p_client_id AND s.company_id = p_company_id
          AND s.is_active = true AND s.is_deleted = false
          AND s.scheme_type NOT IN ('BILL_THRESHOLD','COUPON')
          AND (s.start_date IS NULL OR p_trans_date >= s.start_date)
          AND (s.end_date   IS NULL OR p_trans_date <= s.end_date)
          AND (s.location_ids IS NULL OR p_location_id = ANY(s.location_ids))
          AND (r.applies_to_product_id  IS NULL OR r.applies_to_product_id  = p_product_id)
          AND (r.applies_to_category_id IS NULL OR r.applies_to_category_id = p_category_id)
          AND p_qty >= r.min_qty
          AND (r.max_qty IS NULL OR p_qty <= r.max_qty)
        ORDER BY s.priority ASC, r.min_qty DESC
    LOOP
        EXIT WHEN v_stop;

        DECLARE v_this_discount NUMERIC := 0;
        BEGIN
            CASE v_rule.benefit_type
                WHEN 'PERCENT' THEN
                    v_this_discount := round(p_gross_amount * v_rule.benefit_value / 100.0, 4);
                WHEN 'FIXED_AMOUNT' THEN
                    v_this_discount := v_rule.benefit_value;
                WHEN 'FIXED_PRICE' THEN
                    v_this_discount := greatest(p_gross_amount - (v_rule.benefit_value * p_qty), 0);
                WHEN 'FREE_QTY' THEN
                    -- Buy X Get Y / Free Item: benefit_value = qty given free at zero charge,
                    -- valued at the line's own unit price (discount), OR a distinct free_product_id.
                    IF v_rule.r_free_product_id IS NOT NULL THEN
                        v_free_product_id := v_rule.r_free_product_id;
                        v_free_qty := v_rule.benefit_value;
                    ELSE
                        v_this_discount := round((p_gross_amount / NULLIF(p_qty,0)) * least(v_rule.benefit_value, p_qty), 4);
                    END IF;
            END CASE;

            IF v_rule.max_discount_amount IS NOT NULL THEN
                v_this_discount := least(v_this_discount, v_rule.max_discount_amount);
            END IF;

            v_total_discount := v_total_discount + v_this_discount;
            v_last_scheme_id := v_rule.s_id;
            v_last_scheme_name := v_rule.s_name;

            IF NOT v_rule.is_stackable THEN
                v_stop := true;
            END IF;
        END;
    END LOOP;

    IF v_last_scheme_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT v_last_scheme_id, v_last_scheme_name,
                        least(v_total_discount, p_gross_amount), v_free_product_id, v_free_qty;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_resolve_pos_schemes_for_line(UUID, UUID, UUID, UUID, UUID, NUMERIC, NUMERIC, DATE) TO authenticated;
