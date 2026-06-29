-- ============================================================
-- Migration 026: Product Master
-- ============================================================
-- Tables:
--   rim_products           → core product/item master (company-wide)
--   rim_product_uom        → UOM conversions + per-UOM barcodes
--   rim_product_location   → per-location stock + cost snapshot
--   rim_product_media      → multiple images / videos per product
--
-- Design decisions:
--   • No rim_uom — UOMs use rim_common_masters (type_key='UNIT', migration 022).
--   • item_size and item_color use rim_common_masters FKs
--     (type_key='ITEM_SIZE' and 'COLOR' respectively, already seeded in 022).
--   • brand_id already references rim_common_masters (type_key='BRAND').
--   • standard_cost / average_cost / last_purchase_cost on rim_products are in
--     the company's BASE currency (for financial books).
--   • cost_currency_id on rim_products = "Maintain Price In" currency —
--     the procurement reference currency (e.g. USD when books are in CDF/ZMW).
--   • rim_product_location stores:
--       current_stock       = quantity on hand (updated by inventory transactions)
--       cost_price          = cost in base currency (for journal/GL entries)
--       cost_price_specific = cost in cost_currency_id (procurement reference)
--   • tracking_type replaces separate is_batch_tracked + is_expiry_tracked:
--       NONE             → no tracking
--       BATCH            → batch/lot number per movement (spare parts, recall-risk)
--       SERIAL           → one serial number per unit (electronics, machinery)
--       BATCH_WITH_EXPIRY → batch + mandatory expiry date (food, pharma, FMCG)
--   • Behavioral flags (is_saleable, is_discountable etc.) use flags JSONB via
--     rim_product_flag_types (migration 024) — no hardcoded boolean columns.
--   • rim_product_location_price and fn_get_product_price deferred to Sales module.
-- ============================================================

-- ── Product master ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rim_products (
  -- Identity & codes
  id                    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id             UUID         NOT NULL REFERENCES ric_clients(id),
  company_id            UUID         NOT NULL REFERENCES ric_companies(id),
  product_code          TEXT         NOT NULL,
  barcode               TEXT,
  part_number           TEXT,
  product_name          TEXT         NOT NULL,
  short_name            TEXT,
  description           TEXT,

  -- Classification
  product_nature        TEXT         NOT NULL DEFAULT 'TRADING'
                        CHECK (product_nature IN
                          ('TRADING','FINISHED_GOOD','RAW_MATERIAL','PACKAGING','CONSUMABLE','SERVICE')),
  category_id           UUID         REFERENCES rim_item_categories(id),
  brand_id              UUID         REFERENCES rim_common_masters(id),   -- type_key='BRAND'
  item_size_id          UUID         REFERENCES rim_common_masters(id),   -- type_key='ITEM_SIZE'
  item_color_id         UUID         REFERENCES rim_common_masters(id),   -- type_key='COLOR'

  -- Base UOM (conversions + per-level barcodes in rim_product_uom)
  base_uom_id           UUID         REFERENCES rim_common_masters(id),   -- type_key='UNIT'

  -- Costing — all amounts in company base currency
  standard_cost         NUMERIC(18,4) NOT NULL DEFAULT 0,
  average_cost          NUMERIC(18,4) NOT NULL DEFAULT 0,
  last_purchase_cost    NUMERIC(18,4) NOT NULL DEFAULT 0,
  allowed_cost_variance NUMERIC(6,2)  NOT NULL DEFAULT 0,

  -- "Maintain Price In" — procurement reference currency (e.g. USD when books are in CDF/ZMW)
  -- NULL = use base currency for all costing
  cost_currency_id      UUID         REFERENCES rim_currencies(id),

  -- Tax
  sales_tax_group_id    UUID         REFERENCES rim_tax_groups(id),
  purchase_tax_group_id UUID         REFERENCES rim_tax_groups(id),
  hsn_sac_code          TEXT,

  -- Preferred supplier
  main_supplier_id      UUID         REFERENCES rim_accounts(id),
  lead_time_days        SMALLINT     NOT NULL DEFAULT 0,

  -- Physical attributes (measurement UOMs are fixed units: g/kg/ml/L/cm/mm)
  weight                NUMERIC(10,4),
  weight_uom            TEXT         CHECK (weight_uom IN ('g','kg','lb','oz') OR weight_uom IS NULL),
  volume                NUMERIC(10,4),
  volume_uom            TEXT         CHECK (volume_uom IN ('ml','L','fl_oz','cm3') OR volume_uom IS NULL),
  length                NUMERIC(10,4),
  width                 NUMERIC(10,4),
  height                NUMERIC(10,4),
  dimension_uom         TEXT         CHECK (dimension_uom IN ('mm','cm','inch','m') OR dimension_uom IS NULL),

  -- Tracking type
  tracking_type         TEXT         NOT NULL DEFAULT 'NONE'
                        CHECK (tracking_type IN ('NONE','BATCH','SERIAL','BATCH_WITH_EXPIRY')),

  -- Core system flags (dedicated columns — drive system / hardware logic)
  is_active             BOOLEAN      NOT NULL DEFAULT true,
  is_deleted            BOOLEAN      NOT NULL DEFAULT false,
  is_scalable           BOOLEAN      NOT NULL DEFAULT false,

  -- Business flags (dynamic — admin defines via rim_product_flag_types screen)
  -- Standard defaults (loaded via "Load Defaults" button):
  --   is_saleable, is_purchasable, is_pos_item, is_discountable,
  --   allow_negative_stock, is_consignment, is_transferable, is_intercompany
  flags                 JSONB        NOT NULL DEFAULT '{}',

  -- Misc
  sort_order            SMALLINT     NOT NULL DEFAULT 0,
  remarks               TEXT,

  -- Audit
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by            UUID         REFERENCES rim_users(id),
  updated_at            TIMESTAMPTZ,
  updated_by            UUID         REFERENCES rim_users(id),

  UNIQUE (client_id, company_id, product_code)
);

