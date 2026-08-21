Status: Implemented 2026-08-21 (migration 148, not yet run by user).

# Inventory Reports — Location filter on Stock Balance + new Stock Value report + "manual-run gate"

## Context

Inventory had exactly one report, "Stock Balance by Location" (`STOCK_BALANCE_MATRIX`, migration 118) —
a MATRIX pivot of `product × location → current_stock`, with only a free-text product search filter and
zero location-access scoping (any user saw every location's stock regardless of their own
`ric_user_location_access` rows). This work adds (1) real location scoping + a Location filter to that
report, and (2) a new, richer "Location-wise Stock Value" report — Barcode/Serial/Item/Unit/Qty/Price/
Value, currency columns labeled by the company's own real currency codes, subtotaled by top-level Item
Category, plus a report-level grand total.

Mid-planning, the user raised a critical architectural concern: a report whose row count scales with the
product catalog (50,000+ products) must not auto-fire an unfiltered query the instant the menu is
clicked. This led to a new, generic Reporting Engine capability: an opt-in `auto_load` flag gating
whether a report fetches data automatically on open vs. requiring an explicit "Run Report" action —
modeled on Odoo/SAP's classic wizard-then-print pattern for heavy reports.

## Decisions (confirmed via AskUserQuestion)
1. Serial-tracked products expand to one row per serial (Balance Qty=1, real serial number); non-serial
   (including batch-tracked) products stay one aggregated row.
2. Zero-balance rows excluded.
3. Current-moment only — no As Of Date filter, reads live `rim_product_location.current_stock`/
   `cost_price` directly.
4. Existing Stock Balance report also gets real row-level location scoping (not just an optional
   filter) — closes a real access-control gap.
5. No Location column on the new report — Location is filter-only (blank = the user's full accessible
   set). One row per item (or per serial) regardless of how many locations are in scope, aggregating
   ACROSS those locations: `Balance Qty = SUM(qty)`, `Value = SUM(qty × price)`,
   `As on Price = Value / Balance Qty` (a quantity-weighted average, not a single location's raw
   `cost_price`).

## New engine capability — `auto_load` manual-run gate

New `ric_report_definitions.auto_load BOOLEAN NOT NULL DEFAULT true` column. Every existing report keeps
its exact current behavior (default `true`). `ReportDataController.init()` still resolves default filter
values as before, but only calls `refresh()` automatically when `bundle.definition.autoLoad` is `true`;
otherwise a new `hasRunOnce = false` flag stays false and `sakal_report_screen.dart` shows a "Run Report"
empty-state panel instead of a spinner/table, until the user (or the filter bar's own pre-existing Apply
button — both converge on `refresh()`) explicitly triggers the first fetch.

This is layered ON TOP OF (not a replacement for) the already-lazy grouped-TABULAR fetch mechanism
(`report_data_controller.dart`'s `_loadRootGroups()`/`expandNode()` — confirmed by reading in full:
initial load already only fetches level-1 aggregated summary rows, full paginated detail only on
group-expand) — that mechanism keeps 50,000 rows from ever being rendered/fetched at once AFTER first
load; `auto_load` stops the FIRST load itself from firing automatically on screens where even that first
summary scan is too risky to run unfiltered.

Set `auto_load = false` on both `STOCK_BALANCE_MATRIX` (confirmed with the user, same unbounded-row-count
risk) and the new `STOCK_VALUE_BY_LOCATION`.

## Existing report — location scoping + filter

`v_stock_balance_matrix_source` (118) retrofitted with the same JWT-scoped `ric_user_location_access`
WHERE block as `v_user_accessible_locations` (127). New `ric_report_filters` row: `location_id`,
`DROPDOWN_LOOKUP` → `v_user_accessible_locations`.

## New report — "Stock Value by Location" (`STOCK_VALUE_BY_LOCATION`)

