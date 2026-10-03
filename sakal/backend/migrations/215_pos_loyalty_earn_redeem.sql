-- ============================================================================
-- Migration 215: loyalty earn/redeem — additive functions, never touching
-- fn_approve_sales_invoice's own large, delicate GL-posting body.
-- ============================================================================
-- fn_set_invoice_loyalty: called right after fn_save_sales_invoice (DRAFT
-- still), sets the 3 loyalty columns added in migration 214. Kept as its
-- own tiny function rather than folding into fn_save_sales_invoice's own
-- reproduction, to avoid a third full verbatim reproduction of that large
-- function for 3 columns that never affect pricing/tax/GL at save time.
--
-- fn_post_loyalty_for_sales_invoice: called by the client immediately after
-- a successful fn_approve_sales_invoice. Idempotent (checks for an existing
-- EARN ledger row for this invoice before posting again) and deliberately
-- NOT embedded inside fn_approve_sales_invoice itself — a loyalty-posting
-- failure must never block or roll back the sale itself; the client treats
-- this call's own failure as a soft, logged warning, not a sale failure.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_set_invoice_loyalty(
    p_client_id              UUID,
    p_company_id             UUID,
    p_invoice_no             TEXT,
    p_invoice_date           DATE,
    p_loyalty_profile_id     UUID,
    p_points_redeemed        NUMERIC DEFAULT 0,
    p_redeem_value_amount    NUMERIC DEFAULT 0
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE rih_sales_invoices SET
        loyalty_profile_id          = p_loyalty_profile_id,
        loyalty_points_redeemed     = coalesce(p_points_redeemed, 0),
        loyalty_redeem_value_amount = coalesce(p_redeem_value_amount, 0)
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date
      AND status = 'DRAFT';
END;
$$;
GRANT EXECUTE ON FUNCTION fn_set_invoice_loyalty(UUID, UUID, TEXT, DATE, UUID, NUMERIC, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION fn_post_loyalty_for_sales_invoice(
    p_client_id   UUID,
    p_company_id  UUID,
    p_invoice_no  TEXT,
    p_invoice_date DATE,
    p_user_id     UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_header        rih_sales_invoices%ROWTYPE;
    v_program       rim_loyalty_programs%ROWTYPE;
    v_qualifying    NUMERIC;
    v_points_earned NUMERIC;
BEGIN
    SELECT * INTO v_header FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date;

    IF NOT FOUND OR v_header.loyalty_profile_id IS NULL OR v_header.status != 'APPROVED' THEN
        RETURN;
    END IF;

    -- Idempotency guard: never double-post for the same invoice.
    IF EXISTS (
        SELECT 1 FROM ril_loyalty_ledger
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND source_doc_type = 'SALES_INVOICE' AND source_doc_no = p_invoice_no
    ) THEN
        RETURN;
    END IF;

    SELECT * INTO v_program FROM rim_loyalty_programs
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND is_active = true AND is_deleted = false
    ORDER BY created_at ASC LIMIT 1;

    IF NOT FOUND THEN
        RETURN;  -- no loyalty program configured — nothing to earn/redeem
    END IF;

    IF coalesce(v_header.loyalty_points_redeemed, 0) > 0 THEN
        INSERT INTO ril_loyalty_ledger (
            client_id, company_id, loyalty_profile_id, trans_type, points_change,
            source_doc_type, source_doc_no, source_doc_date, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.loyalty_profile_id, 'REDEEM', -v_header.loyalty_points_redeemed,
            'SALES_INVOICE', p_invoice_no, p_invoice_date, p_user_id
        );
    END IF;

    v_qualifying := CASE v_program.earn_basis
                        WHEN 'POST_TAX' THEN v_header.grand_total
                        ELSE v_header.grand_total - v_header.tax_amount  -- PRE_TAX and POST_DISCOUNT both exclude tax here (both discount+scheme already baked into grand_total)
                    END * v_header.rate_to_base;
    v_points_earned := round(greatest(v_qualifying, 0) * coalesce(v_program.points_per_amount, 0), 2);

    IF v_points_earned > 0 THEN
        INSERT INTO ril_loyalty_ledger (
            client_id, company_id, loyalty_profile_id, trans_type, points_change,
            source_doc_type, source_doc_no, source_doc_date, created_by
        ) VALUES (
            p_client_id, p_company_id, v_header.loyalty_profile_id, 'EARN', v_points_earned,
            'SALES_INVOICE', p_invoice_no, p_invoice_date, p_user_id
        );
    END IF;

    UPDATE rih_customer_loyalty_profiles SET
        points_balance = (SELECT coalesce(sum(points_change), 0) FROM ril_loyalty_ledger WHERE loyalty_profile_id = v_header.loyalty_profile_id)
    WHERE id = v_header.loyalty_profile_id;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_post_loyalty_for_sales_invoice(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
