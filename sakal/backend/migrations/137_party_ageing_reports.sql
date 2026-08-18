-- ============================================================
-- Migration 137: Customer Ageing & Supplier Ageing reports — Finance.
-- ============================================================
-- Built entirely on the existing Reporting Engine (116-119, 126/127,
-- 132, 135) — no new screen, no new route, same "a new report is a
-- migration, not a Flutter change" pattern as every report before it.
-- Two separate menu items ("technically they are same" per the user) —
-- one shared internal core function, discriminated purely by
-- rim_accounts.account_nature, exposed as two thin per-nature wrappers.
-- Mirrors a working Oracle-ERP predecessor's own VW_OUTSTANDING_BILL /
-- VW_OUTSTANDING_ADVANCE views (user-supplied design reference), which
-- used the identical account_type-discriminated-single-view shape.
--
-- Runs AFTER 136 (party_category -> LOV) — the Category filter/column
-- here does a real join through rim_accounts.party_category_id to
-- rim_common_masters.description, not a derived list of free-text
-- values.
--
-- Always "as of today" (CURRENT_DATE) — no As-On-Date filter, confirmed
-- by the user. Buckets computed from Bill Date (inv_bill_date), also
-- confirmed, not a computed due date.
--
-- Sign convention — confirmed positive "amount owed" magnitudes
-- everywhere (every bucket, Total Outstanding, Unsettled Advance, Net
-- Closing), never literal Dr/Cr sign carry-through the way Account
-- Ledger (132) shows it. A Supplier bill is naturally Cr in the books —
-- literal sign carry-through would make every Supplier Ageing figure
-- negative, which nobody reads an ageing report that way. Net Closing
-- reconciles to fn_account_ledger_totals's own running_balance by
-- magnitude (ABS), not raw signed value — see the verification note
-- on fn_party_ageing_lines_core below for the one known, accepted gap
-- in that reconciliation (no opening-balance CTE here, unlike Trial
-- Balance).
--
-- No Base/Local currency toggle (source_object_local left NULL) — the
-- user's own "Currency" column already means party_currency; every
-- figure here is a party amount, and Net Closing's own reconciliation
-- is inherently a party-currency concept. Matches Account Ledger's
-- (132) precedent, not Trial Balance's (135) book-wide toggle.
--
-- Unsettled Advance — rid_finance_lines rows with inv_bill_no IS NULL,
-- netted by trans_nature, LEFT JOINed to rid_invoice_bill_settlement on
-- the ADVANCE LINE'S OWN trans_no/trans_date/account_id (not the usual
-- inv_bill_no join v_pending_bills uses). This mirrors the Oracle
-- reference's VW_OUTSTANDING_ADVANCE exactly. Confirmed by reading
-- fn_post_finance_voucher (019, lines 536-599) directly: SAKAL's
-- rid_invoice_bill_settlement.trans_no/trans_date already has the
-- identical column shape as Oracle's design (the settling voucher's own
-- transaction), but the settlement-creation loop only fires for
-- non-on-account vouchers whose OWN lines already carry inv_bill_no —
-- an advance's own trans_no never becomes a later settlement row's
-- trans_no today. There is currently no "apply an old advance against a
-- new bill" workflow in SAKAL. Building this join anyway is free and
-- forward-compatible: the day that workflow exists, this report starts
-- reflecting partial consumption automatically, zero changes needed
-- here. Until then every advance correctly shows as fully unsettled —
-- an honest reflection of what the data can express today, not a bug.
--
-- Inter-entity accounts (rim_accounts.inter_entity_group_id IS NOT
-- NULL) — confirmed INCLUDED, not excluded, user's own words: "we can
-- include them, we will put them under a different category (just for
-- reporting purpose)". Implemented as a display-only effective-category
-- override inside fn_party_ageing_lines_core — the real
-- party_category_id column is never touched, and this also makes
-- 'Inter-Entity' a selectable Category filter value for free.
--
-- Grouping: one level, by party_currency, using ric_report_group_levels
-- — proven and LIVE today via migration 118's own
-- PENDING_BILLS_BY_CUSTOMER report (real bold expand/collapse
-- group-header rows with pre-aggregated sums, rendered by
-- sakal_report_table.dart's _buildGroupHeaderRow — not merely a PDF
-- export artifact). One level here (currency only), not 118's two
-- (account then currency) — individual customer/supplier rows are the
-- detail rows directly under the currency group header, so the summary
-- function below takes the SAME params as the detail function, no
-- ancestor-key parameter needed (118's own comment on
-- fn_pending_bills_summary_by_customer_currency documents that
-- ancestor-key convention for its OWN 2-level case; it doesn't apply to
-- a 1-level report).
-- ============================================================


