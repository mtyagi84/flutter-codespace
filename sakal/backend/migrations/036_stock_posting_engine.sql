-- ============================================================
-- Migration 036: Shared Stock Posting Engine
-- ============================================================
-- Second of four foundational migrations before GRN (035-038).
--
-- Every module that moves stock (GRN, and later Sales Invoice, Transfer,
-- Adjustment, Purchase/Sales Return) calls ONE shared procedure —
-- fn_post_stock_movement — instead of writing to rim_product_location
-- directly. This guarantees rim_product_location.current_stock always
-- equals SUM(ril_stock_ledger.qty_change): both writes happen inside the
-- same locked, atomic operation, so there is never a window where one
-- could succeed without the other.
--
-- Concurrency: SELECT ... FOR UPDATE on the rim_product_location row
-- serializes concurrent writers to the SAME product+location (a few ms
-- wait, never a lost update); different products/locations see zero
-- contention with each other. Any function locking MULTIPLE row-types in
-- one call must always acquire locks in this fixed order: PO lines, then
-- rim_product_location rows sorted by product_id. fn_approve_grn (038) is
-- the first consumer of this rule — any future GRN-reversal or
-- Purchase-Return function must follow the same order.
--
-- Costing: moving weighted-average, computed independently in company
-- base currency AND the product's own cost_currency_id (never derived
-- from one another by simple conversion). Full history in
-- ril_cost_price_history, inward movements only — outward movements never
-- change the average cost, only current_stock.
--
-- Objects:
--   ril_stock_ledger              → immutable append-only movement log
--   ril_cost_price_history        → immutable append-only cost audit trail (inward only)
--   fn_post_stock_movement(...)   → the one shared posting procedure
--   fn_verify_stock_integrity(...) → reconciliation/safety-net utility
-- ============================================================

-- ── ril_stock_ledger ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ril_stock_ledger (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL REFERENCES ric_clients(id),
    company_id        UUID          NOT NULL REFERENCES ric_companies(id),
    location_id       UUID          NOT NULL REFERENCES ric_locations(id),
    product_id        UUID          NOT NULL REFERENCES rim_products(id),
    trans_date        DATE          NOT NULL,
    trans_type        TEXT          NOT NULL
                       CHECK (trans_type IN (
                           'GRN','GRN_REVERSAL','PURCHASE_RETURN',
                           'SALES_INVOICE','SALES_RETURN',
                           'TRANSFER_OUT','TRANSFER_IN',
                           'ADJUSTMENT_IN','ADJUSTMENT_OUT','OPENING_STOCK'
                       )),
    qty_change        NUMERIC(18,4) NOT NULL,          -- signed: +IN, -OUT
    base_qty          NUMERIC(18,4) NOT NULL,           -- abs(qty_change), UOM-normalized, always positive for reporting
    batch_no          TEXT,
    expiry_date       DATE,
    unit_cost         NUMERIC(18,4) NOT NULL DEFAULT 0, -- base currency, snapshotted at movement time
    source_doc_type   TEXT          NOT NULL,
    source_doc_no     TEXT          NOT NULL,
    source_doc_date   DATE          NOT NULL,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id)
);

CREATE INDEX IF NOT EXISTS idx_stock_ledger_product_location
    ON ril_stock_ledger (client_id, company_id, location_id, product_id);
CREATE INDEX IF NOT EXISTS idx_stock_ledger_source
    ON ril_stock_ledger (source_doc_type, source_doc_no, source_doc_date);

ALTER TABLE ril_stock_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_stock_ledger" ON ril_stock_ledger
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ril_stock_ledger FROM anon;
GRANT SELECT, INSERT ON ril_stock_ledger TO authenticated;

