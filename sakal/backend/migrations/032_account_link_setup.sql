-- ============================================================
-- 032_account_link_setup.sql
-- Generic GL account-determination framework — replaces hardcoded
-- account columns on categories/products. Ported from a proven legacy
-- design (RIM_LEDGER_LINK_SETUP + RIM_STOCK_LEDGER_SETUP), split into
-- 4 tables so the admin setup screen doesn't need a fake anchor item.
--
-- Tables:
--   rim_account_link_types     → global seeded master: which account
--                                 "roles" exist (Sales Account, Stock
--                                 Account, Purchase Accrual, …)
--   rim_account_link_setup     → per company, per link type: the chosen
--                                 granularity (COMPANY/CATEGORY/LOCATION/ITEM)
--   rim_account_link_defaults  → the admin's actual key→account choices
--                                 (one row per category/location chosen,
--                                 or a single row for COMPANY)
--   rim_account_links          → lazy per-item cache, populated on first
--                                 resolution and reused after that
--
-- Design decisions:
--   • link_key_id on defaults/links is a generic UUID with NO fk — the
--     target table depends on link_type (category_id/location_id/
--     product_id). Deliberate: matches the legacy LINK_KEY column,
--     app/function validated, keeps one shape across all 4 levels.
--   • fn_resolve_account_link replicates the legacy FUN_STOCKACCOUNTS
--     algorithm: exact cache hit first; on miss, resolve from
--     rim_account_link_defaults per the configured granularity
--     (walking category ancestors for CATEGORY), cache the result into
--     rim_account_links, then return it. Item-wise defaults have no
--     further fallback — an unconfigured item resolves to NULL and the
--     caller (e.g. GRN posting) must fail loudly, never post to no account.
--   • Editing a default later does NOT retroactively update items
--     already cached — same behavior as the legacy system. Use
--     fn_clear_account_link_cache to force re-resolution when a default
--     changes.
-- ============================================================


-- ------------------------------------------------------------
-- rim_account_link_types
-- ------------------------------------------------------------
CREATE TABLE rim_account_link_types (
    id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    link_key    TEXT          NOT NULL,
    link_name   TEXT          NOT NULL,
    is_system   BOOLEAN       NOT NULL DEFAULT true,
    sort_order  SMALLINT      NOT NULL DEFAULT 0,
    is_active   BOOLEAN       NOT NULL DEFAULT true,
    is_deleted  BOOLEAN       NOT NULL DEFAULT false,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by  UUID          REFERENCES rim_users(id),
    updated_at  TIMESTAMPTZ,
    updated_by  UUID          REFERENCES rim_users(id),
    UNIQUE (link_key)
);

INSERT INTO rim_account_link_types (link_key, link_name, sort_order) VALUES
    ('SALES_ACCOUNT',           'Sales Account',                 10),
    ('COST_OF_SALES_ACCOUNT',   'Cost of Sales Account',         20),
    ('STOCK_ACCOUNT',           'Stock Account',                 30),
    ('PURCHASE_ACCRUAL_ACCOUNT','GRN Accrual (Purchase) Account',40),
    ('STOCK_ADJUSTMENT_ACCOUNT','Stock Adjustment Account',      50),
    ('ASSET_DEPRECIATION_ACCOUNT','Asset Depreciation Account',  60),
    ('SALES_DISCOUNT_ACCOUNT',  'Sales Discount Account',        70),
    ('STOCK_IN_TRANSIT_ACCOUNT','Stock in Transit Account',      80),
    ('EXCHANGE_GAIN_LOSS_ACCOUNT','Exchange Gain and Loss Account',90),
    ('PLANT_STOCK_RM_PM_ACCOUNT','Plant Stock Account (RM/PM)', 100),
    ('PLANT_STOCK_FG_ACCOUNT',  'Plant Stock Account (FG)',     110),
    ('STOCK_ACCOUNT_FG',        'Stock Account (FG)',           120),
    ('STOCK_CONSUMPTION_ACCOUNT','Stock Consumption Account',   130);

ALTER TABLE rim_account_link_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read_account_link_types" ON rim_account_link_types
    FOR SELECT TO authenticated USING (true);

REVOKE ALL ON rim_account_link_types FROM anon;
GRANT SELECT ON rim_account_link_types TO authenticated;


