# Profit & Loss reports — Finance (first HIERARCHICAL report type)

Status: Implemented 2026-08-19 (migration `143_profit_loss_hierarchical.sql`), not yet run in Supabase.

## Context

Two new reports: **P&L Group Summary** (groups + subtotals only, no individual accounts) and **P&L
Account Detail** (full account-level breakdown under its real group hierarchy). Both built on
`report_type='HIERARCHICAL'`, which existed in the Reporting Engine's schema since migration 116
(`ric_report_columns.parent_key_column`/`level_column` were even reserved for it) but had **zero
rendering support in Flutter** until this build — confirmed by grep: `ReportDefinition.isHierarchical`
was checked nowhere in `sakal_report_screen.dart`'s widget-selection logic.

### Why not the existing fixed-depth grouped mechanism
Ageing and Pending Bills already have a working multi-level collapsible-group mechanism
(`ric_report_group_levels`), but it requires a *fixed* number of levels declared per report. User
explicitly ruled this out: *"we have no control over group hierarchy in Finance accounts so we can not
go with fixed 2 level hierarchy, we have to build a real arbitrary depth"* — confirmed correct by
reading both COA seeds in `013_chart_of_accounts.sql`: some accounts sit directly under the top-level
root, others are 2-3 levels deep, and this varies per account, not just per company.

### Root account codes (same technique as the Expense Report's `v_expense_accounts`, migration 141)
- INDIAN: Income root `4000` ('Revenue'), Expense root `5000` ('Expense')
- OHADA: Income root `7000` ('Class 7 - Revenue'), Expense root `6000` ('Class 6 - Expenses')

`accounting_std` lives on every `rim_accounts` row including the roots, so no join to
`rim_accounting_setup` is needed — the root is found directly by `parent_id IS NULL AND account_code IN
(...)`.

### Location Group — confirmed no separate "Company-wide vs Entity-level" mechanism needed
Reusing Trial Balance's own `p_location_group_id` filter pattern verbatim: leaving it blank *is* the
company-wide view, picking a specific group *is* the entity-level view, for both `SIMPLE` and
`INTER_ENTITY` companies. An inter-entity invoice between two location groups already posts as real
Income in the selling group's own books and real Expense in the buying group's, so the GL data is
already location-tagged correctly — no special-casing needed for `inter_location_model`.

## Design

### Fetch pattern: whole tree at once, not lazy per-node
A P&L's account tree is small (hundreds of nodes at most) — so instead of the lazy per-node
`expandNode` round-trip the grouped-TABULAR mechanism uses, the whole tree is fetched **once** per
load, same shape MATRIX already uses. All expand/collapse happens **client-side**, instant, no spinner
per node.

### `fn_pl_tree_base`/`_local` — the core recursive engine
Returns every node (group and leaf) under both roots that has non-zero net activity, each carrying its
own `parent_id` so the frontend can build a genuine tree:
1. **`subtree`** — walks *down* from both roots (arbitrary depth), tagging every descendant with
   `section` ('INCOME'/'EXPENSE') and `level_depth`.
2. **`ancestry`** — walks *up* from every posting-allowed leaf back through `subtree`, collecting
   **every** ancestor along the way (not just the root, generalizing `v_expense_accounts`'s own
   upward-walk technique).
3. **`leaf_amounts`** — nets each leaf's own financial activity for the period (`CR-DR` for Income,
   `DR-CR` for Expense, matching the user's own stated formula exactly), with the standard
   `rid_finance_lines`/`rih_finance_headers` composite join, `posted_only`, Location Group, and
   `ric_user_location_access` filters.
