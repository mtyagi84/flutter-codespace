-- ============================================================
-- 028_location_groups.sql
-- Inter-location model (SIMPLE / INTER_ENTITY) + Location Groups
-- + Location address/group fields + rim_accounts inter-entity link
-- See memory: project-location-groups-design for full architecture.
-- ============================================================


-- ------------------------------------------------------------
-- ric_companies.inter_location_model
-- Set once at company setup — never change after transactions exist.
-- SIMPLE       — one P&L + Balance Sheet for the whole company.
-- INTER_ENTITY — each location group is an independent entity.
-- ------------------------------------------------------------
ALTER TABLE ric_companies
    ADD COLUMN inter_location_model TEXT NOT NULL DEFAULT 'SIMPLE'
        CHECK (inter_location_model IN ('SIMPLE', 'INTER_ENTITY'));


-- ------------------------------------------------------------
-- ric_location_groups
-- Groups locations into accountable entities.
-- customer_account_id / supplier_account_id only used in INTER_ENTITY mode.
-- ------------------------------------------------------------
CREATE TABLE ric_location_groups (
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            UUID        NOT NULL REFERENCES ric_clients(id),
    company_id           UUID        NOT NULL REFERENCES ric_companies(id),
    group_code           TEXT        NOT NULL,
    group_name           TEXT        NOT NULL,
    responsible_user_id  UUID        REFERENCES rim_users(id),
    customer_account_id  UUID        REFERENCES rim_accounts(id),
    supplier_account_id  UUID        REFERENCES rim_accounts(id),
    is_active            BOOLEAN     NOT NULL DEFAULT true,
    is_deleted           BOOLEAN     NOT NULL DEFAULT false,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_at           TIMESTAMPTZ,
    updated_by           UUID,
    UNIQUE (client_id, company_id, group_code)
);

CREATE INDEX idx_ric_location_groups_company ON ric_location_groups (client_id, company_id);

CREATE TRIGGER trg_ric_location_groups_updated_at
    BEFORE UPDATE ON ric_location_groups
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE ric_location_groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "dev_allow_all_location_groups" ON ric_location_groups FOR ALL USING (true) WITH CHECK (true);


-- ------------------------------------------------------------
-- ric_locations — group linkage, address, operational flags
-- ------------------------------------------------------------
ALTER TABLE ric_locations
    ADD COLUMN group_id                  UUID REFERENCES ric_location_groups(id),
    ADD COLUMN responsible_user_id       UUID REFERENCES rim_users(id),
    ADD COLUMN address_line1             TEXT,
    ADD COLUMN address_line2             TEXT,
    ADD COLUMN city_id                   UUID REFERENCES rim_cities(id),
    ADD COLUMN postal_code               TEXT,
    ADD COLUMN email                     TEXT,
    ADD COLUMN tax_reg_number            TEXT,
    ADD COLUMN is_negative_stock_allowed BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX idx_ric_locations_group ON ric_locations (group_id);


-- ------------------------------------------------------------
-- rim_accounts.inter_entity_group_id
-- NULL = regular external account. NOT NULL = belongs to a location group
-- (used as that group's customer/supplier account in other groups' books).
-- ------------------------------------------------------------
ALTER TABLE rim_accounts
    ADD COLUMN inter_entity_group_id UUID REFERENCES ric_location_groups(id);

CREATE INDEX idx_rim_accounts_inter_entity_group ON rim_accounts (inter_entity_group_id);
