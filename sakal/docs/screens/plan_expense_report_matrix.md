# Month-wise Expense Report (MATRIX) + currency-toggle label fix — Finance

Status: Implemented 2026-08-18 (migration `141_expense_report_matrix.sql`), not yet run in Supabase.

## Context

New Finance report: one dynamic column per calendar month in the selected date range, net
Debit−Credit for that Expense account that month, rows labeled by Group Name (immediate parent) +
Account Name, a free "Total Expense" row-total column. Reuses the Reporting Engine's existing MATRIX
mechanism (built for Stock Balance by Location, migration 118) — dynamic columns were already a
solved, generic, client-side pivot (`lib/core/reporting/report_matrix_pivot.dart`), so this is
purely a migration, no new Flutter rendering code.

### The hard design question: what counts as an "Expense" account

`rim_accounts` has no `account_nature='Expense'` value. Investigated both accounting standards this
app supports (`rim_accounts.accounting_std`, seeded per company at COA setup) and found they use
**different** root account codes for Expense — confirmed by reading both seed blocks in
`013_chart_of_accounts.sql`:

- **INDIAN**: root `('5000', 'Expense')`.
- **OHADA**: root `('6000', 'Class 6 - Expenses')` — OHADA's own class numbering has no 1:1 mapping
  to INDIAN's Asset/Liability/Equity/Income/Expense split at all (Treasury and Cost Accounting are
  separate top-level classes with no INDIAN equivalent).

Neither a fixed `account_code LIKE '5%'` nor a fixed `'5000'` root check works for both. **Resolved**
with a new reusable view, `v_expense_accounts (client_id, company_id, account_id)`, computed via a
recursive CTE walking each leaf account to its root ancestor (`parent_id IS NULL`), classifying it as
Expense only if the root's own code matches its own standard's convention. Deliberately scoped to
"is this an expense account" only — not a general 5-way classifier, since a wrong universal mapping
now would actively mislead a future P&L/Balance Sheet report (still on CLAUDE.md's pending list)
rather than help it.

### Confirmed via Q&A
- **Group Name** = immediate parent (same convention as Trial Balance/Ageing), filter scoped to only
  expense-account parent groups.
- **12-month cap** = hard block in the UI, built as a new **generic, registry-driven** capability
  (`ric_report_definitions.max_date_range_months`, checked in `sakal_report_screen.dart`'s `onApply`
  before the report fetches) rather than hardcoding this report's key in Flutter — any future report
  with the same "date range drives column explosion" concern opts in via its own migration alone.
- **Zero-activity accounts** = excluded for free via the SQL source function's own
  `HAVING SUM(...) <> 0` per (account, month) — no separate toggle needed.

## What migration 141 creates

- `ALTER TABLE ric_report_definitions ADD COLUMN max_date_range_months INTEGER` — NULL (no limit) on
  every existing report definition.
- `v_expense_accounts` — the recursive standard-aware classifier described above.
- `v_expense_account_groups_lookup` — Group Name filter dropdown, parent accounts with ≥1 expense
  child, mirrors `v_party_account_groups_lookup`'s shape exactly (137).
- `fn_expense_report_matrix_base`/`_local` — Base/Local twin MATRIX source functions (same pattern as
  Trial Balance's own twins), each: joins `rid_finance_lines`→`rih_finance_headers`
  (composite trans_no+trans_date key)→`v_expense_accounts`→`rim_accounts` (self-join for immediate
  parent); `net_amount = SUM(CASE trans_nature='DR' THEN amount ELSE -amount END)`; grouped by
  `(account_id, date_trunc('month', trans_date))`; `month_label` formatted `'YYYY-MM'` (sorts
  chronologically as a plain string, matching `report_matrix_pivot.dart`'s own plain string sort — no
  extra sort-key trick needed, unlike the TABULAR reports); standard `ric_user_location_access` check.
- Registry: `report_type='MATRIX'`, row-group columns `group_name`+`account_name`, dimension column
  `month_label`, measure column `net_amount` — the trailing "Total" column is the Matrix widget's own
  existing free row-total, no SQL/column needed for it. Filters: `date_range` (required,
  default THIS_MONTH), `posted_only` (BOOLEAN, default `true` — pragmatically reuses the existing
  3-state Yes/No/All widget rather than a new 2-state filter type just for cleaner labeling), `group_id`
  (DROPDOWN_LOOKUP). New feature code `FN-RPT-EXR`, serial 10 in the `FN-RPT` group.

## Currency toggle label fix (report-wide)

`sakal_report_screen.dart`'s `SegmentedButton` showed the literal words "Base"/"Local" — replaced
with the company's real currency codes via the already-existing `baseCurrencyProvider`/
`localCurrencyProvider` (`master_cache_providers.dart`), falling back to the word only if the
provider hasn't resolved yet. Benefits Trial Balance and Account Ledger too, not just this report —
no separate migration needed, those providers already existed.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/141_expense_report_matrix.sql` | **New** — the whole feature |
| `backend/functions/fn_seed_client_modules.sql` | Added `FN-RPT-EXR` for future clients |
| `lib/core/reporting/report_models.dart` | Added `ReportDefinition.maxDateRangeMonths` |
| `lib/core/reporting/sakal_report_screen.dart` | Currency toggle labels + generic date-range-cap check in `onApply` |

## Verification

Not yet run in Supabase / not independently re-verified against real data (no local Postgres
toolchain). Recommended manual pass once run:
1. `SELECT * FROM fn_expense_report_matrix_base(...)` for a known date range — every returned
   account is genuinely an Expense account under that company's own accounting standard (test with
   at least one INDIAN and one OHADA company if both exist).
2. UI: a date range > 12 months is blocked with a visible inline error; a ≤12-month range renders one
   column per month, correctly ordered.
3. Group Name filter only lists expense parent groups.
4. Currency toggle shows real currency codes on this report AND on Trial Balance/Account Ledger.
5. An account with zero net movement across the whole range never appears as a row.
