-- ============================================================
-- Migration 025: Tax Master (World-Class Design)
-- ============================================================
-- Architecture follows Odoo's proven multi-country tax model:
--
--   rim_tax_types            → Global vocabulary (VAT/GST/WHT/EXCISE…)
--   rim_taxes                → Company-configured named taxes + GL accounts
--   rim_tax_compound_sources → Sources for COMPOUND-type taxes (e.g. India Cess)
--   rim_tax_rates            → Date-effective rates per tax (budget-safe)
--   rim_tax_groups           → Bundles applied together on a transaction line
--   rim_tax_group_members    → Which taxes belong to each group
--
-- fn_get_active_tax_rate     → Returns rate% for a tax on a given date
-- fn_replace_group_members   → Atomic replace of group membership
--
-- Transaction lines will carry only tax_group_id.
-- ZERO vs EXEMPT: both 0% — ZERO is recoverable, EXEMPT is not.
-- ============================================================

-- ── 1. rim_tax_types (global, no client/company) ─────────────────────────────

CREATE TABLE IF NOT EXISTS rim_tax_types (
  id             UUID     PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_type_code  TEXT     NOT NULL UNIQUE,
  type_name      TEXT     NOT NULL,
  is_withholding BOOLEAN  NOT NULL DEFAULT false,
  sort_order     SMALLINT NOT NULL DEFAULT 0,
  is_active      BOOLEAN  NOT NULL DEFAULT true
);

INSERT INTO rim_tax_types (tax_type_code, type_name, is_withholding, sort_order)
VALUES
  ('VAT',         'Value Added Tax',       false, 1),
  ('GST',         'Goods & Services Tax',  false, 2),
  ('WITHHOLDING', 'Withholding Tax',       true,  3),
  ('EXCISE',      'Excise Duty',           false, 4),
  ('CUSTOMS',     'Customs Duty',          false, 5),
  ('TURNOVER',    'Turnover Tax',          false, 6),
  ('SERVICE_TAX', 'Service Tax',           false, 7)
ON CONFLICT (tax_type_code) DO NOTHING;

-- Read-only for everyone; no tenant filter needed
ALTER TABLE rim_tax_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_tax_types" ON rim_tax_types;
CREATE POLICY "read_tax_types" ON rim_tax_types
  FOR SELECT TO authenticated, anon USING (true);

GRANT SELECT ON rim_tax_types TO authenticated, anon;

-- ── 2. rim_taxes (company-level tax definitions) ─────────────────────────────

CREATE TABLE IF NOT EXISTS rim_taxes (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id             UUID        NOT NULL REFERENCES ric_clients(id),
  company_id            UUID        NOT NULL REFERENCES ric_companies(id),
  tax_code              TEXT        NOT NULL,
  tax_name              TEXT        NOT NULL,
  tax_type_code         TEXT        NOT NULL REFERENCES rim_tax_types(tax_type_code),
  applicable_on         TEXT        NOT NULL DEFAULT 'BOTH'
                        CHECK (applicable_on IN ('SALES','PURCHASE','BOTH')),
  calculation_type      TEXT        NOT NULL DEFAULT 'PERCENTAGE'
                        CHECK (calculation_type IN ('PERCENTAGE','FIXED_AMOUNT','COMPOUND')),
  is_price_inclusive    BOOLEAN     NOT NULL DEFAULT false,
  is_reverse_charge     BOOLEAN     NOT NULL DEFAULT false,
  -- GL accounts (nullable — may be linked after COA is set up)
  gl_output_account_id  UUID        REFERENCES rim_accounts(id),
  gl_input_account_id   UUID        REFERENCES rim_accounts(id),
  gl_expense_account_id UUID        REFERENCES rim_accounts(id),
  sort_order            SMALLINT    NOT NULL DEFAULT 0,
  is_active             BOOLEAN     NOT NULL DEFAULT true,
  is_deleted            BOOLEAN     NOT NULL DEFAULT false,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by            UUID        REFERENCES rim_users(id),
  updated_at            TIMESTAMPTZ,
  updated_by            UUID        REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, tax_code)
);

