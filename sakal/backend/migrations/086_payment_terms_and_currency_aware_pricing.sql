-- ============================================================
-- Migration 086: Payment Terms master + Incoterm + currency-aware
-- fn_get_active_price
-- ============================================================
-- Pre-launch revision surfaced while reviewing migration 087 (Sales
-- Order) before it runs against real Supabase for the first time. Three
-- pieces, built together because they're all foundational fixes that
-- 087 itself will consume:
--
--   1. fn_get_active_price becomes currency-aware — a real bug found
--      during review: it returned a raw selling_price with no
--      indication of what currency it was IN, and fn_save_sales_order
--      (087) took that number directly as the line rate. A Sales Order
--      raised in a currency different from whatever the Price Master
--      batch was entered in would have silently charged the wrong
--      amount. DROP + CREATE is required here (not a plain CREATE OR
--      REPLACE) because the RETURNS TABLE column list changes shape —
--      see the project's own documented gotcha on this.
--
--   2. rim_payment_terms/rim_payment_term_lines — Payment Terms was a
--      bare TEXT field, copy-pasted identically across Purchase Order,
--      Sales Quotation, and Sales Order. Odoo's real model
--      (account.payment.term / account.payment.term.line) is a proper
--      master with installment lines (e.g. "30% now, 70% in 30 days")
--      — built here so Sales Quotation/Order (and a future Sales
--      Invoice) all pick from one shared master instead of free text.
--      No due-date computation logic lives here — that's for whichever
--      future module actually posts a receivable; this module only
--      ever gets *referenced*.
--
--   3. Incoterm — reuses the EXISTING rim_common_masters/
--      rim_common_master_types generic mechanism (same one already
--      used for Brand/Unit/Color/reason-type lookups) rather than a
--      new bespoke table — a plain picklist needs nothing more.
--
-- Also retrofits rih_sales_quotations (081, already shipped) with the
-- two new reference columns, additive-only — the old payment_terms/
-- delivery_terms TEXT columns are kept, never dropped, so any existing
-- row keeps working; the Flutter screen switches to the new columns
-- going forward.
-- ============================================================


-- ============================================================
-- PART 1: fn_get_active_price becomes currency-aware
-- ============================================================

DROP FUNCTION IF EXISTS fn_get_active_price(UUID, UUID, UUID, UUID, UUID, UUID, DATE);

