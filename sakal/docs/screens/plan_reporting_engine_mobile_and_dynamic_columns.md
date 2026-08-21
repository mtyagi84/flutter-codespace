Status: Implemented 2026-08-21.

# Reporting Engine — mobile filter-bar layout bug + dynamic Barcode/Serial No column visibility

## Context

Two bugs found via live testing of the Inventory reports (Stock Balance/Value/Details/Ledger), both
confirmed to be real gaps in the shared Reporting Engine (`lib/core/reporting/`), not report-specific:

1. Mobile filter fields didn't fill available width — `SakalReflowRow` pre-computed a single uniform
   child width from a global estimate (`totalWidth / minChildWidth`), then applied it to every child
   inside a `Wrap`. On a narrow screen this estimate didn't match how `Wrap` actually breaks lines (it
   computed ~1.5 "units per row" but `Wrap` only fit 1 real field per line), leaving dead trailing space.
2. Barcode/Serial No columns (Stock Value/Stock Details reports, migrations 148/149) always showed —
   `ric_report_columns.default_visible=true` is a static per-company DB flag; the engine had no concept
   at all of a dynamically-gated column (confirmed: zero precedent anywhere in the reporting engine for
   company-setting-driven or data-driven visibility).

## Fixes

### `SakalReflowRow` (`lib/core/widgets/sakal_reflow_row.dart`)
Replaced the estimate-then-`Wrap` approach with grouping children into real rows first (by cumulative
weight vs. `unitsPerRow = floor(totalWidth / minChildWidth)`), then rendering each row as a `Row` of
`Expanded(flex: weight)` children — every row's children now divide 100% of that row's real width by
weight, with no gap between an estimate and what `Wrap` actually does. Fixes the mobile dead-space bug
directly and is more correct in general (any partial row, on any screen size, now stretches).

### Dynamic column visibility — centralized, not per-report
New provider `hasSerialTrackedProductsProvider` (`lib/core/providers/master_cache_providers.dart`, same
shape as `baseCurrencyProvider`) — a cheap existence check (`GET /rim_products?tracking_type=eq.SERIAL
&is_deleted=eq.false&limit=1`). Company-level signal (does this company use serial tracking at all),
not a per-fetch "did this result happen to include a serial row" check — deliberately chosen because
Stock Value (148) is a GROUPED report whose top-level summary rows never carry `serial_no`, so a
fetched-rows check wouldn't work uniformly across grouped and ungrouped reports.

`report_models.dart`: `ReportBundle.copyWith({columns})`; new top-level `filterDynamicColumns(columns,
{enableBarcode, hasSerialTracking})` — drops `columnKey=='barcode'` when `!enableBarcode`, drops
`columnKey=='serial_no'` when `!hasSerialTracking`. Small explicit rule keyed by these two well-known
column keys, not a pluggable registry.

`sakal_report_screen.dart` — the one generic screen every report renders through, so fixing it here
covers every report automatically: `build()` computes `effectiveBundle = bundle.copyWith(columns:
filterDynamicColumns(...))` and passes it (not the raw `bundle`) into `SakalReportTable`/
`SakalReportMatrixTable` — covers both desktop (confirmed: `SakalReportTable`'s `_hiddenColumns` is a
subtractive filter applied on top of `widget.bundle.columns`, read fresh via a getter every build, so
a column simply absent from the list has no stale-`initState` issue) and mobile cards (reads
`bundle.visibleColumns`, which now operates on the already-filtered list). `_exportPdf()`/
`_exportExcel()` apply the same `filterDynamicColumns(...)` call to the separate `columns:` argument
passed to `ReportPdfExport.export`/`ReportExcelExport.export`/`exportMatrix`.

No changes needed inside `sakal_report_table.dart`, `report_pdf_export.dart`, or `report_excel_export.dart`
— all three already correctly consume whatever column list they're handed; the fix is entirely in what
gets handed to them, computed once, centrally.

## Critical files
- `lib/core/widgets/sakal_reflow_row.dart`
- `lib/core/providers/master_cache_providers.dart` — new `hasSerialTrackedProductsProvider`.
- `lib/core/reporting/report_models.dart` — `ReportBundle.copyWith`, `filterDynamicColumns`.
- `lib/core/reporting/sakal_report_screen.dart` — wired into `build()`, `_exportPdf()`, `_exportExcel()`.
- No backend/migration changes — both bugs are Flutter-only.

## Verification
1. Any report's filter bar on a mobile-width viewport: every field fills its own row edge-to-edge.
2. Stock Value/Stock Details, screen + PDF + Excel, on a company with `enable_barcode=false`: Barcode
   column absent from all three.
3. Same reports, on a company with zero `tracking_type='SERIAL'` products: Serial No column absent from
   all three.
4. A company WITH both enabled still sees both columns exactly as before.
5. Every other existing report (no `barcode`/`serial_no` columns) is unaffected.
