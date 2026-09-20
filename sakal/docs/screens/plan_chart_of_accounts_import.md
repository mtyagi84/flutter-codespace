Status: Implemented 2026-09-20 (migration 200 deployed + verified live; `coa_import_screen.dart` built; old upload button removed from Chart of Accounts screen; `flutter analyze` clean)

# Chart of Accounts Import — reconciliation wizard for a client's own COA

## Context

Every future tenant arrives with their own existing chart of accounts (from
Tally or another system), which needs to be reconciled against SAKAL's own
auto-seeded standard COA — NOT replaced by it. Two facts, confirmed by
direct research this session, rule out a Product-style "wipe and reinsert"
approach:

1. **SAKAL's top-level group structure is not just seed data — the
   Hierarchical Profit & Loss, Balance Sheet, and Cash Flow reports
   hardcode specific `account_code` literals** (`'1000'`, `'2000'`,
   `'4110'`, etc., per `accounting_std`) to locate "Assets," "Liabilities,"
   "Revenue," and their major children. Deleting or restructuring those
   groups would silently break those reports — no error, just missing
   numbers.
2. **`is_system_fixed` currently protects nothing at the database level** —
   only the Chart of Accounts screen's own Delete button checks it
   client-side. Worse, the three auto-created infrastructure accounts
   (Stock Account, Cost of Sales, Purchase Accrual/GR-IR — created by
   `fn_seed_default_leaf_accounts_and_links` during tenant setup and
   load-bearing for GRN/GL posting) aren't even flagged `is_system_fixed`,
   so they can currently be deleted with zero warning.

The user's own framing is exactly right and is what this plan implements:
**`SAKAL_COA ∪ (Client_COA − SAKAL_COA)`** — keep everything SAKAL already
has, and add only the client's accounts that don't already have an
equivalent, as new leaves under SAKAL's existing (protected) group
hierarchy.

## Design — a 3-step reconciliation wizard, replacing the current upload button

The existing Chart of Accounts screen's Template/Upload Excel buttons
(`_downloadAccountsTemplate`/`_uploadAccountsExcel` in
`chart_of_accounts_screen.dart`) are **removed** per the user's explicit
request — that tool only ever does "insert new leaf under a known parent,"
with no way to recognize that a client's row might already correspond to an
existing SAKAL account. It's replaced by a new, dedicated screen.

**Step 1 — Upload.** Template columns: `Client Account Code, Client Account
Name, Nature, Client Group/Category (informational only), Currency` plus
the same optional Customer/Supplier party-detail columns the current tool
already supports (`Party Type, Contact Person, Phone, Email, Address Line
1/2, Tax ID, Credit Days, Credit Limit`) — carries forward that existing
capability, since a client's own ledger export typically mixes every
nature in one sheet (same reasoning already used for the current tool).

**Step 2 — Reconcile grid.** After upload, ONE batched RPC call (never
per-row — matching this session's own repeated lesson about avoiding N+1
calls on a large import) fetches a best-guess existing-account match for
every row at once, using Postgres's `pg_trgm` trigram similarity, narrowed
to the same `account_nature` so a Customer row never suggests an Expense
account. The grid (built on the same sticky-header +
`ListView.builder`-based pattern proven this session for Bulk Upload
Products / the merged Opening Stock screen — both scrollbars, stays fast
at hundreds of rows) shows, per row:
- **Suggested Match** — an editable account picker, pre-filled with the
  best guess (or blank if nothing scored high enough); the user can accept,
  pick a different existing account, or clear it.
- **Action** — defaulted from whether a match exists (`Map` / `Create New`
  / `Skip`), always user-overridable.
- **Parent Group** (enabled only for `Create New`) — an autocomplete over
  SAKAL's *existing* groups only, same "Parent Account Code" convention the
  current tool already uses. This screen never offers to create a new
  *group* — only new leaves under the existing, protected hierarchy.
- **New Account Code** — auto-suggested via the existing
  `fn_next_account_code` for `Create New` rows, editable.

