Status: Implemented 2026-08-25 (migration 155, not yet run by user).

# Inventory — Stock Count Worksheet Register + Stock Count Variance Report

## Context

Twelfth/thirteenth Inventory reports. Stock Count is a two-screen module: Screen 1 (Counter) does a
blind physical count (no system quantity anywhere in its data path) and Submits; Screen 2 (Manager)
consolidates one or more SUBMITTED counts, computes variance against ledger-derived system stock as of a
chosen date, and Approves — which auto-posts a real Stock Adjustment via the existing engine, tagging
the adjustment header `source_doc_type='STOCK_COUNT_REVIEW'`. There was no report surfacing either the
raw counts a counter submitted, or the variance/outcome once a review is approved — both are built here.

Built alongside a regroup of the existing Stock Adjustment Register (see the addendum in
`plan_stock_adjustment_reports.md`) — both reuse the same document-level GROUPED pattern, reviewed with
the user via an artifact mockup before implementation.

## Schema recap (confirmed via direct read of migrations 078, 079, 153)
- `rih_stock_count_headers`: `count_no/date`, `location_id`, `category_filter_id` (nullable),
  `nature_filter` (nullable), `status CHECK IN ('DRAFT','SUBMITTED','CONSOLIDATED')`, `submitted_by`
  (UUID FK `rim_users`), `created_by`.
- `rid_stock_count_lines`: `is_counted BOOLEAN` (authoritative "row touched" flag), `counted_base_qty`,
  `barcode`. No `system_qty` column anywhere — deliberate blind-count design.
- `rih_stock_adjustment_headers.source_doc_type/no/date` (added 079) — how a Review's own posted
  Adjustment traces back; `source_doc_no`/`source_doc_date` = the Review's own number/date,
  `adjustment_date` = the Review's `as_of_date` (a different date, both worth exposing).

## Report A — Stock Count Worksheet Register (flat)
One row per counted line from Screen 1. New `v_stock_count_lines` (header+line join, no UNION ALL — no
batch/serial dimension at this stage) + `v_stock_count_counters` (distinct submitted_by → `rim_users.full_name`
lookup, since `submitted_by` is a real UUID FK, unlike Material Requisition's free-text `requested_by`).
Columns: Count No, Date, Location, Category, Nature, Counted By, Barcode, Item Code/Name, Unit,
Counted?, Counted Qty. Filters: date range, Location, Category, Nature, Counted By, Product, Status.
`IN-RPT-SCW`, serial_no=11, standard backfill.

## Report B — Stock Count Variance Report (GROUPED, two variants)
Thin wrapper `v_stock_count_variance_lines` (an `EXISTS` filter over `v_stock_adjustment_lines`, narrowed
to `rih_stock_adjustment_headers.source_doc_type='STOCK_COUNT_REVIEW'` — no changes to 153's own view).
Group row = Adjustment No/Date/Location/Reason **plus** Review No/Date (`source_doc_no`/`source_doc_date`,
1:1 with one Adjustment since one Review posts exactly one Adjustment) — all resolved by
`fn_stock_count_variance_group_summary`, same "identity fields live at group level only" shape as the
Adjustment Register regroup. Detail rows: Barcode, Serial No, Item Code/Name, Unit, Adjustment Type,
System Qty, Adjusted Qty, [Unit Cost, Value in the -V variant]. `IN-RPT-SCV` (serial_no=12, standard
backfill) / `IN-RPT-SCV-V` (serial_no=13, no auto-backfill — same cost-visibility carve-out as
`STOCK_ADJUSTMENT_REGISTER_VALUE`).

## Grouping mechanism (shared with the Stock Adjustment Register regroup)
"Grouped" is not a `report_type` value — the CHECK constraint only allows `TABULAR`/`MATRIX`/
`HIERARCHICAL`. A report is grouped purely by having a `ric_report_group_levels` row attached, same
mechanism Pending Bills by Customer/Supplier (140) already proved. `group_by_column`/`group_label_column`
= `adjustment_no` (single-column key — `adjustment_no` alone is unique enough per company's own running
document sequence in practice, though the header's real composite PK is `(adjustment_no, adjustment_date)`
— same single-column limitation 140 already accepts for `account_id`). Client-side, `ric_report_table.dart`'s
existing `_buildGroupHeaderRow`/`isGrouped` machinery (built for Pending Bills/Ageing) needed zero changes
— first real use on a document-register-style report rather than a party/account rollup.

## Scrollbar fix (same session, separate concern)
User reviewed the grouping design via an HTML artifact mockup and separately flagged that landscape
reports have "no scrollbar to scroll" — `sakal_report_table.dart`'s horizontal `Scrollbar` around the
table body got a `ScrollbarTheme` wrapper (thickness 11px, `trackVisibility`/`thumbVisibility` both
always-on, track/thumb colored from `AppColors.border`/`textSecondary`) so the scroll affordance is
visible without hover/drag. One shared widget — fixes every report at once, not just these two.

## Critical files
- `backend/migrations/155_stock_adjustment_regroup_and_stock_count_reports.sql` — everything above
  (Piece 1: Adjustment Register regroup; Piece 2: Worksheet Register; Piece 3: Variance Report).
- `backend/functions/fn_seed_client_modules.sql` — three new rows (`IN-RPT-SCW`, `IN-RPT-SCV`,
  `IN-RPT-SCV-V`).
- `lib/core/reporting/sakal_report_table.dart` — `ScrollbarTheme` wrap around the body `Scrollbar`.
- `docs/screens/plan_stock_adjustment_reports.md` — addendum recording the regroup.

## Verification (pending — user has not yet run migration 155)
1. Stock Adjustment Register (both variants) render as collapsible groups — one row per document,
   expanding to line items; a line-level reason override still shows correctly in its own detail row.
2. Worksheet Register shows every counted line for a submitted count; `is_counted=false` rows show "No",
   not a blank/zero qty; filtering by Counted By narrows to that user's own counts.
3. Variance Report groups by Adjustment No, shows Review No/Date on the group row (not repeated per
   line); only ever contains adjustments whose `source_doc_type='STOCK_COUNT_REVIEW'`.
4. Both with/without-Value pairs: a user granted only the base report never sees Unit Cost/Value, in
   either the group row or detail rows.
5. All new/changed reports respect existing location-access scoping.
6. The horizontal scrollbar is now visibly persistent on at least one grouped and one flat report — no
   hover/drag needed to discover a report scrolls.
