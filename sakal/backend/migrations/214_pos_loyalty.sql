-- ============================================================================
-- Migration 214: POS loyalty program — phone-number-first, no customer required
-- ============================================================================
-- Per docs/pos/01_data_model.md §4 and 02_pricing_promotions_loyalty.md §4.
-- A POS sale never needs a real rim_accounts customer to earn/redeem points —
-- the cashier asks for a mobile number only if the customer agrees to share
-- it. The ledger (ril_loyalty_ledger) is the one source of truth, mirroring
-- ril_stock_ledger's own "ledger is truth, balance column is cache" principle.
-- ============================================================================

CREATE TABLE IF NOT EXISTS rim_loyalty_programs (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                       UUID NOT NULL REFERENCES ric_clients(id),
    company_id                      UUID NOT NULL REFERENCES ric_companies(id),
    program_name                    TEXT NOT NULL,
    points_per_amount               NUMERIC(18,6) NOT NULL DEFAULT 0,
    point_value_in_base_currency    NUMERIC(18,6) NOT NULL DEFAULT 0,
    min_points_to_redeem            INTEGER NOT NULL DEFAULT 0,
    max_redemption_percent_of_bill  NUMERIC(5,2),
    tier_multiplier_enabled         BOOLEAN NOT NULL DEFAULT false,
    expiry_months                   INTEGER,
    earn_basis                      TEXT NOT NULL DEFAULT 'POST_DISCOUNT' CHECK (earn_basis IN ('PRE_TAX','POST_TAX','POST_DISCOUNT')),
    is_active                       BOOLEAN NOT NULL DEFAULT true,
    is_deleted                      BOOLEAN NOT NULL DEFAULT false,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rih_customer_loyalty_profiles (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID NOT NULL REFERENCES ric_clients(id),
    company_id      UUID NOT NULL REFERENCES ric_companies(id),
    mobile_number   TEXT NOT NULL,
    customer_id     UUID REFERENCES rim_accounts(id),
    display_name    TEXT,
    points_balance  NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    is_deleted      BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_loyalty_profile_mobile UNIQUE (client_id, company_id, mobile_number)
);

CREATE TABLE IF NOT EXISTS ril_loyalty_ledger (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID NOT NULL REFERENCES ric_clients(id),
    company_id          UUID NOT NULL REFERENCES ric_companies(id),
    loyalty_profile_id  UUID NOT NULL REFERENCES rih_customer_loyalty_profiles(id),
    trans_type          TEXT NOT NULL CHECK (trans_type IN ('EARN','REDEEM','EXPIRE','RETURN_REVERSAL','BONUS','MANUAL_ADJUSTMENT','CANCEL_REVERSAL')),
    points_change       NUMERIC(18,4) NOT NULL,
    source_doc_type     TEXT,
    source_doc_no       TEXT,
    source_doc_date     DATE,
    reason              TEXT,
    created_by          UUID REFERENCES rim_users(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_loyalty_ledger_profile ON ril_loyalty_ledger (loyalty_profile_id);
CREATE INDEX IF NOT EXISTS idx_loyalty_ledger_source ON ril_loyalty_ledger (client_id, company_id, source_doc_type, source_doc_no);

-- rih_sales_invoices gets the link so earn/redeem can be traced per sale.
ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS loyalty_profile_id UUID REFERENCES rih_customer_loyalty_profiles(id);
ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS loyalty_points_redeemed NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE rih_sales_invoices ADD COLUMN IF NOT EXISTS loyalty_redeem_value_amount NUMERIC(18,4) NOT NULL DEFAULT 0;

DROP POLICY IF EXISTS "auth_rw_rim_loyalty_programs" ON rim_loyalty_programs;
CREATE POLICY "auth_rw_rim_loyalty_programs" ON rim_loyalty_programs
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rim_loyalty_programs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rim_loyalty_programs FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_loyalty_programs TO authenticated;

DROP POLICY IF EXISTS "auth_rw_rih_customer_loyalty_profiles" ON rih_customer_loyalty_profiles;
CREATE POLICY "auth_rw_rih_customer_loyalty_profiles" ON rih_customer_loyalty_profiles
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rih_customer_loyalty_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rih_customer_loyalty_profiles FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_customer_loyalty_profiles TO authenticated;

DROP POLICY IF EXISTS "auth_rw_ril_loyalty_ledger" ON ril_loyalty_ledger;
CREATE POLICY "auth_rw_ril_loyalty_ledger" ON ril_loyalty_ledger
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE ril_loyalty_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ril_loyalty_ledger FROM anon;
GRANT SELECT, INSERT ON ril_loyalty_ledger TO authenticated;

-- ============================================================================
-- fn_get_or_create_loyalty_profile — called by the New Sale screen the
-- moment a cashier types/confirms a mobile number. Idempotent: a repeat
-- customer resolves to their existing profile instead of creating a
-- duplicate (mobile_number is UNIQUE per company already).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_get_or_create_loyalty_profile(
    p_client_id     UUID,
    p_company_id    UUID,
    p_mobile_number TEXT,
    p_display_name  TEXT DEFAULT NULL
)
RETURNS TABLE (id UUID, mobile_number TEXT, display_name TEXT, points_balance NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id UUID;
BEGIN
    SELECT p.id INTO v_id FROM rih_customer_loyalty_profiles p
    WHERE p.client_id = p_client_id AND p.company_id = p_company_id
      AND p.mobile_number = trim(p_mobile_number);

    IF v_id IS NULL THEN
        INSERT INTO rih_customer_loyalty_profiles (client_id, company_id, mobile_number, display_name)
        VALUES (p_client_id, p_company_id, trim(p_mobile_number), nullif(trim(p_display_name), ''))
        RETURNING rih_customer_loyalty_profiles.id INTO v_id;
    ELSIF p_display_name IS NOT NULL AND trim(p_display_name) <> '' THEN
        UPDATE rih_customer_loyalty_profiles SET display_name = trim(p_display_name) WHERE rih_customer_loyalty_profiles.id = v_id AND display_name IS NULL;
    END IF;

    RETURN QUERY
    SELECT p.id, p.mobile_number, p.display_name, p.points_balance
    FROM rih_customer_loyalty_profiles p WHERE p.id = v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_get_or_create_loyalty_profile(UUID, UUID, TEXT, TEXT) TO authenticated;
