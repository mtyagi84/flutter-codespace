-- ============================================================
-- Migration 186: Reporting Engine fixes found by the full-suite
-- backend-RPC smoke test (test/backend/reports_smoke_backend_test.dart,
-- 2026-09-14) — the first time all 79 report definitions were ever
-- exercised end-to-end against a real tenant in one pass.
-- ============================================================
--
-- Two independent real bugs found, both fixed here:
--
-- 1. ric_product_movement_snapshot lost its readability the moment
--    migration 185 correctly applied `security_invoker = true` to EVERY
--    view app-wide (closing the real cross-tenant RLS-bypass bug that
--    migration fixed). v_product_movement_analysis was built on the
--    OPPOSITE assumption — its own comment says "No RLS on this table
--    itself...access control enforced entirely via the JOIN to
--    ric_report_jobs" — which only works when the view runs with the
--    OWNER's rights (security_invoker = false), not the querying user's.
--    185's blanket fix was still the right call (this exact view being an
--    unnoticed exception is why "no exceptions" is the correct default),
--    but this one view's access-control design needed a real follow-up:
--    give the table its OWN RLS, scoped through its own job_id back to
--    the already-RLS-designed ric_report_jobs (client_id/company_id AND
--    submitted_by — "user-wise", per that table's own migration 156
--    comment), then grant SELECT to authenticated. This is NOT a plain
--    client_id/company_id policy (this table has neither column itself)
--    — it's an EXISTS subquery against the owning job row.
--
-- 2. FIVE report filter rows have a `param_target` that names a column
--    which does not exist on that report's own `source_object` — every
--    one of these reports has had a genuinely broken date filter since
--    the migration that created it, invisible until a real end-to-end
--    call was made (a UI click-test with an empty date field, or a
--    "Run Report" whose filter panel just shows blank options, would
--    both easily miss this — it only 400s once a real date value is
--    actually supplied):
--      - VENDOR_ON_TIME_DELIVERY   (158): 'expected_date'      -> v_purchase_order_delivery has 'expected_delivery_date'
--      - DAY_BOOK_REGISTER          (166): 'date'               -> v_finance_voucher_lines has 'trans_date'
--      - CHEQUE_REGISTER            (166): 'date'               -> v_cheque_register has 'trans_date'
--      - VAT_TAX_RETURN_SUMMARY     (167): 'date'               -> v_vat_tax_lines has 'trans_date'
--      - WITHHOLDING_TAX_SUMMARY    (167): 'date'               -> v_withholding_tax_lines has 'trans_date'
--    Fixed as a plain data UPDATE on ric_report_filters — no view/
--    function change needed, the SOURCE columns were always correct.
-- ============================================================

-- ── 1. ric_product_movement_snapshot RLS ─────────────────────────────────
ALTER TABLE ric_product_movement_snapshot ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "auth_r_product_movement_snapshot" ON ric_product_movement_snapshot;
CREATE POLICY "auth_r_product_movement_snapshot" ON ric_product_movement_snapshot
    FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM ric_report_jobs j
        WHERE j.id = ric_product_movement_snapshot.job_id
          AND j.client_id    = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
          AND j.company_id   = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid
          AND j.submitted_by = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
    ));

REVOKE ALL ON ric_product_movement_snapshot FROM anon;
GRANT SELECT ON ric_product_movement_snapshot TO authenticated;
-- service_role keeps its own separate ALL grant from migration 156 —
-- untouched, still how fn_run_product_movement_analysis_job writes rows.


-- ── 2. Fix the 5 mismatched param_target values ──────────────────────────
UPDATE ric_report_filters f
SET param_target = 'expected_delivery_date'
FROM ric_report_definitions d
WHERE f.report_id = d.id
  AND d.report_key = 'VENDOR_ON_TIME_DELIVERY'
  AND f.param_target = 'expected_date';

UPDATE ric_report_filters f
SET param_target = 'trans_date'
FROM ric_report_definitions d
WHERE f.report_id = d.id
  AND d.report_key IN ('DAY_BOOK_REGISTER', 'CHEQUE_REGISTER', 'VAT_TAX_RETURN_SUMMARY', 'WITHHOLDING_TAX_SUMMARY')
  AND f.param_target = 'date';
