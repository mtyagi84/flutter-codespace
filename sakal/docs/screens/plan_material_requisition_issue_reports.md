Status: Implemented 2026-08-22 (migration 154, not yet run by user).

# Inventory — Material Requisition Register + Material Issue Register

## Context

Tenth/eleventh Inventory reports — document-register style, same shape as every register report this
session. Material Requisition is pure intent (no stock movement, no batch/serial); Material Issue is
what actually leaves stock against one or more requisitions (has batch/serial via the shared tables).

## Schema recap (confirmed via direct read of migrations 066-068, 075)
- `rih_material_requisition_headers`: `requisition_no/date`, `location_id`, `requested_by TEXT` (free
  text, not an FK), `status CHECK IN ('DRAFT','APPROVED','PARTIALLY_ISSUED','CLOSED')`.
- `rid_material_requisition_lines`: `product_id`, `uom_id`, `base_qty` (requested qty),
  `department_id`/`consumption_area_id` at LINE level (not header), `barcode`. No batch/serial at all.
- `rih_material_issue_headers`: `issue_no/date`, `location_id`, `status CHECK IN ('DRAFT','APPROVED')`.
- `rid_material_issue_lines`: `source_requisition_no/date` + `source_requisition_line_serial`,
  `product_id`, `uom_id`, `base_qty` (issue qty), `department_id`/`consumption_area_id` at LINE level,
  `barcode`. Has batch/serial — shared `rid_transaction_line_serials`, `source_doc_type='MATERIAL_ISSUE'`.
- `rim_department_consumption_areas`: `department_id`, `consumption_area_id`, `account_id`.
- Department/Consumption Area are `rim_common_masters` rows (type_key `DEPARTMENT`/`CONSUMPTION_AREA`).

## Decisions
1. Requisition Status "Approved" bucket = anything past Draft (`APPROVED`, `PARTIALLY_ISSUED`, `CLOSED`
   all map to `'APPROVED'`) — same `status_group` technique as Stock Transfer Register's 3-state status.
2. Material Issue report includes a Serial No column (one row per serial for serial-tracked products,
   dynamically hidden when not applicable) — added beyond the user's literal column list for consistency
   with every other register report this session, confirmed via AskUserQuestion.

## Cascading Consumption Area filter — first real use of the engine's plain-equality branch

"Consumption Area based on selected Department" reuses the cascading-lookup-filter capability built for
Stock Details' Category→Product filter (migration 149) verbatim — no engine change. Unlike Category→
Product (a hierarchy needing `fn_category_subtree` to expand), Department→Area is a flat one-hop
relationship, so this is the first report to use `depends_on_expand_fn=NULL` (plain equality on
`depends_on_column`) instead of an expand function. New `v_consumption_areas` lookup view exposes
`department_id` as a real column so the filter bar's own `{column}=eq.{parentValue}` request works
directly.

## "Requested By" filter — a distinct-values lookup, not a master table

`requested_by` is plain free text with no FK — there's no existing lookup table for it. New
`v_material_requisition_requesters` view (`SELECT DISTINCT requested_by AS id, requested_by AS
requester_name FROM rih_material_requisition_headers`) — the filter bar's generic `{id,label}` lookup
mechanism doesn't require `id` to be a UUID, so the raw text value works directly. Reused by BOTH reports
— Material Issue resolves it by joining back to the ORIGINATING requisition header via
`source_requisition_no/date`.

## Views

`v_material_requisition_lines` — one flat SELECT (no UNION ALL — this module has no batch/serial at
all). Header+line joined, `status_group` computed, Department/Area names resolved via
`rim_common_masters`. Location-access scoping on the header's own single `location_id`.

`v_material_issue_lines` — non-serial + serial-expansion UNION ALL, same convention as every other
Inventory register report. LEFT JOINs back to `rih_material_requisition_headers` (via
`source_requisition_no/date`) purely to resolve `requested_by`; the requisition's own No/Date are already
direct columns on the issue line (`source_requisition_no/date`), no join needed for those.

## Registry

Both `TABULAR`, no group levels, `auto_load=false`. `MATERIAL_REQUISITION_REGISTER` (`IN-RPT-MRQ`,
serial_no=9): Requisition No/Date, Department, Area, Barcode, Item Code/Name, Unit, Qty (SUM). Filters:
date range (required, `THIS_MONTH`), Location, Requested By, Product, Department, Area (cascading),
Status (Pending/Approved, default Approved). `MATERIAL_ISSUE_REGISTER` (`IN-RPT-MIS`, serial_no=10):
same shape plus Requisition No/Date reference columns and Serial No, `param_target='status'` directly
(only 2 real states, no `status_group` mapping needed). Both get standard `ric_user_menus` backfill (no
cost/value data here, so no Stock-Adjustment-style permission split needed).

## Critical files
- `backend/migrations/154_material_requisition_issue_reports.sql` — everything above.
- `backend/functions/fn_seed_client_modules.sql` — two new rows (`IN-RPT-MRQ`, `IN-RPT-MIS`).
- No Flutter changes — reuses the existing cascading-filter mechanism, dynamic Barcode/Serial No
  visibility, and location-access scoping conventions verbatim.

## Verification (pending — user has not yet run migration 154)
1. A DRAFT requisition shows only under Pending; APPROVED/PARTIALLY_ISSUED/CLOSED all show under
   Approved (default).
2. Picking a Department narrows the Consumption Area dropdown to only that department's own areas.
3. Requested By dropdown lists distinct real values; picking one narrows both reports (Material Issue
   via its requisition join).
4. Material Issue's Requisition No/Date columns correctly trace back to the originating requisition,
   even when one Issue consolidates multiple requisitions.
5. A serial-tracked product's issued line expands to one row per serial; Material Requisition never
   shows a Serial No column at all (module has none).
6. Barcode column hides/shows per the existing app-wide `enable_barcode` rule on both reports.
