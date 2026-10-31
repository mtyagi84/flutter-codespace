-- ============================================================================
-- reset_all_transactions.sql
--
-- Deletes EVERY transaction (header + line + ledger) row for ONE tenant
-- (client_id + company_id), across every module, leaving ALL master data
-- (rim_*/ric_* setup: products, customers, suppliers, Chart of Accounts,
-- tax setup, company/location/user setup, format masters, price lists, etc.)
-- completely untouched EXCEPT where explicitly noted in Section 10/11 below.
--
-- This is a one-time maintenance script, not a numbered migration — it does
-- not change the schema, only data. Not meant to be re-run as part of the
-- normal migration sequence.
--
-- ORDER MATTERS. Every rid_* line/charge table has a composite FK back to
-- its own rih_* header (client_id, company_id, <doc_no>, <doc_date>), so
-- lines/charges are always deleted before their header. One genuine
-- cross-module FK exists (rid_bank_reconciliation_matches -> both
-- rid_finance_lines and rid_bank_statement_lines), handled first. Verified
-- against every CREATE TABLE / FOREIGN KEY / ON DELETE CASCADE clause in
-- sakal/backend/migrations/ before writing this — not from memory.
--
-- WHAT THIS SCRIPT ALSO DOES (confirmed with the user before writing):
--   - Resets rim_product_location.current_stock/cost_price/cost_price_specific
--     to 0 — these are master-table columns MUTATED by transaction posting;
--     leaving them non-zero after wiping the ledger would show stock/cost
--     values with no transaction history behind them.
--   - Deletes all rows from the two document-numbering sequence tables
--     (ril_trans_no_seq, ril_company_doc_no_seq). Both functions
--     (fn_next_trans_no / fn_next_company_doc_no) use
--     INSERT ... ON CONFLICT DO NOTHING with current_seq starting at 0, so a
--     MISSING row means numbering starts fresh at 1 on the next document —
--     confirmed by reading both functions, not assumed.
--   - Clears the report-job-queue and notification tables too (ric_report_jobs,
--     ric_user_notifications, ric_product_movement_snapshot) — these
--     accumulate from report submissions and aren't core business
--     transactions, but the user asked for a fully clean slate everywhere.
--   - Wipes Price Master (rih_price_master_headers/rid_price_master_lines) —
--     technically a rate list, not a physical transaction, but the user
--     confirmed wiping it is fine for this reset.
--
-- HOW TO USE:
--   1. Fill in your own client_id and company_id below (Section 0).
--   2. Review the whole script once — this is IRREVERSIBLE for the data it
--      touches.
--   3. Run the ENTIRE script as one batch in the Supabase SQL editor. It is
--      wrapped in a single transaction: if anything fails, everything rolls
--      back and nothing is left half-deleted.
-- ============================================================================

BEGIN;

-- ── 0. Fill in your tenant here ─────────────────────────────────────────────
-- Every DELETE/UPDATE below is scoped to these two IDs so no other tenant's
-- data is touched. set_config(..., true) scopes these to the current
-- transaction only.
SELECT set_config('app.reset_client_id',  '5cf9eacb-77c4-4ec6-ba87-a4fc24d05f1a', true);
SELECT set_config('app.reset_company_id', 'e8ea07be-afce-4063-abe3-96945fc5c10b',  true);

-- Sanity check: fail loudly (and roll back) if the placeholders were never
-- replaced, rather than silently matching zero rows and looking like success.
DO $$
BEGIN
    IF current_setting('app.reset_client_id', true)  IS NULL
       OR current_setting('app.reset_client_id', true)  = 'PASTE-YOUR-CLIENT-ID-UUID-HERE'
       OR current_setting('app.reset_company_id', true) IS NULL
       OR current_setting('app.reset_company_id', true) = 'PASTE-YOUR-COMPANY-ID-UUID-HERE'
    THEN
        RAISE EXCEPTION 'Edit Section 0 of this script and paste your real client_id/company_id before running.';
    END IF;
END $$;

