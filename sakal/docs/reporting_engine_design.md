# Reusable Reporting Engine — architecture design (MVP1)

## Status (2026-08-04): built, not yet verified

All 5 build phases are implemented: backend registry (migration `116_reporting_engine.sql`), the core Flutter package (`lib/core/reporting/`), PDF/Excel export (including a matrix-aware pivoted Excel export), routing/menu wiring, and all 3 pilot reports (migrations `117_pending_bills_report_columns.sql`, `118_reporting_engine_pilots.sql`). Two real design bugs were caught and fixed *during* implementation, before either pilot's SQL was written — see the "Correction made during implementation" notes inline below (tenancy columns on the registry tables; `totals_source_object`/`summary_source_object` must be `STABLE` functions, never plain VIEWs, or filters would silently be ignored).

**Not yet done**: `flutter analyze`, `flutter test`, and running the migrations against Supabase — there is no local Flutter/Postgres toolchain in this environment (see `feedback_no_flutter_toolchain_verification` memory), so this needs to happen in the Codespace, same as every other feature in this project. Widget tests and pgTAP for the new tables/functions are not yet written either — do that after `flutter analyze`/migrations confirm the code and SQL are actually sound, not before.

## Context

Every ERP module so far (Sales/Purchase/Inventory/Finance) has shipped listing + transaction screens, but the `Reports` menu is still empty — `lib/features/reports/` doesn't exist. The only trace of reporting today is three stub routes seeded under Finance (`/finance/trial-balance`, `/finance/profit-loss`, `/finance/balance-sheet` — `fn_seed_client_modules.sql`, `app_router.dart`), each rendering a placeholder widget with no screen behind it.

The plan is to build reports **module by module** going forward, but without hand-building each one from scratch — a shared, configurable reporting engine (tabular + matrix/pivot, on-screen + PDF + Excel, filterable, sortable, with adjustable/hideable columns) that every future report plugs into, Odoo-style, without reinventing UI/export code each time.

