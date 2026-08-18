# Pending Bills by Customer regroup + Pending Bills by Supplier — Finance Reports

Status: Implemented 2026-08-18 (migration `140_pending_bills_by_currency_and_supplier.sql`, plus `fn_seed_client_modules.sql` updated for future clients). One bug (VALUES row length mismatch) caught by the user running it in Supabase, fixed same day.

## Context

User asked for three changes to the existing "Pending Bills by Customer" report (one of the original 3 Reporting Engine pilots, migration 118):

1. Add a Customer Name search filter — it had none.
2. Swap its grouping from Customer → Currency to **Currency → Customer**, with a real subtotal row at both levels (currency-wise and customer-wise totals).
3. Build an equivalent **Pending Bills by Supplier** report.

## Design

Same shared-core-plus-nature-wrappers shape as `fn_party_ageing_lines_core` (137) — one engine discriminated by `account_nature`, exposed as thin Customer/Supplier wrapper pairs. `v_pending_bills` (117) has no `account_nature` column; every new function joins `rim_accounts` directly for it, same as the Ageing reports.

**Three function pairs, each with a `_core` + two nature wrappers:**
- `fn_pending_bills_summary_by_currency_core` (level 1 — groups by `party_currency` only)
- `fn_pending_bills_summary_by_currency_account_core` (level 2 — groups by `account_id` within one `party_currency` ancestor, param named `p_party_currency` to match level 1's `group_by_column`)
- `fn_pending_bills_totals_by_nature_core` (report-level totals — the original report had none at all; added as an improvement)

All three take `p_account_id UUID DEFAULT NULL` so the new Customer/Supplier Name filter narrows the group summaries too, not just the detail rows — confirmed by reading `ReportRepository.fetchGroupSummary`/`_buildFilterParams`: every declared filter's value is passed to `fn_..._summary_*`/`fn_..._totals_*` RPC calls automatically as `p_<param_target>`, not just the detail feed.

**Security**: all three new function families include the standard `ric_user_location_access` check (matching every report built since 132/135/137). The *original* three 118 functions never had one — a real, pre-existing gap, left untouched and explicitly noted in the migration rather than silently fixed, since closing it wasn't asked for and touches a function still used elsewhere (`fn_pending_bills_totals` backs the separate, unrelated "Pending Bills Register" flat report).

**Filter scoping reuses migration 139's mechanism**: `ric_report_filters.lookup_source` (otherwise meaningless for `FINANCE_ACCOUNT_PICKER`) holds `'Customer'`/`'Supplier'`, consumed by `sakal_report_filter_bar.dart`'s existing FINANCE_ACCOUNT_PICKER case — built for the Ageing reports, reused here for free.

**Registry**: Pending Bills by Customer's `report_key` and `feature_code` (`FN-RPT-PBG`) are unchanged — only its columns/filters/group_levels are redesigned in place (added a hidden `party_currency` column, added the `account_id` filter, swapped `ric_report_group_levels`). Pending Bills by Supplier is a genuinely new `report_key`/feature code (`FN-RPT-PBS`, serial 9), added to `fn_seed_client_modules.sql` too for future clients.

**No Flutter changes** — the nature-scoped picker, grouped-table alignment/expand-all mechanics, and mobile card view were all already built for the Ageing reports and apply here unmodified.

## Real bug caught by the user running it in Supabase

The Supplier report's `ric_report_columns` INSERT declared a 13-column header (`..., aggregate_fn, currency_code_column`) but its last two rows (`account_label`, `party_currency`) only supplied 12 values — Postgres rejected the whole INSERT with `VALUES lists must all be the same length`. Fixed by adding the missing trailing `NULL`. Every other `VALUES` block in the file was checked line-by-line against its own column header afterward and confirmed correct — this was the only occurrence.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/140_pending_bills_by_currency_and_supplier.sql` | **New** — 6 functions (2 per level × Customer/Supplier + totals), registry redesign + new report |
| `backend/functions/fn_seed_client_modules.sql` | Added `FN-RPT-PBS` row for future clients |

## Verification

Not yet independently re-verified against real data in this session (no local Postgres toolchain). Recommended manual pass once run in Supabase:
1. Pending Bills by Customer: currency-level rows show correct per-currency subtotals; expanding a currency shows customer rows summing back to that subtotal.
2. Pending Bills by Supplier: same, scoped to Supplier accounts only.
3. Customer/Supplier Name filter narrows both the group summaries and the expanded detail rows, not just one or the other.
4. Grand-total footer (new on both reports) matches the sum of all currency subtotals.
