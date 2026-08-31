Status: Implemented 2026-08-28 (migrations 174-176 + 5 new Flutter screens, not yet run/tested by user).

# Bank Reconciliation — full feature (schema + Format Master + 3 screens + report)

## Context
This came out of a "what's the biggest remaining gap in the ERP" discussion. Confirmed via direct schema
read: `rim_accounts` has no bank-identification columns, and no bank-statement or reconciliation-matching
table exists anywhere in the schema — a genuine from-scratch feature, not a report-only exercise like
every Purchase/Sales/Finance/Master reporting batch built earlier this session. Sized and sequenced
differently on purpose.

## Design principles (agreed with the user through discussion, not assumed)
1. **Reuses two proven existing patterns rather than inventing new accounting mechanics**:
   - The settlement/matching junction-table shape already proven by `rid_invoice_bill_settlement`
     (migration 019) — generalized here to a `match_group_id` to support many-to-many matches.
   - `fn_cash_bank_position` (migration 168, built earlier this session) supplies the "Book Balance as
     per Ledger" side of the reconciliation summary — no new balance calculation invented.
2. **Persistent statement records ARE the resume mechanism** (an Odoo-aligned refinement) — uploaded
   statement lines are permanent records; reopening the same Bank Statement document is "resume where I
   left off," no separate progress-tracking table needed.
3. **A per-bank Format Master** (`rim_bank_statement_formats`) drives parsing — different banks have
   wildly different statement layouts (column names/order, date formats), so this is configured once per
   bank and reused on every upload, rather than hardcoding one layout.
4. **CSV/Excel are the reliable path; PDF is explicitly weaker and gated behind mandatory human review**
   before its extracted rows can be trusted as real statement lines. A PDF has no real "column" concept —
   text is just positioned glyphs; table reconstruction is a heuristic that can silently misplace a value
   if a bank tweaks their template. Scanned/image PDFs are out of scope entirely (no text layer to
   extract — would need OCR, a separately unreliable problem). All parsing (CSV/Excel/PDF) happens
   client-side in Flutter, same "parse locally, then save via RPC" pattern Opening Stock's own Excel
   import already uses — the backend only ever receives already-parsed JSON, never a raw file.
5. **Many-to-many matching is always user-driven**, via multi-select on both sides with a running-total
   guardrail (Match only enables once ticked-book-total equals ticked-bank-total exactly, re-validated
   server-side, never trusting the client check alone). Auto-Match only ever proposes clean 1:1 pairs —
   mirrors how Odoo's own reconciliation widget behaves (automatic for the easy cases, manual multi-select
   for the combinatorial ones).
6. **Bank-only entries (e.g. bank charges) get a simplified inline quick-entry** on the matching screen
   itself (Account + Amount + Narration → posts a real voucher), not a forced trip to the full
   Payment/Receipt/Journal Voucher screen.

## Schema (see plan file for full column lists)
`rim_bank_statement_formats` (Format Master) → `rim_bank_accounts` (bank details per Bank-nature
account) → `rih_bank_statement_headers`/`rid_bank_statement_lines` (uploaded statements, DRAFT/APPROVED,
no GL impact) → `rid_bank_reconciliation_matches` (group-based junction table, many-to-many).

