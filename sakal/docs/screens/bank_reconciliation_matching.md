# Bank Reconciliation Matching

## Screen Name
Bank Reconciliation Matching (`/finance/bank-reconciliation`)

## Description
The working screen where a user ties their books to the bank's own statement. Shows every unreconciled
BOOK entry for a chosen Bank Account/period on one side and every unreconciled BANK statement line on
the other, lets the user tick any combination on either side and match them as a group once the two
totals agree exactly, offers a one-click Auto-Match for the easy 1:1 pairs, and lets a bank-only line
(e.g. a bank charge) be booked inline without leaving the screen. A live reconciliation summary shows
progress toward zero.

## Layout
Filter bar: Bank Account, From Date, To Date, Load button. Below it, two scrollable panels side by side
on desktop (stacked on mobile) — "Book Entries" (left) and "Bank Statement Lines" (right), each row with
a checkbox. A sticky footer shows the running selected totals for each side and the Match button
(enabled only when they agree exactly and at least one side has a selection). An "Auto-Match" button
sits in the filter bar. A small reconciliation summary card (Book Balance / Bank Balance / Difference)
sits above the two panels, refreshed after every match/auto-match/quick-entry.

## Functionality
- Loading unreconciled BOOK lines: `v_bank_reconciliation_book_lines` filtered to the chosen Bank
  Account and date range — absence of an active row in `rid_bank_reconciliation_matches` is what makes
  a line "unreconciled" (no separate flag).
- Loading unreconciled BANK lines: `v_bank_reconciliation_statement_lines`, same absence-based logic,
  scoped to APPROVED statements only.
- Tick any number of rows on either side; a running total per side is always visible. Match enables
  only when the two totals are exactly equal (re-validated server-side by
  `fn_create_reconciliation_match`, never trusted from the client alone).
- Auto-Match calls `fn_auto_match_bank_statement` — 1:1 exact-amount, close-date pairs only. Anything
  needing a split/bundle is always a deliberate manual tick-and-match action.
- A bank-only statement line (no book counterpart — e.g. a bank charge) can be resolved inline: tap
  "Book This", pick a counterpart Account, confirm the amount (prefilled from the statement line) and a
  narration, and it posts a real two-line Journal Voucher (`fn_save_finance_voucher` +
  `fn_post_finance_voucher`, the SAME generic voucher engine every manual JV entry already uses) with
  the Bank account as one leg. The new book line then appears on the left, ready to match normally (or
  auto-matches on the next Auto-Match pass). This is a deliberately simplified quick entry — always
  posts in the company's base currency at rate 1 — for anything needing multi-currency or a different
  voucher type, use the full Journal/Payment/Receipt Voucher screen instead.
- Unmatch: an already-matched pair isn't shown on this screen (it's no longer "unreconciled") — unmatch
  is a Bank Reconciliation Statement report action / future admin action on `fn_remove_reconciliation_match`,
  not built into this screen's own UI in v1.
- Reconciliation summary: `fn_bank_reconciliation_summary(bank_account_id, as_of_date=ToDate)` — shows
  Book Balance, Adjusted Book Balance, Bank Statement Balance, Adjusted Bank Balance, and
  `reconciliation_diff`. Refreshed after every action so the user watches it converge toward zero.

## Data Flow
Read-only views (`v_bank_reconciliation_book_lines`/`v_bank_reconciliation_statement_lines`) for the two
panels; `fn_create_reconciliation_match`/`fn_auto_match_bank_statement` for matching;
`fn_bank_reconciliation_summary` for the live schedule; `fn_save_finance_voucher`/
`fn_post_finance_voucher` (existing, unmodified) for the inline quick-entry. No new posting engine
anywhere — matching itself never touches `rid_finance_lines`, it only records cross-references
(migration 175).
