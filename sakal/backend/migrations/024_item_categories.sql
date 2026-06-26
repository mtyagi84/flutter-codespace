-- ============================================================
-- Migration 024: Item Category Hierarchy
-- ============================================================
-- Three tables:
--   rim_category_levels    → admin configures level count + labels (1-4)
--   rim_product_flag_types → admin defines boolean flags (dynamic, no ALTER needed)
--   rim_item_categories    → the actual category tree (self-referential, flags JSONB)
-- One function:
--   fn_category_subtree    → expands category_id to all descendants (used in reports)
--
-- Flag inheritance rules:
--   Creating child   → pre-fill flags from parent (app logic)
--   Editing parent   → prompt user: cascade to sub-categories? (app logic)
--   Transaction pick → filter: WHERE flags @> '{"is_saleable":true}'  (GIN index)
--
-- Adding a new flag type: INSERT one row into rim_product_flag_types.
-- No ALTER TABLE, no migration needed.
-- ============================================================

-- ── Level configuration ───────────────────────────────────────────────────────
CREATE TABLE rim_category_levels (
  id           UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    UUID      NOT NULL REFERENCES ric_clients(id),
  company_id   UUID      NOT NULL REFERENCES ric_companies(id),
  level_no     SMALLINT  NOT NULL CHECK (level_no BETWEEN 1 AND 4),
  level_label  TEXT      NOT NULL,
  is_mandatory BOOLEAN   NOT NULL DEFAULT false,
  is_active    BOOLEAN   NOT NULL DEFAULT true,
  sort_order   SMALLINT  NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID      REFERENCES rim_users(id),
  updated_at   TIMESTAMPTZ,
  updated_by   UUID      REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, level_no)
);

-- ── Product flag type definitions ────────────────────────────────────────────
-- Each row defines one boolean flag that appears on categories + products.
-- flag_key is the JSONB key used everywhere — keep it stable once used in code.
-- Standard flags are loaded via "Load Defaults" button on the setup screen.
CREATE TABLE rim_product_flag_types (
  id            UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID      NOT NULL REFERENCES ric_clients(id),
  company_id    UUID      NOT NULL REFERENCES ric_companies(id),
  flag_key      TEXT      NOT NULL,
  flag_label    TEXT      NOT NULL,
  default_value BOOLEAN   NOT NULL DEFAULT true,
  description   TEXT,
  sort_order    SMALLINT  NOT NULL DEFAULT 0,
  is_active     BOOLEAN   NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    UUID      REFERENCES rim_users(id),
  updated_at    TIMESTAMPTZ,
  updated_by    UUID      REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, flag_key)
);

-- ── Category tree ─────────────────────────────────────────────────────────────
-- flags JSONB stores all boolean flag values e.g. {"is_saleable": true, "is_purchasable": false}
-- No fixed boolean columns — flags are fully dynamic via rim_product_flag_types.
CREATE TABLE rim_item_categories (
  id             UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id      UUID      NOT NULL REFERENCES ric_clients(id),
  company_id     UUID      NOT NULL REFERENCES ric_companies(id),
  parent_id      UUID      REFERENCES rim_item_categories(id),
  level_no       SMALLINT  NOT NULL CHECK (level_no BETWEEN 1 AND 4),
  category_name  TEXT      NOT NULL,
  category_short TEXT,
  flags          JSONB     NOT NULL DEFAULT '{}',
  sort_order     INTEGER   NOT NULL DEFAULT 0,
  is_active      BOOLEAN   NOT NULL DEFAULT true,
  is_deleted     BOOLEAN   NOT NULL DEFAULT false,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     UUID      REFERENCES rim_users(id),
  updated_at     TIMESTAMPTZ,
  updated_by     UUID      REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, parent_id, category_name)
);

CREATE INDEX idx_item_categories_parent ON rim_item_categories (parent_id);
CREATE INDEX idx_item_categories_tenant ON rim_item_categories (client_id, company_id, level_no);
CREATE INDEX idx_item_categories_flags  ON rim_item_categories USING GIN (flags);

-- ── Recursive subtree expansion ──────────────────────────────────────────────
-- Returns the given category_id PLUS all its descendants.
-- Report usage: WHERE (p_cat IS NULL OR category_id IN (SELECT id FROM fn_category_subtree(p_cat)))
-- Cascade usage: UPDATE rim_item_categories SET flags = ? WHERE id IN (SELECT id FROM fn_category_subtree(?))
CREATE OR REPLACE FUNCTION fn_category_subtree(p_category_id uuid)
RETURNS TABLE (id uuid) LANGUAGE sql STABLE AS $$
  WITH RECURSIVE tree AS (
    SELECT id FROM rim_item_categories WHERE id = p_category_id
    UNION ALL
    SELECT c.id FROM rim_item_categories c
    JOIN  tree t ON c.parent_id = t.id
  )
  SELECT id FROM tree;
$$;

-- ── RLS ───────────────────────────────────────────────────────────────────────
ALTER TABLE rim_category_levels    ENABLE ROW LEVEL SECURITY;
ALTER TABLE rim_product_flag_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE rim_item_categories    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth_rw_category_levels" ON rim_category_levels
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

CREATE POLICY "auth_rw_product_flag_types" ON rim_product_flag_types
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

CREATE POLICY "auth_rw_item_categories" ON rim_item_categories
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_category_levels    FROM anon;
REVOKE ALL ON rim_product_flag_types FROM anon;
REVOKE ALL ON rim_item_categories    FROM anon;

GRANT SELECT, INSERT, UPDATE ON rim_category_levels    TO authenticated;
GRANT SELECT, INSERT, UPDATE ON rim_product_flag_types TO authenticated;
GRANT SELECT, INSERT, UPDATE ON rim_item_categories    TO authenticated;
GRANT EXECUTE ON FUNCTION fn_category_subtree(uuid)   TO authenticated;
