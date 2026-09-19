-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 192 — Reset All Products (Bulk Upload Products "start over")
--
-- A tenant that has just uploaded Product Master and found data-quality
-- issues (wrong category tree, wrong tax groups, etc.) needs a clean way to
-- wipe every product and re-upload, WITHOUT falling into the "reuse vs
-- duplicate soft-deleted row" complexity the ordinary reuse-existing-master
-- logic has (see CLAUDE.md's plain-UNIQUE-constraint note). This is safe
-- ONLY before any transaction has ever been posted against any product —
-- a company-wide gate, never a per-product one, so a reset never leaves a
-- confusing mix of old and new product codes/categories behind.
--
-- fn_can_reset_all_products follows the exact NULL-is-safe / TEXT-reason
-- convention already established in migration 130 (fn_can_change_product_
-- base_uom etc.) — checks every table that records product activity, not
-- just ril_stock_ledger, since PO/Quotation/Order/Price-Master lines never
-- touch the stock ledger at all and would otherwise be silently missed.
--
-- fn_reset_all_products re-runs the same check itself (never trusts that a
-- client-side pre-check still holds by the time Save actually runs) before
-- hard-deleting every product + its child rows. Hard delete, not soft
-- delete: since the check just proved zero transactions ever referenced
-- these rows, nothing depends on keeping them for audit trail, and hard
-- delete avoids reintroducing the soft-delete name-collision problem on the
-- very next upload.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── fn_can_reset_all_products ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_can_reset_all_products(
    p_client_id  UUID,
    p_company_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_product_count INTEGER;
BEGIN
    SELECT count(*) INTO v_product_count
    FROM rim_products
    WHERE client_id = p_client_id AND company_id = p_company_id;

    IF v_product_count = 0 THEN
        RETURN 'There are no products to reset.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM ril_cost_price_history
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_grn_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_purchase_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_material_requisition_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_stock_transfer_request_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_stock_transfer_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_stock_receipt_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_stock_adjustment_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_opening_stock_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_stock_count_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_sales_quotation_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_sales_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_sales_invoice_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_sales_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_sales_delivery_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
        UNION ALL
        SELECT 1 FROM rid_price_master_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
    ) THEN
        RETURN format('One or more of the %s existing product(s) already have transaction history (stock movement, purchase, sale, or price history). Reset is only available before any transaction exists for any product in this company.', v_product_count);
    END IF;

    RETURN NULL;
END;
$$;

-- ── fn_reset_all_products ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_reset_all_products(
    p_client_id  UUID,
    p_company_id UUID
) RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_block_reason  TEXT;
    v_deleted_count INTEGER;
BEGIN
    v_block_reason := fn_can_reset_all_products(p_client_id, p_company_id);
    IF v_block_reason IS NOT NULL THEN
        RAISE EXCEPTION 'PRODUCTS_HAVE_TRANSACTIONS' USING DETAIL = v_block_reason;
    END IF;

    SELECT count(*) INTO v_deleted_count
    FROM rim_products
    WHERE client_id = p_client_id AND company_id = p_company_id;

    DELETE FROM rim_product_media
    WHERE client_id = p_client_id AND company_id = p_company_id;

    DELETE FROM rim_product_uom
    WHERE client_id = p_client_id AND company_id = p_company_id;

    DELETE FROM rim_account_links
    WHERE client_id = p_client_id AND company_id = p_company_id AND product_id IS NOT NULL;

    DELETE FROM rim_product_location
    WHERE client_id = p_client_id AND company_id = p_company_id;

    DELETE FROM rim_products
    WHERE client_id = p_client_id AND company_id = p_company_id;

    RETURN v_deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION fn_can_reset_all_products(UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION fn_reset_all_products(UUID, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION fn_can_reset_all_products(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_reset_all_products(UUID, UUID) TO authenticated;