CREATE INDEX IF NOT EXISTS idx_products_tenant   ON rim_products (client_id, company_id);
CREATE INDEX IF NOT EXISTS idx_products_code     ON rim_products (client_id, company_id, product_code);
CREATE INDEX IF NOT EXISTS idx_products_barcode  ON rim_products (barcode) WHERE barcode IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_products_category ON rim_products (category_id);
CREATE INDEX IF NOT EXISTS idx_products_supplier ON rim_products (main_supplier_id);
CREATE INDEX IF NOT EXISTS idx_products_flags    ON rim_products USING GIN (flags);

-- ── UOM conversions + per-UOM barcodes ───────────────────────────────────────
-- One row per UOM level: Piece (base), Carton (12 pcs), Pallet (100 pcs).
-- Each level can have its own barcode — scanning a carton barcode auto-converts to units.
-- uom_id references rim_common_masters where type_key = 'UNIT'.
CREATE TABLE IF NOT EXISTS rim_product_uom (
  id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id         UUID         NOT NULL,
  company_id        UUID         NOT NULL,
  product_id        UUID         NOT NULL REFERENCES rim_products(id) ON DELETE CASCADE,
  uom_id            UUID         NOT NULL REFERENCES rim_common_masters(id),
  conversion_factor NUMERIC(18,6) NOT NULL DEFAULT 1 CHECK (conversion_factor > 0),
  barcode           TEXT,
  is_base_uom       BOOLEAN      NOT NULL DEFAULT false,
  is_purchase_uom   BOOLEAN      NOT NULL DEFAULT false,
  is_sales_uom      BOOLEAN      NOT NULL DEFAULT false,
  sort_order        SMALLINT     NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by        UUID         REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, product_id, uom_id)
);

CREATE INDEX IF NOT EXISTS idx_product_uom_product ON rim_product_uom (product_id);
CREATE INDEX IF NOT EXISTS idx_product_uom_barcode ON rim_product_uom (barcode) WHERE barcode IS NOT NULL;

