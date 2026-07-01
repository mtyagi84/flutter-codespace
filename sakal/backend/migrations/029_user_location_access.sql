-- ============================================================
-- 029_user_location_access.sql
-- Which locations a user is restricted to, and their default.
-- Add/edit/view/approve rights come from ric_master_menus screen
-- permissions, not from this table — this table only scopes locations.
-- See memory: project-location-groups-design.
-- ============================================================

CREATE TABLE ric_user_location_access (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID        NOT NULL REFERENCES ric_clients(id),
    company_id      UUID        NOT NULL REFERENCES ric_companies(id),
    user_id         UUID        NOT NULL REFERENCES rim_users(id),
    location_id     UUID        NOT NULL REFERENCES ric_locations(id),
    is_default      BOOLEAN     NOT NULL DEFAULT false,
    is_active       BOOLEAN     NOT NULL DEFAULT true,
    is_deleted      BOOLEAN     NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID,
    updated_at      TIMESTAMPTZ,
    updated_by      UUID,
    UNIQUE (user_id, location_id)
);

CREATE INDEX idx_ric_user_location_access_user     ON ric_user_location_access (user_id);
CREATE INDEX idx_ric_user_location_access_location ON ric_user_location_access (location_id);

-- Only one default location per user.
CREATE UNIQUE INDEX uq_ric_user_location_access_default
    ON ric_user_location_access (user_id)
    WHERE is_default = true AND is_deleted = false;

CREATE TRIGGER trg_ric_user_location_access_updated_at
    BEFORE UPDATE ON ric_user_location_access
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE ric_user_location_access ENABLE ROW LEVEL SECURITY;
CREATE POLICY "dev_allow_all_user_location_access" ON ric_user_location_access FOR ALL USING (true) WITH CHECK (true);
