# Balance Sheet reports — Finance (third HIERARCHICAL report, last core financial statement)

Status: Implemented 2026-08-19 (migration `144_balance_sheet_hierarchical.sql`), not yet run in Supabase.

## Context

Two new reports — **Balance Sheet Summary** (sections + subtotals only) and **Balance Sheet Account
Detail** (full tree down to individual accounts) — same report-count shape as [[project_profit_loss_hierarchical_2026_08_19]],
on the same `report_type='HIERARCHICAL'` engine (migration 143), now generalized (see below) to serve
both financial statements from one shared Flutter implementation. This is the last of the three core
financial statements CLAUDE.md's Finance module status line tracked as pending (Trial Balance 135, P&L
143, Balance Sheet 144).

### Why this was the hardest classification problem in the schema
P&L's Income/Expense classification was a clean root-code lookup — both accounting standards' Revenue
and Expense roots are unambiguous. Balance Sheet is not: reading both COA seeds in
`013_chart_of_accounts.sql` directly (not guessed) —

**INDIAN** — clean, root-code classification suffices everywhere: `1000` Assets, `2000` Liabilities,
`3000` Equity.

**OHADA** — two of five relevant root classes mix categories directly under one root:
- `1000` ("Equity & Long Term Financing"): children `1100` Reserves / `1200` Retained Earnings / `1300`
  Net Income = EQUITY, but `1600` Loans & Borrowings = LIABILITY.
- `4000` ("Third Parties"): child `4110` Customers = ASSET (receivable), but `4010` Suppliers / `4200`
  Personnel / `4300` Social Security / `4400` State & Taxes = LIABILITY.
- `2000`/`3000`/`5000` (Fixed Assets / Inventory / Treasury) are unambiguous ASSET roots.
- `6000`/`7000` (Expense/Revenue, P&L's own domain) and `9000` (internal Cost Accounting) are excluded
  entirely.

`4400` State & Taxes has no seed-level receivable/payable split (unlike INDIAN's own `1140`/`2120`
split) — confirmed via Q&A during planning to classify **LIABILITY by default** (the dominant real-world
case for a trading company; a net tax *receivable* position simply shows negative, correct in total).

**Genuine code collision, handled explicitly**: OHADA's ASSET root `2000` (Fixed Assets) collides with
INDIAN's own LIABILITY root `2000`; OHADA's `3000` (Inventory→ASSET) collides with INDIAN's EQUITY root
`3000`; OHADA's `1100`/`1200`/`4110`/`4200` also collide with unrelated INDIAN sub-group codes (Current
Assets, Non-Current Assets, Product Sales, Non-Operating Revenue — confirmed live by grep on the actual
INDIAN seed). Every classification branch is explicitly scoped by `accounting_std`, so no cross-standard
leakage is possible even though the raw `account_code` text overlaps — a single company only ever has
ONE seeded COA (its own `accounting_std`), so only one branch can ever match for that company regardless.

### No automated year-end closing exists yet — designed around, not built here
Confirmed via Q&A: a separate future mechanism will zero Income/Expense account balances at the start
of every financial year. This report is built *assuming* that mechanism exists, not implementing it.
Until it's live, "Current Year Earnings" reflects all-time Income/Expense activity rather than just the
current year — the report still mathematically balances either way (double-entry is self-consistent
regardless), just with a misleadingly-labeled figure. Flagged here, not fixed here.

## Design

