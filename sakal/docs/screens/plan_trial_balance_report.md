# Trial Balance report — Finance

Status: Implemented 2026-08-18 (migration `135_trial_balance_report.sql`). Migration run against Supabase and verified by the user the same day.

Implementation note: this report needed **zero new Flutter code** — see "Key discovery" below. The entire feature is one SQL migration. The only Dart touched was a shared cosmetic polish to `report_pdf_export.dart` (navy header/footer), which benefits every report, not just this one.

## Context

Trial Balance sat on CLAUDE.md's "still pending" list for the Finance module for weeks. An earlier session had already built its **prerequisite** — see [[plan_opening_balance_entry_screen]], which says in its own Context section: *"Trial Balance itself is a separate, later plan — it can't be meaningfully tested without this data existing first."* That work produced `rid_opening_balance_lines` (bill-level opening balances) plus `v_opening_balance_summary` (nets them into one signed figure per account / FY / location-group), and prescribed the formula this report consumes:

> opening (as of `date_from`) = this view's signed figure for the FY containing `date_from`, **plus** net movement of `rid_finance_lines` from that FY's start date up to `date_from`.

Nothing had consumed that view until now. This plan builds the actual report on top of it.

### User's spec (verbatim requirements)

- **Columns** (landscape): Account Group Name, Account Name, Opening Balance (Amount), Opening Balance Type (Dr/Cr), Debit, Credit, Closing Balance (Amount), Closing Balance Type (Dr/Cr)
- **Parameters**: From Date, To Date, With/Without Zero, Currency (Base or Local), Location Group (if entity-wise P&L is set up)
- **Header/footer**: same design as the 2026-08-19 transaction-document print polish
- **Account Group Name**: *"Immidiate parent(no heirarchy) but report should be sorted on group code so that i comes like Assets Liability Income , xpense.."* — i.e. immediate parent only, **sorted by group code**, not alphabetically by group name.

## Key discovery: the Reporting Engine needs no Flutter change

Every report in this app is served by ONE generic screen (`lib/core/reporting/sakal_report_screen.dart`, route `/reports/:reportKey`) driven entirely by four registry tables (`ric_report_definitions` / `_columns` / `_filters` / `_group_levels`, migration 116) plus a Postgres FUNCTION or VIEW. **A new report is a migration, not a Flutter change.**

Deliberately **NOT** used: `report_type='HIERARCHICAL'` + `ric_report_group_levels`. That schema exists (116 even names Trial Balance as its eventual first consumer) but has never been exercised by any report. Account Group is just a plain `TABULAR` column here — which is also exactly what the user's literal column list asks for. Taking the untested path would have coupled a first-of-its-kind report to a first-of-its-kind engine feature.

Report PDF export is a **separate system** from the transaction-document Print Engine — `report_pdf_export.dart`'s own top comment says so deliberately (a report's PDF is a simple paginated table, not a fielded document layout). "Same header/footer as last session" therefore meant polishing that file's own header/footer to match the navy accent, not routing reports through `PrintTemplate`/`PrintElement`.

## What migration 135 creates

### `v_location_groups_lookup`
`SELECT id, client_id, company_id, group_name FROM ric_location_groups WHERE is_active AND NOT is_deleted` — feeds the Location Group filter's `DROPDOWN_LOOKUP`. First report filter in the app to use Location Group at all.

### Four functions (Base/Local twins)

| Function | Purpose |
|---|---|
| `fn_trial_balance_lines_base` | One row per postable account, Base currency |
| `fn_trial_balance_lines_local` | Identical, reading `local_amount` |
| `fn_trial_balance_totals_base` | Single-row Total Debit / Total Credit |
| `fn_trial_balance_totals_local` | Identical, Local currency |

Signature (all four share the first six params):

```
p_client_id UUID, p_company_id UUID, p_date_from DATE, p_date_to DATE,
p_include_zero BOOLEAN DEFAULT false, p_location_group_id UUID DEFAULT NULL
```

`LANGUAGE sql STABLE`. Composed of four CTEs:

- **`fy`** — the financial year containing `p_date_from`.
- **`opening_master`** — `v_opening_balance_summary`'s signed figure for that FY (scoped by location group when supplied).
- **`opening_movement`** — net signed movement from `fy.fy_start_date` up to (**not including**) `p_date_from`.
- **`period_movement`** — Debit/Credit split within `[p_date_from, p_date_to]`, via `SUM(...) FILTER (WHERE trans_nature = ...)`.

Opening = `opening_master.signed + opening_movement.signed`. Closing = opening + period_debit − period_credit. Both are surfaced as an **unsigned `ABS()` amount plus a separate Dr/Cr type column**, matching the user's column spec (negative ⇒ `Cr`).