Three exploration passes into the existing codebase confirmed the landscape:
- **`lib/core/printing/`** (`PrintEngine`, `pw.Document` via the `pdf`/`printing` packages) already solves "generate a PDF from data and download/share it cross-platform" — directly reusable plumbing. Its `PrintFieldRegistry`, however, is a hardcoded per-document-type Dart `switch` — too static for reports with runtime-defined columns (GL accounts, date grouping, etc.), so it's not reused for column definitions.
- **`SakalAdaptiveList`/`PagedListController`** (the shared list-rendering pair) have no sort-on-click, no column hide/show, no resize, and `PagedListController` has no sort/filter state — real gaps a reporting grid needs to fill, confirmed via source read.
- **Backend convention**: every existing report-like query is a plain `VIEW` or a `STABLE` `fn_...` with typed params, queried via ordinary PostgREST GET/RPC — no generic `p_filters JSONB` + dynamic-SQL pattern exists anywhere, and views never carry their own RLS (they inherit it from the base table's `auth_rw_<table>` policy via invoker-rights execution). A single mega `fn_run_report(key, filters jsonb)` with dynamic SQL would break that trust model — the design below deliberately avoids it.

Decisions made across several design-review rounds:
1. **DB-driven registry** — report definitions (columns, filters, sort defaults) live in new tables, not Dart code. Adding a report later means a migration, not a Flutter deploy.
2. **Design for a `HIERARCHICAL` report type now, build it later** — the schema accounts for Trial Balance/P&L/Balance Sheet's indented-tree-with-subtotals shape from day one, but MVP1 only implements `TABULAR` and `MATRIX`.
3. **Grouping is fixed per report** (the report author declares the group-by level(s) when building that report), not a runtime "Group by: ___" dropdown a user can change ad hoc — simpler, and keeps every grouped report's SQL as typed/declared objects rather than reopening the dynamic-SQL question decision 1 above deliberately closed.
4. **Multi-level grouping from the start** (e.g. Customer → Product Group, each with its own subtotal), not just a single group-by column.
5. **No per-user row-level visibility restriction for v1** — every report is scoped by company/client only, same as every existing RLS policy in this schema. A report is either visible to a user (via the menu/permission system) or it isn't; there's no "salesperson sees only their own records" filtering inside a report. Can be added per-report later without an engine redesign if a specific report needs it.
6. **Explicitly deferred to MVP2, not silently dropped** — see the dedicated MVP2 section below for email/share/scheduled-download. Also deferred, no concrete plan yet (revisit if actually requested): saved filter presets/"favorites", charts/graphs (wasn't part of the original requirements), and any report-level caching layer (deliberately skipped — risks stale numbers; the performance safeguards below should carry real load without it).

## Architecture summary

One **generic Flutter screen** (`ReportScreen(reportKey)`) renders any report by reading its definition from a **DB-driven registry** (4 new tables — 3 for the core definition, plus a 4th for optional grouping levels), and fetching data from the report's own backing `VIEW`/`STABLE fn_` — the same per-report-SQL-object convention every other module already uses, so RLS safety is inherited for free, not reinvented. Filtering, sorting, and pagination are pushed down to PostgREST/Postgres (`?order=`, `?limit=`, `?offset=`, `Prefer: count=exact`) rather than done client-side, directly addressing the performance concern. Matrix (pivot) reports get their aggregation done in SQL (`GROUP BY`) but their *pivoting* (turning one dimension into variable columns) happens client-side in Flutter over an already-small, pre-aggregated result set — avoids fragile `crosstab()`/dynamic-column SQL.

Net effect: shipping report #2, #3, #4... is "write a `VIEW`/`fn_`, insert registry rows, add a menu row" — no new Dart screen per report.

## Backend design

### Registry tables (migration `116_reporting_engine.sql`, built)

**Correction made during implementation**: every table in this schema — confirmed against `rid_grn_lines` and 115+ other migrations — carries `client_id`+`company_id` directly, including child/line tables, no exceptions. An earlier draft of this doc assumed the registry tables could be global/system-level with no tenant columns (reasoning by analogy to `PrintFieldRegistry`, which is a hardcoded Dart switch, not a table at all). That would have been the first table in this entire schema without `client_id`/`company_id`, so all 4 tables below carry them like everything else, with the standard `auth_rw_<table>` RLS policy. Report *definitions* are still not per-company *customized* content in practice — every company gets the same rows inserted for a given report (same shape as how Incoterms are seeded identically for every existing company, migration 086) — this is a tenancy-convention correction, not a change to what the data actually means.

**`ric_report_definitions`** — one row per report:
```
id, client_id, company_id, report_key, report_name TEXT,
report_type TEXT CHECK IN ('TABULAR','MATRIX','HIERARCHICAL'),   -- HIERARCHICAL unused until Phase 2
source_type TEXT CHECK IN ('VIEW','FUNCTION'),
source_object TEXT,            -- e.g. 'v_purchase_register' or 'fn_stock_summary_matrix'
module_code TEXT,              -- which module's menu it's grouped under
default_sort_column TEXT, default_sort_dir TEXT CHECK IN ('ASC','DESC'),
default_page_size INT DEFAULT 50,
use_exact_count BOOLEAN DEFAULT true,     -- false for reports over very large detail tables: use PostgREST's estimated (planner-based, near-free) count instead of Prefer: count=exact
max_export_rows INT DEFAULT 100000,       -- hard cap on a PDF/Excel export's row count; UI prompts to narrow filters instead of exporting past this
totals_source_object TEXT,                -- nullable: a STABLE FUNCTION (never a plain VIEW — see correction below) returning ONE row (SUM/COUNT per aggregate_fn column) over the same filters as source_object, no GROUP BY. NULL if the report has no aggregate_fn columns worth totaling.
is_active BOOLEAN DEFAULT true
```

**`ric_report_columns`** — one row per column:
```
id, client_id, company_id, report_id FK, column_key TEXT,      -- must match a field in the row JSON
label TEXT, data_type TEXT CHECK IN ('TEXT','NUMBER','DATE','BOOLEAN','BADGE'),
format TEXT, align TEXT CHECK IN ('LEFT','RIGHT','CENTER'),
sortable BOOLEAN DEFAULT true, default_visible BOOLEAN DEFAULT true,
default_width INT, sort_order INT,
aggregate_fn TEXT CHECK IN ('SUM','AVG','COUNT','MIN','MAX',NULL),  -- how this column rolls up in a group subtotal / grand total row; NULL = not aggregated (blank on subtotal rows)
is_pivot_row_group BOOLEAN DEFAULT false,   -- MATRIX only: fixed row key(s)
is_pivot_dimension BOOLEAN DEFAULT false,   -- MATRIX only: becomes the variable columns
is_pivot_measure BOOLEAN DEFAULT false,     -- MATRIX only: the aggregated value
currency_code_column TEXT,                  -- nullable: for a money column whose currency VARIES per row (trans_amount, party_amount), names the sibling column holding that row's own currency code, so the cell renders e.g. "500,000 CDF" using the row's own code
drilldown_route TEXT, drilldown_key_column TEXT,  -- nullable: e.g. drilldown_route='/purchase/grn', drilldown_key_column='grn_no' makes this cell a tappable link into that document's own EXISTING entry screen — zero new screens needed
parent_key_column TEXT, level_column TEXT   -- unused until Phase 2 (HIERARCHICAL), present so no later ALTER TABLE
```
**Number formatting**: a `NUMBER`-typed column's `format` is rendered through the app's existing `AppNumberFormat` utility (company grouping style + per-currency decimal settings, migration 091) — not a new formatting mechanism, just reuse.

**Multi-currency design — which of the schema's 4 amount columns (`trans_amount`, `base_amount`, `local_amount`, `party_amount`) a report may aggregate**: the distinction isn't "pick one currency for the whole report," it's "which column stays the same currency across every row, and which varies row by row":
- **`base_amount` and `local_amount` are safe to `SUM`/`AVG`** — both are *company-level* currencies (every transaction in a company converts to the same base currency and the same local currency), so they're consistent across every row regardless of what each individual document was raised in. A report can total either, or expose **both side by side** as two separate aggregate columns (useful for DRC/Zambia's base-vs-local dual reporting need) — no runtime currency switcher needed.
- **`trans_amount` and `party_amount` are never safe to aggregate** — they vary per row (one invoice in CDF, the next in USD; a customer's own ledger currency). These stay display-only (`aggregate_fn = NULL`), always paired with `currency_code_column` pointing at that row's own currency code so the cell renders correctly per row, never summed, never used as a `MATRIX` pivot measure or a group subtotal.
- **Detail rows commonly show both**: an "Amount (Original)" reference column (`trans_amount` + `currency_code_column`, varies per row, informational) alongside an "Amount (Base)" column (`base_amount`, rendered with the company's single fixed base-currency symbol from session/company config) that's what actually gets summed. Totals bar, group subtotals, and grand total are always computed from the base/local column(s), never the original-currency one.
- Because `base_amount`/`local_amount` are already stored per-transaction at that transaction's own *historical* exchange rate (the existing "always-multiply, rate stored per line" convention), summing them gives a historically-correct total automatically — no fresh revaluation logic needed in the reporting engine itself.
- This is a report-authoring discipline (which source column a report's `VIEW` exposes as its aggregate column), not something a `CHECK` constraint can enforce — the code-review verification step below exists specifically to catch it before a report ships.

**`ric_report_filters`** — one row per filter control:
```
id, client_id, company_id, report_id FK, filter_key TEXT, label TEXT,
filter_type TEXT CHECK IN ('DATE_RANGE','DATE','DROPDOWN_STATIC','DROPDOWN_LOOKUP','ACCOUNT_PICKER','PRODUCT_PICKER','TEXT','BOOLEAN'),
lookup_source TEXT,             -- table name for DROPDOWN_LOOKUP
static_options JSONB,           -- fixed list for DROPDOWN_STATIC
param_target TEXT,              -- the actual PostgREST column / RPC param name this maps to
required BOOLEAN DEFAULT false, default_value TEXT, sort_order INT
```
RLS: standard `auth_rw_<table>` policy on all 4 tables (see correction note above) — client_id/company_id scoped, same pattern as every other table in this schema.

### Grouping & subtotals (e.g. Sales Register subtotaled by Product Group, plus a grand total)

Grouping is a capability layered onto a `TABULAR` report, not a new report type — and it's architecturally the same idea `MATRIX`'s row-group already uses (a dimension whose distinct values become subtotal buckets), just applied to rows-with-nested-detail instead of rows-with-pivoted-columns.

**`ric_report_group_levels`** — one row per grouping level per report, ordered outermost-first:
```
id, client_id, company_id, report_id FK,
level_no INT,                    -- 1 = outermost (e.g. Customer), 2 = next (e.g. Product Group), ...
group_by_column TEXT,            -- key column present in this level's summary rows AND the detail rows below it — used to filter children on expand
group_label_column TEXT,         -- human-readable column shown in the group header row (often same as group_by_column)
summary_source_object TEXT,      -- a dedicated STABLE FUNCTION (never a plain VIEW — see correction below): filters its own base rows by argument, THEN aggregates: SELECT <level1_col>..<this level's col>, <label_col>, <agg columns> ... GROUP BY <level1_col>..<this level's col>
UNIQUE(report_id, level_no)
```

**Why a dedicated summary object per level, not one dynamic GROUP BY**: PostgREST has no generic "group by this column" query-string feature, and the design deliberately ruled out dynamic SQL to protect the RLS trust model. So each level gets its own small, hand-written, typed SQL object — same effort and safety posture as the report's main detail view, just one more object per level. A 2-level report therefore ships with 3 SQL objects total: the detail view + 2 summary objects (level 1 grouped by `customer`, level 2 grouped by `customer, product_group`).

**Correction made during implementation — `summary_source_object` (and `totals_source_object` below) must always be a `STABLE` FUNCTION, never a plain VIEW.** A plain `VIEW` doing `SELECT product_id, SUM(qty) ... GROUP BY product_id` has already collapsed away every column that isn't `product_id` or the aggregate itself — there's no `trans_date` left in its output for PostgREST to filter on. PostgREST's `?col=op.val` filters apply to a relation's own OUTPUT columns, which is AFTER a view's internal aggregation has run, not before — so a plain view here would silently ignore every filter the user applied on screen (dates, location, search text), showing subtotals for the WHOLE table regardless of what's currently filtered. A `STABLE` function sidesteps this: filter values arrive as real function arguments and get applied inside the function's own `WHERE` clause *before* it aggregates — the only way a summary/totals query can stay consistent with the detail rows the user is actually looking at. Caught by tracing the actual query mechanics before writing the pilot's SQL, not discovered as a live bug.

**Authoring rule (revised)**: a summary function's own `WHERE` clause must apply the same filters as the detail view's filterable columns (`ric_report_filters.param_target`, passed in as the function's own named parameters — e.g. `p_trans_date_from`/`p_trans_date_to`), so a date-range/location filter applied on screen produces consistent totals at every level, not just in the detail rows. A summary function's aggregate output columns must reuse the *same* `column_key` names as `ric_report_columns` declares for the detail row — this lets one rendering code path draw a cell from either a detail row or a group-summary row with no special-casing.

**Fetch pattern (on screen)** — mirrors Odoo's collapsed-by-default list grouping, and resolves the pagination-vs-subtotal tension directly:
1. On load, fetch level 1's summary rows in full (no pagination needed — it's one row per distinct level-1 value, e.g. ~dozens of customers, not thousands of invoice lines) → render as collapsed group headers, subtotal cells already visible.
2. Expanding a level-1 group calls level 2's summary function with that group's own key passed as an argument (`?<level1_col>=<value>`, a raw function argument, not a PostgREST `eq.` filter) → nested collapsed sub-group headers with their own subtotals.
3. Expanding the deepest configured level fetches actual **detail** rows from the report's normal `source_object`, filtered by every ancestor group key, using the existing paginated fetch (`ReportDataController`) — this is the only tier that can be large, and it's the only tier that was ever paginated.
4. Every expand is cached client-side (re-collapsing/re-expanding doesn't refetch).
5. **Grand total**: summed client-side from the (small, fully-loaded) level-1 summary rows — free, no extra query needed for a *grouped* report specifically (see the general "Report totals" mechanism below for reports with no grouping tier to lean on). Pinned as a sticky footer row.

**Export (PDF/Excel)**: always renders fully expanded, regardless of on-screen collapse state — fetches the complete filtered/sorted detail set once (same "ignore on-screen pagination" rule export already follows), then computes every level's subtotal rows plus the grand total from that one fully-loaded set client-side, interleaving subtotal rows after each group in the printed/exported order. Nobody wants a downloaded report with collapsed groups.

**Indexing**: each level's `group_by_column` needs an index on the underlying base table (same rule as sortable/filterable columns above) — usually already covered since these are typically FK columns (`customer_id`, `product_group_id`).

**`MATRIX` reports get row/column totals the same way, for free**: since matrix data is already a small, fully-loaded, pre-aggregated set, row totals (sum across pivoted columns), a column-totals footer row, and a grand-total corner cell are all cheap client-side arithmetic over data already in memory — no new fetch pattern needed there.

### Report totals — visible the instant the report runs, never dependent on pagination

The real gap this closes: a plain *ungrouped* `TABULAR` report (e.g. a 2,000-row Sales Register, 50 rows/page) has no small "already loaded" tier to derive a total from the way a grouped report's level-1 rows provide for free — summing only the currently-loaded page would silently show the wrong number, and making the user page to the end to see a total is a real usability failure, not an acceptable trade-off.

**Mechanism (same idea Odoo's own list-view footer sum and most BI tools use — a dedicated aggregate query, not a derived one)**: any report with at least one `aggregate_fn`-flagged column declares `totals_source_object` — one more small, typed SQL object, same authoring convention as everything else here. Same correction as `summary_source_object` above applies: **always a `STABLE` function, never a plain VIEW**, taking the report's own filters as named arguments (`p_trans_date_from`, etc.) and applying them in its own `WHERE` clause before aggregating — `fn_x_totals(p_client_id, p_company_id, p_trans_date_from, p_trans_date_to, ...) RETURNS TABLE(qty NUMERIC, value NUMERIC, row_count BIGINT)`, no `GROUP BY`, always exactly one row. Deliberately **not** built on a PostgREST built-in aggregate `select=` expression (some newer PostgREST versions support `sum()`/`count()` inline in `select=`) — that would be a version-dependent capability to rely on, and wouldn't solve the pre-aggregation filtering problem anyway.

**Fetch/render**: when the report screen loads (and again whenever a filter changes), the totals query fires *once*, in parallel with the first page of detail rows — it's a single-row, indexed, cheap aggregate, same cost class as a grouped report's level-1 summary. The result renders as a sticky totals bar/footer that stays visible and unchanged regardless of which page the user is currently viewing — it only re-fetches when filters change, never on page-through. This directly answers "should the total be visible as soon as the report runs": yes, because it's never coupled to pagination in the first place.

A report with no `aggregate_fn` columns (e.g. a pure text/date listing with nothing worth totaling) simply leaves `totals_source_object` NULL and gets no totals bar — not every report needs one.

**Consistency check**: since export computes its own grand total client-side from the fully-fetched export dataset (see Export section above), the pgTAP/verification suite should assert the on-screen totals bar and an export's computed grand total agree for the same filters — the one place these two independent code paths could silently drift if a `totals_source_object`'s WHERE clause and the detail view's ever fall out of sync.

### Every report is still its own VIEW or STABLE function
No new dynamic-SQL/generic-filter mechanism. A report's backing object stays a normal, typed, per-report `VIEW` (simple aggregation) or `STABLE fn_...` (needs computation), following the exact pattern `v_pending_bills` / `fn_compute_stock_count_variance` already establish. This is what keeps RLS intact — the view/function runs with invoker rights, so the base table's existing `auth_rw_<table>` policy enforces `client_id`/`company_id` scoping exactly as it does today, with zero new security surface.

**Unifying detail**: mandate every report-backing function be `STABLE` and called via **GET**, not POST — PostgREST allows `STABLE`/`IMMUTABLE` functions to be invoked as `GET /rpc/fn_name?p_arg=val&order=...&limit=...&offset=...`, which means `order=`/`limit=`/`offset=`/`select=` all work identically whether the source is a view or a function. The Flutter data-source layer gets ONE code path instead of two.

**Total-count for pagination**: use `Prefer: count=exact` (a standard PostgREST header, not yet used elsewhere in the app) to get `Content-Range` back with total row count, driving "N results" / total-pages UI.

**Indexing**: any column a report declares `sortable`/filterable must already be indexed on the underlying base table (or gets a new index in that report's migration) — sort/filter/pagination all happen in Postgres, not by loading everything into Flutter and sorting client-side. This is the direct answer to the sort-performance requirement.

**Historical accuracy for "as of a date" reports**: this schema already established the right principle for Stock Count — variance is computed by summing the immutable `ril_stock_ledger` as of a chosen date, never by reading a live `current_stock` balance. Any future report with the same shape (AR/AP aging, stock valuation, any "as of [date]" report) must follow the same rule: compute from the immutable ledger/history as of that date, not from a live/current balance column. This is a per-report authoring discipline, not an engine mechanism — noted here so it isn't rediscovered as a bug later.

## Performance & scale safeguards

Worked through against a concrete worst case — a product-wise sales report over a 2-year date range on a multi-million-row transaction table — to make sure this degrades gracefully instead of hanging, timing out, or crashing:

- **A "product-wise" report is a grouped report, not a flat one.** The screen only ever asks Postgres for `GROUP BY product` sums — the result set Flutter receives is bounded by *distinct products* (hundreds/thousands), never by how many transactions happened over the date range. Two years of raw transactions are only fetched if a user explicitly expands one product's detail rows, and that fetch is paginated (50 at a time) exactly like the group-1 summary is not. This is the direct mitigation for "will it hang."
- **`ListView.builder` is a hard rule for `SakalReportTable`/`SakalReportMatrixTable`**, not an implementation detail — rows (and group headers) are lazily built for what's on screen plus a small overscroll buffer, never eagerly built into a `Column` for the full result set. Row count on screen never determines Flutter's rendering cost, only what's currently visible does.
- **Default bounded filters**: any `DATE_RANGE` filter should ship with a sane `default_value` (e.g. "this month") rather than blank/unbounded — a report shouldn't be able to accidentally trigger a full unfiltered 2-year scan just because nobody touched the filter bar yet. Applies to the initial group-1 summary fetch too, not just detail rows.
- **`use_exact_count`**: `Prefer: count=exact` forces Postgres to run a real `COUNT(*)`, which is fine on an indexed, filtered query but a real cost on a loosely-filtered scan of a huge detail table. Reports over very large detail views can flip this off in favor of PostgREST's estimated (query-planner-based, near-free) count — "About N results" instead of an exact number, a report-level config choice, not a code change.
- **Export is the one place a "give me everything" request is legitimate, and the one place a naive implementation could actually OOM or freeze the UI**: both the `pdf` and `excel` packages build the full document in memory before writing it, with no true streaming. `max_export_rows` (on `ric_report_definitions`) hard-caps this — exceeding it prompts "narrow your filters" rather than attempting an unbounded export. Within the cap, export generation runs off the UI thread (`compute()`/isolate) with a progress indicator, so even a large-but-allowed export doesn't freeze the app while it builds.
- **Query timeouts surface as a normal error, not an indefinite hang**: report endpoints go through the same `DioClient`/`ErrorPresenter`/`AppLogger` path every other screen already uses (see CLAUDE.md's "Error handling" convention) — a slow/timed-out query shows a friendly message, not a frozen spinner. Worth explicitly setting a longer `receiveTimeout` for report endpoints specifically during implementation, since a legitimate large aggregate query can reasonably take longer than a normal CRUD save.

## Frontend design — `lib/core/reporting/` (new, mirrors `lib/core/printing/`'s shape)

- **`report_models.dart`** — `ReportDefinition`/`ReportColumn`/`ReportFilter` Dart classes (`fromJson`), mirroring the registry tables.
- **`report_repository.dart`** — fetches a report's definition (cached via a Riverpod `FutureProvider.family`, same convention as `master_cache_providers.dart`), and fetches report **data**: builds the GET querystring generically from active filter values (`eq.`/`gte.`/`lte.`/`ilike.` per `filter_type`) + `order=<col>.<asc|desc>` + `limit=`/`offset=`, targets `/<source_object>` or `/rpc/<source_object>` depending on `source_type`. Default `select=*` (simplifies column show/hide to a pure client-side/no-refetch toggle, see below) unless a report opts into a restricted `select`.
- **`report_data_controller.dart`** — a `PagedListController`-like state holder, but adding `sortColumn`/`sortDir`/`Map<String,dynamic> filterValues`, re-fetching page 1 whenever any of those change; scroll-triggered `loadMore` for subsequent pages, same UX as the existing pagination rollout. Also fires the (independent, single-row) totals fetch whenever filters change — never on `loadMore`/page-through — exposing a `totals` value the screen renders as a sticky bar regardless of scroll/page position.
- **`sakal_report_filter_bar.dart`** *(new shared widget — confirmed nothing like it exists yet)* — renders the right input per `ReportFilter.filter_type` (date-range picker, `DropdownButtonFormField` for static/lookup dropdowns, `SakalAutocomplete` for account/product pickers, `TextField`, checkbox), collects values, `onApply` callback. A `TEXT` filter debounces (~350ms, same convention `PagedListController`'s own search-filter rollout already uses elsewhere) rather than re-running the report on every keystroke; dropdowns/dates apply immediately on change.
- **`sakal_report_table.dart`** *(new desktop-oriented grid, not a `SakalAdaptiveList` reuse — reports are inherently wide/desktop-first)* — tappable column headers toggle sort (re-fetches via the controller, not client resort); a drag handle on each header's right edge resizes that column (local `Map<String,double>` width state, min-width clamped); a "Columns" button opens a checklist to toggle visibility — since `select=*` already fetched every column, this is instant local state, no refetch. Mobile falls back to a simple stacked-card list (same card-rendering idea `SakalAdaptiveList` already uses) since resize/hide is a desktop-table concept. When `ric_report_group_levels` rows exist for the report, the grid switches to grouped mode: collapsible group-header rows (▶/▼ + label + subtotal cells) nested per level per the fetch pattern above, a sticky Grand Total footer row, and expand-state + fetched-group-rows cached in local state so re-expanding never refetches.
- **`sakal_report_matrix_table.dart`** — takes the normalized rows + the report's declared row-group/pivot-dimension/measure columns, pivots client-side (distinct pivot-dimension values → dynamic column set, computed at render time) into the wide matrix shape, then reuses the same row/cell rendering primitives as the tabular grid. Pivoted columns aren't independently sortable/resizable in v1 — keeps it simple, matches "mostly for Excel download" framing.
- **`report_pdf_export.dart`** — reuses `PrintEngine`'s existing `pw.Document`/`printing`-package plumbing directly (bytes → `Printing.sharePdf()`/`layoutPdf()`, same call already used for documents) with a new, much simpler renderer: title + filter summary line + a paginated table (`pw.TableHelper.fromTextArray` or equivalent) + page footer. Not built on `PrintTemplate`/`PrintElement` — confirmed too document-centric for this. Same `max_export_rows` cap + `compute()`/isolate + progress indicator as Excel export.
- **`report_excel_export.dart`** — uses the already-installed `excel` package (currently import-only, no export code anywhere to reuse) to build a workbook from the full filtered/sorted result set (ignores on-screen pagination, respects filters/sort, checked against `max_export_rows` first — see Performance section above) with per-`data_type` cell formatting, generated via `compute()`/isolate with a progress indicator. Needs one small new cross-platform "save these bytes as a downloadable file" helper (`file_picker`'s `saveFile` is already a dependency and should cover web/mobile/desktop) — pin down the exact API during implementation, not a design blocker.
- **`sakal_report_screen.dart`** — the one generic screen: `ReportScreen({required String reportKey})`, `ConsumerStatefulWidget` + `ScreenPermissionMixin` with `screenName = '/reports/$reportKey'`. Loads the definition, renders title + PDF/Excel export buttons + `SakalReportFilterBar` + (`SakalReportTable` or `SakalReportMatrixTable` per `report_type`) wired to `ReportDataController`.

**Drill-through**: when a column declares `drilldown_route`/`drilldown_key_column`, its cells render as a tappable link (`GoRouter.push` to that route with the row's key value) — since every destination (GRN, Sales Invoice, etc.) already has a working entry screen, this is pure wiring, no new screens. Standard ERP UX ("click a line in the Sales Register, land on the actual invoice") for near-zero extra cost.

## Routing/menu integration

- One new parameterized route in `app_router.dart`: `GoRoute(path: '/reports/:reportKey', builder: (c, s) => ReportScreen(reportKey: s.pathParameters['reportKey']!))`.
- Each new report's migration adds one `ric_master_menus` row (`screen_name = '/reports/<report-key-kebab>'`) under its owning module's menu group — same seeding mechanism every other feature already uses.
- Existing Finance stub routes (`/finance/trial-balance` etc.) are left untouched for now — Phase 2 decides whether they fold into `HIERARCHICAL` or stay bespoke; nothing here removes or breaks them.

## What the end user actually sees (plain-language walkthrough)

1. **Getting to a report** — Reports menu, organized by module (Sales/Purchase/Inventory/Finance Reports), same as any other menu today. Click a report, e.g. "Sales Register."
2. **It opens already showing something useful** — filter bar pre-filled with a sensible default (e.g. "this month"), not blank. A **Totals bar** ("Total Qty: 12,450 | Total Value: $340,120") is visible immediately, before touching pagination. Data below — table on desktop, cards on mobile.
3. **Narrowing it down** — change filters, the table and totals bar update together. Typing in search doesn't refresh on every keystroke.
4. **Looking at the data** — click a column header to sort; drag a column edge to resize; a "Columns" button hides ones not needed. A grouped report (e.g. by Product Group) starts collapsed with each group's own subtotal already showing — click to expand and see the transactions inside; a grand total stays pinned at the bottom regardless of scroll position. A matrix report looks like a spreadsheet (e.g. products down the side, locations across the top) with row and column totals. Clicking a linked cell (e.g. an invoice number) jumps straight into that actual document.
5. **Getting it out of the app** — Download PDF / Download Excel, both exporting everything matching the current filters (not just the visible page), fully expanded with subtotal and grand-total rows.
6. **On a phone** — same filters, same totals, same export buttons, but a simple card list instead of a resizable table.

## MVP2 (next phase — deliberately not part of this build)

Three features planned next, once MVP1 (this design) is proven out — named now so the MVP1 design doesn't accidentally foreclose them:

- **Email a report** — send the PDF/Excel export as an email attachment (or a link) directly from the report screen, instead of only downloading it locally. Needs email-sending infrastructure this app doesn't have anywhere yet (no SMTP/transactional-email integration exists in the codebase today) — that infrastructure question is bigger than the reporting engine itself and should be scoped as its own small project when MVP2 starts, not assumed away.
- **Share (mobile)** — hand the exported file to the OS share sheet (WhatsApp, email client, Drive, etc.) instead of only saving it. Flutter's `share_plus` package is the standard tool for this and is not yet a dependency — small, low-risk addition when the time comes. Likely the easiest MVP2 item since MVP1 already produces the PDF/Excel bytes; this is just a different destination for them (`Share.shareXFiles(...)` instead of/alongside the save-to-disk helper).
- **Schedule a large report to generate in the background, download when ready** — for a report large enough that a live export isn't practical (approaching or past `max_export_rows`, or just slow enough to not want to wait on screen). This is functionally a small job queue: request → generate off-device or in a background task → notify the user → download when ready, rather than the MVP1 "generate now, in an isolate, with a progress bar" flow. Needs its own design pass at MVP2 time (where does generation actually run — a background Flutter isolate is not the same as a durable job that survives the app closing, so this likely needs either a scheduled Postgres/Edge-Function job or a proper backend worker, not just a longer client-side wait).

**Why MVP1's design doesn't block these**: `max_export_rows`, the `compute()`/isolate export generation, and the PDF/Excel byte-producing functions are all already isolated into their own small pieces (`report_pdf_export.dart`/`report_excel_export.dart`) rather than baked into the screen — MVP2's "share" and "schedule" features are new *destinations/triggers* for those same bytes, not a rebuild of how they're produced.

## Build phases

1. **Backend registry** — migration creating the 4 tables above (`ric_report_definitions`, `ric_report_columns`, `ric_report_filters`, `ric_report_group_levels`) + RLS/grants.
2. **Core Flutter reporting package** — models, repository, data controller, filter bar, tabular grid (sort/resize/hide + grouped/collapsible mode with grand-total footer), matrix grid (with row/column totals).
3. **Export** — PDF (reusing `PrintEngine` plumbing) and Excel (`excel` package + new save-bytes helper), both rendering grouped reports fully expanded with subtotal + grand-total rows.
4. **Routing/menu wiring** — the one parameterized route.
5. **Three pilot reports, to validate the whole pipeline before module-by-module rollout begins:**
   - **Tabular pilot**: register the already-existing `v_pending_bills` view as a `TABULAR` report (zero new backend SQL) — proves filter bar → sort → resize → hide/show → PDF → Excel end to end on real data with no new business logic risk.
   - **Grouped tabular pilot**: extend the same `v_pending_bills` dataset with 2 grouping levels (e.g. level 1 = customer, level 2 = currency — both already present columns, no new business logic) plus their 2 summary views — proves the multi-level expand/collapse + subtotal + grand-total mechanism end to end before any real module report depends on it.
   - **Matrix pilot**: one small new view, e.g. `v_stock_balance_matrix_source` (product_id/name × location_id/name × current_stock, a plain `SELECT` off `rim_product_location` — no new business logic), registered as a `MATRIX` report (row-group = product, pivot-dimension = location, measure = current_stock) — proves client-side pivoting + row/column totals + Excel export of a pivoted shape.

## Critical files
- `lib/core/printing/print_engine.dart`, `print_models.dart` — PDF plumbing to reuse for export.
- `lib/core/widgets/sakal_adaptive_list.dart`, `lib/core/utils/paged_list_controller.dart` — existing patterns the new grid/controller follow but don't extend (gaps confirmed: no sort/hide/resize).
- `lib/core/utils/screen_permission_mixin.dart` — reused as-is by `ReportScreen` (dynamic `screenName`).
- `lib/core/router/route_names.dart`, `app_router.dart` — where the one parameterized route is added.
- `backend/migrations/020_pending_bills_view.sql`, `079_stock_count_review.sql` (`fn_compute_stock_count_variance`) — the existing per-report VIEW/function convention being followed, not replaced.
- `backend/functions/fn_seed_client_modules.sql`, `ric_master_menus` — menu-seeding convention for each new report's menu row.
- `sakal/pubspec.yaml` — confirms `pdf`, `printing`, `excel`, `file_picker` are already dependencies; no grid/pivot package needs adding.

## Verification plan
1. `flutter analyze` clean after each phase.
2. New widget tests for `SakalReportTable` (click-to-sort calls the controller with the right column/direction, resize drag updates width, hide/show toggle removes a column without refetching; grouped mode: expanding level 1 fetches level 2 summary rows filtered by the right key, expanding level 2 fetches paginated detail rows, re-collapsing/re-expanding doesn't refetch, grand-total row sums correctly) and `SakalReportFilterBar` (each filter type renders and reports its value on Apply).
3. pgTAP for the registry migration (definition/columns/filters/group-levels round-trip, RLS grants) plus the three pilot views/summary views — including a check that a level-2 subtotal plus its siblings sums back to the parent level-1 subtotal, and all level-1 subtotals sum to the grand total.
4. Manual smoke test of all three pilot reports at desktop and mobile widths (mobile falls back to card layout) — sort, filter, resize, hide a column, expand/collapse both grouping levels, then PDF export and Excel export, confirming the downloaded file is fully expanded with correct subtotal and grand-total rows matching on-screen data.
5. Load-test at least one pilot against a seeded large dataset (tens/hundreds of thousands of detail rows behind a small number of groups) to confirm: initial load stays fast (group-summary-only), scrolling/expanding stays smooth (`ListView.builder`, no full-list eager build), and an export attempt past `max_export_rows` prompts to narrow filters instead of hanging or crashing.
6. Add a `totals_source_object` to the Tabular pilot (`v_pending_bills`, e.g. `SUM(balance)`/`COUNT(*)`) and confirm: the totals bar shows the correct number immediately on load (before touching pagination), stays unchanged while paging through, updates only when a filter changes, and matches the grand total computed by that same pilot's Excel export.
7. Add `drilldown_route`/`drilldown_key_column` to one column on the Tabular pilot and confirm tapping it navigates to the correct existing entry screen with the right record loaded.
8. Code-review check (not a test — this is a human-judgment rule, not something CI can verify): confirm every `aggregate_fn=SUM/AVG` column declared across the pilot reports maps to `base_amount`/`local_amount` (or an equivalent genuinely company-level, single-currency source), never `trans_amount`/`party_amount` or any column that can vary per row; confirm every `trans_amount`/`party_amount`-sourced column has a `currency_code_column` set and no `aggregate_fn`.
