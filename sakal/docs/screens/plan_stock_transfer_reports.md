Status: Implemented 2026-08-22 (migration 151, not yet run by user).

# Inventory — Stock Transfer Register + Pending Transfer to Receive

## Context

Fifth/sixth Inventory reports. A document-register style report (one row per transfer LINE, header
fields repeated) modeled on Sales Register (`126_sales_details_views.sql`/`127_sales_register_report.sql`
— the closest existing precedent), plus a companion report of transfers still awaiting receipt.

While researching Stock Receipt's schema, found a real mismatch with the original ask ("if partially
received, Pending qty should appear"): this schema has **no partial-receipt concept at all** —
`rih_stock_receipts` has `UNIQUE(source_transfer_no, source_transfer_date)` (exactly one receipt per
transfer, ever), and `fn_approve_stock_receipt` forces the transfer to `status='CLOSED'` unconditionally
the moment that one receipt is approved, regardless of whether every line was fully received. Any
shortfall is written off as a loss immediately, never carried forward. Confirmed with the user: "Pending"
means (1) transfers dispatched but with no receipt filed at all yet, PLUS (2) a separate flagged view of
already-closed transfers that were received short — both in one report, distinguished by a Receipt Status
column, not a fabricated ongoing "still open" state that doesn't exist in the system.

## Decisions
1. Pending report = "not received at all" rows (full qty pending) + "short received" rows (flagged,
   shortfall qty only) — no schema change to Stock Receipt itself.
2. Line identifiers = the same trio as every other Inventory report this session: Product Code (always),
   Barcode (dynamically hidden per company setting), Serial No (dynamically hidden when the company has
   no serial-tracked products) — serial-tracked lines expand to one row per serial. Both dynamic-hiding
   mechanisms already exist app-wide (`filterDynamicColumns`, `hasSerialTrackedProductsProvider`) — no
   new Flutter code needed.

## `v_stock_transfer_lines` — shared base VIEW (mirrors `v_sales_details_base`)

`UNION ALL` of a non-serial branch (one row per line, `p.tracking_type != 'SERIAL'`) and a serial branch
(one row per serial, joined to the shared `rid_transaction_line_serials` table tagged
`source_doc_type='STOCK_TRANSFER'`). Both expose `transfer_no/date`, a computed `status_group`
(`CASE WHEN status IN ('APPROVED','CLOSED') THEN 'APPROVED' ELSE status END` — lets a plain PostgREST
`eq.` filter treat "Approved" as inclusive of the bookkeeping-only `CLOSED` state, matching the user's
literal 3-option Draft/Approved/All filter without inventing a 4th status), from/to location
ids+names, `source_request_no/date`, `remarks` (as `doc_remarks`), `barcode`, `serial_no`, product
code/name, unit, `transfer_qty`.

**Location-access scoping** checks EITHER `from_location_id` OR `to_location_id` against the user's own
`ric_user_location_access` rows — a user responsible for receiving needs to see a transfer dispatched
from a location they don't otherwise manage, and vice versa.

## `fn_stock_transfer_register_totals`

Wraps the view with the report's own filter params (same shape as `fn_sales_register_totals_base`) —
`fetchTotals` always calls its target as a FUNCTION even when the main source is a VIEW.

## `fn_stock_transfer_pending_receipt` / `_totals`

Three-branch `UNION ALL`, built directly from base tables (not the shared view, since the short-received
branch needs LINE-level totals to diff against `received_base_qty`, which the view's serial-expanded rows
don't carry):
1. **Not received, non-serial**: `status='APPROVED'` is sufficient on its own — a transfer can only reach
   `'APPROVED'` if no receipt has ever been filed (filing one forces `CLOSED` unconditionally) — no
   `NOT EXISTS` subquery needed. `receipt_status='Not Received'`, `pending_qty = base_qty`.
2. **Not received, serial**: same scope, serial-expanded, `pending_qty=1` per serial.
3. **Short received** (line-level, not serial-expanded — deliberate v1 scoping, see below):
   `status='CLOSED'`, `LEFT JOIN rid_stock_receipt_lines` via `source_transfer_line_serial`, `WHERE
   (base_qty - COALESCE(received_base_qty,0)) > 0` — `receipt_status='Short Received'`,
   `pending_qty` = the shortfall only. The LEFT JOIN also naturally catches a line the receipt missed
   entirely (no matching receipt line at all → `received_base_qty` NULL → full `base_qty` pending).

**Scoping note**: branch 3 does not resolve a shortfall down to which specific serial(s) are missing
(would need diffing the transfer's own serial set against the receipt's own — a real but more involved
piece of logic; a shortfall is typically investigated at the document level anyway). `Serial No` is left
blank on short-received rows. Extendable later inside branch 3 alone if it turns out to matter.

## Registry

Both `TABULAR`, no group levels, `auto_load=false` (consistent with every Inventory report since 148).
`STOCK_TRANSFER_REGISTER` (`IN-RPT-STR`, serial_no=4): source=VIEW `v_stock_transfer_lines`. Filters:
`date_range` (required, default `THIS_MONTH`), `from_location_id`/`to_location_id` (optional), `status`
(DROPDOWN_STATIC Draft/Approved, `param_target='status_group'`, default `APPROVED` — the dropdown's own
built-in "All" null option covers the third choice). `STOCK_TRANSFER_PENDING_RECEIPT` (`IN-RPT-STP`,
serial_no=5): source=FUNCTION `fn_stock_transfer_pending_receipt`, same columns plus `Receipt Status`/
`Pending Qty`, no status filter.

**Landscape PDF**: column widths sized realistically (~13-15 columns, 90-220px each) so the existing
automatic landscape trigger in `report_pdf_export.dart` (`sum(default_width) > 700 → landscape`, already
built, no new flag) fires naturally.

## Critical files
- `backend/migrations/151_stock_transfer_reports.sql` — everything above.
- `backend/functions/fn_seed_client_modules.sql` — new `IN-RPT-STR`/`IN-RPT-STP` rows.
- No Flutter changes — reuses existing dynamic-column-visibility and landscape-PDF mechanisms.

## Verification (pending — user has not yet run migration 151)
1. A DRAFT transfer only appears under Status=Draft or All; an APPROVED or CLOSED transfer both appear
   under Status=Approved (default).
2. Request No/Date blank for a DIRECT transfer, populated for an against-request one.
3. Serial-tracked product → one row per serial; non-serial → one aggregated row.
4. PDF renders landscape automatically.
5. Pending report: an APPROVED not-yet-received transfer's lines show `Not Received` + full pending qty;
   a fully-received CLOSED transfer doesn't appear at all; a short-received CLOSED transfer's short
   lines show `Short Received` + shortfall-only pending qty, Serial No blank.
6. Barcode/Serial No columns hide/show per the existing app-wide rule — first exercise of that mechanism
   on a VIEW-sourced report (previously only FUNCTION-sourced ones).
