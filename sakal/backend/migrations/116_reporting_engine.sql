-- ============================================================
-- Migration 116: Reusable Reporting Engine — registry schema (MVP1)
-- ============================================================
-- Full design: sakal/docs/reporting_engine_design.md — read that first.
-- This migration only creates the DB-driven REGISTRY (what a report looks
-- like: its columns, filters, grouping levels). It inserts zero report
-- rows — actual report definitions (Tabular pilot, Grouped pilot, Matrix
-- pilot, and every future module report) are seeded by their OWN later
-- migrations, same as any other master/config data in this schema.
--
-- Deliberately NOT a generic dynamic-SQL engine: every report's actual
-- data still comes from a normal, typed, per-report VIEW or STABLE
-- function (source_object / summary_source_object / totals_source_object
-- below are just NAMES of those objects) — RLS is inherited for free from
-- the underlying base tables via invoker-rights execution, exactly like
-- every other view/function in this schema. See the design doc's
-- "Backend design" section for the full reasoning.
--
-- client_id/company_id on every table here (including the child tables)
-- matches this schema's own universal multi-tenant convention — confirmed
-- against rid_grn_lines and every other table before writing this file;
-- an earlier draft of the design doc assumed these could be global/
-- system-level tables with no client_id, which would have been the first
-- table in 115+ migrations without one. Corrected here, not in the doc's
-- text (the doc's SQL comments describe intent; this file is what ships).
--
-- Objects:
--   ric_report_definitions  -> table (one row per report)
--   ric_report_columns      -> table (one row per column)
--   ric_report_filters      -> table (one row per filter control)
--   ric_report_group_levels -> table (one row per grouping level, optional)
-- ============================================================

-- ------------------------------------------------------------
-- ric_report_definitions
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ric_report_definitions (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    report_key            TEXT          NOT NULL,
    report_name           TEXT          NOT NULL,
    report_type           TEXT          NOT NULL
                          CHECK (report_type IN ('TABULAR', 'MATRIX', 'HIERARCHICAL')),
                          -- HIERARCHICAL unused until Phase 2 (Trial Balance/P&L/Balance Sheet)
    source_type           TEXT          NOT NULL
                          CHECK (source_type IN ('VIEW', 'FUNCTION')),
    source_object         TEXT          NOT NULL,
                          -- e.g. 'v_purchase_register' or 'fn_stock_summary_matrix' — a
                          -- STABLE function is always called via GET, same as a view
                          -- (see design doc's "Unifying detail"), so one fetch code path
                          -- covers both.
    module_code           TEXT          NOT NULL,
                          -- which module's menu group this report is organized under
    default_sort_column   TEXT,
    default_sort_dir      TEXT          CHECK (default_sort_dir IN ('ASC', 'DESC')),
    default_page_size     INTEGER       NOT NULL DEFAULT 50,
    use_exact_count       BOOLEAN       NOT NULL DEFAULT true,
                          -- false for reports over very large detail tables: use
                          -- PostgREST's estimated (planner-based, near-free) count
                          -- instead of Prefer: count=exact
    max_export_rows       INTEGER       NOT NULL DEFAULT 100000,
                          -- hard cap on a PDF/Excel export's row count; the UI prompts
                          -- to narrow filters instead of exporting past this
    totals_source_object  TEXT,
                          -- nullable: a VIEW/function returning ONE row (SUM/COUNT per
                          -- aggregate_fn column below) over the same filters as
                          -- source_object, no GROUP BY. NULL if this report has no
                          -- aggregate_fn columns worth totaling.
    is_active             BOOLEAN       NOT NULL DEFAULT true,
    is_deleted             BOOLEAN       NOT NULL DEFAULT false,
    created_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by             UUID          REFERENCES rim_users(id),
    updated_at             TIMESTAMPTZ,
    updated_by             UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, report_key)
);

CREATE INDEX IF NOT EXISTS idx_report_definitions_lookup
    ON ric_report_definitions (client_id, company_id, module_code, is_active, is_deleted);

CREATE TRIGGER trg_ric_report_definitions_updated_at
    BEFORE UPDATE ON ric_report_definitions
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ------------------------------------------------------------
-- ric_report_columns
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ric_report_columns (
    id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID          NOT NULL REFERENCES ric_clients(id),
    company_id            UUID          NOT NULL REFERENCES ric_companies(id),
    report_id             UUID          NOT NULL REFERENCES ric_report_definitions(id) ON DELETE CASCADE,
    column_key            TEXT          NOT NULL,
                          -- must match a field in the row JSON the source_object returns
    label                 TEXT          NOT NULL,
    data_type             TEXT          NOT NULL
                          CHECK (data_type IN ('TEXT', 'NUMBER', 'DATE', 'BOOLEAN', 'BADGE')),
    format                TEXT,
                          -- rendered through the app's existing AppNumberFormat utility for
                          -- NUMBER columns — not a new formatting mechanism, just reuse
    align                 TEXT          CHECK (align IN ('LEFT', 'RIGHT', 'CENTER')),
    sortable               BOOLEAN       NOT NULL DEFAULT true,
    default_visible        BOOLEAN       NOT NULL DEFAULT true,
    default_width          INTEGER,
    sort_order              INTEGER       NOT NULL DEFAULT 0,
    aggregate_fn           TEXT          CHECK (aggregate_fn IN ('SUM', 'AVG', 'COUNT', 'MIN', 'MAX')),
                          -- how this column rolls up in a group subtotal / grand total row;
                          -- NULL = not aggregated (blank on subtotal rows). Must map to a
                          -- genuinely single-currency source column (base_amount/local_amount),
                          -- never trans_amount/party_amount — see design doc's multi-currency
                          -- section; not something a CHECK constraint can enforce.
    is_pivot_row_group     BOOLEAN       NOT NULL DEFAULT false,   -- MATRIX only: fixed row key(s)
    is_pivot_dimension     BOOLEAN       NOT NULL DEFAULT false,   -- MATRIX only: becomes the variable columns
    is_pivot_measure       BOOLEAN       NOT NULL DEFAULT false,   -- MATRIX only: the aggregated value
    currency_code_column   TEXT,
                          -- nullable: for a money column whose currency VARIES per row
                          -- (trans_amount, party_amount), names the sibling column holding
                          -- that row's own currency code, so the cell renders e.g.
                          -- "500,000 CDF" using the row's own code
    drilldown_route        TEXT,
    drilldown_key_column   TEXT,
                          -- nullable pair: e.g. drilldown_route='/purchase/grn',
                          -- drilldown_key_column='grn_no' makes this cell a tappable link
                          -- into that document's own EXISTING entry screen
    parent_key_column      TEXT,
    level_column            TEXT,
                          -- unused until Phase 2 (HIERARCHICAL) — present now so no later
                          -- ALTER TABLE is needed when that phase starts
    is_active               BOOLEAN       NOT NULL DEFAULT true,
    created_at               TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by               UUID          REFERENCES rim_users(id),
    updated_at               TIMESTAMPTZ,
    updated_by               UUID          REFERENCES rim_users(id),
    UNIQUE (report_id, column_key)
);

CREATE INDEX IF NOT EXISTS idx_report_columns_lookup
    ON ric_report_columns (client_id, company_id, report_id, sort_order);

CREATE TRIGGER trg_ric_report_columns_updated_at
    BEFORE UPDATE ON ric_report_columns
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ------------------------------------------------------------
-- ric_report_filters
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ric_report_filters (
    id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID          NOT NULL REFERENCES ric_clients(id),
    company_id     UUID          NOT NULL REFERENCES ric_companies(id),
    report_id      UUID          NOT NULL REFERENCES ric_report_definitions(id) ON DELETE CASCADE,
    filter_key     TEXT          NOT NULL,
    label          TEXT          NOT NULL,
    filter_type    TEXT          NOT NULL
                   CHECK (filter_type IN ('DATE_RANGE', 'DATE', 'DROPDOWN_STATIC', 'DROPDOWN_LOOKUP',
                                           'ACCOUNT_PICKER', 'PRODUCT_PICKER', 'TEXT', 'BOOLEAN')),
    lookup_source  TEXT,          -- table name for DROPDOWN_LOOKUP
    lookup_label_column TEXT,     -- which column of lookup_source to display (id is always the value)
    static_options JSONB,         -- fixed list for DROPDOWN_STATIC
    param_target   TEXT          NOT NULL,
                   -- the actual PostgREST column / RPC param name this maps to
    required       BOOLEAN       NOT NULL DEFAULT false,
    default_value  TEXT,
                   -- a DATE_RANGE filter should set a sane bounded default (e.g. "this
                   -- month") rather than blank/unbounded — see design doc's Performance
                   -- section
    sort_order     INTEGER       NOT NULL DEFAULT 0,
    is_active      BOOLEAN       NOT NULL DEFAULT true,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by     UUID          REFERENCES rim_users(id),
    updated_at     TIMESTAMPTZ,
    updated_by     UUID          REFERENCES rim_users(id),
    UNIQUE (report_id, filter_key)
);

CREATE INDEX IF NOT EXISTS idx_report_filters_lookup
    ON ric_report_filters (client_id, company_id, report_id, sort_order);

CREATE TRIGGER trg_ric_report_filters_updated_at
    BEFORE UPDATE ON ric_report_filters
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ------------------------------------------------------------
-- ric_report_group_levels
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ric_report_group_levels (
    id                   UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            UUID          NOT NULL REFERENCES ric_clients(id),
    company_id           UUID          NOT NULL REFERENCES ric_companies(id),
    report_id            UUID          NOT NULL REFERENCES ric_report_definitions(id) ON DELETE CASCADE,
    level_no             INTEGER       NOT NULL,
                         -- 1 = outermost (e.g. Customer), 2 = next (e.g. Product Group), ...
    group_by_column      TEXT          NOT NULL,
                         -- key column present in this level's summary rows AND the detail
                         -- rows below it — used to filter children on expand
    group_label_column   TEXT          NOT NULL,
                         -- human-readable column shown in the group header row (often same
                         -- as group_by_column)
    summary_source_object TEXT         NOT NULL,
                         -- a dedicated VIEW/function: SELECT <level1_col>..<this level's
                         -- col>, <label_col>, <agg columns> ... GROUP BY <level1_col>..
                         -- <this level's col>. Its WHERE clause must filter on exactly the
                         -- same columns as the report's own filterable columns (see design
                         -- doc's "Authoring rule").
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by            UUID          REFERENCES rim_users(id),
    updated_at            TIMESTAMPTZ,
    updated_by            UUID          REFERENCES rim_users(id),
    UNIQUE (report_id, level_no)
);

CREATE INDEX IF NOT EXISTS idx_report_group_levels_lookup
    ON ric_report_group_levels (client_id, company_id, report_id, level_no);

CREATE TRIGGER trg_ric_report_group_levels_updated_at
    BEFORE UPDATE ON ric_report_group_levels
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ------------------------------------------------------------
-- Row Level Security — standard auth_rw_<table> convention
-- ------------------------------------------------------------
ALTER TABLE ric_report_definitions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ric_report_columns      ENABLE ROW LEVEL SECURITY;
ALTER TABLE ric_report_filters      ENABLE ROW LEVEL SECURITY;
ALTER TABLE ric_report_group_levels ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_rw_report_definitions" ON ric_report_definitions;
CREATE POLICY "auth_rw_report_definitions" ON ric_report_definitions
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

DROP POLICY IF EXISTS "auth_rw_report_columns" ON ric_report_columns;
CREATE POLICY "auth_rw_report_columns" ON ric_report_columns
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

DROP POLICY IF EXISTS "auth_rw_report_filters" ON ric_report_filters;
CREATE POLICY "auth_rw_report_filters" ON ric_report_filters
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

DROP POLICY IF EXISTS "auth_rw_report_group_levels" ON ric_report_group_levels;
CREATE POLICY "auth_rw_report_group_levels" ON ric_report_group_levels
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_report_definitions  FROM anon;
REVOKE ALL ON ric_report_columns      FROM anon;
REVOKE ALL ON ric_report_filters      FROM anon;
REVOKE ALL ON ric_report_group_levels FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON ric_report_definitions  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ric_report_columns      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ric_report_filters      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ric_report_group_levels TO authenticated;