**`fn_stock_value_by_location(p_client_id, p_company_id, p_location_id, p_category_id, p_brand_id)`** —
a single function returning BOTH base and local currency columns on the same row (`price_base`,
`value_base`, `price_local`, `value_local`) — a deliberate departure from the original plan's Base/Local
"currency toggle" twin-function design (`fn_..._base`/`fn_..._local` + `source_object_local`). That
mechanism is explicitly unsupported for GROUPED reports (`ReportDataController`'s grouped-tree fetch path
— `_loadRootGroups`/`expandNode` — deliberately never consults `currencyMode`/`sourceObjectLocal`, per
`report_models.dart`'s own doc comment on `sourceObjectLocal`), and this report needs grouping for its
category subtotals. It also matches what the user actually asked for more directly: both Price/Value
pairs shown as columns simultaneously, not a switch between them. Caught and corrected during
implementation, before the migration was finalized.

- **`accessible_locations`** CTE — same location-access scoping as the retrofit above, narrowed by
  `p_location_id` when supplied.
- **`top_category`** CTE — walks each matching product's category up to its level-1 ("Main") root via a
  recursive "walk up to parent" CTE (adapted from `032_account_link_setup.sql`'s own CATEGORY
  account-link resolution), `COALESCE`d to `'Uncategorized'` for a product with no category — the
  COALESCE happens INSIDE the base function (not just the summary function) so the leaf-detail-row
  PostgREST filter (`top_level_category_name=eq.Uncategorized`, fired when a user expands that group)
  matches the same string the summary/grouping step produced. An earlier draft COALESCE'd only in the
  summary function, which would have silently returned zero rows on expand — caught via self-review of
  the engine's own group-expand filtering mechanism.
- **`loc_rates`** CTE — one `fn_get_exchange_rate` call per accessible location (short-circuits to `1`
  when base=local, so a single-currency company pays no meaningful extra cost).
- **`non_serial_rows`** — `rim_product_location` × `rim_products`, `tracking_type != 'SERIAL'`,
  `GROUP BY product`, weighted-average price/value in both currencies, `HAVING SUM(qty) > 0`.
- **`serial_rows`** — `v_serial_stock_status` filtered `status='IN_STOCK'`, one row per serial, joined to
  `rim_product_location` for that location's own cost.
- **`fn_stock_value_by_location_summary`** — level-1 group summary (`GROUP BY top_level_category_name`),
  the report's own `ric_report_group_levels` `summary_source_object`.
- **No separate totals function** — this report is grouped, and `ReportDataController.refresh()`'s
  grouped path never calls `fetchTotals` at all (confirmed: the grand total is free client-side
  arithmetic over the already-loaded level-1 summary rows via `groupedGrandTotal`). Migration 118's own
  Pilot 2 (also grouped) sets no `totals_source_object` either — same precedent.

### Dynamic, per-company currency-code column labels

The one genuinely new registry usage: no prior report interpolates a real currency code into a
`ric_report_columns` label (every other report's per-company registry loop inserts identical static
text). This report's registry DO-loop reads `base_currency`/`local_currency` from `ric_companies` per
company, builds labels dynamically (`'As on Price (' || v_base_ccy || ')'`, etc.), and — when
`base_currency = local_currency` for that company — skips inserting the Local column pair entirely (same
precedent as Ageing's own currency-columns-sometimes-irrelevant handling, migration 137).

### New filters/lookups
- **Location** — `v_user_accessible_locations` (127), optional.
- **Item Category** — plain lookup over `rim_item_categories` (any level; `fn_category_subtree` makes
  picking any level correct).
- **Brand** — new `v_product_brands` view (`rim_common_masters` joined `rim_common_master_types
  WHERE type_key='BRAND'`).

### Registry
`STOCK_VALUE_BY_LOCATION`, `TABULAR` + one `ric_report_group_levels` row (grouped-TABULAR, same shape as
Party Ageing/Pending Bills). Feature code `IN-RPT-SVL`, `screen_name='/reports/STOCK_VALUE_BY_LOCATION'`,
`group_code='IN-RPT'`, `serial_no=1`. `fn_seed_client_modules.sql` updated for future clients.
`ric_user_menus` backfilled for every existing user with view access to any Inventory feature (same
pattern as migration 119's own reporting-engine-pilot backfill).

## Critical files (as-built)
- `backend/migrations/148_inventory_stock_reports.sql` — everything above in one file: `auto_load`
  column; `v_stock_balance_matrix_source` retrofit + new filter + `auto_load=false`; `v_product_brands`;
  `fn_stock_value_by_location` + `_summary`; per-company dynamic-label registry DO-loop; `ric_user_menus`
  backfill.
- `backend/functions/fn_seed_client_modules.sql` — new `IN-RPT-SVL` row.
- `lib/core/reporting/report_models.dart` — `ReportDefinition.autoLoad` (default `true`).
- `lib/core/reporting/report_data_controller.dart` — `init()` gated by `autoLoad`, new `hasRunOnce` flag.
- `lib/core/reporting/sakal_report_screen.dart` — new "Run Report" empty-state branch.

## Known, accepted gaps (not fixed here, pre-existing / out of scope)
- A `DROPDOWN_LOOKUP` filter's PDF header summary (`_buildFilterSummary()`) prints the filter's raw
  selected value (an id), not its resolved label — a pre-existing engine-wide limitation affecting every
  report with a lookup filter, not something introduced by this migration. Not fixed here; flagged for a
  future generic fix.
- A client created after this migration runs does not automatically get the new report's
  `ric_report_definitions`/columns/filters/group_levels rows (only `ric_master_menus`, via
  `fn_seed_client_modules.sql`) — same accepted limitation as every prior per-company-DO-loop report
  registry migration (Incoterms, 118, 137, ...).

## Verification (pending — user has not yet run migration 148)
1. Stock Balance by Location: a user with `ric_user_location_access` rows now only sees their own
   locations pivoted; the new Location filter lists only their own accessible locations.
2. Stock Value by Location: no location picked → aggregates across all accessible locations; one picked
   → matches that location's own stock exactly.
3. A product held at two locations with two different `cost_price` values produces the correct
   quantity-weighted average `As on Price (Base)`; `Value (Base) = Balance Qty × that average` reconciles.
4. A serial-tracked product shows one row per serial currently `IN_STOCK`; batch/untracked products show
   one aggregated row.
5. Category filter narrows correctly at any level (subtree-inclusive).
6. Group subtotals: each Main Category subtotal equals the sum of its own rows' Value (Base); the
   report-level grand total equals the sum of all group subtotals.
7. A base=local-currency company shows only ONE Price/Value pair; a dual-currency company shows both,
   correctly labeled with real currency codes.
8. Both Stock Balance and Stock Value screens now open showing a "Run Report" prompt, not data. Every
   OTHER existing report still auto-loads exactly as before.
