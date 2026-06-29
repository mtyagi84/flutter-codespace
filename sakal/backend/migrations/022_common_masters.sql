-- rim_common_master_types: global reference table, no client/company/location
-- Types are system-seeded and never created by end users.
-- type_key is the fixed enum constant Flutter code references.
CREATE TABLE rim_common_master_types (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  type_key   TEXT        NOT NULL UNIQUE,
  type_name  TEXT        NOT NULL,
  is_active  BOOLEAN     NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID        REFERENCES rim_users(id),
  updated_at TIMESTAMPTZ,
  updated_by UUID        REFERENCES rim_users(id)
);


-- rim_common_masters: client+company scoped lookup values per type.
-- No location_id — these are company-wide masters, same exception as rim_accounts.
CREATE TABLE rim_common_masters (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   UUID        NOT NULL REFERENCES ric_clients(id),
  company_id  UUID        NOT NULL REFERENCES ric_companies(id),
  type_id     UUID        NOT NULL REFERENCES rim_common_master_types(id),
  description TEXT        NOT NULL,
  short_name  TEXT,
  sort_order  INTEGER     NOT NULL DEFAULT 0,
  is_active   BOOLEAN     NOT NULL DEFAULT true,
  is_deleted  BOOLEAN     NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID        REFERENCES rim_users(id),
  updated_at  TIMESTAMPTZ,
  updated_by  UUID        REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, type_id, description)
);

-- Seed master types — fixed set, never changed via UI
INSERT INTO rim_common_master_types (type_key, type_name) VALUES
  ('BRAND',     'Brand'),
  ('UNIT',      'Unit'),
  ('ITEM_SIZE', 'Item Size'),
  ('COLOR',     'Color');

-- PostgREST access grants
-- App uses a custom fn_login (not Supabase Auth), so all requests run
-- under the anon role. Grant anon the same access as authenticated.
GRANT SELECT ON rim_common_master_types TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON rim_common_masters TO anon, authenticated;

-- RLS policies (only active if RLS is enabled on the table)
CREATE POLICY "read_types" ON rim_common_master_types
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY "read_masters" ON rim_common_masters
  FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "write_masters" ON rim_common_masters
  FOR ALL TO anon, authenticated USING (true);