CREATE INDEX IF NOT EXISTS idx_rim_taxes_tenant ON rim_taxes (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_rim_taxes_type   ON rim_taxes (client_id, company_id, tax_type_code);

ALTER TABLE rim_taxes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_taxes" ON rim_taxes;
CREATE POLICY "auth_rw_taxes" ON rim_taxes
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_taxes FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_taxes TO authenticated;

-- ── 3. rim_tax_compound_sources (junction for COMPOUND-type taxes) ─────────────
-- Used only when calculation_type = 'COMPOUND' (e.g. India Health & Education Cess
-- which is 4% of CGST+SGST combined). Most deployments will have zero rows here.

CREATE TABLE IF NOT EXISTS rim_tax_compound_sources (
  id              UUID     PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id       UUID     NOT NULL REFERENCES ric_clients(id),
  company_id      UUID     NOT NULL REFERENCES ric_companies(id),
  compound_tax_id UUID     NOT NULL REFERENCES rim_taxes(id),
  source_tax_id   UUID     NOT NULL REFERENCES rim_taxes(id),
  UNIQUE (client_id, company_id, compound_tax_id, source_tax_id)
);

CREATE INDEX IF NOT EXISTS idx_rim_tcs_compound ON rim_tax_compound_sources (compound_tax_id);
CREATE INDEX IF NOT EXISTS idx_rim_tcs_source   ON rim_tax_compound_sources (source_tax_id);

ALTER TABLE rim_tax_compound_sources ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_tax_compound_sources" ON rim_tax_compound_sources;
CREATE POLICY "auth_rw_tax_compound_sources" ON rim_tax_compound_sources
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_tax_compound_sources FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_tax_compound_sources TO authenticated;

-- ── 4. rim_tax_rates (date-effective rates) ───────────────────────────────────
-- ZERO and EXEMPT both give 0% but differ:
--   ZERO   = zero-rated, input tax IS recoverable (exports, basic food)
--   EXEMPT = exempt, input tax NOT recoverable (rent, medical)
-- Use rate_label to distinguish in reports.

CREATE TABLE IF NOT EXISTS rim_tax_rates (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id      UUID         NOT NULL REFERENCES ric_clients(id),
  company_id     UUID         NOT NULL REFERENCES ric_companies(id),
  tax_id         UUID         NOT NULL REFERENCES rim_taxes(id),
  rate_label     TEXT         NOT NULL DEFAULT 'STANDARD'
                 CHECK (rate_label IN ('STANDARD','REDUCED','ZERO','EXEMPT','SPECIAL')),
  rate           NUMERIC(8,4) NOT NULL DEFAULT 0
                 CONSTRAINT chk_tax_rate_nonneg CHECK (rate >= 0),
  effective_from DATE         NOT NULL,
  effective_to   DATE,
  threshold_min  NUMERIC(18,4),
  threshold_max  NUMERIC(18,4),
  description    TEXT,
  is_active      BOOLEAN      NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by     UUID         REFERENCES rim_users(id),
  updated_at     TIMESTAMPTZ,
  updated_by     UUID         REFERENCES rim_users(id),
  CONSTRAINT chk_tax_rate_dates CHECK (effective_to IS NULL OR effective_to > effective_from),
  UNIQUE (client_id, company_id, tax_id, rate_label, effective_from)
);

CREATE INDEX IF NOT EXISTS idx_rim_tax_rates_tax    ON rim_tax_rates (tax_id, rate_label, effective_from DESC);
CREATE INDEX IF NOT EXISTS idx_rim_tax_rates_tenant ON rim_tax_rates (client_id, company_id, tax_id);

ALTER TABLE rim_tax_rates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_tax_rates" ON rim_tax_rates;
CREATE POLICY "auth_rw_tax_rates" ON rim_tax_rates
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_tax_rates FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_tax_rates TO authenticated;

-- ── 5. rim_tax_groups (bundles for transaction lines) ────────────────────────

CREATE TABLE IF NOT EXISTS rim_tax_groups (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID        NOT NULL REFERENCES ric_clients(id),
  company_id    UUID        NOT NULL REFERENCES ric_companies(id),
  group_code    TEXT        NOT NULL,
  group_name    TEXT        NOT NULL,
  applicable_on TEXT        NOT NULL DEFAULT 'BOTH'
                CHECK (applicable_on IN ('SALES','PURCHASE','BOTH')),
  description   TEXT,
  sort_order    SMALLINT    NOT NULL DEFAULT 0,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  is_deleted    BOOLEAN     NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    UUID        REFERENCES rim_users(id),
  updated_at    TIMESTAMPTZ,
  updated_by    UUID        REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, group_code)
);