## Functions
`fn_save_bank_statement`/`fn_approve_bank_statement` (Approve blocked while any PDF-sourced line has
`is_reviewed = false`), `fn_auto_match_bank_statement` (1:1 only), `fn_create_reconciliation_match`
(server-validates the two totals agree exactly), `fn_remove_reconciliation_match`,
`fn_bank_reconciliation_summary` (the two-sided schedule, `reconciliation_diff` flags any residual gap —
same convention as Cash Flow Statement's own diff column).

## Screens (3, each gets its own `docs/screens/<name>.md` requirement doc before Flutter build)
1. Bank Statement Format Master (setup + test-parse preview).
2. Bank Statement Upload & Review (upload CSV/Excel/PDF, PDF rows flagged unreviewed until confirmed).
3. Bank Reconciliation Matching (the genuinely novel UI: two-pane multi-select with running totals,
   Auto-Match, inline quick-entry for bank-only lines).

## Report
Bank Reconciliation Statement — reuses the existing generic reporting engine (`FUNCTION`-sourced from
`fn_bank_reconciliation_summary`), same as every report built this session.

## Menu placement
New `group_code = 'FN-BRC'` ("Bank Reconciliation") under the existing `FN` module for the 3 operational
screens; the report goes under the existing `FN-RPT` group.

## Build sequence
1. Migration: schema + save/approve functions.
2. Migration: matching/auto-match/summary functions.
3. Format Master screen (+ requirement doc).
4. Upload & Review screen (+ requirement doc) — CSV/Excel first, PDF via a local text-extraction package.
5. Matching screen (+ requirement doc).
6. Migration: register the report.

## Verification
See the full plan file (`C:\Users\manglu.singh\.claude\plans\act-as-a-senior-cheerful-hickey.md`) for the
complete verification checklist — covers Auto-Match correctness, PDF review gating, many-to-many
matching, inline quick-entry, and the reconciliation report tying to zero.

## As-built summary
- **174**: schema (`rim_bank_statement_formats`, `rim_bank_accounts`, `rih_bank_statement_headers`/
  `rid_bank_statement_lines`) + `fn_save_bank_statement`/`fn_approve_bank_statement` + menu seed
  (`FN-BSF`/`FN-BAC`/`FN-BST`/`FN-BRM` under new group `FN-BRC`).
- **175**: `rid_bank_reconciliation_matches` (group-based junction table) + views
  (`v_bank_reconciliation_book_lines`/`v_bank_reconciliation_statement_lines`) +
  `fn_create_reconciliation_match`/`fn_remove_reconciliation_match`/`fn_auto_match_bank_statement`/
  `fn_bank_reconciliation_summary`.
- **176**: registers `BANK_RECONCILIATION_STATEMENT` on the existing generic reporting engine.
- **Flutter**: `bank_statement_format_screen.dart`, `bank_accounts_screen.dart` (small master CRUD,
  direct DioClient, no repository layer — mirrors `sales_executive_master_screen.dart`),
  `bank_statement_list_screen.dart` + `bank_statement_entry_screen.dart` (upload/parse/review/save/
  approve), `bank_reconciliation_matching_screen.dart` (the novel two-pane matching UI + inline
  quick-entry that composes the existing `fn_save_finance_voucher`/`fn_post_finance_voucher`).
  Parsing logic lives in `lib/features/finance/data/bank_statement_parser.dart` (CSV via the `csv`
  package, Excel via the already-used `excel` package, PDF via `syncfusion_flutter_pdf` — user
  confirmed the Community License applies at this project's current size/revenue).
- New pubspec dependencies: `csv: ^6.0.0`, `syncfusion_flutter_pdf: ^27.2.5`.
- New routes: `bankStatementFormats`, `bankAccounts`, `bankStatements`, `bankStatementEntry`,
  `bankReconciliation` (`route_names.dart`/`app_router.dart`).

## Known simplifications, stated explicitly (not silently glossed over)
- The inline quick-entry in the Matching screen always posts in the company's BASE currency at rate 1
  — no multi-currency handling. Anything needing a different currency should use the full Journal/
  Payment/Receipt Voucher screen instead (explicitly stated in the dialog's own helper text).
- Unmatch has a backend function (`fn_remove_reconciliation_match`) but no dedicated UI button in v1 —
  an already-matched pair simply doesn't appear on the Matching screen anymore (it's no longer
  "unreconciled"), so there was no natural place to surface an unmatch action without adding a third
  "already matched" panel. Flagged as a v2 UI enhancement, not an oversight.
- PDF table reconstruction in `BankStatementParser.parsePdf` uses a simple horizontal-gap-clustering
  heuristic (`gapThreshold = 12.0`) — reasonable for a typical bank statement table, but not tuned
  against real bank PDF samples yet. Every PDF-sourced row is flagged unreviewed specifically because
  of this — the mandatory review step is the real safety net, not the heuristic's accuracy.