-- ============================================================
-- Filter lookup views
-- ============================================================

-- Group Name filter — only Chart-of-Accounts parent groups that
-- actually have at least one Customer or Supplier child, not every
-- group in the chart.
CREATE OR REPLACE VIEW v_party_account_groups_lookup AS
SELECT DISTINCT p.id, p.client_id, p.company_id, p.account_name AS group_name
FROM rim_accounts p
JOIN rim_accounts c
    ON  c.parent_id  = p.id
    AND c.client_id  = p.client_id
    AND c.company_id = p.company_id
WHERE c.account_nature IN ('Customer', 'Supplier')
  AND c.is_deleted = false
  AND p.is_deleted = false;

GRANT SELECT ON v_party_account_groups_lookup TO authenticated;

-- Currency filter — only currencies actually used by a Customer/Supplier
-- account, not every currency in rim_currencies.
CREATE OR REPLACE VIEW v_party_currencies_lookup AS
SELECT DISTINCT rc.id, a.client_id, a.company_id, rc.currency_id AS currency_code
FROM rim_accounts a
JOIN rim_currencies rc ON rc.id = a.account_currency_id
WHERE a.account_nature IN ('Customer', 'Supplier')
  AND a.is_deleted = false;

GRANT SELECT ON v_party_currencies_lookup TO authenticated;

-- Category filter — a real DROPDOWN_LOOKUP directly over rim_common_masters,
-- one view per report (a shared view would leak Customer categories into
-- the Supplier Ageing filter and vice versa — DROPDOWN_LOOKUP's
-- lookup_source has no per-report WHERE clause of its own, so scoping
-- happens at the view level instead) — plus the synthetic 'Inter-Entity'
-- pseudo-category (see fn_party_ageing_lines_core below) unioned in, so
-- it's selectable like any other value, with a stable id
-- ('INTER-ENTITY', the literal string, never a real rim_common_masters
-- row) that the core function's own p_category_id matching treats as a
-- special case. The synthetic row's own client_id/company_id are pulled
-- from the requesting session's JWT rather than a real table row, so it
-- still scopes correctly per company like every other row here.
CREATE OR REPLACE VIEW v_customer_categories_lookup AS
SELECT cm.id::text AS id, cm.client_id, cm.company_id, cm.description AS category_name
FROM rim_common_masters cm
JOIN rim_common_master_types t ON t.id = cm.type_id
WHERE t.type_key = 'CUSTOMER_CATEGORY'
  AND cm.is_deleted = false AND cm.is_active = true
