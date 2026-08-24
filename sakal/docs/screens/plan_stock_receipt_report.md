Status: Implemented 2026-08-22 (migration 152, not yet run by user).

# Inventory — Stock Receipt Register report

## Context

Seventh Inventory report, sibling of the Stock Transfer Register (151). The user's first draft of the
column list copy-pasted the Transfer Register's own labels ("Transfer No/Date... Transfer Qty") — flagged
as likely an error since a "Stock Receipt Report" should show the Receipt's own document identity and
actual RECEIVED quantity (which can be less than what was transferred), not the transfer's. Confirmed via
AskUserQuestion: Receipt No/Date + Received Qty as the primary identity, with Transfer No/Date carried
through as reference columns (same "if available" pattern as Request No/Date).

## Columns (as corrected by the user)
Receipt No, Receipt Date, Transfer No, Transfer Date, From Store, Request No (if available), Request
Date (if available), To Store, Remarks, [Barcode/Serial No/Item Code trio], Item Name, Unit, Received
Qty, **Short Received** (the per-line shortfall, shown inline on every row — not a separate filtered
view this time, since the user wants all receipts with the shortfall visible alongside).

## `v_stock_receipt_lines` — base VIEW (same UNION ALL convention as `v_stock_transfer_lines`, 151)

Non-serial branch (one row per line) + serial branch (one row per serial, via the RECEIPT's own
`rid_transaction_line_serials` rows tagged `source_doc_type='STOCK_RECEIPT'` — this report is about what
was actually received, not what was transferred, so serial identity comes from the receipt side).

- `receipt_no/date`, `status` (receipt's own — `DRAFT`/`APPROVED` only, no `CLOSED` concept for
  receipts).
- `transfer_no/date` = `rih_stock_receipts.source_transfer_no/date` (the link back).
- `from_location_name`/`to_location_name` from the RECEIPT's own `from_location_id`/`to_location_id`
  columns directly (it has its own, doesn't need to borrow the transfer's).
- `source_request_no/date` — one hop further, joined via the linked `rih_stock_transfers` row (the
  receipt itself has no request reference; only the transfer does).
- `received_qty` = `rid_stock_receipt_lines.received_base_qty` (1 per serial row).
- `short_received` = `GREATEST(transfer_line.base_qty - received_base_qty, 0)`, joined to the matching
  `rid_stock_transfer_lines` row via `source_transfer_line_serial`. **0 on every serial-expanded row** —
  a physically-scanned received serial is, by definition, not short; shortfall is a line-level concept
  (same reasoning as Pending Transfer to Receive's own short-received branch, 151).

Location-access scoping: same "either from OR to location accessible" rule as 151.

## `fn_stock_receipt_register_totals`

Wraps the view with the report's own filter params — same shape as `fn_stock_transfer_register_totals`.
`SUM(received_qty)`, `SUM(short_received)`, `COUNT(*)`.

## Registry

`STOCK_RECEIPT_REGISTER` (`IN-RPT-SRR`, serial_no=6), `TABULAR`, `auto_load=false`. Filters: `date_range`
(required, default `THIS_MONTH`, on `receipt_date`), `from_location_id`/`to_location_id` (optional),
`status` (DROPDOWN_STATIC Draft/Approved, default Approved — receipt only has 2 real states, no
`status_group` mapping needed unlike the Transfer Register's 3-state status).

## Critical files
- `backend/migrations/152_stock_receipt_report.sql` — everything above.
- `backend/functions/fn_seed_client_modules.sql` — new `IN-RPT-SRR` row.
- No Flutter changes — reuses existing dynamic-column-visibility and automatic landscape-PDF mechanisms.

## Verification (pending — user has not yet run migration 152)
1. Receipt No/Date and Transfer No/Date are genuinely different values (not aliases of each other).
2. A receipt against a DIRECT (not-against-request) transfer shows Request No/Date blank; an
   against-request one shows them populated.
3. A fully-received line shows `Short Received = 0`; a short-received line shows the real shortfall.
4. Serial-tracked receipt lines expand to one row per serial, each with `Short Received = 0`.
5. PDF renders landscape automatically (wide column set, same trigger as 151).