Only **posted** entries count: every movement CTE joins `rih_finance_headers` and filters `is_posted = true AND is_deleted = false`, same convention as `fn_account_ledger_lines` (132).

### Currency toggle — reuses migration 127's mechanism

`source_object` / `source_object_local` (and the same pair for totals) are both populated, which is what makes `ReportDefinition.hasCurrencyToggle` true and renders the Base/Local `SegmentedButton`. Chosen over 132's `DROPDOWN_STATIC` param approach because Trial Balance is book-wide Base/Local, not a per-line party currency.

### Security

Every movement CTE embeds the same `ric_user_location_access` check as 132 — *no rows configured for this user ⇒ no restriction; otherwise restrict to their locations*. This is **additional to**, not a replacement for, table-level RLS.

### Sorting — the `sort_key` trick

`default_sort_column` can only ever name ONE column, but the required order is *group code, then account code*. Solved with a synthesized hidden column (`default_visible = false`):

```sql
LPAD(group_code, 12, '0') || '~' || LPAD(account_code, 12, '0') AS sort_key
```

Zero-padding makes a text sort behave numerically. Same idea as `sort_seq` in migration 132. **Every column is `sortable = false`** — letting a user click a header to re-sort would destroy the Assets → Liabilities → Income → Expense grouping the sort exists to produce.

Account Group Name is the account's **immediate parent** via a plain self-join (`LEFT JOIN rim_accounts p ON p.id = a.parent_id`), falling back to the account's own code when it has no parent. Note this does *not* use `v_rim_accounts_with_parent` (134) — a direct join was simpler and avoids a dependency.

### Registry rows (per company)

- **Definition**: `report_key='TRIAL_BALANCE'`, `TABULAR`, `source_type='FUNCTION'`, `module_code='FN'`, `default_sort_column='sort_key'`, `default_page_size=500`.
- **Columns**: the user's 8, plus hidden `sort_key`. `default_width` sums to **830** — deliberately >700 so `report_pdf_export.dart`'s existing width heuristic auto-selects **landscape**, with no orientation field needed.
- **Filters**: `date_range` (DATE_RANGE, **required**, default `THIS_MONTH`), `include_zero` (BOOLEAN, default `false` = "Without Zero"), `location_group` (DROPDOWN_LOOKUP → `v_location_groups_lookup`, optional).
- Same per-company `DO $$ LOOP` + `ON CONFLICT DO UPDATE` + full-replace-columns/filters shape as 127/132.

### Menu wiring — repoint, don't add

`FN-TRB` already existed as a placeholder resolving to a bare `_Placeholder` widget at `/finance/trial-balance`. Per this project's standing rule (*always check `ric_master_menus` for an existing placeholder before assuming a new menu-seed is needed*), its `screen_name` is **repointed** to `/reports/TRIAL_BALANCE` rather than adding a second feature code. `ric_user_menus` is backfilled with `view_allowed = true` for existing users. The old route in `app_router.dart` / `route_names.dart` is left harmlessly unreferenced.

## Files touched

| File | Change |
|---|---|
| `backend/migrations/135_trial_balance_report.sql` | **New** — 492 lines; the entire feature |
| `lib/core/reporting/report_pdf_export.dart` | Navy (`#1B3A6B`) table-header fill, company name, report title, and a thicker `1.4` header divider — replacing generic `blueGrey800`/grey. Shared by **every** report |

No other Dart file changed. No new screen, no new provider, no new route.

## Verification

Completed by the user 2026-08-18: migration run in Supabase, then checked end-to-end.

1. Sidebar → Finance → Reports → Trial Balance opens the generic report screen (confirms the `FN-TRB` repoint took).
2. **Total Debit reconciles with Total Credit** in the totals row — the natural double-entry sanity check, and the strongest single signal the opening/period math is right.
3. Row order reads Assets → Liabilities → Income → Expense (the `sort_key` ordering against the real COA numbering).
4. Base/Local toggle swaps the figures.
5. With/Without Zero adds/removes nil accounts.
6. Location Group filter (INTER_ENTITY companies only).
7. PDF export — landscape, navy header/footer.

## Known gaps / follow-ups

- **`HIERARCHICAL` report type remains unexercised** app-wide. If a future Trial Balance revision wants real collapsible group subtotals rather than a flat group column, that engine path needs building and testing first.
- **No drill-down** from a Trial Balance row into Account Ledger (132). Both reports exist independently; linking them is a natural next step.
- **Opening balance depends entirely on `rid_opening_balance_lines` being populated** for the FY in question. An account with no opening-balance row and no prior-period movement simply opens at zero — correct behaviour, but it means a company that skipped the Opening Balance screen at go-live will show an incomplete Trial Balance with no warning.
- **P&L and Balance Sheet are still pending** — the remaining two items on the Finance module's reports list. Both can reuse this report's opening-balance CTE shape almost verbatim.