UNION ALL
SELECT 'INTER-ENTITY',
       (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid,
       (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid,
       'Inter-Entity';

GRANT SELECT ON v_customer_categories_lookup TO authenticated;

CREATE OR REPLACE VIEW v_supplier_categories_lookup AS
SELECT cm.id::text AS id, cm.client_id, cm.company_id, cm.description AS category_name
FROM rim_common_masters cm
JOIN rim_common_master_types t ON t.id = cm.type_id
WHERE t.type_key = 'SUPPLIER_CATEGORY'
  AND cm.is_deleted = false AND cm.is_active = true
UNION ALL
SELECT 'INTER-ENTITY',
       (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid,
       (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid,
       'Inter-Entity';

GRANT SELECT ON v_supplier_categories_lookup TO authenticated;


-- ============================================================
-- fn_party_ageing_lines_core — the shared engine both wrappers call.
-- Not itself a PostgREST report source (no report registers it
-- directly). STABLE, one row per Customer/Supplier account that has
-- outstanding bills and/or an unsettled advance.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_ageing_lines_core(
    p_client_id      UUID,
    p_company_id     UUID,
    p_account_nature TEXT,               -- 'Customer' or 'Supplier', set only by the two wrappers below
    p_group_id       UUID DEFAULT NULL,
    p_category_id    TEXT DEFAULT NULL,  -- rim_common_masters.id as text, or the literal 'INTER-ENTITY'
    p_account_id     UUID DEFAULT NULL,
    p_currency       TEXT DEFAULT NULL
) RETURNS TABLE (
    account_id        UUID,
    party_currency     TEXT,
    group_name         TEXT,
    category_name      TEXT,
    account_name       TEXT,
    bucket_0_30        NUMERIC,
    bucket_31_60       NUMERIC,
    bucket_61_90       NUMERIC,
    bucket_over_90     NUMERIC,
    total_outstanding  NUMERIC,
    unsettled_advance  NUMERIC,
    net_closing        NUMERIC,
    sort_key           TEXT
) LANGUAGE sql STABLE AS $$
    -- ric_user_location_access (029) — zero active rows for the JWT's
    -- user_id = unrestricted; any active rows = limited to that set. Same
    -- block as fn_account_ledger_lines (132)/fn_trial_balance_lines_base
    -- (135), applied here directly inside bill_lines/advance_per_voucher
    -- (both already join rih_finance_headers, so h.location_id is
    -- in scope) rather than as a bolt-on existence check at the very end
    -- — pushing it to the source is what makes it actually correct: an
    -- account with lines in both an accessible and an inaccessible
    -- location must only ever total the accessible one's amounts, not
    -- merely appear in the report if ANY of its lines happen to qualify.
    WITH location_ok AS (
        SELECT NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                            WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                              AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                              AND ula.is_active = true AND ula.is_deleted = false) AS unrestricted
    ),
    bill_lines AS (
        -- Same shape as v_pending_bills (117) — not reused directly,
        -- since this needs group/category/nature columns and day-bucketing
        -- that view doesn't expose (same reasoning fn_account_ledger_lines,
        -- 132, used for its own bespoke function rather than a generic view).
        SELECT
            l.client_id, l.company_id, l.location_id, l.account_id,
            l.party_currency,
            l.inv_bill_date,
            (l.party_amount - COALESCE(s.settled_amt, 0)) AS balance_amount
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
        LEFT JOIN (
            SELECT client_id, company_id, location_id, account_id, inv_bill_no,
                   SUM(paid_amount) AS settled_amt
            FROM rid_invoice_bill_settlement
            WHERE is_deleted = false
            GROUP BY client_id, company_id, location_id, account_id, inv_bill_no
        ) s ON  s.client_id   = l.client_id   AND s.company_id = l.company_id
            AND s.location_id = l.location_id AND s.account_id = l.account_id
            AND s.inv_bill_no = l.inv_bill_no
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.inv_bill_no IS NOT NULL
          AND l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
          AND (l.party_amount - COALESCE(s.settled_amt, 0)) > 0.001
          AND (
              (SELECT unrestricted FROM location_ok)
              OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                      AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                      AND ula.is_active = true AND ula.is_deleted = false)
          )
    ),
    bill_buckets AS (
        SELECT
            account_id, party_currency,
            COALESCE(SUM(balance_amount) FILTER (WHERE CURRENT_DATE - inv_bill_date <= 30), 0)                          AS bucket_0_30,
            COALESCE(SUM(balance_amount) FILTER (WHERE CURRENT_DATE - inv_bill_date BETWEEN 31 AND 60), 0)              AS bucket_31_60,
            COALESCE(SUM(balance_amount) FILTER (WHERE CURRENT_DATE - inv_bill_date BETWEEN 61 AND 90), 0)              AS bucket_61_90,
            COALESCE(SUM(balance_amount) FILTER (WHERE CURRENT_DATE - inv_bill_date > 90), 0)                           AS bucket_over_90,
            COALESCE(SUM(balance_amount), 0)                                                                            AS total_outstanding
        FROM bill_lines
        GROUP BY account_id, party_currency
    ),
    -- The Oracle-derived join: settlement consumption matched on the
    -- ADVANCE LINE's own trans_no/trans_date/account_id, not the usual
    -- inv_bill_no join — see this migration's own header comment.
    -- Lines are pre-aggregated to one row per (account, voucher) BEFORE
    -- joining the settlement-sum subquery — joining line-by-line first
    -- would duplicate settled_amt (and double-count it) for the rare but
    -- real case of a JV posting more than one line against the same
    -- account within a single voucher.
    advance_per_voucher AS (
        SELECT
            l.client_id, l.company_id, l.location_id, l.account_id, l.trans_no, l.trans_date, l.party_currency,
            SUM(CASE WHEN l.trans_nature = 'DR' THEN l.party_amount ELSE -l.party_amount END) AS signed_amount
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON  h.client_id   = l.client_id  AND h.company_id = l.company_id
            AND h.location_id = l.location_id AND h.trans_no  = l.trans_no
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.inv_bill_no IS NULL
          AND l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
          AND (
              (SELECT unrestricted FROM location_ok)
              OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                      AND ula.client_id = p_client_id AND ula.company_id = p_company_id
                                      AND ula.is_active = true AND ula.is_deleted = false)
          )
        GROUP BY l.client_id, l.company_id, l.location_id, l.account_id, l.trans_no, l.trans_date, l.party_currency
    ),
    advance_lines AS (
        SELECT
            pv.account_id, pv.party_currency,
            SUM(pv.signed_amount - COALESCE(s.settled_amt, 0)) AS signed_unsettled
        FROM advance_per_voucher pv
        LEFT JOIN (
            SELECT client_id, company_id, location_id, account_id, trans_no, trans_date,
                   SUM(paid_amount) AS settled_amt
            FROM rid_invoice_bill_settlement
            WHERE is_deleted = false
            GROUP BY client_id, company_id, location_id, account_id, trans_no, trans_date
        ) s ON  s.client_id   = pv.client_id   AND s.company_id  = pv.company_id
            AND s.location_id = pv.location_id AND s.account_id  = pv.account_id
            AND s.trans_no    = pv.trans_no    AND s.trans_date  = pv.trans_date
        GROUP BY pv.account_id, pv.party_currency
    ),
    accounts AS (
        SELECT
            a.id, a.account_code, a.account_name AS raw_account_name,
            a.parent_id, a.inter_entity_group_id,
            p.account_name AS group_name,
            -- Effective category override: inter-entity accounts are
            -- INCLUDED (confirmed by the user), just labelled distinctly
            -- for reporting purposes — the real party_category_id column
            -- is never touched.
            CASE WHEN a.inter_entity_group_id IS NOT NULL THEN 'Inter-Entity'
                 ELSE cm.description END AS category_name,
            CASE WHEN a.inter_entity_group_id IS NOT NULL THEN 'INTER-ENTITY'
                 ELSE a.party_category_id::text END AS category_key
        FROM rim_accounts a
        LEFT JOIN rim_accounts p ON p.id = a.parent_id AND p.client_id = a.client_id AND p.company_id = a.company_id
        LEFT JOIN rim_common_masters cm ON cm.id = a.party_category_id
        WHERE a.client_id = p_client_id AND a.company_id = p_company_id
          AND a.account_nature = p_account_nature
          AND a.posting_allowed = true AND a.is_deleted = false
    ),
    -- Every (account_id, party_currency) combination that has EITHER a
    -- bill or an advance — a plain LEFT JOIN on account_id alone (without
    -- also matching party_currency) would cross-multiply an account that
    -- has bills in one currency and an advance in a different one,
    -- silently pairing bucket amounts from currency A with unsettled
    -- advance from currency B in a single output row. Caught in review,
    -- not live — an account transacting in more than one party_currency
    -- is an edge case, but a real one this schema doesn't rule out.
    currency_keys AS (
        SELECT account_id, party_currency FROM bill_buckets
        UNION
        SELECT account_id, party_currency FROM advance_lines
    ),
    combined AS (
        SELECT
            acc.id AS account_id,
            ck.party_currency,
            acc.group_name,
            acc.category_name,
            '[' || acc.account_code || '] ' || acc.raw_account_name AS account_name,
            COALESCE(bb.bucket_0_30, 0)       AS bucket_0_30,
            COALESCE(bb.bucket_31_60, 0)      AS bucket_31_60,
            COALESCE(bb.bucket_61_90, 0)      AS bucket_61_90,
            COALESCE(bb.bucket_over_90, 0)    AS bucket_over_90,
            COALESCE(bb.total_outstanding, 0) AS total_outstanding,
            ABS(COALESCE(adv.signed_unsettled, 0)) AS unsettled_advance,
            acc.parent_id, acc.account_code, acc.category_key
        FROM accounts acc
        JOIN currency_keys ck ON ck.account_id = acc.id
        LEFT JOIN bill_buckets bb ON bb.account_id = ck.account_id AND bb.party_currency = ck.party_currency
        LEFT JOIN advance_lines adv ON adv.account_id = ck.account_id AND adv.party_currency = ck.party_currency
    )
    SELECT
        c.account_id, c.party_currency, c.group_name, c.category_name, c.account_name,
        c.bucket_0_30, c.bucket_31_60, c.bucket_61_90, c.bucket_over_90,
        c.total_outstanding, c.unsettled_advance,
        (c.total_outstanding - c.unsettled_advance) AS net_closing,
        LPAD(COALESCE(c.party_currency, ''), 8, '0') || '~' || LPAD(c.account_code, 12, '0') AS sort_key
    FROM combined c
    WHERE (p_group_id IS NULL OR c.parent_id = p_group_id)
      AND (p_category_id IS NULL OR c.category_key = p_category_id)
      AND (p_account_id IS NULL OR c.account_id = p_account_id)
      AND (p_currency IS NULL OR c.party_currency = p_currency);
      -- ric_user_location_access is already applied inside bill_lines/
      -- advance_per_voucher above, at the source — not repeated here.
