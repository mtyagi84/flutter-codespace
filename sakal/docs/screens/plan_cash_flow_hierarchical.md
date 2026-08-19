# Cash Flow Statement — fourth and final core financial statement

Status: Implemented 2026-08-19 (migration `145_cash_flow_hierarchical.sql`). Not yet run in Supabase.

## Context

`sakal/docs/screens/Cash Flow.md` is a CA-education primer the user wanted turned into a real report —
the fourth and final classic financial statement after Trial Balance (135), Profit & Loss (143), and
Balance Sheet (144), all three built on the same generic HIERARCHICAL reporting engine.

## Decisions (confirmed via AskUserQuestion before implementation)
1. **Direct method** — trace actual Cash/Bank ledger movements, classify by contra account. Rejected
   Indirect method (start from Net Profit, add back Depreciation, adjust working capital) because this
   schema has no Fixed Asset Register / automated depreciation engine — only plain CoA labels
   (`2800`/`6800`) and a dormant `ASSET_DEPRECIATION_ACCOUNT` link-config from migration 032, never
   consumed — so a reliable Depreciation add-back isn't available.
2. **Real GL account hierarchy** for categories within each section, not a hand-curated fixed list —
   self-maintaining, matches whatever accounts a company actually has, same philosophy as P&L/BS.
3. **Summary + Account Detail pair** — `CASH_FLOW_SUMMARY` / `CASH_FLOW_DETAIL`, same shape as every
   prior financial statement. No existing `FN-CF*` menu placeholder existed (confirmed via grep) — both
   are genuinely new feature codes (`FN-RPT-CFS`/`FN-RPT-CFD`, serials 13/14), not a repoint.

## Design

### Core technique — same P&L/BS machinery, new leaf computation
Reuses the roots → subtree → ancestry → leaf amount → node_totals fan-out shape from `fn_pl_tree_base`
(143) / `fn_balance_sheet_tree_base` (144), but the leaf amount is a genuinely new derivation: an
**apportioned cash contribution**, not a direct account balance/movement.

1. **`cash_lines`** — every `rid_finance_lines` row on a `Cash`/`Bank`-nature account within the date
   range (standard `posted_only`/`location_group`/`ric_user_location_access` filters), netted **per
   voucher** (`Dr-positive = inflow`) — a voucher can have multiple cash/bank lines (split cash+bank
   payment) that must net to one figure before apportionment.
2. **`contra_lines`** — every NON-cash-nature line in those same vouchers, carrying `base_amount` (NOT
   `trans_amount`) as its apportionment weight — per this schema's own established rule from migration
   058 ("any DR=CR balance check across a voucher's lines must sum `base_amount`, never `trans_amount`,
   since a voucher can legitimately mix `trans_currencies` across lines" — e.g. Purchase Bill's own
   Exchange Gain/Loss line). `base_amount` is used identically in both `_base` and `_local` functions, so
   the apportionment *fractions* never change with the Base/Local toggle — only the final displayed cash
   figure does.
