-- ============================================================
-- Migration 235: Purchase Reports — 2 real bugs found live, fixed
-- ============================================================
-- Found during the 2026-10-25 browser-E2E pass (Purchase Reports batch),
-- same network-request-tracing discipline that caught Day Book/Cheque
-- Register's bug earlier this session (migrations 233/234).

-- ------------------------------------------------------------
-- Bug 1: Vendor On-Time Delivery -- totals RPC 404
-- ------------------------------------------------------------
-- Same root-cause SHAPE as Cheque Register (migration 234): this report
-- has no ric_report_group_levels row, so its main grid query hits the
-- v_purchase_order_delivery VIEW directly via PostgREST column filters,
-- where param_target correctly matches the view's own
-- expected_delivery_date column (confirmed via information_schema) --
-- the filter config itself is correct and must NOT change. The actual
-- bug is narrower: fn_purchase_order_delivery_totals (the report's
-- totals_source_object, used for the footer Total row) declared its own
-- date parameters as p_expected_date_from/p_expected_date_to instead of
-- p_expected_delivery_date_from/p_expected_delivery_date_to, so the
-- engine's p_${param_target}_from/_to construction never matched any
-- overload. DROP FUNCTION + CREATE (not CREATE OR REPLACE alone) since
-- Postgres disallows renaming an IN parameter through REPLACE. Full
-- body reproduced verbatim (via pg_get_functiondef) from the live
-- function, only the two parameter names + their references changed.

DROP FUNCTION IF EXISTS fn_purchase_order_delivery_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT);

CREATE OR REPLACE FUNCTION fn_purchase_order_delivery_totals(
    p_client_id  UUID,
    p_company_id UUID,
    p_expected_delivery_date_from DATE DEFAULT NULL,
    p_expected_delivery_date_to   DATE DEFAULT NULL,
    p_supplier_id UUID DEFAULT NULL,
    p_location_id UUID DEFAULT NULL,
    p_product_id  UUID DEFAULT NULL,
    p_delivery_status TEXT DEFAULT NULL
) RETURNS TABLE(row_count bigint) LANGUAGE sql STABLE AS $function$
    SELECT COUNT(*)
    FROM v_purchase_order_delivery
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND (p_expected_delivery_date_from IS NULL OR expected_delivery_date >= p_expected_delivery_date_from)
      AND (p_expected_delivery_date_to   IS NULL OR expected_delivery_date <= p_expected_delivery_date_to)
      AND (p_supplier_id  IS NULL OR supplier_id = p_supplier_id)
      AND (p_location_id  IS NULL OR location_id = p_location_id)
      AND (p_product_id   IS NULL OR product_id  = p_product_id)
      AND (p_delivery_status IS NULL OR delivery_status = p_delivery_status);
$function$;

GRANT EXECUTE ON FUNCTION fn_purchase_order_delivery_totals(
    UUID, UUID, DATE, DATE, UUID, UUID, UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------
-- Bug 2: Reorder / Replenishment -- default-ON filter targets a
-- nonexistent view column
-- ------------------------------------------------------------
-- below_reorder_only is a BOOLEAN filter whose param_target maps
-- directly onto a raw PostgREST column-equality filter
-- (below_reorder_only=eq.true) against v_reorder_replenishment -- but
-- that view has no such column at all (it's a derived condition:
-- current_stock < reorder_level), confirmed via information_schema.
-- Worse, this filter's default_value='true' means the report fails its
-- very first, default-filters "Run Report" click every time -- not an
-- edge case. Fix: add the computed boolean column the filter already
-- expects. View body below is the LIVE definition fetched directly via
-- pg_get_viewdef (never hand-retyped -- a first attempt at manually
-- reproducing this exact WHERE clause introduced a paren-count typo and
-- failed to deploy), with only the one new trailing column inserted by
-- script, same WITH (security_invoker = true) preserved per this
-- project's own mandatory CREATE VIEW rule (CLAUDE.md).

CREATE OR REPLACE VIEW v_reorder_replenishment AS
 SELECT rpl.client_id,
    rpl.company_id,
    rpl.product_id,
    p.product_code,
    p.product_name,
    p.category_id,
    p.brand_id,
    rpl.location_id,
    loc.location_name,
    rpl.current_stock,
    rpl.reorder_level,
    rpl.min_stock_qty,
    rpl.max_stock_qty,
    GREATEST(rpl.max_stock_qty - rpl.current_stock, 0::numeric) AS suggested_reorder_qty,
    COALESCE(( SELECT sum(po.qty_pending) AS sum
           FROM v_pending_purchase_orders po
          WHERE po.client_id = rpl.client_id AND po.company_id = rpl.company_id AND po.product_id = rpl.product_id AND po.location_id = rpl.location_id), 0::numeric) AS open_po_qty,
    p.main_supplier_id,
    ms.account_name AS main_supplier_name,
    p.lead_time_days,
    p.last_purchase_cost,
    (rpl.current_stock < rpl.reorder_level) AS below_reorder_only
   FROM rim_product_location rpl
     JOIN rim_products p ON p.id = rpl.product_id
     LEFT JOIN ric_locations loc ON loc.id = rpl.location_id
     LEFT JOIN rim_accounts ms ON ms.id = p.main_supplier_id
  WHERE p.is_deleted = false AND p.is_active = true AND (NOT (EXISTS ( SELECT 1
           FROM ric_user_location_access ula
          WHERE ula.user_id = ((current_setting('request.jwt.claims'::text, true)::json ->> 'user_id'::text)::uuid) AND ula.client_id = rpl.client_id AND ula.company_id = rpl.company_id AND ula.is_active = true AND ula.is_deleted = false)) OR (rpl.location_id IN ( SELECT ula.location_id
           FROM ric_user_location_access ula
          WHERE ula.user_id = ((current_setting('request.jwt.claims'::text, true)::json ->> 'user_id'::text)::uuid) AND ula.client_id = rpl.client_id AND ula.company_id = rpl.company_id AND ula.is_active = true AND ula.is_deleted = false)))
;

ALTER VIEW v_reorder_replenishment SET (security_invoker = true);

GRANT SELECT ON v_reorder_replenishment TO anon, authenticated, service_role;
