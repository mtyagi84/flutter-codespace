# Opening Balance entry screen — Chart of Accounts / Finance Masters

Status: Implemented 2026-08-13 — pending `flutter test`/`flutter analyze` and manual verification (see Verification section below).

Implementation note: the line-row UX ended up mirroring Journal Voucher's own `Wrap`-based Card-per-row pattern (FinanceAccountPicker + fields in a `SakalFieldCard`-wrapped `Wrap`), not the `SakalTableHeaderBar`/`SakalLineItemCard` desktop/mobile split originally described below — Journal Voucher's shape is the closer existing precedent for an "account + amount + type" row specifically, and is simpler to implement correctly. No Financial-Year-level document/header table was introduced (no `fn_save_*` RPC either) — save is a direct PostgREST delete-then-bulk-insert against `rid_opening_balance_lines`, scoped by `(client_id, company_id, fy_id, location_group_id)`, exactly as designed below.

## Context

While designing a Trial Balance report, it became clear the report's opening-balance figures must come from `rim_opening_balances` (the Chart-of-Accounts FY-opening master) rather than being derived by summing transaction history — because Income/Expense accounts reset to zero at each financial-year close while Asset/Liability/Equity accounts carry forward, and only a human (closing the books) knows which is which for a given account. Investigation found `rim_opening_balances` has **zero UI, zero backend RPC, and zero app-side consumer anywhere** — a fully-defined but completely unbuilt table. This plan builds that screen. **Trial Balance itself is a separate, later plan** — it can't be meaningfully tested without this data existing first.

Mid-design, the real requirement turned out to be bigger than "one balance figure per account per FY":
- **Bill-level granularity**: one account can have multiple opening-balance rows, each tied to a historical Invoice/Bill No + Date — the same `inv_bill_no`/`inv_bill_date` convention `rid_finance_lines` already uses everywhere else in this schema. A customer's opening balance isn't one lump Dr figure, it's however many of their old invoices were still outstanding at go-live.
- **All three currencies entered directly** (Base, Local, Party) — no auto-derivation via `fn_get_exchange_rate`, since that function requires a `location_id` and opening balances have no location relationship; this is one-time historical data transcribed from the client's prior books, not a live conversion.
- **Location-group scoping** — under `INTER_ENTITY` accounting, opening balances must be entered per location group (each group is its own entity with its own books), same conditional pattern already built for Finance vouchers.
- **Excel import**, mirroring Opening Stock's own template/upload pattern — given a real company could have 50-200+ accounts (and multiple bills per account) needing entry at go-live, manual row-by-row entry alone isn't practical.

## Data model

### Rename + redesign `rim_opening_balances` → `rid_opening_balance_lines`