### Classification technique — boundary "virtual roots", no separate view
Rather than a standalone `v_balance_sheet_accounts` classification view (the earliest sketch in
planning), the section boundary is expressed directly as extra "virtual root" rows in
`fn_balance_sheet_tree_base`/`_local`'s own `roots` CTE — the exact same shape `fn_pl_tree_base`'s own
`roots` CTE already uses (migration 143), just with some entries one level below the true
`parent_id IS NULL` root (OHADA's `1100`/`1200`/`1300`/`1600`/`4010`/`4110`/`4200`/`4300`/`4400`)
instead of always being the literal root. `subtree` then walks DOWN from each virtual root exactly like
P&L — the ambiguous real root (`1000`/`4000` for OHADA) is never itself selected as a virtual root, so
its mixed meaning is fully absorbed by its children becoming separate top-level (`level_depth=1`) tree
nodes instead of being bundled under one node. A deliberate simplification over the original plan
sketch — same proven pattern, no new object to maintain.

### Balance computation — reuses Trial Balance's opening+movement-to-date formula
Asset/Liability/Equity accounts carry forward indefinitely (unlike Income/Expense) — `leaf_balance`
reuses Trial Balance's (135) own `fy` CTE + `v_opening_balance_summary` + `rid_finance_lines` movement
formula verbatim, computed through `p_as_of_date` inclusive instead of split into a separate
opening/period pair (a Balance Sheet is one point in time, not a from/to range). Sign convention: raw
figure is Dr-positive (same as Trial Balance); ASSET keeps that sign, LIABILITY/EQUITY negate it to show
Cr-positive — mirrors exactly how P&L signs Income (Cr-positive) vs Expense (Dr-positive). Unlike P&L's
own `leaf_amounts` (which only has rows for accounts with actual period movement), `leaf_balance` uses
LEFT JOINs so an account with a carried-forward balance but zero current-year movement still appears.

### "Current Year Earnings" — reuses `fn_pl_totals_base`/`_local` directly, unmodified
Resolves the financial year containing the as-of date (same `fy` CTE used for opening balances), then
calls `fn_pl_totals_base(p_client_id, p_company_id, fy.fy_start_date, p_as_of_date, p_posted_only,
p_location_group_id)` — **zero changes to migration 143's own functions**. Its `net_profit` is unioned
in as one synthetic EQUITY leaf (`'Current Year Earnings'`, sentinel UUID
`00000000-0000-0000-0000-000000000001`, not a real `rim_accounts` row), always shown in both Summary and
Detail (outside the `p_leaves_included` filter, since it functions as a top-level EQUITY line item, not
a collapsible leaf account).

### Built-in correctness check — stronger than P&L's own
`fn_balance_sheet_totals_base`/`_local` compute `total_assets`, `total_liabilities`, `total_equity`,
`total_liabilities_equity` (= liabilities + equity), and `difference` (= assets − liabilities_equity) by
summing each section's own `level_depth=1` group totals (already fully rolled up, including the
synthetic Current Year Earnings row) — never re-deriving the rollup a third time, so the footer can
never disagree with the tree. `difference` should always compute to exactly 0 when classification and
the Current Year Earnings figure are both right — the primary pass/fail signal once this runs against
real data.

