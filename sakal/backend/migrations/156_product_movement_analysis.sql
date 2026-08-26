-- ============================================================
-- Migration 156: Product Movement Analysis (Fast/Slow/Non-Moving)
--   via a new generic Report Job Queue + Notification base
-- ============================================================
-- Three pieces, in dependency order:
--   A. ric_user_notifications      — generic, minimal in-app notification base
--   B. ric_report_jobs + pg_cron   — generic, reusable async job queue for any
--                                    future full-catalog-scale report
--   C. Product Movement Analysis   — the actual report, built on A + B
--
-- WHY a job queue instead of a live query or a shared snapshot table: this
-- report aggregates over the ENTIRE product catalog (one row per product,
-- not bounded by transaction volume the way every prior report this
-- session was) — a 50,000-SKU catalog makes this genuinely heavy. A first
-- design (one shared, mutable snapshot table per company, wholesale-
-- replaced on refresh) was rejected: two users requesting different
-- periods at the same time would stomp each other's data. A pure live
-- query has zero concurrency issues (Postgres MVCC handles concurrent
-- reads natively) but blocks the requesting user's screen for however
-- long the full-catalog computation takes. This design instead: a user
-- submits a job with their own params, pg_cron processes it asynchronously
-- (confirmed available on this deployment — Supabase Cloud), results are
-- stored keyed by job_id (never shared/overwritten between users' own
-- jobs), and the user is notified in-app when it's ready. Mirrors how SAP
-- itself often runs MC46 (Slow-Moving) as a background job for large
-- plants.
--
-- Research behind the classification rule: Odoo's own FSN report uses a
-- Stock Turnover Ratio (F >3, S 1-3, N <1) over a picked date range; SAP's
-- MC46/MC50 use "days since last goods issue" / stock-depletion-over-time.
-- Synthesis used here: SAP's cleanest signal (zero sales = unambiguously
-- Non-Moving) + Odoo's ratio-driven Fast/Slow split for everything that
-- DID sell + SAKAL's own already-proven ledger-reconstruction technique
-- (from fn_stock_details, migration 149) for an accurate Average Stock
-- denominator instead of just today's rim_product_location.current_stock.
--
-- Full design: sakal/docs/screens/plan_product_movement_analysis.md
-- ============================================================


-- ============================================================
-- PIECE A — Notification base (generic, minimal, reusable beyond this
-- report — a future full workflow/approval-notifications module builds on
-- this same table, not a separate one).
-- ============================================================
CREATE TABLE IF NOT EXISTS ric_user_notifications (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID        NOT NULL REFERENCES ric_clients(id),
    company_id        UUID        NOT NULL REFERENCES ric_companies(id),
    user_id           UUID        NOT NULL REFERENCES rim_users(id),   -- the recipient
    notification_type TEXT        NOT NULL,   -- 'REPORT_JOB_COMPLETE'/'REPORT_JOB_FAILED' today;
                                               -- deliberately no CHECK constraint — a future workflow
                                               -- module adds its own types with zero migration here
    title             TEXT        NOT NULL,
    message           TEXT,
    link_route        TEXT,       -- go_router path to navigate to on click, e.g.
                                   -- '/reports/PRODUCT_MOVEMENT_ANALYSIS?job_id=...'; nullable —
                                   -- not every notification type needs a destination
    is_read           BOOLEAN     NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at           TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_user_notifications_recipient
    ON ric_user_notifications(client_id, company_id, user_id, is_read, created_at DESC);

ALTER TABLE ric_user_notifications ENABLE ROW LEVEL SECURITY;

-- A user only ever sees their OWN notifications, not every user's in the
-- company — an extra predicate on top of this project's standard
-- client_id/company_id RLS shape.
DROP POLICY IF EXISTS "auth_rw_user_notifications" ON ric_user_notifications;
CREATE POLICY "auth_rw_user_notifications" ON ric_user_notifications
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND user_id    = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND user_id    = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid);

REVOKE ALL ON ric_user_notifications FROM anon;
GRANT SELECT, UPDATE ON ric_user_notifications TO authenticated;   -- UPDATE only for marking is_read;
                                                                    -- INSERT happens via the trusted
                                                                    -- pg_cron worker (bypasses RLS as a
                                                                    -- superuser-owned job), never client-side
