-- ============================================================
-- Migration 024: Item Category Configuration + Master
-- ============================================================
-- Two tables:
--   rim_category_levels   → admin configures labels & count (1-4 levels)
--   rim_item_categories   → the actual category tree (self-referential)
-- One function:
--   fn_category_subtree   → expands a category_id to all descendants
--                           Used by ALL reports with category filter
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

-- ── Category tree (self-referential) ─────────────────────────────────────────
CREATE TABLE rim_item_categories (
  id             UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id      UUID      NOT NULL REFERENCES ric_clients(id),
  company_id     UUID      NOT NULL REFERENCES ric_companies(id),
  parent_id      UUID      REFERENCES rim_item_categories(id),
  level_no       SMALLINT  NOT NULL CHECK (level_no BETWEEN 1 AND 4),
  category_name  TEXT      NOT NULL,
  category_short TEXT,
  sort_order     INTEGER   NOT NULL DEFAULT 0,
  is_active      BOOLEAN   NOT NULL DEFAULT true,
  is_deleted     BOOLEAN   NOT NULL DEFAULT false,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     UUID      REFERENCES rim_users(id),
  updated_at     TIMESTAMPTZ,
  updated_by     UUID      REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, parent_id, category_name)
);

CREATE INDEX idx_item_categories_parent   ON rim_item_categories (parent_id);
CREATE INDEX idx_item_categories_tenant   ON rim_item_categories (client_id, company_id, level_no);

-- ── Recursive subtree expansion ──────────────────────────────────────────────
-- Returns the given category_id plus ALL its descendants.
-- Used in reports: WHERE category_id IN (SELECT id FROM fn_category_subtree(?))
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
ALTER TABLE rim_category_levels  ENABLE ROW LEVEL SECURITY;
ALTER TABLE rim_item_categories  ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth_rw_category_levels" ON rim_category_levels
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

CREATE POLICY "auth_rw_item_categories" ON rim_item_categories
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_category_levels FROM anon;
REVOKE ALL ON rim_item_categories FROM anon;
GRANT SELECT, INSERT, UPDATE        ON rim_category_levels TO authenticated;
GRANT SELECT, INSERT, UPDATE        ON rim_item_categories TO authenticated;
GRANT EXECUTE ON FUNCTION fn_category_subtree(uuid) TO authenticated;