Table is confirmed empty and has zero consumers — safe to drop and recreate rather than ALTER-in-place. Renamed because its grain changed from "one master value per account" (`rim_`) to bill-level transactional detail (`rid_`, matching `rid_finance_lines`' own prefix convention).

```
id                UUID PK
client_id         UUID NOT NULL
company_id        UUID NOT NULL
account_id        UUID NOT NULL REFERENCES rim_accounts(id)   -- posting_allowed=true only, enforced client-side same as every other account picker
fy_id             UUID NOT NULL REFERENCES rim_financial_years(id)
location_group_id UUID NULL REFERENCES ric_location_groups(id)  -- NULL under SIMPLE; required under INTER_ENTITY (enforced client-side, mirroring the voucher Location-field pattern)
base_amount       NUMERIC(18,4) NOT NULL DEFAULT 0
local_amount      NUMERIC(18,4) NOT NULL DEFAULT 0
party_amount      NUMERIC(18,4) NOT NULL DEFAULT 0
party_currency    TEXT NOT NULL          -- defaults from the account's own account_currency_id, editable
ob_type            TEXT NOT NULL CHECK (ob_type IN ('Dr','Cr'))
inv_bill_no        TEXT NULL             -- optional; mainly meaningful for Customer/Supplier accounts
inv_bill_date      DATE NULL
is_deleted          BOOLEAN NOT NULL DEFAULT false
created_at/by, updated_at/by             -- standard audit columns
```

No uniqueness constraint on `(account_id, fy_id)` — multiple legitimate rows per account are the whole point now. Standard `auth_rw_rid_opening_balance_lines` RLS policy, indexed on `(client_id, company_id, account_id, fy_id)`.

### `v_opening_balance_summary` — the aggregate a future Trial Balance/Account Ledger will read

```sql
SELECT client_id, company_id, account_id, fy_id, location_group_id,
       SUM(CASE WHEN ob_type='Dr' THEN base_amount  ELSE -base_amount  END) AS base_signed,
       SUM(CASE WHEN ob_type='Dr' THEN local_amount ELSE -local_amount END) AS local_signed,
       SUM(CASE WHEN ob_type='Dr' THEN party_amount ELSE -party_amount END) AS party_signed,
       MAX(party_currency) AS party_currency   -- expected uniform per account; MAX is a defensive pick, not a real aggregation
FROM rid_opening_balance_lines
WHERE is_deleted = false
GROUP BY client_id, company_id, account_id, fy_id, location_group_id;
```
This view is built now so the schema is ready, but **not consumed by anything in this plan** — Trial Balance (or a corrected Account Ledger) reads it in a future session.

**Explicitly flagged, not solved here**: these bill-level rows are not fed into `v_pending_bills` (which today only sources from `rid_finance_lines`), so an opening-balance invoice won't yet appear in Payment/Receipt Voucher's "Against Bill" settlement picker. Worth doing eventually so a customer's historical opening invoice can actually be settled through the normal flow, but it means touching an already-shipped, widely-used view — a separate, deliberately deferred piece of work.

## Screen design — one worksheet, no separate list screen

`rid_opening_balance_lines` has no status/document lifecycle (unlike Opening Stock's DRAFT/APPROVED) and rows are **freely editable at any time, no lock** — the Trial Balance formula (opening = seeded FY value + movement since FY-start) already tolerates the seeded value being corrected after transactions exist, so an Opening-Stock-style "already established" guard isn't actually needed for correctness.

**Header**: Financial Year picker (required) + Location Group picker (hidden under `SIMPLE`, required under `INTER_ENTITY` — same `interLocationModelProvider`-gated pattern already built for the Finance vouchers).

**Body**: a multi-row worksheet — implemented as Journal Voucher's own `Wrap`-based Card-per-row pattern (see implementation note above), each row = `FinanceAccountPicker` + Base/Local/Party amount fields + Party Currency (defaults from the picked account's `account_currency_id`, editable) + Dr/Cr toggle + optional Bill No/Bill Date. `(+)`/`(x)` per row via `DeferredRowDisposal`. Loads existing rows for the selected FY+Group on open; Save does a full delete-and-reinsert for that FY+Group scope, direct PostgREST calls (no custom RPC — this table has no server-side validation/posting logic requiring one).

**Excel import**, mirroring Opening Stock's exact template/upload/error-reporting shape (`_downloadTemplate`/`_uploadExcel` in `opening_stock_entry_screen.dart` was the template): columns `Account Code, Account Name, Base Amount, Local Amount, Party Amount, Party Currency, Opening Balance Type, Invoice/Bill No, Invoice/Bill Date`. Uploaded rows append to the worksheet (not auto-save) so the user can review before committing, same as Opening Stock.

## Menu wiring

Sits under the existing `FN-MST`/"Finance Masters" group — the same group Chart of Accounts, Account Link Setup, and Exchange Rates already live in — **not** Transactions or Reports. `feature_code='MST-OB'`, `feature_name='Opening Balance'`, `screen_name='/master/opening-balances'`, `serial_no=7` (next free slot in that group). Added both as a migration `INSERT ... ON CONFLICT` for existing companies (`133_opening_balance_lines.sql`) and into `fn_seed_client_modules.sql`'s own `FN-MST` block for new clients. `RouteNames.openingBalances` placed near `chartOfAccounts`/`accountLinkSetup`; `excel_upload_allowed=true` on the menu row gates the Upload Excel/Template buttons via `ScreenPermissionMixin.canExcelUpload`.

## Files touched

- `backend/migrations/133_opening_balance_lines.sql` (new) — `rid_opening_balance_lines` table + `v_opening_balance_summary` view + RLS + menu row + `ric_user_menus` backfill.
- `backend/functions/fn_seed_client_modules.sql` — `MST-OB` row added to the `FN-MST` block.
- `lib/core/providers/master_cache_providers.dart` — added `locationGroupsProvider` and `financialYearsProvider` (neither existed before).
- `lib/features/master/domain/repositories/opening_balance_repository.dart` (new)
- `lib/features/master/data/datasources/opening_balance_remote_ds.dart` (new) — plain PostgREST calls, no offline/local_ds branch (online-only setup data, same as Chart of Accounts itself).
- `lib/features/master/data/repositories/opening_balance_repository_impl.dart` (new)
- `lib/features/master/presentation/providers/opening_balance_providers.dart` (new)
- `lib/features/master/presentation/screens/opening_balance_entry_screen.dart` (new) — the whole screen, no separate list screen.
- `lib/core/router/route_names.dart` + `app_router.dart` — one new route.

## Verification

No local Flutter/Postgres toolchain here:
1. Run migration 133, confirm `rid_opening_balance_lines`/`v_opening_balance_summary` exist with correct RLS.
2. In the app: open Finance Masters → Opening Balance, confirm FY picker works, Location Group field is absent under `SIMPLE` and required under `INTER_ENTITY` (test company toggle, same as the voucher work's own verification step).
3. Add several rows for one account (including two rows sharing the same account with different Bill Nos), save, reload the screen for the same FY — confirm all rows restore correctly.
4. Download the Excel template, fill it, upload — confirm rows populate the worksheet correctly and bad rows report clearly, matching Opening Stock's own error-reporting behavior.
5. Query `v_opening_balance_summary` directly and confirm it correctly nets Dr/Cr across multiple rows for the same account into one signed figure per currency.

## Follow-up fixes, 2026-08-14

Live testing surfaced three real gaps beyond the original design, all implemented in the same session:

1. **Line-items layout** — the original `Wrap`-based Card-per-row implementation (see the implementation note at the top) let fields wrap onto a second line even on wide desktop viewports, missing this codebase's own mandatory "Line-items grid" pattern. Rebuilt using the actual pattern: `SakalTableHeaderBar` + `SakalScrollableTable` (one continuous row per line on desktop, horizontal scroll instead of wrapping) and `SakalLineItemCard` 2-column grid on mobile — matching Sales/Purchase Order.
2. **Excel template downloaded blank** — root cause shared with Opening Stock's own template download: `FilePicker.platform.saveFile()` uses Chrome's File System Access API on web, which needs a still-valid user activation and silently fails once that window passes. Fixed both screens using `web_download.dart`'s `downloadBytesOnWeb` (already built for the Reporting Engine's own Excel export, never applied back to either Opening screen).
3. **No way to find one account among thousands** — added a client-side search box filtering by account code/name or Invoice/Bill No.

Then three more real requirements surfaced:

4. **Editing restricted to the earliest financial year** — `_earliestFyId` computed from `financialYearsProvider` (min `fy_start_date`); `_editable = canEdit && _fyId == _earliestFyId`. The FY dropdown stays fully populated and selectable (per explicit user choice — later years, once FY-closing auto-generation exists, should still be browsable) but every field/button that mutates data is disabled when a non-earliest year is selected, with an inline banner explaining why.
5. **Excel template now pre-fills every posting-allowed account** with its current opening balance (one row per existing bill-line; a blank amount row for an account with nothing yet) instead of downloading empty — `_downloadTemplate` now reads `_postableAccounts` + `_lines`. Re-uploading **replaces** the on-screen worksheet rather than appending (matches an export→edit→re-import round trip without creating duplicate rows) — `_uploadExcel` clears `_lines` before populating, and skips any parsed row where every amount is 0 and Bill No is empty (untouched placeholder rows from the export don't become real persisted zero-value lines).
6. **Invoice/Bill No + Date gated to Customer/Supplier accounts** — `_OBLineRow` gained `accountNature` (from `rim_accounts.account_nature`, now also selected in `OpeningBalanceRemoteDs.getLines()`'s embed), set on account selection, on load, and on Excel upload. Bill fields stay in the grid for column alignment but render disabled/greyed for any other account nature, and any stale value is cleared when a line's account is changed away from Customer/Supplier.