3. **Cash↔Bank internal transfers excluded for free** — a Contra Voucher moving money between two
   cash-equivalent accounts has an EMPTY `contra_lines` set for that voucher (both its legs are
   cash/bank-nature, filtered out), so it never appears downstream. No special-case code — standard
   accounting treatment (movements between cash and cash-equivalents aren't part of the statement) falls
   out of the JOIN structure by construction.
4. **`leaf_amounts`** — apportions each voucher's net cash movement across its contra lines by each
   line's own share of the voucher's total contra `base_amount` — same "apportion by amount share within
   one document" technique already used for GRN/Sales Invoice charge apportionment.
5. **Classify + roll up** — each contra account is classified into OPERATING/INVESTING/FINANCING via an
   extended virtual-root technique (below), then the ancestor-fanout rollup (identical to 143/144) gives
   every group node its own correctly rolled-up subtotal in one pass.

### Classification table (virtual roots)
Unlike Balance Sheet's symmetric 3-way split (which explicitly covers the whole COA), Cash Flow's
OPERATING bucket is the "everything else" catch-all — INVESTING and FINANCING get small explicit lists,
OPERATING gets an explicit list of every remaining real account-code group (never the ambiguous shared
parent itself — same carve-out technique 144 used for OHADA's `1000`/`4000`, applied one level deeper
here for INDIAN's Current Liabilities too). Scoped by `accounting_std` exactly like 144.

- **INVESTING**: INDIAN `1200` (Non-Current Assets). OHADA `2000` (Fixed Assets, includes Investments
  `2700`).
- **FINANCING**: INDIAN `2160`/`2210`/`2220` (Borrowings/Term Loans/Lease Liabilities), `3100`/`3200`
  (Capital/Reserves & Surplus — a dividend, with no dedicated account seeded, would post here). OHADA
  `1600` (Loans & Borrowings), `1100`/`1200`/`1300` (Reserves/Retained Earnings/Net Income — the same
  codes 144 classified EQUITY; here Financing for the identical reason).
- **OPERATING** (explicit catch-all): INDIAN `1100` (Current Assets, all), `2110`/`2120`/`2130`/`2140`/
  `2150`/`2170` (Current Liabilities minus `2160`), `2230` (Deferred Tax Liability — a judgment call:
  grouped with Tax Liabilities, not the Loan codes, since IFRS treats income-tax cash flows as Operating
  unless specifically tied to a financing/investing transaction), `4000`/`5000` (Revenue/Expense, all).
  OHADA `3000` (Inventory, all — a current-asset item, not fixed asset), `4010`/`4110`/`4200`/`4300`/
  `4400` (Third Parties minus `1600`), `5800` (Internal Transfers), `6000`/`7000` (Expense/Revenue, all).
  `9000` (internal Cost Accounting) excluded entirely — never a real cash contra.

### Opening/Closing Cash + reconciliation — the strongest correctness check of any report this session
Opening Cash (as of `p_date_from`) and Closing Cash reuse Trial Balance's (135) opening+movement-to-date
formula, restricted to `account_nature IN ('Cash','Bank')`, computed **independently** of the 3-section
apportionment logic. Because this is double-entry, `Operating + Investing + Financing` MUST exactly equal
`Closing − Opening Cash` if the SQL is correct — any gap is a real bug in this report's classification/
apportionment, not a genuine accounting discrepancy. Exposed as `reconciliation_diff` on the totals
function — the primary pass/fail signal once run.

### Frontend — zero structural change
`report_hierarchy_export.dart`'s `hierarchySpecFor()` gained a `_cashFlowSpec` (3 sections, 4 totals
rows) matched via a `'CASH_FLOW'` reportKey prefix. `sakal_report_hierarchical_table.dart`,
`report_pdf_export.dart`, `report_excel_export.dart`, `sakal_report_screen.dart`,
`report_data_controller.dart` needed NO changes — already fully generic from the P&L/BS generalization
work earlier the same day (commit `1484a2c`).

### Registry
- `report_type='HIERARCHICAL'`, filters: `date_range` (period report like P&L, `THIS_MONTH` default),
  `posted_only`, `location_group_id` — identical widget reuse.
- `CASH_FLOW_SUMMARY` (`FN-RPT-CFS`, serial 13) / `CASH_FLOW_DETAIL` (`FN-RPT-CFD`, serial 14) — both
  genuinely new, `fn_seed_client_modules.sql` updated for future clients.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/145_cash_flow_hierarchical.sql` | **New** — the whole backend |
| `backend/functions/fn_seed_client_modules.sql` | Two new feature codes added |
| `lib/core/reporting/report_hierarchy_export.dart` | `_cashFlowSpec` + `'CASH_FLOW'` prefix match |
| `docs/screens/plan_cash_flow_hierarchical.md` | **New** — this file |

## Verification
Not yet run in Supabase / not independently re-verified against real data (no local Postgres toolchain,
genuinely novel apportionment SQL). Recommended pass, in priority order:
1. **`reconciliation_diff = 0`** — the primary, strongest pass/fail signal, for both an INDIAN and an
   OHADA test company if both exist.
2. A Cash→Bank Contra Voucher transfer produces ZERO net effect on the statement.
3. A voucher with multiple contra lines (e.g. an Expense Voucher with several expense-account lines
   settled by one cash payment) apportions correctly — sum of apportioned leaf amounts equals the
   voucher's own net cash movement.
4. Summary and Detail reports' section subtotals match exactly for the same filters.
5. Base/Local toggle, Posted Only/All, Location Group, and Period (date range) filters all work.
6. PDF/Excel export renders the 3-section tree + all 4 totals rows correctly, and this session's earlier
   P&L/BS exports did NOT regress from the same shared-infra generalization.
