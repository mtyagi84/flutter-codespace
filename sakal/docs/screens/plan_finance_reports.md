Status: Implemented 2026-08-27 (migrations 166-168, not yet run by user). Comparative Profit & Loss /
Balance Sheet DEFERRED — see below.

# Finance Module Reports — 6 of 8 planned reports built

## Context
Finance already had 14 reports (Trial Balance, P&L, Balance Sheet, Cash Flow, Ageing, Pending Bills,
Account Ledger, Expense Report). Full gap analysis + design reviewed with the user as an HTML artifact
before any SQL was written: `sakal/docs/screens/artifact_finance_reports_plan.html`. This doc is the
as-built summary — read the artifact for the complete per-report spec (all 8 originally scoped reports,
including the 2 deferred ones).

## Real finding that changed scope mid-build
**Comparative Profit & Loss / Balance Sheet (reports 5-6) are DEFERRED, not built.** While starting on
them, direct inspection of `sakal_report_hierarchical_table.dart`/`PlNode` (the Flutter widget that
renders every HIERARCHICAL report) found it hardcoded to a single `amount` value per tree row — Base vs
Local currency is actually two separate function calls behind a toggle (`source_object`/
`source_object_local`), not two columns rendered together, contradicting the artifact's original
assumption. Adding Current/Prior/Variance columns to a comparative tree report needs real Flutter widget
work, not just SQL — unlike every other report in this batch, which all use the fully generic
TABULAR/GROUPED engine. User confirmed: ship the other 6 now, plan the comparative statements as a
dedicated follow-up once the Flutter widget work is scoped.

## The 6 reports built, by migration
- **166** (foundational registers): Day Book / Voucher Register (`DAY_BOOK_REGISTER`, grouped by
  voucher, ALL voucher types via a new `v_finance_voucher_lines` view), Cheque Register
  (`CHEQUE_REGISTER`, tabular, one row per cheque-mode voucher — deliberately NOT called "Outstanding
  Cheques" since no clearance/reconciliation tracking exists anywhere in the schema to honestly support
  that claim).
- **167** (tax compliance): VAT / Tax Return Summary (`VAT_TAX_RETURN_SUMMARY`, grouped by Tax — Output
  vs Input vs Net Payable, read straight off `rid_finance_lines` matched against each tax's own
  `gl_output_account_id`/`gl_input_account_id`, so it's cross-module for free and can't drift from what
  Sales/Purchase/Expense actually posted), Withholding Tax Summary (`WITHHOLDING_TAX_SUMMARY`, grouped
  by Supplier — filters on the `source_line_type='WITHHOLDING'` tag Expense Voucher's own posting
  function already writes; Gross Amount is reconstructed as Net Payable + WHT Amount, the standard WHT
  identity, correct regardless of which exact accounts each leg posted to).
- **168** (analysis, pure composition — zero new account classification invented): Financial Ratio
  Analysis (`FINANCIAL_RATIO_ANALYSIS`, one row per ratio — Gross/Net Profit Margin %, ROA %, ROE %,
  Debt-to-Equity — composes the EXISTING `fn_pl_totals_base`/`fn_balance_sheet_totals_base` plus the
  `source_line_type='COGS'` tag; deliberately excludes Current Ratio/Quick Ratio since no
  Current-vs-Non-Current classification exists on `rim_accounts` and inferring it from group-name text
  would be a fragile guess, not a real classification — flagged explicitly rather than built wrong),
  Cash & Bank Position Summary (`CASH_BANK_POSITION_SUMMARY`, one row per Cash/Bank account's live
  balance as of a date — mirrors Trial Balance's own opening-balance + movement pattern exactly,
  restricted to `account_nature IN ('Cash','Bank')`).

## Conventions followed (all established earlier this session, none new)
- Location-access scoping (`ric_user_location_access`) on every view/function.
- GROUPED reports (Day Book, VAT Summary, WHT Summary) use `ric_report_group_levels` + a dedicated
  `_group_summary` function, same pattern as every prior batch.
- FUNCTION-sourced reports (Ratio Analysis, Cash & Bank Position) follow the exact parameter-naming
  convention already established by Trial Balance/P&L/Balance Sheet (`p_<param_target>`), since the
  reporting engine calls these via RPC with named arguments matching each filter's `param_target`.
- Standard `ric_user_menus` backfill for all 6, `fn_seed_client_modules.sql` updated with all 6 new
  `FN-RPT-*` codes for future clients.

## Verification (pending — user has not yet run migrations 166-168)
1. All 6 reports appear under Finance → Reports for a user with existing Finance module access.
2. VAT / Tax Return Summary: post a Sales Invoice and a GRN/Purchase Bill with the same tax — confirm
   Output and Input both appear correctly and Net Payable nets them.
3. Withholding Tax Summary: post an Expense Voucher with a withholding-type tax — confirm Gross Amount =
   Net Payable + WHT Amount exactly, and WHT % is sane.
4. Financial Ratio Analysis: cross-check Revenue/Net Profit/Total Assets rows against the existing P&L
   Summary/Balance Sheet Summary reports for the same period — they must match exactly, since this
   report is pure composition over those same functions.
5. Cash & Bank Position Summary: compare a Cash/Bank account's shown balance against its own Account
   Ledger report's closing balance for the same as-of date — must match.
6. `flutter analyze`/`flutter test` — no Flutter changes were needed for this batch (all 6 reports use
   the existing generic `ReportScreen`/reporting engine), but worth a green-check pass regardless.

## Deferred (not built, tracked for a future session)
- **Comparative Profit & Loss / Balance Sheet** — needs Flutter widget work on the HIERARCHICAL tree
  renderer to support multiple value columns per row (Current/Prior/Variance), not just a migration.
- **Bank Reconciliation Statement** (never in scope for this batch, per the artifact's own "deliberately
  not built" section) — needs a full reconciliation feature (bank statement import, clearance matching
  workflow, new schema columns), not a read-only report.