-- ── 1. Cross-module dependency — must go first ──────────────────────────────
-- rid_bank_reconciliation_matches has row-level FKs into BOTH
-- rid_finance_lines(id) and rid_bank_statement_lines(id).
DELETE FROM rid_bank_reconciliation_matches
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 2. Generic soft-linked tables (no formal FK to any specific header) ────
DELETE FROM rid_transaction_line_batches
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_transaction_line_serials
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_transport_details
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 3. Bank Reconciliation ───────────────────────────────────────────────────
DELETE FROM rid_bank_statement_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rih_bank_statement_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 4. Sales ─────────────────────────────────────────────────────────────────
DELETE FROM rid_sales_delivery_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_sales_delivery_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_sales_return_charges
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_sales_return_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_sales_return_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_cash_receipt_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_cash_receipt_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_sales_invoice_charges
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_sales_invoice_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_sales_invoices
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_sales_order_charges
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_sales_order_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_sales_orders
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rih_prospect_conversions
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_sales_quotation_charges
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_sales_quotation_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_sales_quotations
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- Price Master — technically a rate list, not a physical transaction, but
-- follows rih_/rid_ naming; user confirmed wiping it is fine for this reset.
DELETE FROM rid_price_master_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_price_master_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 5. Purchase ──────────────────────────────────────────────────────────────
DELETE FROM rid_purchase_return_charge_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_purchase_return_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_purchase_return_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- Purchase Invoice has no separate lines table — it composes GRN's own
-- accrual lines instead (verified against 054_purchase_invoice.sql).
DELETE FROM rih_purchase_invoices
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_po_payment_terms
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_po_charge_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_purchase_order_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_purchase_orders
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_grn_charge_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_grn_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_grn_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 6. Inventory ─────────────────────────────────────────────────────────────
DELETE FROM rid_stock_count_review_sources
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_stock_count_review_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_stock_count_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_stock_count_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_opening_stock_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_opening_stock_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_stock_adjustment_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_stock_adjustment_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_stock_receipt_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_stock_receipts
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_stock_transfer_charge_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_stock_transfer_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_stock_transfers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_stock_transfer_request_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_stock_transfer_requests
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_material_issue_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_material_issue_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_material_requisition_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_material_requisition_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 7. Finance ───────────────────────────────────────────────────────────────
DELETE FROM rid_invoice_bill_settlement
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_cheque_register
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rid_finance_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_finance_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- Opening Balance lines have no rih_ header table.
DELETE FROM rid_opening_balance_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM rid_expense_voucher_lines
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM rih_expense_voucher_headers
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 8. Ledgers (append-only, no incoming FK — derived from everything above) ─
DELETE FROM ril_stock_ledger
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

DELETE FROM ril_cost_price_history
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 9. Job queue / notifications ─────────────────────────────────────────────
-- ric_product_movement_snapshot cascades automatically off ric_report_jobs
-- (ON DELETE CASCADE), but deleted explicitly here too for clarity.
DELETE FROM ric_product_movement_snapshot
WHERE job_id IN (
    SELECT id FROM ric_report_jobs
    WHERE client_id = current_setting('app.reset_client_id')::uuid
      AND company_id = current_setting('app.reset_company_id')::uuid
);
DELETE FROM ric_report_jobs
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM ric_user_notifications
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 10. Reset master-table running balances (UPDATE, never delete the row) ──
-- rim_product_location is the only master table with columns mutated by
-- transaction posting (current_stock/cost_price/cost_price_specific) — no
-- other master table caches a running balance (Chart of Accounts balances
-- are always computed live from rid_finance_lines).
UPDATE rim_product_location
SET current_stock = 0, cost_price = 0, cost_price_specific = 0
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

-- ── 11. Reset document numbering ─────────────────────────────────────────────
-- fn_next_trans_no / fn_next_company_doc_no both INSERT ... ON CONFLICT DO
-- NOTHING with current_seq starting at 0 — a MISSING row means the next
-- document starts fresh at 1. Confirmed by reading both functions.
DELETE FROM ril_trans_no_seq
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;
DELETE FROM ril_company_doc_no_seq
WHERE client_id = current_setting('app.reset_client_id')::uuid
  AND company_id = current_setting('app.reset_company_id')::uuid;

COMMIT;

-- ============================================================================
-- After running: every list screen across every module should show zero
-- rows for this tenant, all master data (Products/Customers/Suppliers/Chart
-- of Accounts/Format Masters/etc.) stays fully intact, rim_product_location
-- shows zero stock everywhere, and the next document created in each module
-- starts numbering at 1 again.
-- ============================================================================
