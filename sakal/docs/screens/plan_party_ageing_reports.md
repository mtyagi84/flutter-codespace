# Customer Ageing & Supplier Ageing reports (+ party_category LOV conversion) — Finance

Status: Implemented 2026-08-18 (migrations `136_party_category_lov.sql` + `137_party_ageing_reports.sql`). Both run against Supabase and verified by the user the same day — `flutter test` 604/604 green after the four screen edits.

Implementation note: like every report since Sales Register (127), the two new reports themselves needed **zero new Flutter code** — the entire report feature is one migration (137). The only Dart touched was the `party_category` LOV conversion (136), which is a real, independent feature the report design surfaced as a prerequisite, not report plumbing.

## Context

Two reports the user asked for, described as "technically they are same": **Customer Ageing** and **Supplier Ageing**, discriminated purely by `rim_accounts.account_nature`. Built on the generic Reporting Engine (`ric_report_definitions`/`_columns`/`_filters`/`_group_levels`, migration 116) — a new report is a migration, not a screen.

### User's spec (verbatim requirements)
- **Parameters**: Group Name (one/all, Customer/Supplier groups only), Category (one/all), Account Name (one/all), Currency (one/all, only currencies that account actually uses).
- **Columns**: Currency (group level), Group Name, Category, Account Name, Outstanding ≤30/31-60/61-90/>90 Days, Total Outstanding, Unsettled Advance, Net Closing (must reconcile to the account's real closing balance).
- Two separate menu entries, grouped/subtotalled by Currency.

### The one genuinely hard design question: Unsettled Advance

The user supplied their prior Oracle ERP's own `VW_OUTSTANDING_BILL`/`VW_OUTSTANDING_ADVANCE` view definitions as a reference. Its table shape maps almost 1:1 onto SAKAL's `rid_finance_lines`/`rid_invoice_bill_settlement`/`rim_accounts`. Confirmed by reading `fn_post_finance_voucher` directly (019, lines 536-599): SAKAL's settlement-creation loop only fires for non-on-account vouchers whose lines already carry `inv_bill_no` — **there is currently no "apply an old advance against a new bill" workflow in SAKAL**, an advance's own `trans_no` never becomes a later settlement row's `trans_no`. The report's SQL mirrors Oracle's exact join shape anyway (advance line's own `trans_no`/`trans_date`/`account_id` against `rid_invoice_bill_settlement`) — free and forward-compatible: the day that feature exists, this report starts reflecting partial consumption automatically, zero report changes needed. Until then every advance correctly shows fully unsettled.

### Scope grew mid-design: `party_category` became a real LOV

Investigating the Category filter found `rim_accounts.party_category` was plain TEXT — deliberately, per migration 094's own comment, since converting it "would ripple into" `fn_convert_prospect_to_customer` (Sales Order's prospect→customer wizard), out of scope at the time. User decided to fix it properly: *"let us not keep it an open text field."* Full blast radius, confirmed by direct code investigation: `customer_master_screen.dart`/`supplier_master_screen.dart` already had a dropdown sourced from `rim_common_masters` but bound `value: c['description']` (wrote the description string, not an id); `chart_of_accounts_screen.dart` was a plain `TextField`; `prospect_conversion_dialog.dart` was a plain `TextFormField` with zero LOV wiring — the exact screen 094 named as the reason `party_category` stayed TEXT.

