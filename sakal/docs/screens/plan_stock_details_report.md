Status: Implemented 2026-08-21 (migration 149, not yet run by user).

# Inventory — Stock Details report (Opening/Inward/Outward/Closing) + cascading-filter engine capability

## Context

Third Inventory report, after Stock Balance by Location and Stock Value by Location (migration 148, run).
Stock Details is a movement report over a date range — Opening/Inward/Outward/Closing Qty per product,
optionally scoped by Location/Category/Product. Unlike the prior two reports it reads `ril_stock_ledger`
directly (the immutable, append-only movement log) rather than `rim_product_location.current_stock`.

While scoping the optional Product filter, research found the existing `PRODUCT_PICKER` filter type is a
plain non-searchable dropdown with no working precedent (Sales Register's own use of it has no
`lookup_source` configured, so it's non-functional today). The user asked for a **cascading** Product
filter (scoped to the selected Category) and said this pattern will be needed "in many more places in
Sales and Inventory reports" — built as a small, reusable engine capability, not report-specific code.

## Decisions
1. Product filter = cascading dropdown, scoped to the Category's subtree, re-fetched when Category
   changes — a new generic Reporting Engine capability (see below).
2. Include Zero toggle (not a fixed exclude) — same shape as Trial Balance's own `Include Zero Balances`
   BOOLEAN filter (migration 135). Default unchecked.
3. Serial-tracked products expand to one row per serial (same convention as Stock Value report) — serial
   identity only exists on `ril_stock_ledger` rows, so a serial-tracked product with zero ledger history
   produces no row even with Include Zero checked. Non-serial (incl. batch) products stay one aggregated
   row per product, enumerated `FROM rim_products` (LEFT JOIN the ledger) so Include Zero correctly
   surfaces a product with literally zero transactions ever, not just a net-zero one.
4. From/To Date required, no SQL-level default on the function params (`p_trans_date_from DATE,
   p_trans_date_to DATE`, no `DEFAULT`) — a missing date would silently produce a wrong Opening figure.
5. All Locations = sum across the user's accessible locations, one row per product — a transfer between
   two accessible locations correctly nets to zero at the company-wide view.

## `fn_stock_details` / `fn_stock_details_totals`

Plain flat `TABULAR`, ungrouped (no currency split needed — pure quantities; no category subtotals were
asked for, unlike Stock Value's grouped shape).

- `accessible_locations` CTE — same inlined `ric_user_location_access` block as migration 148.
- `non_serial` CTE — `FROM rim_products p LEFT JOIN ril_stock_ledger sl ...` (LEFT JOIN is what lets
  Include Zero surface a zero-history product). `opening_qty = SUM(qty_change) FILTER (trans_date <
  from)`, `inward_qty = SUM(qty_change) FILTER (in range AND qty_change>0)`, `outward_qty =
  ABS(SUM(qty_change) FILTER (in range AND qty_change<0))` (shown as a positive magnitude). Research
  confirmed `ril_stock_ledger`'s own `chk_stock_ledger_direction` CHECK constraint enforces `qty_change`'s
  sign correctly for every `trans_type` at insert time, so filtering purely by sign needs no per-type
  branching. `OPENING_STOCK` (077) is just another ledger row, so the `opening_qty` predicate naturally
  includes it.
- `serial_rows` CTE — `FROM ril_stock_ledger` (driven by real rows only, since serial identity has no
  master table), `GROUP BY product, serial_no`, same three aggregate expressions.
- `combined` CTE — `UNION ALL`, `closing_qty = opening_qty + inward_qty - outward_qty` computed once here.
- Final filter: `WHERE p_include_zero OR opening_qty<>0 OR inward_qty<>0 OR outward_qty<>0 OR
  closing_qty<>0` — exact shape of Trial Balance's own zero-row filter (135).
- `fn_stock_details_totals` — SUM of the four qty columns + row_count, wired as `totals_source_object`
  (this report is ungrouped, so `ReportDataController.refresh()`'s plain path DOES call `fetchTotals`,
  unlike migration 148's grouped Stock Value report).
- New index `idx_stock_ledger_client_company_date ON ril_stock_ledger (client_id, company_id, trans_date)`
  — no prior index covered a date-range scan unfiltered by product.

## Registry

`STOCK_DETAILS`, `TABULAR`, no group levels. `auto_load=false`. Feature code `IN-RPT-SDT`,
`screen_name='/reports/STOCK_DETAILS'`, `group_code='IN-RPT'`, `serial_no=2`. Filters: `date_range`
(required, default `THIS_MONTH`), `location_id`, `category_id`, `product_id` (cascading, see below),
`include_zero` (BOOLEAN, default `'false'`). `ric_user_menus` backfilled; `fn_seed_client_modules.sql`
updated.

## New engine capability — cascading (parent-scoped) lookup filters

`SakalReportFilterBar` previously loaded every lookup filter's options once in `initState`, independent
of any other filter's value. Three new nullable columns on `ric_report_filters`:
- `depends_on_filter_key` — the parent filter's own `filter_key` (e.g. `'category_id'`).
- `depends_on_column` — the column on THIS filter's `lookup_source` to filter by (e.g. `'category_id'`
  on `rim_products`).
- `depends_on_expand_fn` — optional RPC (`RETURNS TABLE(id uuid)`) that expands the parent's raw value
  into a set of ids first (e.g. `'fn_category_subtree'`); when NULL, the parent's value is used as a
  plain equality filter instead — covers a flatter future cascade (e.g. a location-scoped dropdown)
  without assuming every cascade is a category tree. Deliberately no generic "expand function param
  name" column yet (YAGNI) — every cascade needed today uses `fn_category_subtree`'s own single
  `p_category_id` param; add that column only when a differently-shaped expand function is actually
  needed.

`ReportFilter` (`report_models.dart`) gains the 3 nullable `dependsOn*` fields.

`SakalReportFilterBar` (`sakal_report_filter_bar.dart`):
- `_loadLookupOptions(f, {parentValue})` — capped at `limit: 500` regardless of scoping. When
  `dependsOnFilterKey` is set: `parentValue == null` → unscoped capped fetch; `dependsOnExpandFn` set →
  first resolves the parent's value into an id set via that RPC, then filters
  `{dependsOnColumn}=in.(...)`; otherwise a plain `{dependsOnColumn}=eq.{parentValue}`.
- `initState` — a dependent filter resolves its initial `parentValue` from
  `widget.initialValues[dependsOnFilterKey]` before its first load (reopening a report with Category
  already selected shows the right Product options immediately).
- `_set`/`_reloadDependents` — changing a parent filter clears every dependent filter's own current value
  (it may not be valid under the new scope) and reloads its options.
- **Real bug caught via self-review before shipping**: the existing `DropdownButtonFormField` for
  `DROPDOWN_LOOKUP`/`ACCOUNT_PICKER`/`PRODUCT_PICKER` had no `key:` — per CLAUDE.md's own documented
  FormField rule (`initialValue` is read once; an externally-driven value change needs
  `key: ValueKey(currentValue)` to resync), clearing a dependent filter's value programmatically
  (`_reloadDependents`) would have silently left the dropdown showing its stale prior selection. Fixed
  by adding `key: ValueKey(selectedValue)` to that widget — the same fix class CLAUDE.md already
  documents as having recurred 4 times in one prior session (Contra Voucher, Expense Voucher); this is
  effectively the 5th occurrence, caught proactively this time via the documented rule rather than live
  testing.

## Critical files
- `backend/migrations/149_stock_details_report.sql` — everything above.
- `backend/functions/fn_seed_client_modules.sql` — new `IN-RPT-SDT` row.
- `lib/core/reporting/report_models.dart` — `ReportFilter.dependsOn*` fields.
- `lib/core/reporting/sakal_report_filter_bar.dart` — cascading-lookup logic + the `key:` fix.
- No changes to `report_data_controller.dart`/`sakal_report_screen.dart` — plain ungrouped TABULAR path,
  `auto_load` gate already exists from migration 148.

## Verification (pending — user has not yet run migration 149)
1. A product received via GRN before From Date, no movement inside the range: Opening = qty received,
   Inward/Outward = 0, Closing = Opening.
2. A product with a GRN and a Sales Invoice inside the range: `Closing = Opening + Inward - Outward`
   reconciles against `rim_product_location.current_stock` when To Date = today and Location = one
   specific location.
3. All Locations: a transfer between two accessible locations nets to zero at the company-wide view;
   picking just the source or destination location shows the real one-sided effect.
4. Serial-tracked product: one row per serial with ledger activity in scope; never-received serial
   product shows nothing even with Include Zero checked.
5. Include Zero unchecked hides all-zero rows; checked shows them, including a product with literally
   zero ledger history ever.
6. Category filter narrows correctly (subtree-inclusive); the Product dropdown, opened right after
   picking a Category, lists only products in that subtree (capped at 500); picking a DIFFERENT Category
   afterward clears any previously selected Product and reloads the list.
7. Every other existing report (none of which declare `depends_on_filter_key`) is unaffected — filter
   bar's eager-load-on-initState behavior is unchanged for them.
