-- ============================================================================
-- create_qa_reset_function.sql
--
-- Wraps reset_all_transactions.sql's exact logic as a callable RPC,
-- fn_reset_qa_tenant(), so the E2E test harness (tenant_reset.dart) can
-- reset the QA tenant between runs WITHOUT a service-role key or direct
-- Postgres connection — the locked decision in the approved E2E test
-- automation plan (reconfirmed 2026-09-12: PostgREST + JWT only).
--
-- SAFE BY CONSTRUCTION, not by a checked parameter: this function takes NO
-- arguments at all. The QA tenant's client_id/company_id are hardcoded
-- constants inside the function body (filled in below, after you've run
-- seed_qa_master_data.sql once) — it is structurally impossible to call
-- this function against any tenant other than the one baked in here, no
-- matter who calls it or what they pass. Blast radius is bounded to the
-- one QA tenant's own fake test data, same as reset_all_transactions.sql
-- itself, just invokable over PostgREST instead of pasted into the SQL
-- editor each time.
--
-- HOW TO USE:
--   1. Run seed_qa_master_data.sql first — it prints client_id/company_id.
--   2. Fill in v_client_id/v_company_id below with those exact values.
--   3. Run this whole script once in the Supabase SQL editor to create the
--      function (CREATE OR REPLACE — safe to re-run if you ever change the
--      hardcoded IDs, e.g. after recreating the QA tenant with a new email).
--   4. tenant_reset.dart calls it via POST /rest/v1/rpc/fn_reset_qa_tenant
--      (any authenticated JWT — the function's own hardcoded scope is what
--      keeps it safe, not who's calling it).
--
-- Table order is copied verbatim from reset_all_transactions.sql — see that
-- file's own header comment for the FK-dependency reasoning. Keep the two
-- files in sync if a future module adds a new transactional table.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_reset_qa_tenant()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    -- ── CUSTOMIZE: paste the QA tenant's IDs from seed_qa_master_data.sql ──
    v_client_id  UUID := '00000000-0000-0000-0000-000000000000';  -- PASTE
    v_company_id UUID := '00000000-0000-0000-0000-000000000000';  -- PASTE
BEGIN
    IF v_client_id = '00000000-0000-0000-0000-000000000000' THEN
        RAISE EXCEPTION 'fn_reset_qa_tenant: edit this function and paste the real QA client_id/company_id before using it.';
    END IF;

    -- 1. Cross-module dependency — must go first
    DELETE FROM rid_bank_reconciliation_matches WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 2. Generic soft-linked tables
    DELETE FROM rid_transaction_line_batches WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_transaction_line_serials WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_transport_details        WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 3. Bank Reconciliation
    DELETE FROM rid_bank_statement_lines    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_bank_statement_headers  WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 4. Sales
    DELETE FROM rid_sales_delivery_lines    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_sales_delivery_headers  WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_return_charges    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_return_lines      WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_sales_return_headers    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_cash_receipt_lines      WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_cash_receipt_headers    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_invoice_charges   WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_invoice_lines     WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_sales_invoices          WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_order_charges     WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_order_lines       WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_sales_orders            WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_prospect_conversions    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_quotation_charges WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_sales_quotation_lines   WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_sales_quotations        WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_price_master_lines      WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_price_master_headers    WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 5. Purchase
    DELETE FROM rid_purchase_return_charge_lines WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_purchase_return_lines        WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_purchase_return_headers      WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_purchase_invoices            WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_po_payment_terms             WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_po_charge_lines              WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_purchase_order_lines         WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_purchase_orders              WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_grn_charge_lines             WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_grn_lines                    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_grn_headers                  WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 6. Inventory
    DELETE FROM rid_stock_count_review_sources     WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_stock_count_review_headers     WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_stock_count_lines              WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_stock_count_headers            WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_opening_stock_lines            WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_opening_stock_headers          WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_stock_adjustment_lines         WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_stock_adjustment_headers       WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_stock_receipt_lines            WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_stock_receipts                 WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_stock_transfer_charge_lines    WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_stock_transfer_lines           WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_stock_transfers                WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_stock_transfer_request_lines   WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_stock_transfer_requests        WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_material_issue_lines           WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_material_issue_headers         WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_material_requisition_lines     WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_material_requisition_headers   WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 7. Finance
    DELETE FROM rid_invoice_bill_settlement WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_cheque_register         WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_finance_lines           WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_finance_headers         WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_opening_balance_lines   WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rid_expense_voucher_lines   WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM rih_expense_voucher_headers WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 8. Ledgers
    DELETE FROM ril_stock_ledger       WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM ril_cost_price_history WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 9. Job queue / notifications
    DELETE FROM ric_product_movement_snapshot
    WHERE job_id IN (SELECT id FROM ric_report_jobs WHERE client_id = v_client_id AND company_id = v_company_id);
    DELETE FROM ric_report_jobs         WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM ric_user_notifications  WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 10. Reset master-table running balances
    UPDATE rim_product_location
    SET current_stock = 0, cost_price = 0, cost_price_specific = 0
    WHERE client_id = v_client_id AND company_id = v_company_id;

    -- 11. Reset document numbering
    DELETE FROM ril_trans_no_seq        WHERE client_id = v_client_id AND company_id = v_company_id;
    DELETE FROM ril_company_doc_no_seq  WHERE client_id = v_client_id AND company_id = v_company_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_reset_qa_tenant() TO authenticated;