**Correction mid-build**: the original plan (matching migration 040's Payment Terms precedent) dropped the old `party_category` TEXT column outright. The user objected: *"why are you droping party category column? I told you I will reset it"* — their earlier "I can set that field null" meant they'd reset the *data* themselves, not authorize dropping the *column*. Migration 136 was corrected before being run: the old `party_category` column is **kept in place, untouched, simply unused** by the app going forward (every screen and `fn_convert_prospect_to_customer` now read/write only the new `party_category_id` FK). Re-grepped the whole `backend/` and `lib/` trees afterward to confirm nothing else ever read the old column — the only consumer was `fn_convert_prospect_to_customer`, already repointed.

## What migration 136 creates

- `ALTER TABLE rim_accounts ADD COLUMN party_category_id UUID REFERENCES rim_common_masters(id);` — nullable, no backfill (dev environment, user resetting data themselves). **No `DROP COLUMN`** — see correction above.
- `fn_convert_prospect_to_customer` re-issued (grepped 087 and 096 for the true current body first, per this project's own "check latest function signature" rule) — only the `party_category` handling changed, to read `nullif(p_account->>'party_category_id', '')::uuid` and write the new column; everything else reproduced verbatim.
- `MasterTypeKey.customerCategory`/`.supplierCategory` added to `lib/core/config/master_type_keys.dart`, replacing two inline-hardcoded strings.
- Four Flutter screens converted from free-text/mis-bound dropdown to a real FK-backed `DropdownButtonFormField<String>` (`value: c['id']`, payload key `party_category_id`):
  - `customer_master_screen.dart` / `supplier_master_screen.dart` — fixed the `value: c['description']` bug, routed through the new `MasterTypeKey` constants.
  - `chart_of_accounts_screen.dart` — replaced a raw `TextField`. This screen is `account_nature`-generic, so the category list re-fetches and clears (`_categoryId = null`) whenever `account_nature` changes between Customer/Supplier/other, with `key: ValueKey('$_nature-$_categoryId')` per the FormField-staleness convention.
  - `prospect_conversion_dialog.dart` — replaced a raw `TextFormField`, fixed to `CUSTOMER_CATEGORY` only (prospects always convert to Customer).

## What migration 137 creates

**Shared core, two thin wrappers**, mirroring the Oracle reference's own nature-discriminated shared view:

```
fn_party_ageing_lines_core(p_client_id, p_company_id, p_account_nature, p_group_id, p_category_id, p_account_id, p_currency)
  → fn_customer_ageing_lines(...)  -- wraps core with 'Customer'
  → fn_supplier_ageing_lines(...)  -- wraps core with 'Supplier'
```
Plus `fn_customer/supplier_ageing_totals` (footer) and `fn_customer/supplier_ageing_summary_by_currency` (the `ric_report_group_levels` level-1 summary).

**Core pipeline** (`LANGUAGE sql STABLE`, `WITH`-chain of CTEs):
1. `location_ok` — `ric_user_location_access` unrestricted/restricted check (029 convention).
2. `bill_lines`/`bill_buckets` — same shape as `v_pending_bills` (117) but with group/category/nature columns and day-bucketing it doesn't expose; `CURRENT_DATE - inv_bill_date` bucketed into ≤30/31-60/61-90/>90 via `FILTER (WHERE ...)`. Location-access filter pushed into this CTE directly (not a bolt-on existence check at the end) so an account with lines in both accessible and inaccessible locations only totals the accessible ones.
3. `advance_per_voucher`/`advance_lines` — the Oracle-derived join (see Context). Lines pre-aggregated to one row per `(account, voucher)` **before** joining the settlement-sum subquery, to avoid duplicating `settled_amt` when a voucher posts more than one line against the same account.
4. `accounts` — joins `rim_accounts` for nature/`inter_entity_group_id`, immediate-parent self-join for `group_name`, `rim_common_masters` via `party_category_id` for `category_name`. **Effective category override**: `inter_entity_group_id IS NOT NULL → 'Inter-Entity'` (display-only; the real `party_category_id` untouched) — confirmed by the user, inter-entity accounts stay in the report, just relabeled.
5. `currency_keys` — `UNION` of both sources' `(account_id, party_currency)` pairs, so `bill_buckets`/`advance_lines` join on **both** columns, not `account_id` alone — an account transacting in more than one currency can't cross-multiply bucket amounts from one currency with advance amounts from another.
6. `combined`/final `SELECT` — every amount `ABS()`'d (positive "amount owed", never literal Dr/Cr sign carry-through — a Supplier bill is naturally Cr and would make every figure negative). `net_closing = total_outstanding - unsettled_advance`. `sort_key = LPAD(currency,8,'0') || '~' || LPAD(account_code,12,'0')`, every column `sortable=false` so a header click can't break the currency grouping.

**Lookup views**: `v_party_account_groups_lookup` (parent accounts with ≥1 Customer/Supplier child), `v_party_currencies_lookup` (currencies actually used by a Customer/Supplier account), `v_customer_categories_lookup`/`v_supplier_categories_lookup` (per-nature `rim_common_masters` query, each with its own `UNION ALL` synthetic `'Inter-Entity'` row — split into two views specifically so Category filter options never leak across Customer/Supplier).

**Registry**: `TABULAR`/`FUNCTION`, no Base/Local toggle (`source_object_local=NULL` — every figure is inherently a party-currency amount, matching Account Ledger's (132) precedent, not Trial Balance's (135) book-wide toggle). One `ric_report_group_levels` row, `group_by_column='party_currency'`. New feature codes `FN-RPT-CAG`/`FN-RPT-SAG` (no existing placeholder found — first genuinely new report menu entries since 127/132/135, all of which repointed an existing placeholder instead), added to `fn_seed_client_modules.sql` for future clients too.

## Real bugs caught and fixed before/during this session

1. **Currency cross-join** (self-review, before user saw it) — original design joined `bill_buckets`/`advance_lines` to `accounts` on `account_id` alone; fixed via the `currency_keys` CTE above.
2. **Location-security amount-leak** (self-review) — original design only checked `EXISTS` at the end; fixed by pushing the filter into `bill_lines`/`advance_per_voucher` directly.
3. **Settlement double-counting** (self-review) — fixed by pre-aggregating to `advance_per_voucher` before the settlement join.
4. **Missing/leaking category lookup** (self-review) — split one shared `v_party_categories_lookup` into two nature-scoped views, each with its own `'Inter-Entity'` union row.
5. **Missing `WITH` keyword** (caught by the user running the migration in Supabase — `ERROR 42601: syntax error at or near "location_ok"`) — `fn_party_ageing_lines_core`'s CTE chain was missing its opening `WITH`, fixed in place.
6. **Column-drop overreach** (caught by the user reading the migration file — see Context above) — corrected before running.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/136_party_category_lov.sql` | **New** — `party_category_id` FK column, `fn_convert_prospect_to_customer` re-issue |
| `backend/migrations/137_party_ageing_reports.sql` | **New** — 671 lines, both reports' full engine + registry |
| `backend/functions/fn_seed_client_modules.sql` | Added `FN-RPT-CAG`/`FN-RPT-SAG` rows |
| `lib/core/config/master_type_keys.dart` | Added `customerCategory`/`supplierCategory` constants |
| `lib/features/master/presentation/screens/customer_master_screen.dart` | Category dropdown fixed to bind `id`, not `description` |
| `lib/features/master/presentation/screens/supplier_master_screen.dart` | Same fix |
| `lib/features/master/presentation/screens/chart_of_accounts_screen.dart` | `TextField` → nature-aware FK dropdown |
| `lib/features/sales/presentation/widgets/prospect_conversion_dialog.dart` | `TextFormField` → FK dropdown |

## Verification

Completed by the user 2026-08-18: both migrations run in Supabase, `flutter test` 604/604 green.

**Not yet independently re-verified in this session** (no local Postgres/Flutter toolchain to run these): Net Closing reconciliation against `fn_account_ledger_totals`, bucket-sum-equals-total per row, currency subtotal correctness, filter isolation, inter-entity relabeling, full UI walk-through (Sidebar → Finance → Reports → both new entries, group headers, PDF/Excel export). Recommended as the next manual pass against real data.

## Known gaps / follow-ups

- **No opening-balance CTE** (unlike Trial Balance, 135) — an account whose exposure predates the ledger and relies on `rid_opening_balance_lines` will show a Net Closing mismatch against `fn_account_ledger_totals`. Documented, not fixed — same category of gap Trial Balance itself flagged.
- **Unsettled Advance's settlement join is forward-compatible but not yet exercised** — no "apply an old advance against a new bill" workflow exists in SAKAL today, so every advance currently shows fully unsettled by construction, not by data.
- **The old `party_category` TEXT column remains in the schema**, unused by the app. Left for the user to reset/drop on their own timeline, not this migration's decision to make.
- **`fn_seed_client_modules.sql`'s own `FN-TRB` row still points at the stale `/finance/trial-balance` placeholder** (pre-existing, unrelated gap noted during the Trial Balance build, not fixed here either).