-- ------------------------------------------------------------
-- rim_account_link_setup
-- One row per (company, link type) — the chosen granularity.
-- No row = not configured at all for this company.
-- ------------------------------------------------------------
CREATE TABLE rim_account_link_setup (
    id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id     UUID          NOT NULL REFERENCES ric_clients(id),
    company_id    UUID          NOT NULL REFERENCES ric_companies(id),
    link_type_id  UUID          NOT NULL REFERENCES rim_account_link_types(id),
    link_type     TEXT          NOT NULL
                  CHECK (link_type IN ('COMPANY','CATEGORY','LOCATION','ITEM')),
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by    UUID          REFERENCES rim_users(id),
    updated_at    TIMESTAMPTZ,
    updated_by    UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, link_type_id)
);

ALTER TABLE rim_account_link_setup ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_account_link_setup" ON rim_account_link_setup
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_account_link_setup FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_account_link_setup TO authenticated;


-- ------------------------------------------------------------
-- rim_account_link_defaults
-- The admin's actual key→account choices. link_key_id is NULL for
-- COMPANY, a rim_item_categories.id for CATEGORY, a ric_locations.id
-- for LOCATION, a rim_products.id for ITEM. No fk on link_key_id —
-- polymorphic target, validated by the app / resolver function.
-- ------------------------------------------------------------
CREATE TABLE rim_account_link_defaults (
    id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id     UUID          NOT NULL REFERENCES ric_clients(id),
    company_id    UUID          NOT NULL REFERENCES ric_companies(id),
    link_type_id  UUID          NOT NULL REFERENCES rim_account_link_types(id),
    link_key_id   UUID,
    account_id    UUID          NOT NULL REFERENCES rim_accounts(id),
    is_active     BOOLEAN       NOT NULL DEFAULT true,
    is_deleted    BOOLEAN       NOT NULL DEFAULT false,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by    UUID          REFERENCES rim_users(id),
    updated_at    TIMESTAMPTZ,
    updated_by    UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, link_type_id, link_key_id)
);

-- Plug the gap standard UNIQUE leaves open: NULL link_key_id (COMPANY
-- level) is never treated as a duplicate by a normal unique constraint.
CREATE UNIQUE INDEX uq_account_link_defaults_company
    ON rim_account_link_defaults (client_id, company_id, link_type_id)
    WHERE link_key_id IS NULL;

CREATE INDEX idx_account_link_defaults_lookup
    ON rim_account_link_defaults (client_id, company_id, link_type_id, link_key_id)
    WHERE is_deleted = false;

ALTER TABLE rim_account_link_defaults ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_account_link_defaults" ON rim_account_link_defaults
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_account_link_defaults FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_account_link_defaults TO authenticated;


-- ------------------------------------------------------------
-- rim_account_links
-- Lazy per-item cache. Populated by fn_resolve_account_link on first
-- resolution for an item; every later transaction is a direct hit.
-- ------------------------------------------------------------
CREATE TABLE rim_account_links (
    id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id     UUID          NOT NULL REFERENCES ric_clients(id),
    company_id    UUID          NOT NULL REFERENCES ric_companies(id),
    link_type_id  UUID          NOT NULL REFERENCES rim_account_link_types(id),
    link_type     TEXT          NOT NULL
                  CHECK (link_type IN ('COMPANY','CATEGORY','LOCATION','ITEM')),
    link_key_id   UUID,
    product_id    UUID          NOT NULL REFERENCES rim_products(id),
    account_id    UUID          NOT NULL REFERENCES rim_accounts(id),
    is_deleted    BOOLEAN       NOT NULL DEFAULT false,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by    UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, link_type_id, product_id)
);

CREATE INDEX idx_account_links_lookup
    ON rim_account_links (client_id, company_id, link_type_id, product_id)
    WHERE is_deleted = false;

ALTER TABLE rim_account_links ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_account_links" ON rim_account_links
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_account_links FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_account_links TO authenticated;


-- ============================================================
-- PG FUNCTIONS
-- ============================================================