$$;

GRANT EXECUTE ON FUNCTION fn_party_ageing_lines_core(UUID, UUID, TEXT, UUID, TEXT, UUID, TEXT) TO authenticated;


-- ============================================================
-- Thin per-nature wrappers — what ric_report_definitions.source_object
-- actually names (PostgREST needs a directly callable, named function).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_customer_ageing_lines(
    p_client_id UUID, p_company_id UUID,
    p_group_id UUID DEFAULT NULL, p_category_id TEXT DEFAULT NULL,
    p_account_id UUID DEFAULT NULL, p_currency TEXT DEFAULT NULL
) RETURNS TABLE (
    account_id UUID, party_currency TEXT, group_name TEXT, category_name TEXT, account_name TEXT,
    bucket_0_30 NUMERIC, bucket_31_60 NUMERIC, bucket_61_90 NUMERIC, bucket_over_90 NUMERIC,
    total_outstanding NUMERIC, unsettled_advance NUMERIC, net_closing NUMERIC, sort_key TEXT
) LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_party_ageing_lines_core(p_client_id, p_company_id, 'Customer', p_group_id, p_category_id, p_account_id, p_currency);
$$;

GRANT EXECUTE ON FUNCTION fn_customer_ageing_lines(UUID, UUID, UUID, TEXT, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_supplier_ageing_lines(
    p_client_id UUID, p_company_id UUID,
    p_group_id UUID DEFAULT NULL, p_category_id TEXT DEFAULT NULL,
    p_account_id UUID DEFAULT NULL, p_currency TEXT DEFAULT NULL
) RETURNS TABLE (
    account_id UUID, party_currency TEXT, group_name TEXT, category_name TEXT, account_name TEXT,
    bucket_0_30 NUMERIC, bucket_31_60 NUMERIC, bucket_61_90 NUMERIC, bucket_over_90 NUMERIC,
    total_outstanding NUMERIC, unsettled_advance NUMERIC, net_closing NUMERIC, sort_key TEXT
) LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_party_ageing_lines_core(p_client_id, p_company_id, 'Supplier', p_group_id, p_category_id, p_account_id, p_currency);
$$;

GRANT EXECUTE ON FUNCTION fn_supplier_ageing_lines(UUID, UUID, UUID, TEXT, UUID, TEXT) TO authenticated;


-- ============================================================
-- Totals footer functions — single row, required since
-- totals_source_object must be a FUNCTION (report_repository.dart).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_customer_ageing_totals(
    p_client_id UUID, p_company_id UUID,
    p_group_id UUID DEFAULT NULL, p_category_id TEXT DEFAULT NULL,
    p_account_id UUID DEFAULT NULL, p_currency TEXT DEFAULT NULL
) RETURNS TABLE (
    bucket_0_30 NUMERIC, bucket_31_60 NUMERIC, bucket_61_90 NUMERIC, bucket_over_90 NUMERIC,
    total_outstanding NUMERIC, unsettled_advance NUMERIC, net_closing NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(bucket_0_30), 0), COALESCE(SUM(bucket_31_60), 0),
           COALESCE(SUM(bucket_61_90), 0), COALESCE(SUM(bucket_over_90), 0),
           COALESCE(SUM(total_outstanding), 0), COALESCE(SUM(unsettled_advance), 0),
           COALESCE(SUM(net_closing), 0)
    FROM fn_customer_ageing_lines(p_client_id, p_company_id, p_group_id, p_category_id, p_account_id, p_currency);
$$;

GRANT EXECUTE ON FUNCTION fn_customer_ageing_totals(UUID, UUID, UUID, TEXT, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_supplier_ageing_totals(
    p_client_id UUID, p_company_id UUID,
    p_group_id UUID DEFAULT NULL, p_category_id TEXT DEFAULT NULL,
    p_account_id UUID DEFAULT NULL, p_currency TEXT DEFAULT NULL
) RETURNS TABLE (
    bucket_0_30 NUMERIC, bucket_31_60 NUMERIC, bucket_61_90 NUMERIC, bucket_over_90 NUMERIC,
    total_outstanding NUMERIC, unsettled_advance NUMERIC, net_closing NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(bucket_0_30), 0), COALESCE(SUM(bucket_31_60), 0),
           COALESCE(SUM(bucket_61_90), 0), COALESCE(SUM(bucket_over_90), 0),
           COALESCE(SUM(total_outstanding), 0), COALESCE(SUM(unsettled_advance), 0),
           COALESCE(SUM(net_closing), 0)
    FROM fn_supplier_ageing_lines(p_client_id, p_company_id, p_group_id, p_category_id, p_account_id, p_currency);
$$;

GRANT EXECUTE ON FUNCTION fn_supplier_ageing_totals(UUID, UUID, UUID, TEXT, UUID, TEXT) TO authenticated;


-- ============================================================
-- Group-level-1 summary functions — ric_report_group_levels' own
-- summary_source_object, GROUP BY party_currency over the same core.
-- Same params as the detail function (no ancestor-key parameter needed
-- — this is a 1-level report, unlike 118's 2-level pilot).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_customer_ageing_summary_by_currency(
    p_client_id UUID, p_company_id UUID,
    p_group_id UUID DEFAULT NULL, p_category_id TEXT DEFAULT NULL,
    p_account_id UUID DEFAULT NULL, p_currency TEXT DEFAULT NULL
) RETURNS TABLE (
    party_currency TEXT, bucket_0_30 NUMERIC, bucket_31_60 NUMERIC, bucket_61_90 NUMERIC,
    bucket_over_90 NUMERIC, total_outstanding NUMERIC, unsettled_advance NUMERIC,
    net_closing NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT party_currency,
           COALESCE(SUM(bucket_0_30), 0), COALESCE(SUM(bucket_31_60), 0),
           COALESCE(SUM(bucket_61_90), 0), COALESCE(SUM(bucket_over_90), 0),
           COALESCE(SUM(total_outstanding), 0), COALESCE(SUM(unsettled_advance), 0),
           COALESCE(SUM(net_closing), 0), COUNT(*)
    FROM fn_customer_ageing_lines(p_client_id, p_company_id, p_group_id, p_category_id, p_account_id, p_currency)
    GROUP BY party_currency;
$$;

GRANT EXECUTE ON FUNCTION fn_customer_ageing_summary_by_currency(UUID, UUID, UUID, TEXT, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_supplier_ageing_summary_by_currency(
    p_client_id UUID, p_company_id UUID,
    p_group_id UUID DEFAULT NULL, p_category_id TEXT DEFAULT NULL,
    p_account_id UUID DEFAULT NULL, p_currency TEXT DEFAULT NULL
) RETURNS TABLE (
    party_currency TEXT, bucket_0_30 NUMERIC, bucket_31_60 NUMERIC, bucket_61_90 NUMERIC,
    bucket_over_90 NUMERIC, total_outstanding NUMERIC, unsettled_advance NUMERIC,
    net_closing NUMERIC, row_count BIGINT
) LANGUAGE sql STABLE AS $$
    SELECT party_currency,
           COALESCE(SUM(bucket_0_30), 0), COALESCE(SUM(bucket_31_60), 0),
           COALESCE(SUM(bucket_61_90), 0), COALESCE(SUM(bucket_over_90), 0),
           COALESCE(SUM(total_outstanding), 0), COALESCE(SUM(unsettled_advance), 0),
           COALESCE(SUM(net_closing), 0), COUNT(*)
    FROM fn_supplier_ageing_lines(p_client_id, p_company_id, p_group_id, p_category_id, p_account_id, p_currency)
    GROUP BY party_currency;
$$;

GRANT EXECUTE ON FUNCTION fn_supplier_ageing_summary_by_currency(UUID, UUID, UUID, TEXT, UUID, TEXT) TO authenticated;


-- ============================================================
-- Registry seeding — per company, both reports in the same loop
-- (same shape as migration 118's own multi-report single-loop pattern).
-- No existing menu placeholder for either report (grepped
-- ric_master_menus/fn_seed_client_modules.sql across every migration —
-- zero hits for "ageing"/"aging" anywhere) — genuinely new feature
-- codes, following the established FN-RPT-XXX convention (FN-RPT-LDG
-- Account Ledger, FN-RPT-PBG Pending Bills by Customer). Serial numbers
-- 7/8 — 3-6 already taken (confirmed via direct grep, no gap).
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_fn_module_id UUID;
    v_report_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_fn_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'FN';

        CONTINUE WHEN v_fn_module_id IS NULL;

        -- ---------------- Customer Ageing ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, 'CUSTOMER_AGEING', 'Customer Ageing',
             'TABULAR', 'FUNCTION', 'fn_customer_ageing_lines', 'FN',
             'sort_key', 'ASC', 200, 'fn_customer_ageing_totals')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object = excluded.source_object,
                default_sort_column = excluded.default_sort_column,
                default_sort_dir = excluded.default_sort_dir,
                default_page_size = excluded.default_page_size,
                totals_source_object = excluded.totals_source_object
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            -- sortable=false everywhere: row order IS the currency/account
            -- sort_key order — a header click would break the currency
            -- grouping. party_currency is default_visible=false at the
            -- detail-row level since it's already shown via the currency
            -- group header. default_width sums to 950 (>700) so the
            -- existing report_pdf_export.dart width heuristic auto-selects
            -- landscape.
            (v_company.client_id, v_company.company_id, v_report_id, 'party_currency',     'Currency',              'TEXT',   'LEFT',  false, false, 80,  1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'group_name',         'Group Name',            'TEXT',   'LEFT',  false, true,  140, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_name',      'Category',              'TEXT',   'LEFT',  false, true,  120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name',       'Customer Name',         'TEXT',   'LEFT',  false, true,  180, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_0_30',        '0-30 Days',             'NUMBER', 'RIGHT', false, true,  100, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_31_60',       '31-60 Days',            'NUMBER', 'RIGHT', false, true,  100, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_61_90',       '61-90 Days',            'NUMBER', 'RIGHT', false, true,  100, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_over_90',     '>90 Days',              'NUMBER', 'RIGHT', false, true,  100, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'total_outstanding',  'Total Outstanding',     'NUMBER', 'RIGHT', false, true,  120, 9, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'unsettled_advance',  'Unsettled Advance',     'NUMBER', 'RIGHT', false, true,  120, 10, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'net_closing',        'Net Closing',           'NUMBER', 'RIGHT', false, true,  120, 11, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'sort_key',           'Sort',                  'TEXT',   'LEFT',  false, false, 0,   12, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, param_target, required, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'group_id', 'Group Name', 'DROPDOWN_LOOKUP',
                'v_party_account_groups_lookup', 'group_name', 'group_id', false, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP',
                'v_customer_categories_lookup', 'category_name', 'category_id', false, 2),
            -- lookup_source repurposed here to hold an account_nature
            -- restriction (see sakal_report_filter_bar.dart's
            -- FINANCE_ACCOUNT_PICKER case) — scopes this picker to
            -- Customer accounts only, not every postable account.
            (v_company.client_id, v_company.company_id, v_report_id, 'account_id', 'Customer Name', 'FINANCE_ACCOUNT_PICKER',
                'Customer', NULL, 'account_id', false, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'currency', 'Currency', 'DROPDOWN_LOOKUP',
                'v_party_currencies_lookup', 'currency_code', 'currency', false, 4);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'party_currency', 'party_currency', 'fn_customer_ageing_summary_by_currency');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-CAG', 'Customer Ageing',
             '/reports/CUSTOMER_AGEING', 7, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

        -- ---------------- Supplier Ageing ----------------
        INSERT INTO ric_report_definitions
            (client_id, company_id, report_key, report_name, report_type, source_type, source_object,
             module_code, default_sort_column, default_sort_dir, default_page_size, totals_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, 'SUPPLIER_AGEING', 'Supplier Ageing',
             'TABULAR', 'FUNCTION', 'fn_supplier_ageing_lines', 'FN',
             'sort_key', 'ASC', 200, 'fn_supplier_ageing_totals')
        ON CONFLICT (client_id, company_id, report_key) DO UPDATE
            SET report_name = excluded.report_name,
                source_object = excluded.source_object,
                default_sort_column = excluded.default_sort_column,
                default_sort_dir = excluded.default_sort_dir,
                default_page_size = excluded.default_page_size,
                totals_source_object = excluded.totals_source_object
        RETURNING id INTO v_report_id;

        DELETE FROM ric_report_columns WHERE report_id = v_report_id;
        INSERT INTO ric_report_columns
            (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
             default_width, sort_order, aggregate_fn)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'party_currency',     'Currency',              'TEXT',   'LEFT',  false, false, 80,  1, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'group_name',         'Group Name',            'TEXT',   'LEFT',  false, true,  140, 2, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_name',      'Category',              'TEXT',   'LEFT',  false, true,  120, 3, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_name',       'Supplier Name',         'TEXT',   'LEFT',  false, true,  180, 4, NULL),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_0_30',        '0-30 Days',             'NUMBER', 'RIGHT', false, true,  100, 5, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_31_60',       '31-60 Days',            'NUMBER', 'RIGHT', false, true,  100, 6, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_61_90',       '61-90 Days',            'NUMBER', 'RIGHT', false, true,  100, 7, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'bucket_over_90',     '>90 Days',              'NUMBER', 'RIGHT', false, true,  100, 8, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'total_outstanding',  'Total Outstanding',     'NUMBER', 'RIGHT', false, true,  120, 9, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'unsettled_advance',  'Unsettled Advance',     'NUMBER', 'RIGHT', false, true,  120, 10, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'net_closing',        'Net Closing',           'NUMBER', 'RIGHT', false, true,  120, 11, 'SUM'),
            (v_company.client_id, v_company.company_id, v_report_id, 'sort_key',           'Sort',                  'TEXT',   'LEFT',  false, false, 0,   12, NULL);

        DELETE FROM ric_report_filters WHERE report_id = v_report_id;
        INSERT INTO ric_report_filters
            (client_id, company_id, report_id, filter_key, label, filter_type, lookup_source,
             lookup_label_column, param_target, required, sort_order)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 'group_id', 'Group Name', 'DROPDOWN_LOOKUP',
                'v_party_account_groups_lookup', 'group_name', 'group_id', false, 1),
            (v_company.client_id, v_company.company_id, v_report_id, 'category_id', 'Category', 'DROPDOWN_LOOKUP',
                'v_supplier_categories_lookup', 'category_name', 'category_id', false, 2),
            (v_company.client_id, v_company.company_id, v_report_id, 'account_id', 'Supplier Name', 'FINANCE_ACCOUNT_PICKER',
                'Supplier', NULL, 'account_id', false, 3),
            (v_company.client_id, v_company.company_id, v_report_id, 'currency', 'Currency', 'DROPDOWN_LOOKUP',
                'v_party_currencies_lookup', 'currency_code', 'currency', false, 4);

        DELETE FROM ric_report_group_levels WHERE report_id = v_report_id;
        INSERT INTO ric_report_group_levels
            (client_id, company_id, report_id, level_no, group_by_column, group_label_column, summary_source_object)
        VALUES
            (v_company.client_id, v_company.company_id, v_report_id, 1, 'party_currency', 'party_currency', 'fn_supplier_ageing_summary_by_currency');

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-RPT-SAG', 'Supplier Ageing',
             '/reports/SUPPLIER_AGEING', 8, 'FN-RPT', 'Reports', 1, false, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, feature_name = excluded.feature_name;

    END LOOP;
END $$;


-- ============================================================
-- ric_user_menus backfill (same pattern as 127/132/135's own Part D): a
-- ric_master_menus row alone makes a feature ELIGIBLE, it grants nobody
-- anything. Give VIEW access to whoever already has view access to any
-- other Finance (FN) feature.
-- ============================================================
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
WHERE mm.feature_code IN ('FN-RPT-CAG', 'FN-RPT-SAG')
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