-- ── Per-location stock + cost snapshot ───────────────────────────────────────
-- current_stock      → quantity on hand; updated by inventory transactions (GRN/issue/transfer)
-- cost_price         → cost in company base currency; used for GL/journal posting
-- cost_price_specific → cost in rim_products.cost_currency_id; procurement reference
--                       e.g. 7.50 USD when base cost is 15,000 CDF
--                       NULL when cost_currency_id is same as company base currency
CREATE TABLE IF NOT EXISTS rim_product_location (
  id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id            UUID         NOT NULL REFERENCES ric_clients(id),
  company_id           UUID         NOT NULL REFERENCES ric_companies(id),
  location_id          UUID         NOT NULL REFERENCES ric_locations(id),
  product_id           UUID         NOT NULL REFERENCES rim_products(id) ON DELETE CASCADE,
  current_stock        NUMERIC(18,4) NOT NULL DEFAULT 0,
  cost_price           NUMERIC(18,4) NOT NULL DEFAULT 0,
  cost_price_specific  NUMERIC(18,4),
  reorder_level        NUMERIC(18,4) NOT NULL DEFAULT 0,
  reorder_qty          NUMERIC(18,4) NOT NULL DEFAULT 0,
  min_stock_qty        NUMERIC(18,4) NOT NULL DEFAULT 0,
  max_stock_qty        NUMERIC(18,4) NOT NULL DEFAULT 0,
  bin_location         TEXT,
  is_active            BOOLEAN      NOT NULL DEFAULT true,
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by           UUID         REFERENCES rim_users(id),
  updated_at           TIMESTAMPTZ,
  updated_by           UUID         REFERENCES rim_users(id),
  UNIQUE (client_id, company_id, location_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_product_location_product ON rim_product_location (product_id);

-- ── Product media (multiple images / videos) ─────────────────────────────────
-- media_data = base64 for images (consistent with user photo pattern across the app)
-- media_url  = link for videos (too large for base64)
CREATE TABLE IF NOT EXISTS rim_product_media (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   UUID         NOT NULL,
  company_id  UUID         NOT NULL,
  product_id  UUID         NOT NULL REFERENCES rim_products(id) ON DELETE CASCADE,
  media_type  TEXT         NOT NULL CHECK (media_type IN ('IMAGE','VIDEO')),
  media_data  TEXT,
  media_url   TEXT,
  is_primary  BOOLEAN      NOT NULL DEFAULT false,
  sort_order  SMALLINT     NOT NULL DEFAULT 0,
  caption     TEXT,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by  UUID         REFERENCES rim_users(id)
);

CREATE INDEX IF NOT EXISTS idx_product_media_product ON rim_product_media (product_id);

-- ── RLS ───────────────────────────────────────────────────────────────────────
ALTER TABLE rim_products           ENABLE ROW LEVEL SECURITY;
ALTER TABLE rim_product_uom        ENABLE ROW LEVEL SECURITY;
ALTER TABLE rim_product_location   ENABLE ROW LEVEL SECURITY;
ALTER TABLE rim_product_media      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_rw_products"         ON rim_products;
DROP POLICY IF EXISTS "auth_rw_product_uom"      ON rim_product_uom;
DROP POLICY IF EXISTS "auth_rw_product_location" ON rim_product_location;
DROP POLICY IF EXISTS "auth_rw_product_media"    ON rim_product_media;

CREATE POLICY "auth_rw_products" ON rim_products
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid);

CREATE POLICY "auth_rw_product_uom" ON rim_product_uom
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid);

CREATE POLICY "auth_rw_product_location" ON rim_product_location
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid);

CREATE POLICY "auth_rw_product_media" ON rim_product_media
  FOR ALL TO authenticated
  USING     (client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid)
  WITH CHECK(client_id  = (current_setting('request.jwt.claims',true)::json->>'client_id')::uuid
         AND company_id = (current_setting('request.jwt.claims',true)::json->>'company_id')::uuid);

-- ── Permissions ───────────────────────────────────────────────────────────────
REVOKE ALL ON rim_products, rim_product_uom, rim_product_location, rim_product_media FROM anon;

GRANT SELECT, INSERT, UPDATE         ON rim_products         TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_product_uom      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_product_location TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON rim_product_media    TO authenticated;
