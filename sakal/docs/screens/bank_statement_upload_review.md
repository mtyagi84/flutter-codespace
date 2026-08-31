# Bank Statement Upload & Review

## Screen Name
Bank Statement Upload & Review (`/finance/bank-statements` list, `/finance/bank-statements/entry` entry)

## Description
Upload a bank's own statement (CSV, Excel, or PDF) for a chosen Bank Account and period. The file is
parsed entirely on-device using that account's Bank Statement Format Master, producing one row per
transaction exactly as printed on the statement. CSV/Excel rows (already real structured tables) are
trusted immediately; PDF rows are flagged for mandatory review, since a PDF has no real "column"
concept and table reconstruction is a heuristic that can silently misplace a value. Approve is blocked
until every PDF-sourced row has been confirmed or corrected. No GL/stock impact at any status — this is
a reference document, the input to Bank Reconciliation Matching, not a posting.

## Layout
List screen: standard `SakalAdaptiveList` of statements (Statement No, Date, Bank Account, Period,
Status, row actions) — same shape as every other document register in this app. Entry screen: header
(Bank Account, Statement No/Date, Period From/To, Opening/Closing Balance) + an "Upload File" button
that opens a file picker, then a line grid showing every parsed row. PDF-sourced rows render with an
amber highlight and an inline edit affordance until confirmed; CSV/Excel rows render normally. Save
Draft / Approve buttons top-right per the app's standard entry-screen convention — Approve disabled
(with an explanatory tooltip) while any row is unreviewed.

## Functionality
- Pick Bank Account (pre-selects its Default Statement Format, overridable per upload if a bank
  occasionally sends a different layout).
- Upload File → detect file type from extension → parse client-side via `BankStatementParser`
  (`lib/features/finance/data/bank_statement_parser.dart`) using the chosen format's
  `column_mapping`/`header_skip_rows`/`date_format` → populate the line grid.
- Each parsed line: Transaction No, Transaction Date, Remarks, Debit, Credit, Running Balance — every
  field editable inline (not just PDF-sourced ones — CSV/Excel data can still have a bank-side quirk
  worth correcting).
- A per-line "Mark Reviewed" toggle (auto-true for CSV/Excel, starts false for PDF) — Approve is
  blocked while any line is `false`.
- Save Draft: calls `fn_save_bank_statement` with the header + current line array (reviewed status
  included per line). Approve: calls `fn_approve_bank_statement`, server-side blocked
  (`LINES_NOT_REVIEWED`) if any line is still unreviewed — the client-side disabled button is UX only,
  the server check is authoritative.
- Once APPROVED, a statement's lines become visible to Bank Reconciliation Matching
  (`v_bank_reconciliation_statement_lines` only reads APPROVED statements).

## Data Flow
`rih_bank_statement_headers`/`rid_bank_statement_lines` via `fn_save_bank_statement`/
`fn_approve_bank_statement` (migration 174) — DRAFT-only edits, standard document-lifecycle pattern
(no GL, no stock, mirrors Sales Quotation/Price Master's "reference document" shape). Reopening a DRAFT
statement re-loads its saved lines (including which ones are already reviewed) — resuming a review
session is just reopening the same document, no separate progress-tracking needed.
