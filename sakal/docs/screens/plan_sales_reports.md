Status: Implemented 2026-08-27 (migrations 163-165, not yet run by user).

# Sales Module Reports — 12 reports

## Context
Unlike Purchase (which started from zero), Sales already had `v_sales_details_base`/`_local`
(migration 126) and the Sales Register report (migration 127) with real, posting-consistent
`cost_price`/`gross_profit`/`gross_profit_percent` columns. Full design (context, schema facts,
per-report filters/columns, explicit "deliberately not building" list) was reviewed with the user
as an HTML artifact before any SQL was written: `sakal/docs/screens/artifact_sales_reports_plan.html`.
This doc is the as-built summary — read the artifact for the complete per-report spec.

## The 12 reports, by migration

- **163** (Gross Profit family — reuses existing invoice/return data, no new views beyond one thin
  wrapper): Item-wise Gross Profit (`ITEM_GROSS_PROFIT`, grouped by Product), Invoice-wise Gross
  Profit (`INVOICE_GROSS_PROFIT` — grouped by the ORIGINAL `invoice_no`, not `doc_no`, so a Return
  automatically nets against the invoice it came from), Customer-wise Gross Profit
  (`CUSTOMER_GROSS_PROFIT`), Salesperson-wise Performance (`SALESPERSON_PERFORMANCE`), Sales Return
  Register (`SALES_RETURN_REGISTER`, grouped by the Return's own `doc_no`, filtered `record_type='R'`).
  All five source from one new wrapper view, `v_sales_gross_profit_lines` (joins `rim_products` onto
  `v_sales_details_base` purely to add `category_id`/`brand_id`, columns the base view deliberately
  doesn't carry — same "wrapper view for one extra join" pattern as Purchase's own Supplier Analysis
  report).
- **164** (Pipeline — Quotation/Order had zero reports, new views needed): Sales Quotation Register
  (`SALES_QUOTATION_REGISTER`, grouped by Quotation, new `v_sales_quotation_lines` view), Sales Order
  Register (`SALES_ORDER_REGISTER`, grouped by Order, new `v_sales_order_lines` view), Quotation
  Conversion Analysis (`QUOTATION_CONVERSION_ANALYSIS`, TABULAR, one row per quotation line, uses the
  REAL `converted_qty` column), Open Sales Orders (`OPEN_SALES_ORDERS`, TABULAR, status-scoped only —
  deliberately NOT qty-gap-based, since `rid_sales_order_lines.delivered_qty` is never actually
  written by any function in this schema; Delivery links to the Invoice, not the Order).
- **165** (Fulfillment & Collections): Sales Delivery Register (`SALES_DELIVERY_REGISTER`, grouped by
  Delivery, new `v_sales_delivery_lines` view, NO financial columns — Delivery is a pure logistics
  document), Pending Deliveries (`PENDING_DELIVERIES`, TABULAR — reuses the EXISTING
  `v_sales_invoice_delivery_status` view from migration 102 directly, widened additively with a new
  trailing `days_since_invoice` column and location-access scoping), Cash Receipt / Collections
  Register (`CASH_RECEIPT_REGISTER`, TABULAR, new `v_cash_receipt_lines` view).

## Conventions followed (all established earlier this session, none new)
- Location-access scoping (`ric_user_location_access`) on every view.
- `ACCOUNT_PICKER` filter type for Customer (matches Sales Register's own precedent — migration 127).
- GROUPED reports use `ric_report_group_levels` + a dedicated `_group_summary` function resolving
  identity fields directly off header tables (never the shared line-level view where avoidable).
- Standard `ric_user_menus` backfill for all 12.
- `fn_seed_client_modules.sql` updated with all 12 `SL-RPT-*` feature codes for future clients.

## Design decisions worth flagging
- **Invoice-wise Gross Profit groups by the ORIGINAL invoice (`invoice_no`/`invoice_date`), not
  `doc_no`.** `v_sales_details_base`'s `invoice_no` column always points at the original invoice even
  on a Return row (`record_type='R'`) — grouping by it means a return automatically nets against the
  invoice it came from, showing the TRUE post-return profitability. Grouping by `doc_no` instead would
  have shown the return as its own separate, disconnected group.
- **Currency toggle (BASE/LOCAL) deliberately NOT added to any of these 12 reports for v1** — Sales
  Register already has this feature (migration 127) via a `_local` view variant; adding it here would
  have doubled the view count for a feature not explicitly requested. Easy follow-up: point
  `source_object_local` at a `_local` variant of the same wrapper views, same mechanism Sales Register
  already proves.
- **`rim_sales_executives` (not `rim_users`) is the correct Sales Person lookup/FK target** — confirmed
  by grep: an earlier migration retrofitted `sales_person_id` on Quotation/Order/Invoice from a
  `rim_users` FK to `rim_sales_executives`, so all Sales Person filters in 163/164 correctly point at
  `rim_sales_executives.full_name`.
- **`v_sales_invoice_delivery_status` widened additively, not replaced** — added `days_since_invoice`
  as a new trailing column and location-access scoping via `CREATE OR REPLACE VIEW` (safe: no existing
  column removed/reordered, so the Sales Invoice screens' own read-only delivery-status badge, which
  already reads this view, is unaffected).

## Explicitly not building (cross-referenced, not forgotten)
- Customer Ageing / AR Outstanding — already covered by Finance (migrations 137/140).
- Item-wise/Customer-wise Sales Summary (pure revenue/qty, no GP) — folded into Reports 1/3, which
  already carry Qty/Revenue alongside Gross Profit.
- A Sales-Order qty-fulfillment-gap report (mirroring Purchase's Pending PO) — not buildable honestly,
  see Open Sales Orders' scope note above.

## Verification (pending — user has not yet run migrations 163-165)
1. All 12 reports appear under Sales → Reports for a user with existing Sales module access.
2. Invoice-wise Gross Profit: create an invoice, then a partial return against it — confirm the
   invoice's own group row nets the return's negative qty/amount/GP correctly rather than showing two
   disconnected rows.
3. Quotation Conversion Analysis: convert part of a quotation line into an order — confirm
   `converted_qty`/`qty_unconverted`/`conversion_percent` update correctly.
4. Pending Deliveries: confirm the widened `v_sales_invoice_delivery_status` view still feeds the
   existing Sales Invoice screens' delivery-status badge correctly (no regression from the additive
   change).
5. Cash Receipt Register: a receipt applied against multiple bills — confirm `applied_amount_local`
   sums correctly per line while `header_local_amount`/`header_base_amount` are NOT double-counted
   across those lines (the totals function de-duplicates on `(receipt_no, receipt_date)` before
   summing header-level columns).
6. `flutter analyze`/`flutter test` — no Flutter changes were needed for this batch (all 12 reports use
   the existing generic `ReportScreen`/reporting engine), but worth a green-check pass regardless.
