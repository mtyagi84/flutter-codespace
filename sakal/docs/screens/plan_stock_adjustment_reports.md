Status: Implemented 2026-08-22 (migration 153, not yet run by user).

# Inventory — Stock Adjustment Register (two variants: with/without Value)

## Context

Eighth Inventory report, built from a first-draft proposal the user asked for explicitly (parameters,
columns, UI) before locking a spec. The first draft proposed a single report with Unit Cost/Value columns
— the user corrected this: cost/value must not be visible to every user, so this ships as TWO separate
reports instead of one report with a hidden column. Rather than a new column-level permission concept,
this reuses the existing per-report permission system every report in this app already has: each report
is its own `ric_master_menus` feature_code with its own `ric_user_menus.view_allowed` per user.

## Schema recap (confirmed via direct read of `076_stock_adjustment.sql`)
- `rih_stock_adjustment_headers`: one `location_id` (not a from/to pair — an adjustment happens at a
  single location), `adjustment_no/date`, `reason_id` (required, header-level), `remarks`,
  `status CHECK IN ('DRAFT','APPROVED')` — same 2-state as Stock Receipt.
- `rid_stock_adjustment_lines`: `base_qty` (always positive) + `adjust_flag CHECK IN ('+','-')`
  (direction), `system_qty` (stock snapshot at line-add time, display hint only), `unit_cost`/
  `unit_cost_specific` (populated by `fn_approve_stock_adjustment` from `rim_product_location.cost_price`
  at Approve time — never user-entered, blank on DRAFT), `barcode`, `reason_id` (optional per-line
  override of the header reason).
- Reason master: `rim_common_masters` where type is `STOCK_ADJUSTMENT_REASON`.
- Batch/serial: shared `rid_transaction_line_serials`, `source_doc_type='STOCK_ADJUSTMENT'` — same trio
  convention as every other Inventory report.

## `v_stock_adjustment_lines` — ONE shared base VIEW, TWO report variants

Same UNION ALL (non-serial + serial-expansion) convention as `v_stock_transfer_lines`/
`v_stock_receipt_lines`. Always includes `unit_cost`/`value` in its own SELECT regardless of which report
variant queries it — permission is enforced at the report/menu level (which report a user can even open),
never by hiding a column inside the view itself. Location-access scoping checks the header's own SINGLE
`location_id` (not a from/to pair). Reason resolves as `COALESCE(line.reason_id, header.reason_id)` —
the line's own override when set. Adjustment Type is a plain `CASE adjust_flag WHEN '+' THEN 'Increase'
ELSE 'Decrease' END`. Serial-expanded rows keep `unit_cost`/`value` at their line-level figure (not
divided) — the line's own `unit_cost` is already a per-unit figure, so each serial genuinely represents
that much value, same convention as Transfer/Receipt's own per-serial qty=1.

**Report A — `STOCK_ADJUSTMENT_REGISTER`** (`IN-RPT-SAD`, serial_no=7): Adjustment No/Date, Location,
Reason, Remarks, Barcode/Serial No/Item Code trio, Item Name, Unit, Adjustment Type, System Qty, Adjusted
Qty. Gets the standard `ric_user_menus` backfill (everyone with existing Inventory access).

**Report B — `STOCK_ADJUSTMENT_REGISTER_VALUE`** ("Stock Adjustment Register (with Value)", `IN-RPT-SAV`,
serial_no=8): same columns plus Unit Cost, Value (`base_qty * unit_cost`). **Deliberately gets NO
automatic backfill** — an admin grants it per-user afterward via the standard permission screen, so cost
data isn't retroactively exposed to every existing Inventory user. Confirmed `fn_seed_client_modules.sql`
never touches `ric_user_menus` for any report (only the eligibility catalog `ric_master_menus`), so future
clients are equally unaffected — no special carve-out needed there.

Both share `fn_stock_adjustment_register_totals` (SUM(Adjusted Qty), SUM(Value)) — Report A's own
`ric_report_columns` simply never declares a `value` column, so the extra returned column is harmless.

## UI (registry-driven, no new Flutter screen)

Filters: date range (required, `THIS_MONTH` default), Location (optional), Reason (optional, new
`v_stock_adjustment_reasons` lookup view mirroring `v_product_brands`), Adjustment Type
(Increase/Decrease), Status (Draft/Approved, default Approved). `auto_load=false` (Run Report gate, same
as every Inventory report). PDF auto-lands landscape (existing width-sum trigger).

**Real gap found while implementing**: the plan promised the Adjustment Type column as a colored badge
(green=Increase, red=Decrease, reusing the app's existing profit/loss color convention) — but the
existing generic `BADGE` data-type renderer (`sakal_report_table.dart`) was flat neutral-gray with no
value-based coloring at all. Fixed with a narrow, exact-match check (`value == 'Increase'` /
`'Decrease'`) inside the existing renderer, so every OTHER `BADGE` column already in use (e.g. Sales
Register's own Status) keeps its current neutral styling — this only colors these two exact values.
Applies to both desktop table and mobile cards automatically (both already route through the same
`_buildCellValue` helper).

## Critical files
- `backend/migrations/153_stock_adjustment_reports.sql` — everything above.
- `backend/functions/fn_seed_client_modules.sql` — two new rows (`IN-RPT-SAD`, `IN-RPT-SAV`).
- `lib/core/reporting/sakal_report_table.dart` — `BADGE` renderer gains Increase/Decrease coloring.

## Verification (pending — user has not yet run migration 153)
1. Report A shows no Unit Cost/Value columns at all; Report B shows both.
2. Neither report is auto-visible to a brand-new user with no prior Inventory permissions granted; an
   existing Inventory user sees Report A automatically but NOT Report B until explicitly granted.
3. Unit Cost/Value blank for a still-DRAFT adjustment, populated for an APPROVED one.
4. Adjustment Type badge: green "Increase", red "Decrease" — both desktop and mobile.
5. A line-level reason override shows in place of the header's own reason.
6. Serial-tracked lines expand one row per serial; System Qty/Unit Cost/Value repeat at their line-level
   figure per serial row (not divided).
7. Sales Register's own Status badge (and any other existing BADGE column) is visually unchanged.