GRANT ALL ON ric_user_notifications TO service_role;


-- ============================================================
-- PIECE B — Generic Report Job Queue (pg_cron-driven, reusable for any
-- future heavy report, not just this one).
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;
-- NOTE: on Supabase, this statement may need the "pg_cron" toggle enabled
-- via Database → Extensions in the dashboard first if the SQL Editor role
-- lacks CREATE EXTENSION privilege — if this line errors, enable it there
-- and re-run the migration; every statement below is safe to re-run.

CREATE TABLE IF NOT EXISTS ric_report_jobs (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID        NOT NULL REFERENCES ric_clients(id),
    company_id     UUID        NOT NULL REFERENCES ric_companies(id),
    report_key     TEXT        NOT NULL,   -- dispatch key, e.g. 'PRODUCT_MOVEMENT_ANALYSIS' —
                                            -- fn_process_pending_report_jobs' own CASE branches on this
    params         JSONB       NOT NULL DEFAULT '{}',
    status         TEXT        NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING','RUNNING','COMPLETED','FAILED')),
    submitted_by   UUID        NOT NULL REFERENCES rim_users(id),
    submitted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at     TIMESTAMPTZ,
    completed_at   TIMESTAMPTZ,
    error_message  TEXT,
    result_row_count INTEGER
);

