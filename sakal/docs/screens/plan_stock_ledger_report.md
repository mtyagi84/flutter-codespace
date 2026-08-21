Status: Implemented 2026-08-21 (migration 150, not yet run by user).

# Inventory — Stock Ledger report (per-product transaction statement, running balance)

## Context

Fourth Inventory report. A per-transaction statement for a single product — like a Finance Account
Ledger/Statement, not a summary — modeled explicitly on `132_account_ledger_report.sql`: Opening Qty as
its own first row, every transaction in the date range with a running balance, Closing Qty as the last
row (via the totals footer, same as 132).

## Decisions
1. **Remarks resolved via a separate function**, `fn_resolve_transaction_remarks(p_client_id,
   p_company_id, p_source_doc_type, p_source_doc_no, p_source_doc_date) RETURNS TEXT` — user's own
   proposal, so that changing what Remarks shows for one document type in the future only ever touches
   this one function, never the ledger report itself. Performance is a non-issue because Product is a
   required filter (small row count by construction), unlike the unbounded-catalog reports (148/149).
2. **Location is an optional filter, not an aggregation dimension** — this is transaction-level, so there
   is no SUM-across-locations concept. Leaving Location blank interleaves every accessible location's
   transactions chronologically; picking one narrows to just that location. Either way the location name
   is appended into Remarks (not a separate column).
3. **Remarks never repeats the row's own Transaction No/Date** (explicit user correction during
   planning) — a document's own number/date (`grn_no`/`grn_date` etc.) is used ONLY as the join key to
   find the right header row; Remarks only ever shows genuinely new information (party name, a
   *different* document's own reference number, a reason, or a location).

## `fn_resolve_transaction_remarks`

One `CASE p_source_doc_type WHEN ... THEN <targeted SELECT> ... END CASE` branch per real
`source_doc_type` value ever passed to `fn_post_stock_movement` (confirmed exhaustive via research):
GRN → supplier name; Purchase Return → supplier + reason; Sales Invoice → customer (or `party_name` for
cash-sale walk-ins) + order_no; Sales Delivery → customer + parent invoice_no; Sales Return → customer +
reason; Stock Transfer → destination location; Stock Receipt → origin location; Stock Adjustment →
reason description; Material Issue → department description (joined via `rid_material_issue_lines`,
matched by `issue_no`+`issue_date`+`product_id`, since the header itself carries no department — only
its lines do); Opening Stock → literal `'Opening Stock'`; anything else → `NULL` (blank, never an
error). `GRN_REVERSAL` and Material Requisition need no branch — neither is ever actually posted to the
ledger in this schema.

## `fn_stock_ledger_lines` / `fn_stock_ledger_totals`

Mirrors `fn_account_ledger_lines` (132) structurally: `accessible_locations` CTE (same JWT-scoped block
as every prior Inventory report) → `all_lines` (raw ledger rows, unenriched) → `opening` (scalar
`SUM(qty_change)` before From Date) → `detail_lines` (enrichment — location join + remarks resolver call
— scoped ONLY to rows actually within the date range, not the product's full history, since that
enrichment is real per-row work) → `combined` (`UNION ALL` of the synthetic Opening Balance row +
detail rows) → final `SELECT` with `SUM(signed_qty) OVER (ORDER BY sort_priority, trans_date, trans_no,
created_at ROWS UNBOUNDED PRECEDING)` as running balance and `ROW_NUMBER() OVER (...)` as the hidden
`sort_seq` tiebreak column (`ril_stock_ledger.created_at` stands in for 132's own `serial_no` tiebreak,
since the ledger's `serial_no` column is a product serial number, not a row sequence).

`fn_stock_ledger_totals` — independent single-scan `FILTER`-based totals (never derived from the window
function's output), same shape as `fn_account_ledger_totals`; its `running_balance` output IS the
Closing Qty.

**Real gotcha found and designed around**: `ReportFilter.required` is parsed by the Flutter model but
never actually enforced anywhere in the reporting engine (confirmed by reading
`report_data_controller.dart`/`report_repository.dart`/`sakal_report_filter_bar.dart`) —
`_buildFilterParams` skips any filter whose value is still `null`. Since Product has no sensible
`default_value`, a fetch attempted before one is picked would omit `p_product_id` from the RPC call
entirely — without a SQL-level `DEFAULT NULL`, that's a hard PostgREST "missing argument" error, not an
empty report. Fixed by giving `p_product_id UUID DEFAULT NULL` anyway (matching `fn_account_ledger_lines`'s
own `p_account_id UUID DEFAULT NULL`, despite its `account` filter also being `required: true`) —
`sl.product_id = p_product_id` naturally matches zero rows when NULL, so an unset-product fetch is
harmless. `auto_load=false` is the real guard that stops that fetch from firing before the user has
picked anything.

## Registry

`STOCK_LEDGER`, `TABULAR`, no group levels (flat, chronological), `auto_load=false`. Feature code
`IN-RPT-SDL`, `screen_name='/reports/STOCK_LEDGER'`, `group_code='IN-RPT'`, `serial_no=3`. Columns:
`trans_no`, `trans_date`, `trans_type`, `remarks`, `qty_in` (Inward, SUM), `qty_out` (Outward, SUM),
`running_balance` (SUM — render-gate only, not a literal re-sum), `sort_seq` (hidden,
`default_sort_column`). All columns `sortable=false` — row order IS the running balance's own
chronological order (same convention as Account Ledger). Filters: `product_id` (DROPDOWN_LOOKUP →
`rim_products`, required — display-only, see gotcha above), `date_range` (DATE_RANGE, required, default
`THIS_MONTH`), `location_id` (DROPDOWN_LOOKUP → `v_user_accessible_locations`, optional). `ric_user_menus`
backfilled; `fn_seed_client_modules.sql` updated.

## Critical files
- `backend/migrations/150_stock_ledger_report.sql` — everything above.
- `backend/functions/fn_seed_client_modules.sql` — new `IN-RPT-SDL` row.
- No Flutter changes — plain ungrouped TABULAR + existing filter types, `auto_load` gate already exists.

## Verification (pending — user has not yet run migration 150)
1. Opening Qty row matches Stock Details' own Opening Qty for the same product/location/From Date (a
   cross-report correctness check against an already-verified report).
2. Each row's Inward/Outward matches its real document; Running Balance after the last row equals the
   Closing Qty (the totals footer).
3. Remarks per doc type as designed — GRN shows supplier, Sales Invoice/Delivery shows customer (+
   order/invoice reference), Stock Transfer/Receipt show the counterpart location, Stock Adjustment shows
   its reason — and Remarks NEVER repeats the row's own Transaction No/Date. Every row also shows
   "Location: <name>".
4. Leaving Location blank interleaves every accessible location's transactions (a transfer's two legs
   both appear, at their own real locations, not netted); picking one location narrows correctly.
5. An unrecognized `source_doc_type` (if one exists in real data) shows blank Remarks, not an error.
