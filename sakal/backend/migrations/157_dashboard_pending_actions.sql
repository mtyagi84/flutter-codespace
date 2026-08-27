-- ============================================================
-- Migration 157: fn_dashboard_pending_actions — cross-module "what needs
--   my attention today" for the new Dashboard v1.
-- ============================================================
-- SAKAL has a DRAFT/pending-approval concept in every transaction module
-- but no existing cross-module aggregator — this is the first one. One
-- UNION ALL branch per document type, each gated by an EXISTS check
-- against ric_user_menus.approve_allowed for that feature_code — a branch
-- contributes ZERO rows (not a zero-count row) when the calling user can't
-- approve that feature, so the dashboard never lists a document type the
-- user has no authority over.
--
-- Two branches (Stock Adjustment, Journal Voucher) additionally filter
-- source_doc_type IS NULL — same guard migrations 111/112 already
-- established for the approve-permission checks themselves: an
-- auto-posted document (e.g. a Stock Adjustment created by approving a
-- Stock Count Review, or a JV posted by GRN's own accrual) is not a
-- separate pending item a human drafts and later approves by hand — it's
-- an internal side effect of approving something else, already counted
-- (if at all) under that OTHER document type's own branch.
--
-- No new tables, no reporting-engine registry rows — this is a small RPC
-- the Dashboard screen calls directly via DioClient, not a report.
--
-- Full design: sakal/docs/screens/plan_dashboard_v1.md
-- ============================================================

CREATE OR REPLACE FUNCTION fn_dashboard_pending_actions(
    p_client_id  UUID,
    p_company_id UUID,
    p_user_id    UUID
) RETURNS TABLE (
    document_type  TEXT,
    feature_code   TEXT,
    pending_count  BIGINT,
    route          TEXT
) LANGUAGE sql STABLE AS $$
    WITH allowed AS (
        SELECT feature_code FROM ric_user_menus
        WHERE client_id = p_client_id AND company_id = p_company_id AND user_id = p_user_id
          AND approve_allowed = true AND is_deleted = false
    )
    SELECT 'Sales Invoice', 'SL-INV', COUNT(*), '/sales/invoices'
    FROM rih_sales_invoices h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'SL-INV')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Sales Order', 'SL-SO', COUNT(*), '/sales/orders'
    FROM rih_sales_orders h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'SL-SO')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Sales Quotation', 'SL-QUO', COUNT(*), '/sales/quotations'
    FROM rih_sales_quotations h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'SL-QUO')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Purchase Order', 'PR-PO', COUNT(*), '/purchase/orders'
    FROM rih_purchase_orders h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'PR-PO')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'GRN', 'PR-GRN', COUNT(*), '/purchase/grn'
    FROM rih_grn_headers h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'PR-GRN')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Purchase Invoice', 'PR-INV', COUNT(*), '/purchase/invoices'
    FROM rih_purchase_invoices h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'PR-INV')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Stock Adjustment', 'IN-ADJ', COUNT(*), '/inventory/adjustments'
    FROM rih_stock_adjustment_headers h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND h.source_doc_type IS NULL
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'IN-ADJ')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Stock Transfer Request', 'IN-STR', COUNT(*), '/inventory/stock-transfer-requests'
    FROM rih_stock_transfer_requests h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'IN-STR')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Journal Voucher', 'FN-JRN', COUNT(*), '/finance/voucher-list'
    FROM rih_finance_headers h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.voucher_type_code = 'JV' AND h.is_posted = false AND h.is_deleted = false
      AND h.source_doc_type IS NULL
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'FN-JRN')
    HAVING COUNT(*) > 0

    UNION ALL

    SELECT 'Expense Voucher', 'FN-EXP', COUNT(*), '/finance/expense-vouchers'
    FROM rih_expense_voucher_headers h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.status = 'DRAFT' AND h.is_deleted = false
      AND EXISTS (SELECT 1 FROM allowed WHERE feature_code = 'FN-EXP')
    HAVING COUNT(*) > 0;
$$;

GRANT EXECUTE ON FUNCTION fn_dashboard_pending_actions(UUID, UUID, UUID) TO authenticated;
