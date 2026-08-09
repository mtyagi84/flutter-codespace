-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 130 — Delete/change guards (Phase 3 of the Sales Invoice Test
-- bugs.docx fix pass). None of these had ANY server-side enforcement before
-- this migration — every one of the 6 screens below let the user delete a
-- master row or change a locked-down field with zero check against real
-- transaction data, even though the resulting orphaned/inconsistent state
-- would silently corrupt reports and postings downstream.
--
-- Each function RETURNS TEXT: NULL means "the action is safe, proceed";
-- a non-null value is the human-readable reason it's blocked (never a raw
-- id/count with no context — same "Error messages — never a raw ID" rule
-- CLAUDE.md documents for every other RAISE EXCEPTION in this schema).
-- Callers on the Flutter side call the function first and show the reason
-- via ErrorPresenter-style messaging before attempting the actual
-- PATCH/soft-delete — this is a pre-check, not a substitute for RLS/
-- ownership checks, which stay exactly as they already are.
--
-- Scope note: rather than enumerating every one of the ~25 transaction
-- header/line tables in this schema per guard, each function checks the
-- schema's own existing "single source of truth" aggregates wherever one
-- exists (ril_stock_ledger for all stock movement, rid_finance_lines for
-- all GL postings) plus the specific direct-reference tables named in the
-- plan. This mirrors the project's own documented precedent (e.g.
-- fn_verify_stock_integrity, the Stock Count variance engine) of trusting
-- the ledger as the authoritative record rather than re-deriving from every
-- individual module.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── fn_can_delete_location ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_can_delete_location(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_location_name TEXT;
BEGIN
    SELECT location_name INTO v_location_name
    FROM ric_locations
    WHERE id = p_location_id AND client_id = p_client_id AND company_id = p_company_id;

    IF EXISTS (
        SELECT 1 FROM rim_users
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND default_location_id = p_location_id AND is_deleted = false
    ) THEN
        RETURN format('Location [%s] is still assigned to one or more users as their default location.', v_location_name);
    END IF;

    IF EXISTS (
        SELECT 1 FROM ric_user_location_access
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = p_location_id
    ) THEN
        RETURN format('Location [%s] is still granted to one or more users via Location Access.', v_location_name);
    END IF;

    IF EXISTS (
        SELECT 1 FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = p_location_id
    ) THEN
        RETURN format('Location [%s] has stock movement history and cannot be deleted.', v_location_name);
    END IF;

    IF EXISTS (
        SELECT 1 FROM rih_finance_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND location_id = p_location_id
    ) THEN
        RETURN format('Location [%s] has posted financial transactions and cannot be deleted.', v_location_name);
    END IF;

    RETURN NULL;
END;
$$;

-- ── fn_can_delete_user ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_can_delete_user(
    p_client_id  UUID,
    p_company_id UUID,
    p_user_id    UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_name TEXT;
BEGIN
    SELECT full_name INTO v_user_name
    FROM rim_users
    WHERE id = p_user_id AND client_id = p_client_id AND company_id = p_company_id;

    IF EXISTS (
        SELECT 1 FROM ric_location_groups
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND responsible_user_id = p_user_id AND is_deleted = false
    ) THEN
        RETURN format('User [%s] is the responsible manager for one or more location groups.', v_user_name);
    END IF;

    IF EXISTS (
        SELECT 1 FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id AND created_by = p_user_id
    ) THEN
        RETURN format('User [%s] has posted stock transactions and cannot be deleted.', v_user_name);
    END IF;

    IF EXISTS (
        SELECT 1 FROM rih_finance_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND (created_by = p_user_id OR posted_by = p_user_id)
    ) THEN
        RETURN format('User [%s] has created or posted financial transactions and cannot be deleted.', v_user_name);
    END IF;

    RETURN NULL;
END;
$$;

-- ── fn_can_delete_item_category ─────────────────────────────────────────
-- Sub-category check is already correctly enforced client-side
-- (item_categories_screen.dart) — this only closes the missing
-- product-reference gap the plan called out.
CREATE OR REPLACE FUNCTION fn_can_delete_item_category(
    p_client_id   UUID,
    p_company_id  UUID,
    p_category_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_category_name TEXT;
    v_product_count  INTEGER;
BEGIN
    SELECT category_name INTO v_category_name
    FROM rim_item_categories
    WHERE id = p_category_id AND client_id = p_client_id AND company_id = p_company_id;

    SELECT count(*) INTO v_product_count
    FROM rim_products
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND category_id = p_category_id AND is_deleted = false;

    IF v_product_count > 0 THEN
        RETURN format('Category [%s] is used by %s product(s) and cannot be deleted.', v_category_name, v_product_count);
    END IF;

    RETURN NULL;
END;
$$;

-- ── fn_can_change_account_currency ──────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_can_change_account_currency(
    p_client_id  UUID,
    p_company_id UUID,
    p_account_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_account_code TEXT;
    v_account_name TEXT;
BEGIN
    SELECT account_code, account_name INTO v_account_code, v_account_name
    FROM rim_accounts
    WHERE id = p_account_id AND client_id = p_client_id AND company_id = p_company_id;

    IF EXISTS (
        SELECT 1 FROM rid_finance_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND account_id = p_account_id AND is_deleted = false
    ) THEN
        RETURN format('Account [%s] %s has posted transactions and its Currency can no longer be changed.', v_account_code, v_account_name);
    END IF;

    RETURN NULL;
END;
$$;

-- ── fn_can_delete_consumption_area ──────────────────────────────────────
-- consumption_area_id on every transaction line references rim_common_masters
-- directly (the same id rim_department_consumption_areas.consumption_area_id
-- points to) — see migration 066's own design note in CLAUDE.md.
CREATE OR REPLACE FUNCTION fn_can_delete_consumption_area(
    p_client_id          UUID,
    p_company_id         UUID,
    p_consumption_area_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_area_name TEXT;
BEGIN
    SELECT description INTO v_area_name
    FROM rim_common_masters
    WHERE id = p_consumption_area_id AND client_id = p_client_id AND company_id = p_company_id;

    IF EXISTS (
        SELECT 1 FROM rid_purchase_order_lines
        WHERE client_id = p_client_id AND company_id = p_company_id AND consumption_area_id = p_consumption_area_id
        UNION ALL
        SELECT 1 FROM rid_grn_lines
        WHERE client_id = p_client_id AND company_id = p_company_id AND consumption_area_id = p_consumption_area_id
        UNION ALL
        SELECT 1 FROM rid_material_requisition_lines
        WHERE client_id = p_client_id AND company_id = p_company_id AND consumption_area_id = p_consumption_area_id
        UNION ALL
        SELECT 1 FROM rid_material_issue_lines
        WHERE client_id = p_client_id AND company_id = p_company_id AND consumption_area_id = p_consumption_area_id
    ) THEN
        RETURN format('Consumption Area [%s] has transactions posted against it and cannot be deleted.', v_area_name);
    END IF;

    RETURN NULL;
END;
$$;

-- ── fn_can_change_product_base_uom ──────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_can_change_product_base_uom(
    p_client_id  UUID,
    p_company_id UUID,
    p_product_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_product_code TEXT;
    v_product_name TEXT;
BEGIN
    SELECT product_code, product_name INTO v_product_code, v_product_name
    FROM rim_products
    WHERE id = p_product_id AND client_id = p_client_id AND company_id = p_company_id;

    IF EXISTS (
        SELECT 1 FROM ril_stock_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id AND product_id = p_product_id
    ) THEN
        RETURN format('Product [%s] %s has stock transaction history and its Base UOM can no longer be changed.', v_product_code, v_product_name);
    END IF;

    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION fn_can_delete_location(UUID, UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION fn_can_delete_user(UUID, UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION fn_can_delete_item_category(UUID, UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION fn_can_change_account_currency(UUID, UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION fn_can_delete_consumption_area(UUID, UUID, UUID) FROM anon;
REVOKE ALL ON FUNCTION fn_can_change_product_base_uom(UUID, UUID, UUID) FROM anon;
GRANT EXECUTE ON FUNCTION fn_can_delete_location(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_can_delete_user(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_can_delete_item_category(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_can_change_account_currency(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_can_delete_consumption_area(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_can_change_product_base_uom(UUID, UUID, UUID) TO authenticated;