CREATE INDEX IF NOT EXISTS idx_report_jobs_pending
    ON ric_report_jobs(status, submitted_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_report_jobs_user
    ON ric_report_jobs(client_id, company_id, submitted_by, submitted_at DESC);

ALTER TABLE ric_report_jobs ENABLE ROW LEVEL SECURITY;

-- "User-wise data" per the user's own framing — a user only ever sees
-- their OWN job submissions/results, not every user's in the company.
DROP POLICY IF EXISTS "auth_rw_report_jobs" ON ric_report_jobs;
CREATE POLICY "auth_rw_report_jobs" ON ric_report_jobs
    FOR ALL TO authenticated
    USING     (client_id    = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id   = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND submitted_by = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid)
    WITH CHECK(client_id    = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id   = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
           AND submitted_by = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid);

REVOKE ALL ON ric_report_jobs FROM anon;
GRANT SELECT, INSERT ON ric_report_jobs TO authenticated;   -- INSERT only via fn_submit_report_job
                                                              -- below in practice, but no harm granting
                                                              -- direct INSERT too (RLS still enforces
                                                              -- submitted_by = the caller's own user_id)
GRANT ALL ON ric_report_jobs TO service_role;


CREATE OR REPLACE FUNCTION fn_submit_report_job(
    p_client_id    UUID,
    p_company_id   UUID,
    p_report_key   TEXT,
    p_params       JSONB,
    p_submitted_by UUID
) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
    v_job_id UUID;
BEGIN
    INSERT INTO ric_report_jobs (client_id, company_id, report_key, params, submitted_by)
    VALUES (p_client_id, p_company_id, p_report_key, p_params, p_submitted_by)
    RETURNING id INTO v_job_id;

    RETURN v_job_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_submit_report_job(UUID, UUID, TEXT, JSONB, UUID) TO authenticated;


-- The pg_cron worker — runs as the role that owns the scheduled job
-- (typically a superuser/postgres role on Supabase), so it bypasses RLS
-- entirely and can see/process every company's pending jobs. Claims work
-- via the standard Postgres poor-man's-queue pattern (SKIP LOCKED) so
-- overlapping cron ticks (a slow batch still running when the next tick
-- fires) never double-process the same job. One job failing must never
-- abort the batch — each job's own exception is caught individually.
CREATE OR REPLACE FUNCTION fn_process_pending_report_jobs(
    p_batch_size INTEGER DEFAULT 5
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_job RECORD;
BEGIN
    FOR v_job IN
        SELECT * FROM ric_report_jobs
        WHERE status = 'PENDING'
        ORDER BY submitted_at
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    LOOP
        UPDATE ric_report_jobs SET status = 'RUNNING', started_at = now() WHERE id = v_job.id;

        BEGIN
            CASE v_job.report_key
                WHEN 'PRODUCT_MOVEMENT_ANALYSIS' THEN
                    PERFORM fn_run_product_movement_analysis_job(v_job.id, v_job.params);
                ELSE
                    RAISE EXCEPTION 'Unknown report_key for job processing: %', v_job.report_key;
            END CASE;

            UPDATE ric_report_jobs SET status = 'COMPLETED', completed_at = now() WHERE id = v_job.id;

            INSERT INTO ric_user_notifications
                (client_id, company_id, user_id, notification_type, title, message, link_route)
            VALUES
                (v_job.client_id, v_job.company_id, v_job.submitted_by, 'REPORT_JOB_COMPLETE',
                 'Report ready', format('Your %s report is ready.', v_job.report_key),
                 format('/reports/%s?job_id=%s', v_job.report_key, v_job.id));

        EXCEPTION WHEN OTHERS THEN
            UPDATE ric_report_jobs
                SET status = 'FAILED', completed_at = now(), error_message = SQLERRM
                WHERE id = v_job.id;

            INSERT INTO ric_user_notifications
                (client_id, company_id, user_id, notification_type, title, message, link_route)
            VALUES
                (v_job.client_id, v_job.company_id, v_job.submitted_by, 'REPORT_JOB_FAILED',
                 'Report failed', format('Your %s report could not be generated: %s', v_job.report_key, SQLERRM),
                 NULL);
        END;
    END LOOP;
END;
$$;

-- Retention — purges jobs (and their report-specific result rows, via
-- ON DELETE CASCADE FKs to ric_report_jobs.id) older than the window.
-- Prevents unbounded growth now that jobs genuinely accumulate (unlike
-- the earlier, rejected shared-snapshot design, where there was only ever
-- one row set to begin with).
CREATE OR REPLACE FUNCTION fn_purge_old_report_jobs(
    p_retention_days INTEGER DEFAULT 30
) RETURNS VOID LANGUAGE sql AS $$
    DELETE FROM ric_report_jobs
    WHERE status IN ('COMPLETED', 'FAILED')
    AND completed_at < (now() - (p_retention_days || ' days')::interval);
$$;

SELECT cron.unschedule('process-report-jobs') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'process-report-jobs');
SELECT cron.schedule('process-report-jobs', '* * * * *', $$SELECT fn_process_pending_report_jobs();$$);

SELECT cron.unschedule('purge-old-report-jobs') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge-old-report-jobs');
SELECT cron.schedule('purge-old-report-jobs', '0 3 * * *', $$SELECT fn_purge_old_report_jobs(30);$$);


-- ============================================================
-- PIECE C — Product Movement Analysis (built on A + B)
-- ============================================================

CREATE TABLE IF NOT EXISTS ric_product_movement_snapshot (
    id                   UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id               UUID    NOT NULL REFERENCES ric_report_jobs(id) ON DELETE CASCADE,
    location_id          UUID    NOT NULL REFERENCES ric_locations(id),
    product_id           UUID    NOT NULL REFERENCES rim_products(id),
    qty_sold             NUMERIC(18,4) NOT NULL DEFAULT 0,
    avg_stock            NUMERIC(18,4) NOT NULL DEFAULT 0,
    current_stock        NUMERIC(18,4) NOT NULL DEFAULT 0,
    days_since_last_sale INTEGER,      -- NULL = never sold
    turnover_ratio       NUMERIC(18,4),-- NULL when avg_stock = 0 and qty_sold = 0 (Non-Moving, no ratio)
    movement_category    TEXT    NOT NULL CHECK (movement_category IN ('Fast-Moving','Slow-Moving','Non-Moving'))
);

CREATE INDEX IF NOT EXISTS idx_product_movement_snapshot_job ON ric_product_movement_snapshot(job_id);

-- No RLS on this table itself — nobody queries it directly. All reads go
-- through v_product_movement_analysis below, which joins back to
-- ric_report_jobs (RLS-protected, "user-wise") and applies the usual
-- location-access scoping. The job-processing function (superuser
-- context) writes to it directly, bypassing RLS entirely as usual.
REVOKE ALL ON ric_product_movement_snapshot FROM anon, authenticated;
GRANT ALL ON ric_product_movement_snapshot TO service_role;


-- The heavy, once-per-job computation. Deliberately queries the RAW base
-- tables (rim_products, ril_stock_ledger, v_sales_details_base), never a
-- caller's own JWT-scoped view — this runs via pg_cron with NO JWT
-- context, so any location-access predicate keyed off
-- current_setting('request.jwt.claims',...) would either see nothing or
-- (as confirmed by reading v_sales_details_base's own WHERE clause) fall
-- through to its "no access rows for this user = unrestricted" branch —
-- either way, scoping must NOT happen here. It happens once, correctly,
-- at READ time in v_product_movement_analysis for whichever real user is
-- actually viewing the job's results.
CREATE OR REPLACE FUNCTION fn_run_product_movement_analysis_job(
    p_job_id UUID,
    p_params JSONB
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_client_id  UUID;
    v_company_id UUID;
    v_date_from  DATE := (p_params->>'date_from')::date;
    v_date_to    DATE := (p_params->>'date_to')::date;
    v_row_count  INTEGER;
BEGIN
    SELECT client_id, company_id INTO v_client_id, v_company_id
    FROM ric_report_jobs WHERE id = p_job_id;

    IF v_date_from IS NULL OR v_date_to IS NULL THEN
        RAISE EXCEPTION 'date_from/date_to are required in job params';
    END IF;

    WITH product_locations AS (
        -- Only product+location combos that actually have an inventory
        -- footprint (rim_product_location row) — not a blind cross join
        -- of every product against every location, which would be mostly
        -- meaningless rows for a multi-location retailer.
        SELECT rpl.product_id, rpl.location_id, rpl.current_stock
        FROM rim_product_location rpl
        JOIN rim_products p ON p.id = rpl.product_id
        WHERE rpl.client_id = v_client_id AND rpl.company_id = v_company_id
          AND p.is_deleted = false AND p.is_active = true
    ),
    period_sales AS (
        SELECT product_id, location_id, SUM(base_qty) AS qty_sold
        FROM v_sales_details_base
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND status = 'APPROVED'
          AND invoice_date BETWEEN v_date_from AND v_date_to
        GROUP BY product_id, location_id
    ),
    last_sale AS (
        -- NOT period-bound — "days since last sale" answers "how long has
        -- it actually been", same convention as SAP MC46, regardless of
        -- whatever window this particular job happens to analyze.
        SELECT product_id, location_id, MAX(invoice_date) AS last_sale_date
        FROM v_sales_details_base
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND status = 'APPROVED'
        GROUP BY product_id, location_id
    ),
    stock_window AS (
        SELECT product_id, location_id,
               COALESCE(SUM(qty_change) FILTER (WHERE trans_date < v_date_from), 0) AS opening_qty,
               COALESCE(SUM(qty_change) FILTER (WHERE trans_date BETWEEN v_date_from AND v_date_to), 0) AS period_change
        FROM ril_stock_ledger
        WHERE client_id = v_client_id AND company_id = v_company_id
        GROUP BY product_id, location_id
    ),
    computed AS (
        SELECT
            pl.product_id, pl.location_id, pl.current_stock,
            COALESCE(ps.qty_sold, 0) AS qty_sold,
            COALESCE(ls.last_sale_date, NULL) AS last_sale_date,
            ((COALESCE(sw.opening_qty, 0)) + (COALESCE(sw.opening_qty, 0) + COALESCE(sw.period_change, 0))) / 2.0 AS avg_stock
        FROM product_locations pl
        LEFT JOIN period_sales ps ON ps.product_id = pl.product_id AND ps.location_id = pl.location_id
        LEFT JOIN last_sale    ls ON ls.product_id = pl.product_id AND ls.location_id = pl.location_id
        LEFT JOIN stock_window sw ON sw.product_id = pl.product_id AND sw.location_id = pl.location_id
    )
    INSERT INTO ric_product_movement_snapshot
        (job_id, location_id, product_id, qty_sold, avg_stock, current_stock,
         days_since_last_sale, turnover_ratio, movement_category)
    SELECT
        p_job_id, c.location_id, c.product_id, c.qty_sold, c.avg_stock, c.current_stock,
        CASE WHEN c.last_sale_date IS NULL THEN NULL ELSE (CURRENT_DATE - c.last_sale_date) END,
        CASE WHEN c.avg_stock = 0 THEN NULL ELSE c.qty_sold / c.avg_stock END,
        CASE
            WHEN c.qty_sold = 0        THEN 'Non-Moving'
            WHEN c.avg_stock = 0       THEN 'Fast-Moving'   -- sold out within the window — see migration
                                                             -- header comment; must precede the ratio
                                                             -- branch, since the ratio itself is NULL here
            WHEN c.qty_sold / c.avg_stock >= 3 THEN 'Fast-Moving'
            ELSE 'Slow-Moving'
        END
    FROM computed c;

    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    UPDATE ric_report_jobs SET result_row_count = v_row_count WHERE id = p_job_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_run_product_movement_analysis_job(UUID, JSONB) TO service_role;


-- Read-side wrapper — the ONLY thing a real user's report screen ever
-- queries. Joins back to ric_report_jobs (RLS already restricts this to
-- the CURRENT user's own jobs — "user-wise data" — before this view's own
-- SELECT even runs) and applies the same location-access scoping
-- convention as every other report this session, plus product/location
-- name resolution for display.
CREATE OR REPLACE VIEW v_product_movement_analysis AS
SELECT
    j.id AS job_id, j.client_id, j.company_id,
    (j.params->>'date_from')::date AS period_date_from,
    (j.params->>'date_to')::date   AS period_date_to,
    s.location_id, loc.location_name,
    s.product_id, p.product_code, p.product_name,
    p.category_id, cat.category_name,
    p.brand_id, br.description AS brand_name,
    p.product_nature,
    (p.flags->>'is_saleable')::boolean AS is_saleable,
    p.base_uom_id, uom.description AS unit_name,
    s.qty_sold, s.avg_stock, s.current_stock,
    s.days_since_last_sale, s.turnover_ratio, s.movement_category
FROM ric_product_movement_snapshot s
JOIN ric_report_jobs j   ON j.id = s.job_id
JOIN rim_products p      ON p.id = s.product_id
LEFT JOIN ric_locations       loc ON loc.id = s.location_id
LEFT JOIN rim_item_categories cat ON cat.id = p.category_id
LEFT JOIN rim_common_masters  br  ON br.id  = p.brand_id
LEFT JOIN rim_common_masters  uom ON uom.id = p.base_uom_id
WHERE j.status = 'COMPLETED'
AND (
    NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = j.client_id AND ula.company_id = j.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
    OR s.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                    AND ula.client_id = j.client_id AND ula.company_id = j.company_id
                    AND ula.is_active = true AND ula.is_deleted = false)
);

GRANT SELECT ON v_product_movement_analysis TO authenticated;


CREATE OR REPLACE FUNCTION fn_product_movement_analysis_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_job_id     UUID,
    p_location_id UUID DEFAULT NULL,
    p_category_id UUID DEFAULT NULL,
    p_brand_id    UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL,
    p_movement_category TEXT DEFAULT NULL
) RETURNS TABLE (
    qty_sold  NUMERIC,
    row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(qty_sold), 0), COUNT(*)
    FROM v_product_movement_analysis
    WHERE client_id  = p_client_id
    AND company_id = p_company_id
    AND job_id     = p_job_id
    AND (p_location_id  IS NULL OR location_id  = p_location_id)
    AND (p_category_id  IS NULL OR category_id  = p_category_id)
    AND (p_brand_id      IS NULL OR brand_id      = p_brand_id)
    AND (p_product_id     IS NULL OR product_id     = p_product_id)
    AND (p_movement_category IS NULL OR movement_category = p_movement_category);
$$;

GRANT EXECUTE ON FUNCTION fn_product_movement_analysis_totals(
    UUID, UUID, UUID, UUID, UUID, UUID, UUID, TEXT) TO authenticated;


-- ============================================================
-- Registry row, one per existing company — a plain TABULAR report (no
-- date_range filter, since the date range is a job-submission parameter,
-- not a live filter — see the report screen's own bespoke Submit flow).
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_in_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_in_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'IN';

        CONTINUE WHEN v_in_module_id IS NULL;

        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size,
             totals_source_object, auto_load)
        VALUES
            (v_company.client_id, v_company.company_id, 'PRODUCT_MOVEMENT_ANALYSIS', 'Product Movement Analysis',
             'TABULAR', 'VIEW', 'v_product_movement_analysis', 'IN', 'qty_sold', 'DESC', 200,
             'fn_product_movement_analysis_totals', false)
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name, totals_source_object = excluded.totals_source_object,
                auto_load = excluded.auto_load
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'location_name', 'Location', 'TEXT', 'LEFT', true, true, 150, 1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_code', 'Item Code', 'TEXT', 'LEFT', true, true, 120, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_name', 'Item Name', 'TEXT', 'LEFT', true, true, 200, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_name', 'Category', 'TEXT', 'LEFT', true, true, 140, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'brand_name', 'Brand', 'TEXT', 'LEFT', true, true, 120, 5, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'unit_name', 'Unit', 'TEXT', 'LEFT', true, true, 90, 6, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'qty_sold', 'Qty Sold', 'NUMBER', 'RIGHT', true, true, 110, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'avg_stock', 'Avg Stock', 'NUMBER', 'RIGHT', true, true, 110, 8, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'current_stock', 'Current Stock', 'NUMBER', 'RIGHT', true, true, 120, 9, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'days_since_last_sale', 'Days Since Last Sale', 'NUMBER', 'RIGHT', true, true, 150, 10, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'turnover_ratio', 'Turnover Ratio', 'NUMBER', 'RIGHT', true, true, 120, 11, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'movement_category', 'Movement Category', 'BADGE', 'CENTER', true, true, 140, 12, NULL);

        -- Live filters over the completed job's own rows — no date_range
        -- here (that's a job-submission param, not a query-time filter).
        -- job_id itself is deliberately NOT a declared filter — the report
        -- screen threads it in as a hidden extraParams key, see Flutter
        -- side. is_saleable defaults UNCHECKED (not filtering) since
        -- rim_product_flag_types has no seeded default across companies —
        -- a default-checked filter would show zero rows for any company
        -- that never configured this flag.
        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type,
             lookup_source, lookup_label_column, static_options, param_target, required, default_value, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'location_id', 'Location', 'DROPDOWN_LOOKUP',
                'v_user_accessible_locations', 'location_name', NULL, 'location_id', false, NULL, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP',
                'rim_item_categories', 'category_name', NULL, 'category_id', false, NULL, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'brand_id', 'Brand', 'DROPDOWN_LOOKUP',
                'v_product_brands', 'brand_name', NULL, 'brand_id', false, NULL, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'product_id', 'Product', 'DROPDOWN_LOOKUP',
                'rim_products', 'product_name', NULL, 'product_id', false, NULL, 4),
            (v_company.client_id, v_company.company_id, v_report_id, 'movement_category', 'Movement Category', 'DROPDOWN_STATIC',
                NULL, NULL,
                '[{"value":"Fast-Moving","label":"Fast-Moving"},{"value":"Slow-Moving","label":"Slow-Moving"},{"value":"Non-Moving","label":"Non-Moving"}]'::jsonb,
                'movement_category', false, NULL, 5);

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_in_module_id, 'IN-RPT-PMA', 'Product Movement Analysis',
             '/reports/PRODUCT_MOVEMENT_ANALYSIS', 14, 'IN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


INSERT INTO ric_user_menus (
    client_id, company_id, user_id, module_id, feature_code, serial_no,
    view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT DISTINCT
    mm.client_id, mm.company_id, existing.user_id, mm.module_id, mm.feature_code, mm.serial_no,
    true, false, mm.approve_allowed, mm.copy_allowed, mm.excel_upload_allowed
FROM ric_master_menus mm
JOIN (
    SELECT DISTINCT user_id, client_id, company_id, module_id
    FROM ric_user_menus
    WHERE view_allowed = true AND is_deleted = false
) existing
    ON  existing.client_id  = mm.client_id
    AND existing.company_id = mm.company_id
    AND existing.module_id  = mm.module_id
WHERE mm.feature_code = 'IN-RPT-PMA'
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
