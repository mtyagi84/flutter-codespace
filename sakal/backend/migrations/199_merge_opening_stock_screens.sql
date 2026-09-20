-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 199 — Merge Opening Stock + Opening Stock Value Upload
-- ═══════════════════════════════════════════════════════════════════════════
-- User correctly flagged the two screens as functionally duplicating each
-- other (both establish opening qty+cost for a product/location, same
-- underlying tables/functions — the only real difference was UI/workflow).
-- See docs/screens/plan_merge_opening_stock_screens.md for the full design.
-- Opening Stock Value Upload's own screen is retired; every capability it
-- added (GL posting via post_gl, the Opening Stock Equity Account link
-- type) is folded into the original Opening Stock screen as an optional
-- "Post to Ledger" toggle instead of a second, separate screen.
--
-- Two backend changes:
-- 1. fn_approve_opening_stock's permission check collapses to always check
--    IN-OPN, regardless of post_gl — there is no longer a second screen to
--    justify the separate IN-OSV permission axis. Full body reproduced
--    verbatim from migration 193 (its current live definition) with only
--    this one branch changed.
-- 2. IN-OSV is hidden from the menu (is_active=false/is_deleted=true, same
--    convention as migration 197's PR-PAY/IN-STK/FN-CBK cleanup) and
--    removed from fn_seed_client_modules.sql (manual re-deploy needed
--    after, per this project's own established convention for that file).
--
-- post_gl, posted_voucher_no, and the OPENING_STOCK_EQUITY_ACCOUNT link
-- type all stay untouched — the merged screen still needs every bit of
-- that backend capability.
-- ═══════════════════════════════════════════════════════════════════════════

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
    v_local_ccy        TEXT;
    v_rate_to_local    NUMERIC;
    v_cost_ccy         TEXT;
    v_unit_cost_spec   NUMERIC;
    v_stock_account    UUID;
    v_equity_account   UUID;
    v_any_product_id   UUID;
    v_line_value       NUMERIC;
    v_total_value      NUMERIC := 0;
    v_gl_lines         JSONB   := '[]'::jsonb;
    v_glv_trans_no     TEXT;
    v_glv_trans_date   DATE;
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

    -- Server-side re-check of approve permission, resolved from the JWT
    -- (never a client-supplied parameter). Always IN-OPN now — the
    -- separate IN-OSV permission axis is retired along with its own
    -- screen; one screen, one permission, whether or not this particular
    -- document happens to post GL.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-OPN');

    -- 2. Period + backdate + future-date checks
    PERFORM fn_check_period_open(p_company_id, p_opening_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'OPENING_STOCK', p_opening_date);

    IF p_opening_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'FUTURE_DATE_NOT_ALLOWED'
            USING DETAIL = format('Opening date %s is in the future — an Opening Stock entry cannot be dated ahead of today.', p_opening_date);
    END IF;

    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;
    v_rate_to_local := CASE WHEN v_base_ccy = v_local_ccy THEN 1
                            ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_local_ccy, p_opening_date) END;

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
    --    would reintroduce the exact bug migration 084 fixed).
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

        -- Derive unit_cost_specific from the entered unit_cost ONLY when
        -- it wasn't already supplied at save time — same-currency
        -- shortcut / fn_get_exchange_rate lookup otherwise, exactly as
        -- before.
        IF v_line.unit_cost_specific IS NOT NULL THEN
            v_unit_cost_spec := v_line.unit_cost_specific;
        ELSE
            SELECT c.currency_id INTO v_cost_ccy
            FROM rim_products p LEFT JOIN rim_currencies c ON c.id = p.cost_currency_id
            WHERE p.id = v_line.product_id;

            IF v_cost_ccy IS NULL OR v_cost_ccy = v_base_ccy THEN
                v_unit_cost_spec := v_line.unit_cost;
            ELSE
                v_unit_cost_spec := v_line.unit_cost * fn_get_exchange_rate(p_company_id, v_header.location_id, v_base_ccy, v_cost_ccy, p_opening_date);
            END IF;
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

        -- 6. GL (only when post_gl): one Dr per line against the product's
        --    own Stock Account — no aggregation across lines sharing an
        --    account, same simplicity precedent as GRN/Material Issue/
        --    Stock Adjustment's own per-line postings.
        IF v_header.post_gl THEN
            v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
            IF v_stock_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = format('No Stock Account resolved for product %s.',
                        (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
            END IF;

            v_line_value := v_line.base_qty * v_line.unit_cost;
            v_total_value := v_total_value + v_line_value;
            v_any_product_id := v_line.product_id;

            v_gl_lines := v_gl_lines || jsonb_build_array(
                jsonb_build_object(
                    'account_id', v_stock_account, 'trans_nature', 'DR',
                    'trans_amount', v_line_value, 'trans_currency', v_base_ccy,
                    'base_amount', v_line_value, 'base_rate', 1,
                    'local_amount', v_line_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                    'party_amount', v_line_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                    'source_line_type', 'OPENING_STOCK_VALUE', 'source_line_no', v_line.line_no
                )
            );
        END IF;
    END LOOP;

    -- 7. Post the GL voucher — one aggregate Cr line against the Opening
    --    Stock Equity Account (matching Purchase Return's own "other side
    --    posted once in aggregate" precedent), anchored on any one product
    --    from this document (this account is always configured at COMPANY
    --    granularity in practice — same anchoring precedent already used
    --    for EXCHANGE_GAIN_LOSS_ACCOUNT). Non-post_gl documents: unchanged,
    --    no fn_post_voucher call at all.
    IF v_header.post_gl THEN
        v_equity_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_any_product_id, 'OPENING_STOCK_EQUITY_ACCOUNT');
        IF v_equity_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = 'No Opening Stock Equity Account configured. Set it up in Account Link Setup first.';
        END IF;

        v_gl_lines := v_gl_lines || jsonb_build_array(
            jsonb_build_object(
                'account_id', v_equity_account, 'trans_nature', 'CR',
                'trans_amount', v_total_value, 'trans_currency', v_base_ccy,
                'base_amount', v_total_value, 'base_rate', 1,
                'local_amount', v_total_value * v_rate_to_local, 'local_rate', v_rate_to_local,
                'party_amount', v_total_value, 'party_currency', v_base_ccy, 'party_rate', 1,
                'source_line_type', 'OPENING_STOCK_EQUITY'
            )
        );

        SELECT trans_no, trans_date INTO v_glv_trans_no, v_glv_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'JV', p_opening_date,
            v_gl_lines, 'OPENING_STOCK', p_opening_no, p_opening_date, p_approved_by
        );
    END IF;

    -- 8. Mark the entry approved.
    UPDATE rih_opening_stock_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_glv_trans_no,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_opening_stock(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── Retire the IN-OSV menu item (same convention as migration 197) ─────────
UPDATE ric_master_menus
SET is_active = false, is_deleted = true, updated_at = now()
WHERE feature_code = 'IN-OSV' AND is_deleted = false;
