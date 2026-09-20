Status: Superseded 2026-09-20 — retired and merged into the Opening Stock
screen after the user correctly flagged this screen as functionally
duplicating it. See `plan_merge_opening_stock_screens.md` for the merge
plan; do not implement anything in this file independently.

Implemented 2026-09-19 (migration 193 deployed; layout bug fixed same day — see commit c9aeb47)

# Opening Stock — Value Upload (Excel, qty + cost, with GL posting)

## Context

The existing Opening Stock screen (`opening_stock_entry_screen.dart`, migrations
077/084) already lets a company establish starting quantity + cost per
product/location — but deliberately posts **no GL entry at all** (documented in
077's own header comment: "the company's overall opening trial balance is
handled separately, later, via a Finance-side account-opening-balances
upload"). That "later" moment is now: the user wants a new, simpler,
bulk-upload-first screen that (a) downloads a template pre-filled from Product
Master, (b) lets the user fill in opening quantity + cost per product, (c)
reviews everything in an on-screen grid before picking the Store/Location, and
(d) on Save, both establishes the stock/cost (as today) **and** posts a real
GL entry: Dr each product's Stock Account, Cr a new "Opening Stock Equity"
account — dated at the start of the company's financial year.

Four design questions were resolved directly with the user before finalizing
this plan:
1. **Batch/Serial tracked products ARE supported** (not excluded) — the
   template gets optional Batch No / Expiry Date / Manufacturing Date /
   Serial No columns (same shape as the existing Opening Stock screen's own
   Excel template), left blank for untracked products.
2. **The posting date is LOCKED to the financial year start date** (not
   editable) — resolved from `rim_financial_years` (the active FY, or the
   earliest one if none is marked active), guaranteeing every value-posting
   opening stock entry lines up with the same date as Chart-of-Accounts
   opening balances entered elsewhere.
3. **Save is one click** (save + approve chained), matching Sales Invoice's
   own "Save IS the Approve step" precedent — not a two-step Draft → Approve
   flow.
4. **The credit account is configured via a NEW Account Link Setup type**
   ("Opening Stock Equity Account"), not an ad-hoc picker on the screen —
   reuses the existing generic framework (`rim_account_link_types` /
   `fn_resolve_account_link`), so the admin configures it once, the same way
   `STOCK_ACCOUNT`/`PURCHASE_ACCRUAL_ACCOUNT` already work for GRN.

## Key design decision — reuse the existing Opening Stock engine, don't duplicate it

`rid_opening_stock_lines` already has every column this new screen needs
(`product_id`, `uom_id`, `base_qty`, `batch_no`/`expiry_date`/`serial_no`,
`unit_cost`, `unit_cost_specific`), and `fn_approve_opening_stock` already has
the exact safety guard this needs too (`OPENING_STOCK_ALREADY_ESTABLISHED`,
checked per product **regardless of which screen created the document** —
critical, since it's what prevents this new screen and the existing one from
ever double-establishing the same product/location). Building a second,
parallel set of tables/functions would duplicate that guard and risk it
drifting out of sync. Instead:

- Add `rih_opening_stock_headers.post_gl BOOLEAN NOT NULL DEFAULT false` —
  purely additive; the existing screen never sets it, so its behavior is
  byte-for-byte unchanged.
- `fn_save_opening_stock` needs **no signature change at all** — both
  `p_header` and each line in `p_lines` are JSONB, so a new `post_gl` key on
  the header and an optional `unit_cost_specific` key per line are simply
  read with `coalesce(...)`/`nullif(...)`, exactly like every other optional
  key this function already handles. Old callers that omit these keys get
  the old behavior (`post_gl=false`, `unit_cost_specific` derived at Approve
  as today).
- `fn_approve_opening_stock` (`CREATE OR REPLACE`, same 5-parameter
  signature, reproducing the CURRENT full body from migration 112 verbatim —
  per this project's own "grep every migration for the latest definition"
  rule, since 112 already added the `IN-OPN` permission check on top of 084):
  - Skip the unit_cost_specific auto-derive step for a line that already has
    a value (this new screen supplies it directly from the Excel "Price
    (Product Currency)" column) — derive only when still NULL, exactly as
    today.
  - After the existing per-line `fn_post_stock_movement` loop, if
    `v_header.post_gl`, build one Dr voucher line per opening-stock line
    (`fn_resolve_account_link(..., 'STOCK_ACCOUNT')` — hard-fail if
    unconfigured, same "never post with no account" rule as every other
    module) plus **one aggregate Cr line** for the whole document's total
    value against `fn_resolve_account_link(..., 'OPENING_STOCK_EQUITY_ACCOUNT')`
    — one Dr per line (matching this codebase's established "no aggregation
    across lines sharing an account" precedent, e.g. Material Issue) plus a
    single aggregate Cr (matching Purchase Return's "other side posted once
    in aggregate" precedent) — then **one** `fn_post_voucher(..., 'JV', ...)`
    call, tagged `source_doc_type='OPENING_STOCK'` (same voucher-type choice
    as GRN's own non-party stock-related JV postings — this is an internal
    Stock↔Equity entry, not a party bill).
  - Permission check branches on `post_gl`: `false` → existing `IN-OPN`
    check (unchanged); `true` → a NEW `IN-OSV` feature-code check instead,
    so an org can grant "plain opening stock" and "GL-posting opening stock
    value upload" as separate permissions — same branching pattern already
    used for GRN vs Stock Count Review's shared `IN-ADJ` composition guard.

## Backend changes (one new migration, next number after 192)

1. `ALTER TABLE rih_opening_stock_headers ADD COLUMN IF NOT EXISTS post_gl BOOLEAN NOT NULL DEFAULT false;`
2. Seed `rim_account_link_types`: `('OPENING_STOCK_EQUITY_ACCOUNT', 'Opening Stock Equity Account', <next sort_order>)` — the existing Account Link Setup screen already lists link types generically from this table, so **no Flutter change is needed** for the admin to configure it.
3. `fn_save_opening_stock` — add the two additive JSONB reads described above.
4. `fn_approve_opening_stock` — `CREATE OR REPLACE`, full body from 112 reproduced verbatim plus the changes above.
5. New menu entry: `feature_code='IN-OSV'`, `feature_name='Opening Stock Value Upload'`, `screen_name='/inventory/opening-stock-value-upload'`, `group_code='IN-OPS'` (same "Operations" group as `IN-OPN`), `excel_upload_allowed=true`, `approve_allowed=true` — inserted into `ric_master_menus` for existing companies (same `JOIN ric_system_modules` shape as 077's own seed) + `ric_user_menus` backfill for users who already have edit access to another IN-OPS feature.
6. `fn_seed_client_modules.sql` — add the `IN-OSV` row to the Inventory Operations block so future clients get it automatically.

## Flutter changes

**New file**: `lib/features/inventory/presentation/screens/opening_stock_value_upload_screen.dart` — `ConsumerStatefulWidget` with `ScreenPermissionMixin` + `ScreenHeaderMixin` + `DeferredRowDisposal`, reusing the **existing** `OpeningStockRepository` (`openingStockRepositoryProvider`) — `save()` and `approve()` are already exactly what's needed; no new repository/datasource required.

- `RouteNames.openingStockValueUpload` + a `GoRoute` in `app_router.dart`.
- **Header**: read-only Location picker's counterpart is required (`DropdownButtonFormField`, required, like every other screen) + a **read-only, locked** "Posting Date" field showing the resolved FY start date (fetched once at init via a plain `GET /rim_financial_years?company_id=eq...&order=fy_start_date.asc` — prefer `is_active=true`, else earliest — with a clear blocking error if the company has no financial year set up yet).
- **Download Template** (`canExcelUpload`-gated, matching every other upload screen): fetches the full active product list directly (`DioClient.instance.get('/rim_products', ...)`, `select: id,product_code,product_name,base_uom_id,tracking_type,uom:rim_common_masters!base_uom_id(description)`, no `limit` cap — `getProductsForPicker`'s existing 500-row cap is too low for a full product-master export) and writes one PRE-FILLED row per product: `Product Code`, `Product Name`, `Unit` (all filled in), plus blank `Qty`, `Batch No`, `Expiry Date`, `Manufacturing Date`, `Serial No`, `Price (Base Currency)`, `Price (Product Currency)` for the user to complete. A tracked product needing multiple lots: the user copies its pre-filled row and fills in different batch/serial values per copy, same convention the existing Opening Stock screen already expects for multi-lot Excel upload.
- **Upload Excel**: matches by `Product Code` (case-insensitive) against a fresh `getProductsForPicker`-style fetch (bumped to a real full-catalog query, not capped at 500), building one grid row per Excel row — `tracking_type` read off the matched product decides whether Batch/Expiry/Mfg/Serial fields render for that row (same `showBatchColumns`/`showSerialColumn` per-row-optional pattern as the existing screen). Deferred validation (accept the row, surface problems at Save) — same convention as every other upload in this app.
- **Grid**: reuses the sticky-header + `ListView.builder` + synced horizontal scroll pattern already built and fixed this session in `bulk_upload_products_screen.dart` (proven fix for the "hangs on ~400 rows" / "header scrolls away" / "no horizontal scrollbar" bugs) — this screen could realistically face a similarly large row count (one row per product in the whole catalog).
- **Advisory already-established check**: once Location is picked, one batched fetch of `rim_product_location` (`current_stock`,`cost_price`) for every matched `product_id` at that location — rows already established are flagged inline (red, matching the existing screen's own `alreadyEstablished` treatment) before Save is even attempted; the real enforcement stays server-side in `fn_approve_opening_stock`, this is UX only.
- **Save**: one click — confirmation dialog (destructive/irreversible, matching the tone of the Bulk Upload Products reset-confirmation dialog) → `_ds.save(header: {..., 'post_gl': true, 'opening_date': fyStartDate}, lines: [...])` → immediately `_ds.approve(...)` on success, in one flow. Both calls happen inside one try/catch; a failure at either step (including `STOCK_ACCOUNT`/`OPENING_STOCK_EQUITY_ACCOUNT` unconfigured, or `OPENING_STOCK_ALREADY_ESTABLISHED` on any single product) fails the WHOLE document atomically inside `fn_approve_opening_stock`'s own transaction — no partial-row-skip logic needed client-side, unlike Bulk Upload Products' independent-per-row REST calls.
- **Online-only** — no offline queuing for this screen (consistent with this project's "Approve stays online-only" rule; since Save always chains Approve here, the whole screen requires connectivity, shown via the standard `OfflineBanner` + disabled Save when offline). This is a deliberate simplification over the existing Opening Stock screen (which supports offline Save Draft) — acceptable since this is fundamentally a one-time company/location setup screen, same reasoning already used for Stock Count Review's Screen 2.
- Blocking overlay + progress text while Save/Approve runs, matching Bulk Upload Products' own pattern (many rows, several seconds+).

## Verification
- `flutter analyze` clean (targeted + full project) after each file change.
- Manual smoke test once deployed: download the template (confirms it pre-fills every active product), fill a handful of untracked products + one batch-tracked product (two lot rows) with qty/cost, upload, pick a location, Save — confirm: `rim_product_location` rows created with correct `current_stock`/`cost_price`, `ril_stock_ledger` rows appended dated at the FY start date, and a `JV` voucher posted (Dr per line's Stock Account, Cr Opening Stock Equity Account) findable via that FY-start date and `source_doc_type='OPENING_STOCK'`. Also confirm: re-running the SAME upload a second time correctly fails the whole document with `OPENING_STOCK_ALREADY_ESTABLISHED` (proving the shared guard still works across screens), and that the OLD Opening Stock screen still behaves exactly as before (no GL posted) since it never sets `post_gl`.