### Frontend — generalized shared infrastructure, not a parallel copy
Per explicit user feedback during planning (*"make sure excel and pdf also follow same pattern as we did
for Profit and loss account"*), Balance Sheet reuses the identical widget/PDF/Excel export mechanics P&L
already has, rather than a separate parallel implementation. `report_hierarchy_export.dart` was
generalized from a P&L-specific shape (hardcoded `PlSections{incomeRoots, expenseRoots}`, hardcoded
'INCOME'/'EXPENSE' checks, a single hardcoded 'Net Profit' totals row) into a `HierarchyReportSpec`
(a `List<HierarchySectionSpec>` + `List<HierarchyTotalRowSpec>`) with `hierarchySpecFor(reportKey)`
returning the right spec by prefix match (`BALANCE_SHEET*` → 3 sections/3 totals rows, everything else →
P&L's 2 sections/1 totals row). `SakalReportHierarchicalTable` now takes a `reportKey` constructor param
and builds N section trees + N totals rows generically. Both `ReportPdfExport.exportHierarchical()` and
`ReportExcelExport.exportHierarchical()` pass `hierarchySpecFor(definition.reportKey)` into the shared
`flattenPlForExport()`. No behavior change for the already-shipped P&L reports (same default P&L spec,
same rendering). Committed separately (`1484a2c`) ahead of the Balance Sheet SQL itself, so it could be
reviewed as a pure refactor with zero new business logic.

### As Of Date filter — first single-DATE filter with a default value in this engine
Every prior report using `filter_type='DATE_RANGE'` had a `'THIS_MONTH'`/`'LAST_30_DAYS'` default
token, parsed by `ReportDataController._parseDefaultDateRange()`. No report had ever used a plain
`filter_type='DATE'` filter with a `default_value` before — `ReportDataController.init()` had no DATE
branch at all, so a `default_value='TODAY'` would have been passed through as the raw String `'TODAY'`
into a filter value slot the DATE widget and `_buildFilterParams` both expect to hold a real `DateTime`
— a real gap, not a hypothetical one, caught before ever running this against Supabase. Fixed by adding
a parallel `_parseDefaultDate()` (mirroring `_parseDefaultDateRange()`'s own shape) and a `DATE`-specific
branch in `init()`, so `'TODAY'` now resolves to today's date at load time, matching how the DATE_RANGE
tokens already work.

### Registry
- `report_type='HIERARCHICAL'`, Base/Local twins via `source_object_local`, `totals_source_object`
  wired to `fn_balance_sheet_totals_base`/`_local`.
- Filters: `as_of_date` (required, `DATE`, `'TODAY'` default — a Balance Sheet is a point in time, not
  a range, unlike P&L's `DATE_RANGE`), `posted_only` (same widget as P&L/Expense Report),
  `location_group_id` (same `v_location_groups_lookup` reuse as P&L/Trial Balance).
- `FN-BSH` placeholder (existed since the very first menu seed, migration 005) repointed from
  `/finance/balance-sheet` to `/reports/BALANCE_SHEET_SUMMARY` — same precedent as Trial Balance's
  `FN-TRB` and P&L's `FN-PNL` repoints. New feature code `FN-RPT-BSD` for the Detail report, serial 12
  (next free after P&L Detail's 11).
- `fn_seed_client_modules.sql` updated for future clients: `FN-BSH` repointed, `FN-RPT-BSD` added.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/144_balance_sheet_hierarchical.sql` | **New** — the whole backend |
| `backend/functions/fn_seed_client_modules.sql` | `FN-BSH` repointed, new `FN-RPT-BSD` added |
| `lib/core/reporting/report_hierarchy_export.dart` | Generalized to `HierarchyReportSpec` (shared with P&L, no behavior change there) |
| `lib/core/reporting/sakal_report_hierarchical_table.dart` | Generalized to N sections / N totals rows via `reportKey` |
| `lib/core/reporting/report_pdf_export.dart` | `exportHierarchical()` passes `hierarchySpecFor(definition.reportKey)` |
| `lib/core/reporting/report_excel_export.dart` | Same |
| `lib/core/reporting/sakal_report_screen.dart` | Passes `reportKey` into the hierarchical widget |
| `lib/core/reporting/report_data_controller.dart` | New `_parseDefaultDate()` + `DATE` filter-type default branch |

## Verification

Not yet run in Supabase / not independently re-verified against real data (no local Postgres toolchain).
Recommended pass once run, in priority order:
1. **`difference` = 0** (Total Assets − (Total Liabilities + Total Equity)) — the primary, self-validating
   correctness signal, for both an INDIAN and an OHADA test company if both exist.
2. An OHADA company's Customers/Suppliers/Personnel/Social Security/State & Taxes accounts land in the
   correct section (Asset vs Liability) despite sharing one root class (`4000`).
3. An OHADA company's Reserves/Retained Earnings/Net Income vs Loans & Borrowings land correctly
   (Equity vs Liability) despite sharing one root class (`1000`).
4. "Current Year Earnings" reflects only the current FY's activity, not all-time — flag to the user if
   it looks like all-time activity instead (means the future closing mechanism isn't live yet, not a
   bug in this report).
5. Summary and Detail reports' section subtotals match exactly for the same filters.
6. As Of Date filter defaults to today; Location Group filter produces a correct entity-level Balance
   Sheet for an `INTER_ENTITY` company; Base/Local toggle and Posted Only/All filter both work.
7. PDF/Excel export renders the real 3-section indented tree (Assets/Liabilities/Equity) plus all three
   totals rows, matching what's on screen — confirm this did NOT regress P&L's own export in the same
   pass, since both now share the generalized code.
