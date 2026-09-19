-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 193 — Opening Stock Value Upload
--
-- Extends the EXISTING Opening Stock engine (077/080/084/112) with an
-- optional GL-posting path, for a new bulk-Excel-upload screen that
-- establishes qty + cost AND debits each product's Stock Account against a
-- new "Opening Stock Equity Account" — dated at the company's financial
-- year start. Deliberately reuses rih_opening_stock_headers/
-- rid_opening_stock_lines/fn_save_opening_stock/fn_approve_opening_stock
-- rather than a parallel set of tables, so the existing
-- OPENING_STOCK_ALREADY_ESTABLISHED guard (per product, regardless of which
-- screen created the document) keeps protecting BOTH screens from ever
-- double-establishing the same product/location. See
-- docs/screens/plan_opening_stock_value_upload.md for the full design.
--
-- - rih_opening_stock_headers.post_gl (new, default false) — the existing
--   screen never sets it, so its behavior is byte-for-byte unchanged.
-- - rih_opening_stock_headers.posted_voucher_no (new, nullable) — traces
--   back to the JV this document posted, same convention as
--   rih_purchase_invoices.posted_voucher_no.
-- - fn_save_opening_stock — NO signature change. p_header/p_lines are
--   already JSONB; 'post_gl' (header) and 'unit_cost_specific' (per line,
--   optional — the new screen supplies it directly from its own "Price
--   (Product Currency)" column) are just two more optional keys, read the
--   same way every other optional key on this function already is.
-- - fn_approve_opening_stock — CREATE OR REPLACE, same 5-parameter
--   signature, full body reproduced verbatim from migration 112 (its
--   current live definition) plus: (a) skip the unit_cost_specific
--   auto-derive step when a value was already supplied at save time,
--   (b) when post_gl, build one Dr voucher line per opening-stock line
--   (STOCK_ACCOUNT, hard-fail if unconfigured — same "never post with no
--   account" rule as every other module) + one aggregate Cr line
--   (OPENING_STOCK_EQUITY_ACCOUNT) and post them via ONE fn_post_voucher
--   call, tagged source_doc_type='OPENING_STOCK', (c) branch the approve-
--   permission check on post_gl: false -> existing IN-OPN, true -> new
--   IN-OSV — same "composition guard" pattern already used elsewhere in
--   this schema (e.g. GRN vs Stock Count Review's shared IN-ADJ check).
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE rih_opening_stock_headers ADD COLUMN IF NOT EXISTS post_gl BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE rih_opening_stock_headers ADD COLUMN IF NOT EXISTS posted_voucher_no TEXT;

-- ── New Account Link Setup type — Cr side of the GL posting ────────────────
-- Existing types run 10..151 (032/054/061/071/099); DR side ('STOCK_ACCOUNT')
-- already exists and needs zero new setup. The Account Link Setup SCREEN
-- already lists link types generically from this table, so no Flutter
-- change is needed for the admin to configure this.
INSERT INTO rim_account_link_types (link_key, link_name, sort_order) VALUES
    ('OPENING_STOCK_EQUITY_ACCOUNT', 'Opening Stock Equity Account', 160)
ON CONFLICT (link_key) DO NOTHING;

-- ── New menu entry: Opening Stock Value Upload (IN-OSV) ─────────────────────
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, 'IN-OSV', 'Opening Stock Value Upload', '/inventory/opening-stock-value-upload',
    10, 'IN-OPS', 'Operations', 0, true, false, true
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'IN'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;

-- Backfill ric_user_menus for existing users who already have edit access to
-- another IN-OPS feature — same proven shape as migration 191's own
-- MST-BUP backfill (module_id is NOT NULL / FK'd, resolved from
-- ric_master_menus, not fabricated).
INSERT INTO ric_user_menus (
    client_id, company_id, user_id, module_id, feature_code, serial_no,
    view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT DISTINCT
    mm.client_id, mm.company_id, existing.user_id, mm.module_id, mm.feature_code, mm.serial_no,
    true, true, mm.approve_allowed, mm.copy_allowed, mm.excel_upload_allowed
FROM ric_master_menus mm
JOIN (
    SELECT DISTINCT um.user_id, um.client_id, um.company_id, um.module_id
    FROM ric_user_menus um
    JOIN ric_master_menus other ON other.client_id = um.client_id AND other.company_id = um.company_id AND other.feature_code = um.feature_code
    WHERE um.edit_allowed = true AND um.is_deleted = false AND other.group_code = 'IN-OPS'
) existing
    ON  existing.client_id  = mm.client_id
    AND existing.company_id = mm.company_id
    AND existing.module_id  = mm.module_id
WHERE mm.feature_code = 'IN-OSV'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, edit_allowed = true, excel_upload_allowed = true, updated_at = now();


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_opening_stock — full body reproduced from migration 080 (its
-- current live definition — it added manufacturing_date to the INSERT list,
-- not present in 077's original body), plus this migration's own additive
-- post_gl/unit_cost_specific reads. Same signature throughout.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_opening_stock(
    p_header  JSONB,
    p_lines   JSONB,   -- [{line_no, product_id, uom_id, uom_conversion_factor, pack_qty, loose_qty, base_qty, batch_no, expiry_date, manufacturing_date, serial_no, unit_cost, unit_cost_specific, barcode, remarks}, ...]
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
    v_post_gl      BOOLEAN;
    v_old_status   TEXT;
    v_is_new       BOOLEAN;
    v_line         JSONB;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_opening_no   := nullif(trim(p_header->>'opening_no'), '');
    v_opening_date := (p_header->>'opening_date')::date;
    v_post_gl      := coalesce((p_header->>'post_gl')::boolean, false);
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
            remarks, post_gl, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_opening_no, v_opening_date,
            nullif(p_header->>'remarks', ''), v_post_gl, p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_opening_stock_headers SET
            location_id  = v_location_id,
            opening_date = v_opening_date,
            remarks      = nullif(p_header->>'remarks', ''),
            post_gl      = v_post_gl,
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND opening_no = v_opening_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_opening_stock_lines (
            client_id, company_id, opening_no, opening_date, line_no,
            product_id, uom_id, uom_conversion_factor, pack_qty, loose_qty, base_qty,
            batch_no, expiry_date, manufacturing_date, serial_no, unit_cost, unit_cost_specific, barcode, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_opening_no, v_opening_date, (v_line->>'line_no')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'pack_qty')::numeric, 0), coalesce((v_line->>'loose_qty')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0),
            nullif(v_line->>'batch_no', ''), (nullif(v_line->>'expiry_date', ''))::date, (nullif(v_line->>'manufacturing_date', ''))::date, nullif(v_line->>'serial_no', ''),
            coalesce((v_line->>'unit_cost')::numeric, 0),
            nullif(v_line->>'unit_cost_specific', '')::numeric,
            nullif(v_line->>'barcode', ''),
            nullif(v_line->>'remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_opening_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_opening_stock(JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_opening_stock — full body reproduced from migration 112
-- (its current live definition), plus the GL-posting extension.
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
    -- (never a client-supplied parameter). Branches on post_gl so a
    -- company can grant "plain opening stock" (IN-OPN) and "GL-posting
    -- opening stock value upload" (IN-OSV) as separate permissions.
    IF v_header.post_gl THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-OSV');
    ELSE
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'IN-OPN');
    END IF;

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
        -- it wasn't already supplied at save time (the Value Upload screen
        -- supplies it directly from its own "Price (Product Currency)"
        -- column) — same-currency shortcut / fn_get_exchange_rate lookup
        -- otherwise, exactly as before.
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

        -- 6. GL (new, only when post_gl): one Dr per line against the
        --    product's own Stock Account — no aggregation across lines
        --    sharing an account, same simplicity precedent as GRN/
        --    Material Issue/Stock Adjustment's own per-line postings.
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