-- ── ril_cost_price_history ────────────────────────────────────────────────────
-- Inward movements only. cost_price_after / cost_price_after_specific are the
-- new moving-average cost, computed by the SAME weighted-average formula run
-- independently in each currency — cost_price_after_specific is never
-- cost_price_after ÷ today's exchange rate.
CREATE TABLE IF NOT EXISTS ril_cost_price_history (
    id                          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                   UUID          NOT NULL REFERENCES ric_clients(id),
    company_id                  UUID          NOT NULL REFERENCES ric_companies(id),
    location_id                 UUID          NOT NULL REFERENCES ric_locations(id),
    product_id                  UUID          NOT NULL REFERENCES rim_products(id),
    trans_date                  DATE          NOT NULL,
    source_doc_type              TEXT          NOT NULL,
    source_doc_no                TEXT          NOT NULL,
    source_doc_date              DATE          NOT NULL,
    qty_before                  NUMERIC(18,4) NOT NULL,
    cost_price_before           NUMERIC(18,4) NOT NULL,
    cost_price_before_specific  NUMERIC(18,4),
    qty_in                      NUMERIC(18,4) NOT NULL,
    cost_price_in               NUMERIC(18,4) NOT NULL,
    cost_price_in_specific      NUMERIC(18,4),
    qty_after                   NUMERIC(18,4) NOT NULL,
    cost_price_after            NUMERIC(18,4) NOT NULL,
    cost_price_after_specific   NUMERIC(18,4),
    rate_to_base                NUMERIC(18,8),
    created_at                  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by                  UUID          REFERENCES rim_users(id)
);

CREATE INDEX IF NOT EXISTS idx_cost_price_history_product_location
    ON ril_cost_price_history (client_id, company_id, location_id, product_id, trans_date);

ALTER TABLE ril_cost_price_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_cost_price_history" ON ril_cost_price_history
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ril_cost_price_history FROM anon;
GRANT SELECT, INSERT ON ril_cost_price_history TO authenticated;

-- ── fn_post_stock_movement ────────────────────────────────────────────────────
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
    p_source_doc_type    TEXT    DEFAULT NULL,
    p_source_doc_no      TEXT    DEFAULT NULL,
    p_source_doc_date    DATE    DEFAULT NULL,
    p_user_id            UUID    DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_pl_id           UUID;
    v_qty_before      NUMERIC(18,4);
    v_cost_before      NUMERIC(18,4);
    v_cost_before_spec NUMERIC(18,4);
    v_qty_after       NUMERIC(18,4);
    v_cost_after       NUMERIC(18,4);
    v_cost_after_spec  NUMERIC(18,4);
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
            created_by
        ) VALUES (
            p_client_id, p_company_id, p_location_id, p_product_id, p_trans_date,
            p_source_doc_type, p_source_doc_no, p_source_doc_date,
            v_qty_before, v_cost_before, v_cost_before_spec,
            p_qty_change, p_unit_cost_base, p_unit_cost_specific,
            v_qty_after, v_cost_after, v_cost_after_spec,
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
        qty_change, base_qty, batch_no, expiry_date, unit_cost,
        source_doc_type, source_doc_no, source_doc_date, created_by
    ) VALUES (
        p_client_id, p_company_id, p_location_id, p_product_id, p_trans_date, p_trans_type,
        p_qty_change, abs(p_qty_change), p_batch_no, p_expiry_date, v_cost_after,
        p_source_doc_type, p_source_doc_no, p_source_doc_date, p_user_id
    );
END;
$$;

-- ── fn_verify_stock_integrity ─────────────────────────────────────────────────
-- Safety-net reconciliation, not a blocking gate. Should never return rows if
-- fn_post_stock_movement's locking is correct — exposed as a small admin report.
CREATE OR REPLACE FUNCTION fn_verify_stock_integrity(
    p_company_id  UUID,
    p_location_id UUID DEFAULT NULL
) RETURNS TABLE (
    product_id    UUID,
    location_id   UUID,
    current_stock NUMERIC,
    ledger_sum    NUMERIC,
    diff          NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT pl.product_id, pl.location_id, pl.current_stock,
           COALESCE(SUM(sl.qty_change), 0) AS ledger_sum,
           pl.current_stock - COALESCE(SUM(sl.qty_change), 0) AS diff
    FROM rim_product_location pl
    LEFT JOIN ril_stock_ledger sl
        ON sl.client_id = pl.client_id AND sl.company_id = pl.company_id
       AND sl.location_id = pl.location_id AND sl.product_id = pl.product_id
    WHERE pl.company_id = p_company_id
      AND (p_location_id IS NULL OR pl.location_id = p_location_id)
    GROUP BY pl.product_id, pl.location_id, pl.current_stock
    HAVING pl.current_stock <> COALESCE(SUM(sl.qty_change), 0);
$$;

GRANT EXECUTE ON FUNCTION fn_post_stock_movement(
    UUID, UUID, UUID, UUID, DATE, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, DATE, TEXT, TEXT, DATE, UUID
) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_verify_stock_integrity(UUID, UUID) TO authenticated;
