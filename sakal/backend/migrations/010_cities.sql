-- ============================================================
-- 010_cities.sql
-- rim_cities: per-company user-managed city list
-- No seed — users add cities they need via UI.
-- Used by hybrid autocomplete in address forms across the app.
-- ============================================================

CREATE TABLE IF NOT EXISTS rim_cities (
    id              uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
    client_id       uuid        NOT NULL REFERENCES ric_clients(id),
    company_id      uuid        NOT NULL REFERENCES ric_companies(id),
    country_code    text        NOT NULL,
    division_id     uuid        REFERENCES rim_divisions(id),  -- optional
    city_name       text        NOT NULL,
    is_active       boolean     NOT NULL DEFAULT true,
    is_deleted      boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    updated_by      uuid,

    UNIQUE (client_id, company_id, country_code, city_name)
);

CREATE INDEX idx_rim_cities_tenant   ON rim_cities (client_id, company_id);
CREATE INDEX idx_rim_cities_country  ON rim_cities (client_id, company_id, country_code);
CREATE INDEX idx_rim_cities_division ON rim_cities (division_id);
CREATE INDEX idx_rim_cities_name     ON rim_cities (client_id, company_id, city_name);

CREATE TRIGGER trg_rim_cities_updated_at
    BEFORE UPDATE ON rim_cities
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