4. **`node_totals`** — fans each leaf's amount out to *every* one of its ancestors via `ancestry`, then
   sums per ancestor. This is what gives a group node its own correctly rolled-up subtotal (its own
   direct postings, if any, plus every descendant's) in **one pass**, not N+1 per-node queries.

`p_leaves_included=false` (Summary report) simply excludes `is_leaf=true` rows from the final result —
group subtotals are identical either way, so Summary and Detail always reconcile exactly.

### `fn_pl_totals_base`/`_local` — the footer
Reuses `fn_pl_tree_base`/`_local` directly, summing each section's own `level_depth=1` group totals
(already fully rolled up) rather than re-deriving the rollup a third time — guarantees the
Income/Expense/Net Profit footer can never disagree with the tree's own numbers.

### Registry
- `report_type='HIERARCHICAL'`, `source_type='FUNCTION'`, Base/Local twins via `source_object_local`
  (same toggle mechanism as every other report), `totals_source_object` wired to `fn_pl_totals_base`/`_local`.
- Filters: `date_range` (required, `THIS_MONTH` default), `posted_only` (BOOLEAN, same widget as the
  Expense Report), `location_group_id` (DROPDOWN_LOOKUP → `v_location_groups_lookup`, already built for
  Trial Balance).
- `FN-PNL` placeholder repointed from `/finance/profit-loss` to `/reports/PROFIT_LOSS_SUMMARY` (same
  precedent as Trial Balance's own `FN-TRB` repoint). New feature code `FN-RPT-PNL` for the Detail
  report, serial 11.

### Frontend — new pieces, all additive
- `ReportDataController._loadAllForHierarchical()` — mirrors `_loadAllForMatrix()`'s single full fetch,
  plus a `fetchTotals` call (MATRIX doesn't need one — its totals are cheap client-side pivot
  arithmetic; HIERARCHICAL's aren't, so it reuses the plain-TABULAR pattern for the footer).
- New `SakalReportHierarchicalTable` widget — builds a real in-memory tree from the flat row list
  (linked by `parent_id`), two top-level collapsible sections (Income, Expense), recursive indented
  rows, client-side expand state (defaults to *expanded*, unlike Ageing/Pending Bills' currency groups
  which default collapsed — a P&L tree is small enough that showing everything up front reads better).
  Indent is scoped to the name cell's own `Expanded` content only — the amount is a separate
  fixed-position trailing widget, so it can never be pushed out of alignment by nesting depth, avoiding
  by construction the exact bug class found and fixed in the grouped-TABULAR mechanism earlier this
  session.
- `sakal_report_screen.dart` gained a third `report_type` branch (Matrix → Hierarchical → plain
  Tabular).

### Update 2026-08-19 (same day): real hierarchical PDF/Excel export built
The deferred export gap above was hit live the same day the screen was tested — wrong row order, no
Income/Expense/Net Profit totals, and (in Excel specifically) an unindented single column that read as
confusing. Rather than the flat 3-column shape the user first sketched as an example (`Type | Group
Name | Account Name | Balance`), the actual fix keeps **real arbitrary-depth hierarchy** in both
exports too — a fixed `Group Name` column can only ever represent one level, which would silently lose
a 3rd/4th-level subgroup some company's COA might have (confirmed with the user, who agreed once this
tradeoff was explained).

Built `report_hierarchy_export.dart` — `PlNode`/`buildPlSections` (the tree-building logic, extracted
out of `SakalReportHierarchicalTable` so the widget and both exporters share one derivation, same
"can never disagree" precedent `report_matrix_pivot.dart` already established for MATRIX) plus
`flattenPlForExport()` (always walks the full tree — a static document has no "collapsed" state, unlike
the widget's own live expand/collapse). `ReportPdfExport.exportHierarchical()` (built via a plain
`pw.Table`/`pw.TableRow`, not `TableHelper.fromTextArray`, for guaranteed per-row bold/indent without
depending on that helper's unverifiable-without-a-toolchain row-styling API) and
`ReportExcelExport.exportHierarchical()` (indentation via a leading-space text prefix, not a
package-specific cell-indent style — `excel: ^4.0.6` has no reliable cross-version indent API) both
render: Income section (fully expanded) → Expense section (fully expanded) → Total Income / Total
Expense / Net Profit, one indented "Account / Group Name" column + Amount. `sakal_report_screen.dart`'s
`_exportPdf`/`_exportExcel` gained a `bundle.isHierarchical` branch each, parallel to the existing
`isMatrix` one, using already-loaded `controller.items`/`controller.totals` — no extra fetch.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/143_profit_loss_hierarchical.sql` | **New** — the whole backend |
| `backend/functions/fn_seed_client_modules.sql` | `FN-PNL` repointed, new `FN-RPT-PNL` added |
| `lib/core/reporting/report_data_controller.dart` | `_loadAllForHierarchical()` |
| `lib/core/reporting/sakal_report_screen.dart` | Third report_type branch; `isHierarchical` export branch in both `_exportPdf`/`_exportExcel` |
| `lib/core/reporting/sakal_report_hierarchical_table.dart` | **New** — the tree widget; later refactored to use the shared `PlNode`/`buildPlSections` |
| `lib/core/reporting/report_hierarchy_export.dart` | **New** (2026-08-19 follow-up) — shared tree-build + export flatten |
| `lib/core/reporting/report_pdf_export.dart` | **New** `exportHierarchical()` (2026-08-19 follow-up) |
| `lib/core/reporting/report_excel_export.dart` | **New** `exportHierarchical()` (2026-08-19 follow-up) |

## Verification

Not yet run in Supabase / not independently re-verified against real data (no local Postgres
toolchain, and this is genuinely novel recursive SQL with real correctness risk). Recommended pass
once run:
1. **Income total − Expense total = Net Profit**, and matches the Detail report's own sum of top-level
   group totals — the core cross-check.
2. A company whose account sits directly under the root, and another 3+ levels deep, both render with
   no missing/duplicated nodes.
3. Summary and Detail reports' group-level subtotals match exactly for the same filters.
4. Location Group filter: blank = whole company; a specific `INTER_ENTITY` group = that entity's own
   correct P&L (spot-check against a known inter-entity transaction).
5. Base/Local toggle and Posted Only/All filter both work correctly.
