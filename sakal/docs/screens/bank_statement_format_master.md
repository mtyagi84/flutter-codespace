# Bank Statement Format Master

## Screen Name
Bank Statement Formats (`/finance/bank-statement-formats`)

## Description
Defines how a specific bank's statement is laid out, so the Bank Statement Upload & Review screen can
parse an uploaded CSV/Excel/PDF file automatically. Configured once per bank, reused on every future
upload. Different banks export wildly different column names, orders, and date formats — this master
is what lets one generic upload/parse flow handle all of them.

## Layout
A plain master list (`SakalAdaptiveList`) — Format Name, File Type, Header Rows to Skip, Status, and
row actions (Edit / Activate-Deactivate). "New Format" button top-right (via `ScreenHeaderMixin`),
gated on `canAdd`. Entry is a dialog (not a full-page form) — the same lightweight pattern used by
Sales Executives Master, since this master has no line items and few fields.

## Functionality
- Format Name (required, free text — e.g. "HDFC Bank", "Ecobank DRC").
- File Type: CSV / EXCEL / PDF.
- Header Rows to Skip: how many rows/lines to skip before real transaction data starts (bank
  letterhead, account summary block).
- Date Format: DD/MM/YYYY / MM/DD/YYYY / YYYY-MM-DD — banks vary.
- Column Mapping (6 fields: Transaction No, Transaction Date, Remarks, Debit, Credit, Running
  Balance) — for CSV/EXCEL, the exact column HEADER NAME as printed on the statement; for PDF, the
  column ORDER (1st, 2nd, 3rd…) since a PDF has no reliable header text to key off. Any field can be
  left blank if that bank's statement doesn't carry it (e.g. no running balance column).

## Data Flow
Direct DioClient CRUD against `rim_bank_statement_formats` (no repository/model layer — same
convention as Sales Executives Master, appropriate for a screen this small). No approval workflow, no
GL impact — this is pure configuration data. Consumed by the Bank Statement Upload & Review screen at
parse time and by the Bank Accounts screen (`default_format_id`) to pre-select a format on upload.
