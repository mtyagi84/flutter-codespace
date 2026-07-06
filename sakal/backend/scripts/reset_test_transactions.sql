-- ============================================================
-- reset_test_transactions.sql
-- DEV/TEST ONLY. Wipes ALL Purchase Order, GRN, Purchase Bill,
-- Finance Voucher, Stock Ledger and Cost Price History data across
-- every client/company, so fresh test entries can be made from a
-- clean slate. Masters (products, accounts, customers/suppliers,
-- tax, COA, currencies, company/location setup, users) are untouched.
--
-- Run in the Supabase SQL Editor. Wrapped in a transaction —
-- if anything looks wrong, ROLLBACK instead of letting it commit.
-- ============================================================

BEGIN;

-- ── Purchase Returns (children before parent) — must precede GRN's own
--    delete below purely for readability of this script; no FK forces the
--    order (source_grn_no/date on rid_purchase_return_lines is a plain
--    generic reference, not an FK, same convention as source_doc_no
--    elsewhere) ──
DELETE FROM rid_transaction_line_batches WHERE source_doc_type = 'PURCHASE_RETURN';
DELETE FROM rid_transaction_line_serials WHERE source_doc_type = 'PURCHASE_RETURN';
DELETE FROM rid_purchase_return_charge_lines;
DELETE FROM rid_purchase_return_lines;
DELETE FROM rih_purchase_return_headers;

-- ── Purchase Bills (no child table — billed_invoice_no/date on
--    rih_grn_headers IS the linkage, wiped along with GRN below) ──
DELETE FROM rih_purchase_invoices;

-- ── GRN (children before parent) ──────────────────────────────
DELETE FROM rid_grn_charge_lines;
DELETE FROM rid_transaction_line_batches WHERE source_doc_type = 'GRN';
DELETE FROM rid_transaction_line_serials WHERE source_doc_type = 'GRN';
DELETE FROM rid_grn_lines;
DELETE FROM rih_grn_headers;

-- ── Purchase Orders (children before parent) ──────────────────
DELETE FROM rid_po_payment_terms;
DELETE FROM rid_po_charge_lines;
DELETE FROM rid_purchase_order_lines;
DELETE FROM rih_purchase_orders;

-- ── Finance Vouchers (children before parent) ──────────────────
DELETE FROM rid_cheque_register;
DELETE FROM rid_invoice_bill_settlement;
DELETE FROM rid_finance_lines;
DELETE FROM rih_finance_headers;

-- ── Stock ledger + cost price history (append-only audit trails) ──
DELETE FROM ril_stock_ledger;
DELETE FROM ril_cost_price_history;

-- ── Reset current stock/cost snapshot back to zero ────────────
-- (rim_product_location rows themselves are master data — keep them,
-- just zero out what the deleted ledger/history used to justify)
UPDATE rim_product_location
SET current_stock       = 0,
    cost_price           = 0,
    cost_price_specific  = NULL;

-- ── Reset document numbering so fresh entries start at 1 again ─
-- (comment these two out if you'd rather keep numbering continuous)
DELETE FROM ril_trans_no_seq WHERE voucher_type_code IN
    ('GRN', 'PINV', 'PUR', 'PRET', 'CRV', 'BRV', 'CPV', 'BPV', 'JV', 'SDN', 'SCN', 'CDN', 'CCN', 'SIV');
DELETE FROM ril_company_doc_no_seq WHERE voucher_type_code = 'PO';

COMMIT;