CREATE INDEX IF NOT EXISTS idx_rim_tax_groups_tenant ON rim_tax_groups (client_id, company_id, is_deleted);

ALTER TABLE rim_tax_groups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_tax_groups" ON rim_tax_groups;
CREATE POLICY "auth_rw_tax_groups" ON rim_tax_groups
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_tax_groups FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_tax_groups TO authenticated;

-- ── 6. rim_tax_group_members (junction) ─────────────────────────────────────
-- sequence_no controls calculation order: compound taxes must have higher seq
-- than the source taxes they apply on top of.

CREATE TABLE IF NOT EXISTS rim_tax_group_members (
  id           UUID     PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    UUID     NOT NULL REFERENCES ric_clients(id),
  company_id   UUID     NOT NULL REFERENCES ric_companies(id),
  tax_group_id UUID     NOT NULL REFERENCES rim_tax_groups(id) ON DELETE CASCADE,
  tax_id       UUID     NOT NULL REFERENCES rim_taxes(id),
  sequence_no  SMALLINT NOT NULL DEFAULT 1,
  UNIQUE (client_id, company_id, tax_group_id, tax_id),
  UNIQUE (client_id, company_id, tax_group_id, sequence_no)
);

CREATE INDEX IF NOT EXISTS idx_rim_tgm_group ON rim_tax_group_members (tax_group_id, sequence_no);
CREATE INDEX IF NOT EXISTS idx_rim_tgm_tax   ON rim_tax_group_members (tax_id);

ALTER TABLE rim_tax_group_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_tax_group_members" ON rim_tax_group_members;
CREATE POLICY "auth_rw_tax_group_members" ON rim_tax_group_members
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_tax_group_members FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_tax_group_members TO authenticated;

-- ── 7. fn_get_active_tax_rate ─────────────────────────────────────────────────
-- Returns NULL (not 0) when no rate found — callers must handle NULL.
-- SECURITY INVOKER keeps RLS on rim_tax_rates enforced.

CREATE OR REPLACE FUNCTION fn_get_active_tax_rate(
  p_tax_id     UUID,
  p_trans_date DATE,
  p_rate_label TEXT DEFAULT 'STANDARD'
) RETURNS NUMERIC AS $$
  SELECT rate
  FROM   rim_tax_rates
  WHERE  tax_id        = p_tax_id
    AND  rate_label    = p_rate_label
    AND  effective_from <= p_trans_date
    AND  (effective_to IS NULL OR effective_to >= p_trans_date)
    AND  is_active     = true
  ORDER BY effective_from DESC
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY INVOKER;

GRANT EXECUTE ON FUNCTION fn_get_active_tax_rate(UUID, DATE, TEXT) TO authenticated;

-- ── 8. fn_replace_group_members ──────────────────────────────────────────────
-- Atomic delete+reinsert of all members for a group.
-- Called via /rpc/fn_replace_group_members from Flutter.
-- p_members JSONB: [{"tax_id":"uuid","sequence_no":1}, ...]

CREATE OR REPLACE FUNCTION fn_replace_group_members(
  p_group_id   UUID,
  p_client_id  UUID,
  p_company_id UUID,
  p_members    JSONB,
  p_user_id    UUID
) RETURNS void AS $$
BEGIN
  DELETE FROM rim_tax_group_members
  WHERE  tax_group_id = p_group_id
    AND  client_id    = p_client_id
    AND  company_id   = p_company_id;

  IF jsonb_array_length(p_members) > 0 THEN
    INSERT INTO rim_tax_group_members
      (id, client_id, company_id, tax_group_id, tax_id, sequence_no)
    SELECT
      gen_random_uuid(),
      p_client_id,
      p_company_id,
      p_group_id,
      (elem->>'tax_id')::uuid,
      (elem->>'sequence_no')::smallint
    FROM jsonb_array_elements(p_members) AS elem;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;

GRANT EXECUTE ON FUNCTION fn_replace_group_members(UUID, UUID, UUID, JSONB, UUID) TO authenticated;