CREATE OR REPLACE FUNCTION fn_get_active_price(
    p_client_id       UUID,
    p_company_id      UUID,
    p_location_id     UUID,
    p_product_id      UUID,
    p_uom_id          UUID,
    p_customer_id     UUID,
    p_as_of_date      DATE,
    p_target_currency TEXT   -- ISO code, e.g. 'EUR' — the caller's own document currency
)
RETURNS TABLE (
    selling_price        NUMERIC,   -- converted TO p_target_currency — what every caller actually uses
    native_selling_price NUMERIC,   -- as stored on the Price Master batch, for audit/display
    price_currency_code  TEXT,
    conversion_rate      NUMERIC,   -- 1 if same currency, else the SELLING rate actually applied
    entry_no             TEXT,
    effective_date       DATE,
    price_type           TEXT,
    is_tax_inclusive      BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_native_price   NUMERIC;
    v_native_ccy     TEXT;
    v_entry_no       TEXT;
    v_effective_date DATE;
    v_price_type     TEXT;
    v_is_tax_incl    BOOLEAN;
    v_rate           NUMERIC;
BEGIN
    IF p_customer_id IS NOT NULL THEN
        SELECT l.selling_price, c.currency_id, l.entry_no, l.effective_date, l.price_type, l.is_tax_inclusive
          INTO v_native_price, v_native_ccy, v_entry_no, v_effective_date, v_price_type, v_is_tax_incl
        FROM   rid_price_master_lines l
        JOIN   rih_price_master_headers h
          ON   h.client_id = l.client_id AND h.company_id = l.company_id
          AND  h.entry_no = l.entry_no AND h.entry_date = l.entry_date
        JOIN   rim_currencies c ON c.id = h.price_currency_id
        WHERE  l.client_id = p_client_id AND l.company_id = p_company_id
          AND  l.location_id = p_location_id
          AND  l.product_id = p_product_id AND l.uom_id = p_uom_id
          AND  l.price_type = 'CUSTOMER' AND l.customer_id = p_customer_id
          AND  l.status = 'APPROVED' AND l.is_deleted = false
          AND  l.effective_date <= p_as_of_date
        ORDER BY l.effective_date DESC, l.created_at DESC
        LIMIT 1;

        IF FOUND THEN
            v_rate := CASE WHEN v_native_ccy = p_target_currency THEN 1
                            ELSE fn_get_exchange_rate(p_company_id, p_location_id, v_native_ccy, p_target_currency, p_as_of_date, 'SELLING') END;
            RETURN QUERY SELECT v_native_price * v_rate, v_native_price, v_native_ccy, v_rate,
                                v_entry_no, v_effective_date, v_price_type, v_is_tax_incl;
            RETURN;
        END IF;
    END IF;

    SELECT l.selling_price, c.currency_id, l.entry_no, l.effective_date, l.price_type, l.is_tax_inclusive
      INTO v_native_price, v_native_ccy, v_entry_no, v_effective_date, v_price_type, v_is_tax_incl
    FROM   rid_price_master_lines l
    JOIN   rih_price_master_headers h
      ON   h.client_id = l.client_id AND h.company_id = l.company_id
      AND  h.entry_no = l.entry_no AND h.entry_date = l.entry_date
    JOIN   rim_currencies c ON c.id = h.price_currency_id
    WHERE  l.client_id = p_client_id AND l.company_id = p_company_id
      AND  l.location_id = p_location_id
      AND  l.product_id = p_product_id AND l.uom_id = p_uom_id
      AND  l.price_type = 'GENERIC' AND l.customer_id IS NULL
      AND  l.status = 'APPROVED' AND l.is_deleted = false
      AND  l.effective_date <= p_as_of_date
    ORDER BY l.effective_date DESC, l.created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN; -- empty — caller must treat "no row" as "no price configured," never silently default
    END IF;

    v_rate := CASE WHEN v_native_ccy = p_target_currency THEN 1
                    ELSE fn_get_exchange_rate(p_company_id, p_location_id, v_native_ccy, p_target_currency, p_as_of_date, 'SELLING') END;
    RETURN QUERY SELECT v_native_price * v_rate, v_native_price, v_native_ccy, v_rate,
                        v_entry_no, v_effective_date, v_price_type, v_is_tax_incl;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_get_active_price(UUID, UUID, UUID, UUID, UUID, UUID, DATE, TEXT) TO authenticated;


-- ============================================================
-- PART 2: Payment Terms master (Odoo-shaped: header + installment lines)
-- ============================================================

CREATE TABLE IF NOT EXISTS rim_payment_terms (
    id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id   UUID          NOT NULL REFERENCES ric_clients(id),
    company_id  UUID          NOT NULL REFERENCES ric_companies(id),
    term_code   TEXT          NOT NULL,
    term_name   TEXT          NOT NULL,
    -- Printable summary, e.g. "30% Advance, 70% in 30 Days" — admin-
    -- typed, not auto-generated from the lines below (keeps v1 simple;
    -- the lines exist for a future due-date/cash-flow computation, not
    -- for rendering this text).
    description TEXT,
    is_active   BOOLEAN       NOT NULL DEFAULT true,
    is_deleted  BOOLEAN       NOT NULL DEFAULT false,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by  UUID          REFERENCES rim_users(id),
    updated_at  TIMESTAMPTZ,
    updated_by  UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_payment_terms_code UNIQUE (client_id, company_id, term_code)
);

CREATE INDEX IF NOT EXISTS idx_payment_terms_tenant ON rim_payment_terms (client_id, company_id, is_deleted);

DROP TRIGGER IF EXISTS trg_rim_payment_terms_updated_at ON rim_payment_terms;
CREATE TRIGGER trg_rim_payment_terms_updated_at
    BEFORE UPDATE ON rim_payment_terms
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rim_payment_terms ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_payment_terms" ON rim_payment_terms;
CREATE POLICY "auth_rw_payment_terms" ON rim_payment_terms
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_payment_terms FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_payment_terms TO authenticated;


CREATE TABLE IF NOT EXISTS rim_payment_term_lines (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID          NOT NULL REFERENCES ric_clients(id),
    company_id      UUID          NOT NULL REFERENCES ric_companies(id),
    term_id         UUID          NOT NULL REFERENCES rim_payment_terms(id),
    sequence        INTEGER       NOT NULL,
    value_type      TEXT          NOT NULL DEFAULT 'PERCENT' CHECK (value_type IN ('PERCENT', 'FIXED')),
    value_amount    NUMERIC(18,4) NOT NULL DEFAULT 0,
    due_days        INTEGER       NOT NULL DEFAULT 0,
    -- Odoo's "end of month" rule — if true, the computed due date snaps
    -- forward to the last day of its own month. No due-date computation
    -- happens anywhere yet (see header comment) — this flag is stored
    -- now so that future logic doesn't need a schema change to use it.
    is_end_of_month BOOLEAN       NOT NULL DEFAULT false,
    is_deleted      BOOLEAN       NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by      UUID          REFERENCES rim_users(id),
    updated_at      TIMESTAMPTZ,
    updated_by      UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_payment_term_lines UNIQUE (client_id, company_id, term_id, sequence)
);

CREATE INDEX IF NOT EXISTS idx_payment_term_lines_term ON rim_payment_term_lines (client_id, company_id, term_id);

ALTER TABLE rim_payment_term_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_payment_term_lines" ON rim_payment_term_lines;
CREATE POLICY "auth_rw_payment_term_lines" ON rim_payment_term_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_payment_term_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_payment_term_lines TO authenticated;


-- ------------------------------------------------------------
-- fn_save_payment_term — validates PERCENT-only batches sum to 100.
-- Deliberately skips that validation when a batch mixes FIXED+PERCENT
-- lines (e.g. "a fixed deposit now, remainder as a percentage later") —
-- a documented v1 simplification, not a silent gap: mixed batches are a
-- real but rarer shape, and validating them correctly needs to know the
-- document's own total (not available here), so it's left to whichever
-- future module actually consumes the lines for real money math.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_save_payment_term(
    p_header  JSONB,   -- {client_id, company_id, term_id, term_code, term_name, description}
    p_lines   JSONB,   -- [{sequence, value_type, value_amount, due_days, is_end_of_month}, ...]
    p_user_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id   UUID;
    v_company_id  UUID;
    v_term_id     UUID;
    v_is_new      BOOLEAN;
    v_line        JSONB;
    v_percent_sum NUMERIC := 0;
    v_all_percent BOOLEAN := true;
BEGIN
    v_client_id  := (p_header->>'client_id')::uuid;
    v_company_id := (p_header->>'company_id')::uuid;
    v_term_id    := (nullif(p_header->>'term_id', ''))::uuid;
    v_is_new     := v_term_id IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one installment line.';
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        IF coalesce(v_line->>'value_type', 'PERCENT') = 'PERCENT' THEN
            v_percent_sum := v_percent_sum + coalesce((v_line->>'value_amount')::numeric, 0);
        ELSE
            v_all_percent := false;
        END IF;
    END LOOP;

    IF v_all_percent AND abs(v_percent_sum - 100) > 0.01 THEN
        RAISE EXCEPTION 'PERCENT_LINES_MUST_SUM_TO_100'
            USING DETAIL = format('The installment percentages sum to %s%%, not 100%%.', v_percent_sum);
    END IF;

    IF v_is_new THEN
        INSERT INTO rim_payment_terms (client_id, company_id, term_code, term_name, description, created_by, updated_by)
        VALUES (v_client_id, v_company_id, trim(p_header->>'term_code'), trim(p_header->>'term_name'),
                nullif(p_header->>'description', ''), p_user_id, p_user_id)
        RETURNING id INTO v_term_id;
    ELSE
        UPDATE rim_payment_terms SET
            term_code   = trim(p_header->>'term_code'),
            term_name   = trim(p_header->>'term_name'),
            description = nullif(p_header->>'description', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE id = v_term_id AND client_id = v_client_id AND company_id = v_company_id;

        DELETE FROM rim_payment_term_lines WHERE term_id = v_term_id;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rim_payment_term_lines (
            client_id, company_id, term_id, sequence, value_type, value_amount, due_days, is_end_of_month, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_term_id,
            (v_line->>'sequence')::integer,
            coalesce(v_line->>'value_type', 'PERCENT'),
            coalesce((v_line->>'value_amount')::numeric, 0),
            coalesce((v_line->>'due_days')::integer, 0),
            coalesce((v_line->>'is_end_of_month')::boolean, false),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_term_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_payment_term(JSONB, JSONB, UUID) TO authenticated;


-- ============================================================
-- PART 3: Incoterm — reuses the existing generic common-masters
-- mechanism (rim_common_master_types/rim_common_masters), same one
-- already used for Brand/Unit/Color/reason-type lookups.
-- ============================================================

INSERT INTO rim_common_master_types (type_key, type_name)
VALUES ('INCOTERM', 'Incoterm')
ON CONFLICT (type_key) DO NOTHING;

-- Seeded globally per client/company at migration time would need a
-- loop over every existing company (same shape as other global-type
-- seeds in this schema) — Incoterms are standard codes, not company-
-- specific data, so seed them once per existing company here and via
-- fn_seed_client_modules-equivalent for future clients is unnecessary
-- overhead; instead this loop seeds every existing company now, and
-- the Flutter Common Masters screen lets an admin add more/deactivate
-- unused ones per company just like any other common-master type.
DO $$
DECLARE
    v_type_id UUID;
    v_company RECORD;
    v_code    TEXT;
    v_codes   TEXT[] := ARRAY['EXW','FCA','CPT','CIP','DAP','DPU','DDP','FAS','FOB','CFR','CIF'];
BEGIN
    SELECT id INTO v_type_id FROM rim_common_master_types WHERE type_key = 'INCOTERM';

    FOR v_company IN SELECT id, client_id FROM ric_companies WHERE is_deleted = false
    LOOP
        FOREACH v_code IN ARRAY v_codes
        LOOP
            INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
            SELECT v_company.client_id, v_company.id, v_type_id, v_code, array_position(v_codes, v_code)
            WHERE NOT EXISTS (
                SELECT 1 FROM rim_common_masters
                WHERE client_id = v_company.client_id AND company_id = v_company.id
                  AND type_id = v_type_id AND description = v_code
            );
        END LOOP;
    END LOOP;
END $$;


-- ============================================================
-- PART 4: Retrofit rih_sales_quotations (081, already shipped) —
-- additive only. Old payment_terms/delivery_terms TEXT columns stay,
-- never dropped; the Flutter screen switches to the new columns going
-- forward.
-- ============================================================

ALTER TABLE rih_sales_quotations
    ADD COLUMN IF NOT EXISTS payment_term_id UUID REFERENCES rim_payment_terms(id),
    ADD COLUMN IF NOT EXISTS incoterm_id     UUID REFERENCES rim_common_masters(id);


-- ============================================================
-- Menu seed — new Payment Terms master screen, existing companies +
-- fn_seed_client_modules.sql for future clients. ric_system_modules
-- only has AD/SL/PR/IN/FN (no dedicated master-data module) — placed
-- under 'AD' / 'AD-SETG' (System Setup), the same group Currency Setup
-- already uses, since Payment Terms is exactly that shape of
-- foundational cross-module reference list.
-- ============================================================

INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, 'AD-PAYTERM', 'Payment Terms', '/master/payment-terms',
    5, 'AD-SETG', 'System Setup', 0, false, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'AD'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
