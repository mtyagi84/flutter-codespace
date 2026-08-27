Status: Implemented 2026-08-27 (migrations 158-162, not yet run by user).

# Purchase Module Reports — 13 reports, first reports this module has ever had

## Context
Purchase had zero reports. Full design (context, schema facts, per-report filters/columns, explicit
"deliberately not building" list) was reviewed with the user as an HTML artifact before any SQL was
written: `sakal/docs/screens/artifact_purchase_reports_plan.html`. This doc is the as-built summary —
read the artifact for the complete per-report spec.

## Schema addition
`rid_purchase_order_lines.expected_delivery_date DATE` (nullable) — LINE level, not header, per the
user's explicit direction (different items on one PO can have different promised arrival dates, matching
Odoo's own `purchase.order.line.date_planned`). Powers Report 11 (Vendor On-Time Delivery) only.

## The 13 reports, by migration
- **158** (Order stage): Purchase Order Register (`PURCHASE_ORDER_REGISTER`, grouped by PO), Pending
  Purchase Orders (`PENDING_PURCHASE_ORDERS`), Vendor On-Time Delivery (`VENDOR_ON_TIME_DELIVERY` —
  the one genuinely complex view: walks each PO line's own receiving GRNs in date order via a correlated
  subquery over `generate_subscripts`/array-slicing to find when cumulative received qty first reaches
  the ordered qty; flagged as the highest-risk query in this whole batch, worth extra scrutiny on first run).
- **159** (Receipt stage): GRN Register (`GRN_REGISTER`, grouped by GRN, non-serial+serial UNION ALL),
  GRN Pending to Bill (`GRN_PENDING_TO_BILL` — fills the gap `v_pending_bills` structurally can't see,
  since an unbilled GRN's provisional accrual never carries `inv_bill_no`), Purchase Charges Register
  (`PURCHASE_CHARGES_REGISTER` — documents, doesn't hide, that no document in this schema ever clears a
  GRN charge).
- **160** (Billing stage): Purchase Invoice Register (`PURCHASE_INVOICE_REGISTER` — group row = the Bill,
  detail rows = its linked GRNs, since a Bill has no line-items of its own), Purchase Tax Summary
  (`PURCHASE_TAX_SUMMARY`, grouped by Supplier, whole-bill-level tax only — no per-rate breakdown, stated
  as a known limitation in the migration's own comments).
- **161** (Returns): Purchase Return Register (`PURCHASE_RETURN_REGISTER`, grouped by Return; Reason
  folds what would've been a separate "Return Reason Analysis" report into this one via
  filter+group-column; `posted_vouchers` column shows JV/SDN/Both via `string_agg` over
  `rih_finance_headers` tagged with this return's own `source_doc_type`/`no`/`date`).
- **162** (Cross-module analysis): Supplier-wise Purchase Analysis (`SUPPLIER_PURCHASE_ANALYSIS`, grouped
  Supplier→Product — simplified from the original design's "GRN value vs Billed value" toggle to
  GRN-value-only, since Purchase Invoice has no line-items to break a lump sum back into per-product
  figures), Item-wise Purchase History (`ITEM_PURCHASE_HISTORY`, product-scoped not date-scoped),
  Purchase Price Variance (`PURCHASE_PRICE_VARIANCE`, vs `rim_products.standard_cost`), Reorder/
  Replenishment (`REORDER_REPLENISHMENT` — zero schema changes, reuses migration 158's own
  `v_pending_purchase_orders` for the Open PO Qty column).

## Conventions followed (all established earlier this session, none new)
- Location-access scoping (`ric_user_location_access`) on every view.
- `ACCOUNT_PICKER` filter type for Supplier (matches Sales Register's own Customer filter precedent
  exactly — migration 127).
- GROUPED reports use `ric_report_group_levels` + a dedicated `_group_summary` function resolving
  identity fields directly off header tables (never the line-level view), same pattern as the Stock
  Adjustment regroup (migration 155).
- Standard `ric_user_menus` backfill for all 13 — none needed the with/without-Value permission split
  (no report here exposes cost/value data as sensitive as Stock Adjustment's own Unit Cost/Value).

## Real design correction made mid-build
The plan's own Report 5/13 location-filter caveat ("verify `rih_purchase_invoices` has `location_id`
before build") was resolved by direct read before writing the SQL — the column does exist, no workaround
needed. Recorded here since the artifact (already shown to the user) still shows the caveat as written at
plan time.

## Verification (pending — user has not yet run migrations 158-162)
1. All 13 reports appear under Purchase → Reports for a user with existing Purchase module access.
2. Vendor On-Time Delivery: create a PO with an expected_delivery_date, receive it via GRN early/late/not
   at all — confirm the delivery_status badge and days_variance are correct in all three cases. This is
   the query most likely to need a live-data fix (correlated array-subscript subquery, never tested
   against real rows).
3. GRN Pending to Bill shows an unbilled APPROVED GRN's real accrual amount, disappears once that GRN is
   billed.
4. Purchase Return Register's `posted_vouchers` column shows "JV", "SDN", or "JV+SDN" correctly for a
   return mixing billed and unbilled GRN lines.
5. Reorder/Replenishment's Open PO Qty matches the same product/location's own Pending Purchase Orders
   total.
6. `flutter analyze`/`flutter test` — no Flutter changes were needed for this batch (all 13 reports use
   the existing generic `ReportScreen`/reporting engine), but worth a green-check pass regardless.