-- ------------------------------------------------------------
-- fn_resolve_account_link
-- Returns the GL account for (product, link type) at the given
-- location. Exact cache hit first; on miss, resolves from
-- rim_account_link_defaults per the company's configured granularity,
-- caches the result, returns it. Returns NULL if nothing is
-- configured — callers must treat NULL as a hard error, never post
-- to no account.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_resolve_account_link(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID,
    p_product_id  UUID,
    p_link_key    TEXT
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_link_type_id UUID;
    v_link_type    TEXT;
    v_account_id   UUID;
    v_link_key_id  UUID;
BEGIN
    SELECT id INTO v_link_type_id
    FROM rim_account_link_types
    WHERE link_key = p_link_key AND is_active = true AND is_deleted = false;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- 1) exact cache hit
    SELECT account_id INTO v_account_id
    FROM rim_account_links
    WHERE client_id    = p_client_id
      AND company_id   = p_company_id
      AND link_type_id = v_link_type_id
      AND product_id   = p_product_id
      AND is_deleted   = false;

    IF FOUND THEN
        RETURN v_account_id;
    END IF;

    -- 2) cache miss: what granularity is configured for this link type?
    SELECT link_type INTO v_link_type
    FROM rim_account_link_setup
    WHERE client_id    = p_client_id
      AND company_id   = p_company_id
      AND link_type_id = v_link_type_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF v_link_type = 'COMPANY' THEN
        v_link_key_id := NULL;
        SELECT account_id INTO v_account_id
        FROM rim_account_link_defaults
        WHERE client_id    = p_client_id AND company_id = p_company_id
          AND link_type_id = v_link_type_id AND link_key_id IS NULL
          AND is_deleted   = false;

    ELSIF v_link_type = 'LOCATION' THEN
        v_link_key_id := p_location_id;
        SELECT account_id INTO v_account_id
        FROM rim_account_link_defaults
        WHERE client_id    = p_client_id AND company_id = p_company_id
          AND link_type_id = v_link_type_id AND link_key_id = p_location_id
          AND is_deleted   = false;

    ELSIF v_link_type = 'CATEGORY' THEN
        -- Walk this product's category up to the root; nearest
        -- configured ancestor (including the item's own category) wins.
        WITH RECURSIVE ancestors AS (
            SELECT c.id, c.parent_id, 0 AS depth
            FROM   rim_item_categories c
            JOIN   rim_products p ON p.category_id = c.id
            WHERE  p.id = p_product_id
            UNION ALL
            SELECT c.id, c.parent_id, a.depth + 1
            FROM   rim_item_categories c
            JOIN   ancestors a ON c.id = a.parent_id
        )
        SELECT d.account_id, a.id INTO v_account_id, v_link_key_id
        FROM   ancestors a
        JOIN   rim_account_link_defaults d
               ON d.client_id    = p_client_id AND d.company_id = p_company_id
              AND d.link_type_id = v_link_type_id AND d.link_key_id = a.id
              AND d.is_deleted   = false
        ORDER BY a.depth
        LIMIT 1;

    ELSIF v_link_type = 'ITEM' THEN
        v_link_key_id := p_product_id;
        SELECT account_id INTO v_account_id
        FROM rim_account_link_defaults
        WHERE client_id    = p_client_id AND company_id = p_company_id
          AND link_type_id = v_link_type_id AND link_key_id = p_product_id
          AND is_deleted   = false;
    END IF;

    IF v_account_id IS NOT NULL THEN
        INSERT INTO rim_account_links (
            client_id, company_id, link_type_id, link_type, link_key_id,
            product_id, account_id, created_by
        ) VALUES (
            p_client_id, p_company_id, v_link_type_id, v_link_type, v_link_key_id,
            p_product_id, v_account_id, NULL
        )
        ON CONFLICT (client_id, company_id, link_type_id, product_id) DO NOTHING;
    END IF;

    RETURN v_account_id;
END;
$$;


-- ------------------------------------------------------------
-- fn_clear_account_link_cache
-- Deletes cached rows so affected items re-resolve (picking up a
-- changed default) on their next transaction. Editing
-- rim_account_link_defaults does NOT auto-cascade — call this after
-- changing a default if you want existing items to pick it up sooner.
-- p_link_key_id: pass the same category/location id whose default
-- changed to clear only affected items; NULL clears the whole link
-- type for the company (COMPANY-level change, or a full reset).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_clear_account_link_cache(
    p_client_id   UUID,
    p_company_id  UUID,
    p_link_key    TEXT,
    p_link_key_id UUID DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_link_type_id UUID;
    v_count        INTEGER;
BEGIN
    SELECT id INTO v_link_type_id
    FROM rim_account_link_types
    WHERE link_key = p_link_key;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    DELETE FROM rim_account_links
    WHERE client_id    = p_client_id
      AND company_id   = p_company_id
      AND link_type_id = v_link_type_id
      AND (p_link_key_id IS NULL OR link_key_id = p_link_key_id);

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_resolve_account_link(UUID, UUID, UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_clear_account_link_cache(UUID, UUID, TEXT, UUID)   TO authenticated;