**Step 3 — Commit.** One confirmation dialog (counts: N mapped, M created,
K skipped), then ONE new RPC call, `fn_apply_coa_import`, does everything
in a single transaction — genuinely safer than the current tool's own
approach (a client-side loop of independent `POST`s, not atomic; a
mid-loop failure today leaves a partial import). For a `Map` row: writes
the client's code onto the existing account's new `external_code` column
(no other field touched — an existing account's name/details are never
silently overwritten by a client import). For a `Create New` row: inserts
exactly like the current tool does today, plus the same `external_code`
for traceability.

## New schema/backend pieces (one new migration, next number 200)

- `rim_accounts.external_code TEXT` (nullable) + a partial unique index on
  `(client_id, company_id, external_code) WHERE external_code IS NOT NULL`
  — the client's own original code, so a **second** import (a corrected
  file, or a later batch) recognizes what's already mapped instead of
  re-prompting, and so support can trace "client's code X = SAKAL account
  Y" after the fact.
- `CREATE EXTENSION IF NOT EXISTS pg_trgm;` + `fn_suggest_coa_import_matches(p_client_id, p_company_id, p_rows JSONB)` — one batched call, returns the best-scoring existing account per input row (LATERAL join using `similarity()`, filtered by matching `account_nature`).
- `fn_apply_coa_import(p_client_id, p_company_id, p_map_rows JSONB, p_create_rows JSONB, p_user_id UUID)` — one transaction, does every Map (UPDATE `external_code`) and every Create (INSERT, same shape as the current tool's own insert payload) together.
- `fn_can_delete_account(p_client_id, p_company_id, p_account_id) RETURNS TEXT` — new guard, same NULL-is-safe/TEXT-reason shape as migration 130's `fn_can_delete_location`/`fn_can_change_product_base_uom`. Checks `rid_finance_lines` (ever posted to) AND `rim_account_link_setup`/`rim_account_link_defaults` (referenced as a link default) — closes the gap where a load-bearing linked account can be deleted with no warning today. Wired into `chart_of_accounts_screen.dart`'s existing `_delete()` method, which currently calls none of this (a direct PATCH with zero server-side guard).
- One-time data fix: `UPDATE rim_accounts SET is_system_fixed = true WHERE id IN (SELECT account_id FROM rim_account_link_setup UNION SELECT account_id FROM rim_account_link_defaults)` across all companies — flips every currently-unprotected, load-bearing linked account (Stock Account, Cost of Sales, Purchase Accrual, and any admin-configured link) to properly protected, not just Shanju's.
- Menu: new feature `MST-COAI` ("Chart of Accounts Import"), screen_name `/master/coa-import`, same `FN-MST` group as `MST-COA` itself. `MST-COA.excel_upload_allowed` reverted back to `false` (same precedent as migration 191's own `MST-PRD` reversion) since its upload button is being removed. Both changes made to `ric_master_menus` (existing companies) and `fn_seed_client_modules.sql` (future tenants).

## Files touched

**Backend**: one new migration (200) with the pieces above.

**Flutter**:
- New file `lib/features/master/presentation/screens/coa_import_screen.dart` — the 3-step wizard, reusing the proven grid pattern (sticky header, `ListView.builder`, synced horizontal scroll, `Scrollbar` on both axes) and the existing account/parent-picker conventions already used in `chart_of_accounts_screen.dart`.
- `chart_of_accounts_screen.dart` — remove `_downloadAccountsTemplate`/`_uploadAccountsExcel`/their header buttons; wire the new `fn_can_delete_account` guard into `_delete()` (call it first, show the reason via `ErrorPresenter`-style messaging, block the delete if non-null — matching how every other `fn_can_delete_*` call site in this app already works).
- `RouteNames.coaImport` + `GoRoute` in `app_router.dart`.
- Whatever data-access pattern `chart_of_accounts_screen.dart` already uses for its own `rim_accounts` calls (confirm during implementation — either a thin repository method addition or direct `DioClient` calls, matching that screen's existing style) gets the three new RPC wrappers.

## Verification
- `flutter analyze` clean (targeted + full project).
- Manual smoke test once deployed: upload a small test file with (a) a row whose name closely matches an existing seeded account (confirm it's suggested as Map with a visible score), (b) a row with no reasonable match (confirm it defaults to Create New under a sensible parent), (c) commit and confirm exactly the right accounts were created/mapped, zero duplicates. Also confirm: attempting to delete the Stock Account (or any linked account) from Chart of Accounts now shows a clear blocking reason instead of silently succeeding.
