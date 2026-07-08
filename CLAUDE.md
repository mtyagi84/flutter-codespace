# SAKAL ERP — Flutter Multi-Platform ERP

## Project Overview
**SAKAL** (Sampurna = Complete in Sanskrit) is a full ERP system built by **Rigevedam Innovations** for retail/wholesale stores targeting DRC (Congo) and Zambia — regions with unstable internet. The app works fully online and offline.

- **App ID**: `com.rigevedam.sakal`
- **Version**: 1.0.0
- **GitHub**: https://github.com/mtyagi84/flutter-codespace
- **Codespace**: https://psychic-meme-q7jp9q54wj53pvv.github.dev
- **Flutter project root**: `C:\Manglu\SAKAL\sakal\`
- **Codespace project path**: `/workspaces/flutter-codespace/sakal/`

---

## Tech Stack

| Layer | Choice |
|---|---|
| Framework | Flutter 3.x — Web, Android, iOS, Desktop (one codebase) |
| State management | `flutter_riverpod ^2.5.1` |
| Navigation | `go_router ^14.0.0` |
| Local DB (offline) | `drift` + `drift_flutter` + `sqlite3_flutter_libs` |
| Remote DB | PostgreSQL |
| API layer | PostgREST — auto REST from PG schema; PG functions for complex reports |
| HTTP client | `dio ^5.6.0` |
| Auth tokens | `flutter_secure_storage` (JWT) |
| Connectivity | `connectivity_plus` |
| Models | `freezed` + `json_serializable` (code generation not yet activated) |

---

## Architecture: Feature-first + Clean Architecture

```
lib/
├── core/                    # Shared infrastructure (no business logic)
│   ├── config/              # AppConfig, AppConstants
│   ├── database/tables/     # Drift table definitions per module
│   ├── network/             # Dio client, auth interceptor, connectivity
│   ├── sync/                # Offline→Online sync engine
│   ├── auth/                # Session manager, token storage
│   ├── errors/              # Failure types, AppException types
│   ├── theme/               # AppTheme, AppColors (Material 3)
│   ├── router/              # GoRouter config, RouteNames constants
│   ├── layout/              # Responsive layout (sidebar/bottom nav)
│   ├── utils/               # Currency, date, validators, ID generator
│   └── widgets/             # Shared UI components (SakalButton, SakalDataTable...)
│
└── features/                # One folder per ERP module
    ├── auth/                # Login, change password
    ├── setup/               # Client, company, location, currency setup
    │   ├── client/
    │   ├── company/
    │   ├── location/
    │   └── currency/
    ├── master/              # Shared master data
    │   ├── customers/
    │   ├── suppliers/
    │   ├── products/
    │   ├── accounts/        # Chart of Accounts
    │   ├── uom/
    │   └── tax_codes/
    ├── users/               # User management + menu permissions
    ├── dashboard/           # Home screen with KPIs
    ├── sales/               # Invoices, receipts, returns
    ├── purchase/            # POs, GRN, purchase invoices, payments
    ├── inventory/           # Stock, transfers, adjustments
    ├── finance/             # Double-entry bookkeeping, reports
    └── reports/             # Cross-module reports
```

Each feature follows Clean Architecture internally:
```
feature/
├── data/
│   ├── datasources/     # local_ds.dart (Drift) + remote_ds.dart (PostgREST)
│   ├── models/          # JSON-serializable models
│   └── repositories/    # Repository implementations
├── domain/
│   ├── entities/        # Pure Dart business objects
│   ├── repositories/    # Abstract interfaces
│   └── usecases/        # Business logic
└── presentation/
    ├── providers/        # Riverpod providers
    ├── screens/          # Full-page widgets
    └── widgets/          # Feature-specific widgets
```

---

## Multi-Tenant Design

**Every single table has**: `client_id + company_id + location_id`

```
clients → companies → location_groups → locations
```
- 1 client → multiple companies
- 1 company → multiple location groups (entities)
- 1 location group → multiple physical locations (e.g. shop floor + backroom)
- Consolidation: UPSERT from location servers → central server (no conflicts — composite key)
- Same codebase works for SaaS (cloud-hosted) or on-premise (client's LAN server)

---

## Inter-Location Model (set once at company setup — never change after transactions exist)

`ric_companies.inter_location_model` has two values:

```
SIMPLE
  All locations share one P&L + Balance Sheet.
  Internal stock movements = pure stock transfer, no financial posting.
  Groups show Gross Profit report only (Sales − COGS per group).

INTER_ENTITY
  Each location group = independent entity with own P&L + Balance Sheet.
  Same group   → pure stock transfer (e.g. shop floor ↔ shop backroom)
  Diff group   → inter-entity invoice (creates customer/supplier transaction)
  Each group has TWO separate accounts for bill-by-bill reconciliation:
    customer_account_id  — receivable (DR when others sell TO this group)
    supplier_account_id  — payable   (CR when this group sells TO others)
```

**CRITICAL rules for all transaction screens:**
- NEVER restrict any location from doing any external transaction (PO, Sales Invoice, GRN etc.)
- Groups ONLY determine how internal movements between the company's OWN locations are treated
- Always check `company.inter_location_model` + `location.group_id` before posting any stock transfer
- Same `group_id` = always stock transfer regardless of mode
- Different `group_id` + INTER_ENTITY = inter-entity invoice (use group's customer/supplier accounts)

**`ric_location_groups` key fields:**
```dart
group_code, group_name
responsible_user_id       // accountable manager
customer_account_id       // → rim_accounts (this group as Customer in other groups' books)
supplier_account_id       // → rim_accounts (this group as Supplier in other groups' books)
```

**`rim_accounts.inter_entity_group_id`** — marks an account as belonging to a location group.
NULL = regular external party. NOT NULL = inter-entity account (separate aging/reports).

---

## Multi-Currency Design

Set at **company setup**:
1. **Base currency** — all financial books shown in this by default
2. **Local currency** — regional currency (e.g. FC for DRC, ZMW for Zambia)

Set at **customer/supplier creation**:
3. **Ledger currency** — currency that party sees their ledger in

Every transaction stores exchange rate → all 3 currencies derived automatically.

---

## ERP Modules

| Module | Status |
|---|---|
| Auth (login, session) | UI done, logic pending |
| Setup (client, company, location, currency) | Pending |
| Master (customers, suppliers, products, COA, UOM, tax) | Pending |
| Users & Permissions | Pending |
| Sales (invoices, receipts, returns) | Pending |
| Purchase (PO, GRN, invoices, payments) | Pending |
| Inventory (stock, transfers, adjustments) | Material Requisition/Issue, Stock Transfer (Request/Transfer/Receipt), and Stock Adjustment all done. Barcode traceability + company-config field gating (Pack/Loose Qty, Barcode) audited complete app-wide |
| Finance (double-entry, trial balance, P&L, balance sheet) | Pending |
| Dashboard | Placeholder only |
| Reports | Pending |

**Finance is full double-entry bookkeeping** — every sales/purchase/payment transaction auto-posts journal entries (DR/CR). Chart of Accounts is hierarchical.

---

## User Permission System

```
users  ──→  user_menu_permissions  ←──  menus
                  ↓
       can_add | can_edit | can_view | can_approve
       (separate rights per menu item)
```

---

## Offline Strategy

**Scenario 1 — Office (LAN)**:
Flutter → PostgREST → PostgreSQL (local server). No internet needed if on LAN.

**Scenario 2 — Field (offline)**:
Flutter → Drift (SQLite on device). Master data pre-synced before leaving.

**Scenario 3 — Back online**:
Pending transactions → push to server → mark SYNCED.

Rules:
- Master data: full replace on sync (server wins)
- Transactions: append-only — PENDING → SYNCED, never re-pushed
- No FAILED state — failures stay PENDING, auto-retry on next sync

---

## Backend (PostgreSQL + PostgREST)

SQL lives in `backend/` alongside Flutter code:

```
backend/
├── migrations/      # Numbered SQL files — run in order
│   ├── 001_tenancy.sql
│   ├── 002_users_permissions.sql
│   ├── 003_currencies.sql
│   ├── 004_master_data.sql
│   ├── 005_finance.sql
│   ├── 006_sales.sql
│   ├── 007_purchase.sql
│   └── 008_inventory.sql
├── functions/       # PG functions for complex reports (trial balance, P&L, stock valuation)
├── rls/             # Row Level Security policies (client_id isolation)
└── seeds/           # Default COA, currencies seed data
```

---

## Theme & Brand

```dart
// app_colors.dart
primary:    #1B3A6B  // Deep Navy
secondary:  #D4860B  // Amber Gold
positive:   #2E7D32  // Green (profit)
negative:   #C62828  // Red (loss/error)
background: #F5F7FA
surface:    #FFFFFF
```

Material 3. Sidebar navigation on Web/Desktop. Bottom navigation on Mobile.

---

## Development Workflow

1. Claude edits files at `C:\Manglu\SAKAL\sakal\`
2. Commit + push from local terminal
3. In Codespace terminal: `git pull`
4. In Codespace terminal: `flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0`

### Adding a new module (future)
1. Add folder under `lib/features/<module>/` with `data/domain/presentation` structure
2. Add route in `lib/core/router/route_names.dart` and `app_router.dart`
3. Add Drift table in `lib/core/database/tables/<module>_tables.dart`
4. Register table in `lib/core/database/app_database.dart`
5. Add SQL migration in `backend/migrations/`

### Changing DB schema (Drift)
- Increment `schemaVersion` in `app_database.dart`
- Add migration step in `MigrationStrategy`

---

## Key Coding Conventions

- Vanilla Dart / Flutter — no unnecessary abstraction
- Riverpod for all state — no setState except purely local UI state
- Repository pattern — UI never touches datasources directly
- All IndexedDB/Drift operations return Futures/Streams
- No comments unless WHY is non-obvious
- Flat imports — use barrel files (`feature/feature.dart`) when a feature grows large
- No external CDN dependencies — app must work fully offline

---

## Mandatory Patterns (must follow on every new screen)

### Screen permissions
Every screen uses `ScreenPermissionMixin` — never write `_findFeature()` by hand:

```dart
// lib/core/utils/screen_permission_mixin.dart
class _MyScreenState extends ConsumerState<MyScreen>
    with ScreenPermissionMixin<MyScreen> {
  @override String get screenName => '/module/screen-route'; // MUST be the route path (e.g. '/master/tax-groups'), NOT a simple name

  // Use canAdd / canEdit / canApprove directly — no other code needed
}
```

`MenuGroup` field is `.features` (NOT `.items`).
`MenuFeature` fields are `.addAllowed` / `.editAllowed` / `.approveAllowed` (NOT `.canAdd` / `.canEdit`).

### Adaptive list (all list screens)
Mobile = card layout, Desktop = table. Use `SakalAdaptiveList` widget.
Template: `lib/features/finance/presentation/screens/finance_voucher_list_screen.dart`

### Save/Approve buttons — top-right of the header row (all entry screens)
Every entry screen places its primary action buttons (`Save Draft`, `Approve`, `Post`, etc.) in the **top header row, right-aligned next to the title** — never at the bottom of the scrollable form. Desktop: `Row(children: [Expanded(child: titleBlock), if (canSave || canApprove) actionButtons])`. Mobile: stack the buttons in a `Column` below the title block instead of inline, to avoid overflow on narrow screens. Extract the title+status block into its own small widget (e.g. `_buildTitleBlock`) so it can be reused in both the mobile and desktop branches.
Template: `lib/features/purchase/presentation/screens/purchase_order_entry_screen.dart`.
This supersedes the earlier bottom-of-form placement used by Finance Voucher Entry — retrofit older screens opportunistically, don't leave the two conventions coexisting long-term.

### Print / PDF support (every entry screen that produces a saved document)
Every transaction document a user can save (PO, GRN, Purchase Invoice, Purchase Return, Material Requisition, Material Issue, Stock Transfer Request, Stock Transfer, Stock Receipt, Finance Voucher, ...) must be printable. The underlying system (`lib/core/printing/` — `PrintEngine`, `PrintTemplate`/`PrintElement`, `PrintFieldRegistry`) is fully generic; adding print support to a new module is additive-only, never a change to the engine:
1. `print_field_registry.dart` — add the module's scalar fields, table name(s), row fields to all 4 switches (`scalarFields`, `tableNames`, `rowFields`, `documentTypeLabel`) and to the `documentTypes` list.
2. `default_templates/<module>_default_template.dart` — a hardcoded fallback template mirroring an existing one of the same shape (e.g. `purchase_return_default_template.dart` for a header+lines+charges+totals document).
3. `print_template_provider.dart` — one `defaultTemplateFor()` switch case.
4. `print_sample_data.dart` — one `forDocumentType()` case with placeholder data, for the template designer's Preview button.
5. The entry screen itself — `_buildPrintDocument()` (map the screen's own state into the registry's field names), `_print<Doc>()` (fetch company + template, call `PrintEngine.printDocument`), `_buildPrintButton()` (icon button, `Tooltip`, spinner while `_printing`), wired into `build()`'s header row (both mobile and desktop branches) guarded by `<docNo> != null` (no button until the document has been saved at least once) — same placement as the Save/Approve buttons above, see any of the Inventory module screens as a template.
Template: `lib/features/inventory/presentation/screens/stock_transfer_entry_screen.dart` (has the fullest shape: header + lines + charges + totals).

### Company-configurable line fields (Pack/Loose Qty, Barcode) — every screen with a product/item line
Two company-level settings must be respected by every screen that has a product/item code line, computed once in `build()` and threaded down to the line-rendering method(s) as plain bool params — never re-read per-row:
```dart
final showLooseQty = (session?.qtyEntryMode ?? 'PACK_AND_LOOSE') != 'PACK_ONLY';
final showBarcode  = session?.enableBarcode ?? false;
...
_buildLinesCard(locked, showLooseQty, showBarcode);
```
- **`showLooseQty`** (`ric_companies.qty_entry_mode`, migration 034) — gates whether a "Qty Loose" field renders next to "Qty Pack". When hidden, the Pack field's label switches to the bare unit name (`showLooseQty ? 'Qty Pack' : 'Quantity'`) rather than staying labeled "Qty Pack" with no counterpart. Applies to every NEW-lot quantity entry (a document's main line, and a `+`-direction batch/serial sub-row entering a fresh lot) — never to a candidate picker confirming/allocating against an already-known EXISTING lot (that field has no conversion-factor context and stays single-quantity, same reasoning as every `allocatedQty`-style picker in the app: Material Issue's/Stock Adjustment's/Purchase Return's/Stock Receipt's batch or serial candidate rows).
- **`showBarcode`** (`ric_companies.enable_barcode`, migration 027, locked once products exist) — gates the barcode scan `TextFormField` itself, not just its usefulness. Never render it unconditionally.
- **Real gap found and fixed (2026-07-08)**: both settings already existed and were correctly wired in GRN/Purchase Order from day one, but four more screens (Material Requisition, Stock Transfer Request, Stock Transfer, Stock Adjustment) grew their own barcode field later without this gating, and two screens (Stock Adjustment, Stock Receipt) had the Loose Qty *controller* in their row model but never rendered the *field*. A full-app audit was needed to find every offender — before considering a new screen's line entry complete, grep for `qtyPackCtrl`/`qtyLooseCtrl`/`barcodeCtrl` in the file and confirm `qtyEntryMode`/`enableBarcode` gates each one.
- **Batch/Serial is intentionally NOT part of this pattern.** `rim_products.tracking_type` (`NONE`/`BATCH`/`SERIAL`/`BATCH_WITH_EXPIRY`) is a per-PRODUCT attribute, never a company-level toggle — there is no `ric_companies` column for it and none should be added. Every transaction screen already branches correctly on each line's own product's tracking_type (`isBatchTracked`/`isSerialTracked` getters) — nothing to gate beyond that.

### MANDATORY pre-completion self-check — Pack/Loose, Barcode, Batch/Serial
This exact class of bug (Pack/Loose/Barcode gating silently missing on a new screen) has recurred across **multiple separate sessions** (2026-07-08's full-app audit, then again inside the Stock Count build) despite being documented above. Narrative documentation alone has proven insufficient — it gets read, not mechanically applied. Treat the following as a **hard gate, not a suggestion**: run these checks and state the result before telling the user a line-entry screen is done, every time, no exceptions.

1. **Grep the new screen file** for `qtyPackCtrl|qtyLooseCtrl|barcodeCtrl|showLooseQty|showBarcode|trackingType|isBatchTracked|isSerialTracked` (see any recent module's build for the exact command). For every `qtyPackCtrl`/`qtyLooseCtrl` pair, confirm the Loose field is actually gated by `showLooseQty` — not just present in the row model (076/077's original bug: controller existed, field was never rendered). For every barcode-capable field, confirm it's wrapped in `if (showBarcode)` — never rendered unconditionally.
2. **If the screen has ANY "which code was scanned" traceability field** (a `barcode` column being saved onto a transaction line): verify it holds **what the user actually scanned this session**, not a value silently defaulted from the product master's own catalog barcode/part number. These are two different pieces of data — a catalog value is a MATCH KEY for resolving a scan to a product; a traceability value is an AUDIT TRAIL of what was scanned. Conflating them (using the catalog value as the saved traceability value regardless of whether scanning even happened) was a real bug found and fixed in the Stock Count build (2026-07-08) — the two need separate fields on the row model (e.g. `catalogBarcode`/`catalogPartNumber` vs `scannedCode`), and the save payload must use the latter.
3. **If the screen has a "resume a saved draft" path** (re-opening a DRAFT), confirm the datasource's read query (`getLines`/equivalent) actually fetches everything the entry UI needs to keep working after resume — not just what was needed for the *first* save. A screen that works right after creation but silently degrades after being reopened (e.g. scan-to-jump losing its match data because the resume query's product embed didn't select `barcode`/`part_number`) is exactly as much a bug as never having built the feature, and is easy to miss because it only shows up on a second session, not the one where the screen was built and smoke-tested.
4. **Batch/Serial**: confirm every product/item line branches on `tracking_type` (`isBatchTracked`/`isSerialTracked`), and that whichever UI shape is appropriate for this specific document (new-lot free-text entry vs. existing-lot candidate picker — never both, never neither) is actually wired for both BATCH and SERIAL, not just one.

/ **Why this keeps happening**: building a new screen by mirroring an existing template silently propagates whatever the template itself got right — if the template has the gap, the copy does too, and if the new screen is written fresh rather than copied, it's easy to remember the "big" business logic and forget these smaller cross-cutting details. Neither failure mode is fixed by reading CLAUDE.md once at the start of a session; it's fixed by re-running this literal check at the *end* of building each screen, using the actual current state of the file, not memory of what was intended.

### Definition of complete (every new transaction screen)
Before considering a new entry/list screen pair done, check all six:
1. **Permissions** — `ScreenPermissionMixin`, `canAdd`/`canEdit`/`canApprove` gate the right buttons.
2. **Security** — RLS policy follows the `auth_rw_<table>` convention, no permissive dev-style policy.
3. **Responsiveness** — `SakalAdaptiveList` on the list screen, mobile/desktop branches on the entry screen.
4. **Offline support** — Drift local cache + `<module>_local_ds.dart` + `SyncEngine` enqueue on save; Approve stays online-only.
5. **Print support** — see above.
6. **Company-configurable line fields** — `showLooseQty`/`showBarcode` gating on every product/item line, PLUS the full **MANDATORY pre-completion self-check** above (run it, don't just remember it).

### PostgREST save (INSERT or UPDATE)
- No `Prefer: return=representation` header (causes 401 with RLS)
- PATCH uses `?id=eq.<id>` filter

### Account pickers
Every account picker shows `[code] name`, searches code OR name, shows parent group as subtitle.
Use `Autocomplete` widget — never `DropdownButton` for accounts.

### Backend security (NEVER use these — Supabase lock-in)
- `auth.uid()` — NEVER
- `auth.jwt()` — NEVER
- `supabase_flutter` package auth — NEVER
- RLS policies: always use `current_setting('request.jwt.claims', true)::json` (portable PostgREST standard)

### Drift / offline guard
```dart
// kIsWeb guard — driftDatabase() crashes on web without web workers
if (!kIsWeb) { ... }
```
Web = always online, Drift only on mobile/desktop.

### DioClient JWT rules — never get these wrong
**Never inject the stored JWT into `/rpc/fn_login`.**
`fn_login` fetches a *new* token. If the stored token is expired, injecting it causes PostgREST to reject the call with `PGRST303 JWT expired` before even checking credentials — the user cannot log back in.
The `onRequest` interceptor in `DioClient` already guards this with `options.path == '/rpc/fn_login'`.

**Always handle 401 in `onError` — never let it bubble to the screen.**
Any 401 from a non-login endpoint means the JWT expired. The `onError` interceptor must:
1. Delete the stored JWT from `FlutterSecureStorage`
2. Call `DioClient.onSessionExpired?.call()` → GoRouter redirects to `/login`
3. Call `OfflineSessionCache.deactivate()` → prevents stale session restore on page refresh
Do NOT call `onSessionExpired` when the 401 comes from `fn_login` itself.

---

## Backend / PostgreSQL Rules (must follow on every new transaction module)

### Shared posting engines — never write directly to the ledger tables
Every module that posts GL entries or moves stock calls ONE shared procedure — never inserts into `rih_finance_headers`/`rid_finance_lines` or updates `rim_product_location` directly from its own `fn_approve_*`/`fn_post_*` function:
- **`fn_post_voucher(...)`** (`backend/migrations/037_voucher_posting_engine.sql`, fixed in `047_post_voucher_serial_no_fix.sql` + `048_post_voucher_ambiguous_column_fix.sql` + `058_voucher_balance_check_uses_base_amount.sql`) — the only entry point for auto-generated GL postings. Composes the existing `fn_save_finance_voucher` + `fn_post_finance_voucher` rather than reimplementing them; tags the header `source_doc_type/no/date` + `posting_source='AUTO'`; assigns each line's `serial_no` itself (1-based, array order) before calling `fn_save_finance_voucher` — that function requires it with no default (manual entry always supplies it), so every caller's line-object contract (`{account_id, trans_nature, trans_amount, ...}`) is deliberately left without it. Three real bugs found live: (1) `serial_no` was missing entirely until 047 — the very first `fn_approve_grn` call through this path failed NOT NULL; (2) once past that, its own `RETURNS TABLE (trans_no text, trans_date date)` made `trans_no`/`trans_date` implicit PL/pgSQL variables that collided with the same-named columns in its own closing `UPDATE rih_finance_headers` — fixed in 048 by qualifying with the table name; (3) both this function's own pre-check AND `fn_post_finance_voucher`'s authoritative DR=CR check summed raw `trans_amount` across all lines — meaningless once a voucher legitimately mixes currencies across lines (Purchase Bill's Exchange Gain/Loss line posts in base currency while every other line posts in the document's own currency), since amounts in different currencies aren't comparable. Fixed in 058 to sum `base_amount` instead — the one column guaranteed to share a single currency (the company's base currency) across every line of a voucher regardless of each line's own `trans_currency`. Invisible until Purchase Bill because every prior caller (manual vouchers, GRN) happens to keep a whole voucher in one `trans_currency`. **Any `RETURNS TABLE (col, ...)` PL/pgSQL function must qualify `col` with the table name in any query against a table with a same-named column** — the ambiguity is otherwise silent until that exact code path finally executes. **Any DR=CR balance check across a voucher's lines must sum `base_amount`, never `trans_amount`** — a voucher can legitimately mix trans_currencies across lines.
- **`fn_post_stock_movement(...)`** (`backend/migrations/036_stock_posting_engine.sql`, negative-stock checks added in `060_stock_movement_negative_stock_check.sql` + `063_purchase_return_batch_serial.sql`) — the only entry point for stock movement. Writes `ril_stock_ledger` (immutable) and updates `rim_product_location.current_stock`/`cost_price` atomically, guaranteeing `current_stock` always equals `SUM(ledger.qty_change)`. Two independent negative-stock rules, checked in this order: (1) **batch/serial-tracked products (`p_batch_no`/`p_serial_no` supplied) can NEVER go negative** — a batch or serial is a specific identifiable lot/unit, not a fungible quantity, so `allow_negative_stock` flags never apply to it, full stop (`BATCH_INSUFFICIENT_STOCK`/`SERIAL_NOT_IN_STOCK`); (2) untracked/aggregate products fall back to the **item-AND-location** `allow_negative_stock` flag combination from 060 (`NEGATIVE_STOCK_NOT_ALLOWED`) — both must explicitly permit it, checked only for outward movements. `v_batch_stock_balance`/`v_serial_stock_status` (063) are plain `ril_stock_ledger` aggregate views for UI hints ("Available: N") — the ledger itself, never a separate running-balance table, stays the one source of truth for both.
Every future module (Purchase Invoice, Sales Invoice, Transfer, Adjustment) calls these two, not bespoke SQL.

### Concurrency — row-level locking, and a real gotcha to avoid repeating
Use `SELECT ... FOR UPDATE` on any row a concurrent writer could race on (e.g. `rim_product_location`, PO/GRN lines) — see `fn_post_stock_movement` for the pattern. Locking is scoped per row, not global: different rows never contend.
**`SELECT ... ORDER BY ... FOR UPDATE` does NOT guarantee PostgreSQL acquires locks in that ORDER BY sequence** — the sort and the row-locking are not reliably sequenced together. When a function must lock multiple rows in a deterministic order to avoid deadlocks, lock **one row per statement**, in a loop over an already-sorted key list (see `fn_approve_grn`'s PO-line-locking loop in `038_grn.sql` for the correct pattern — this was a real bug caught on self-review).
**Fixed lock order** (binding on every future function touching more than one row-type): PO lines, then `rim_product_location` rows sorted by `product_id`.

### Period / backdate checks — every posting function's first validation
`fn_check_period_open(company_id, trans_date)` and `fn_check_backdate_allowed(client_id, company_id, transaction_type, trans_date)` (`backend/migrations/035_period_close_backdated_control.sql`) must be called by every `fn_approve_*`/`fn_post_*` as its first action, before any other validation. Enforced only at Approve/Post — never block a DRAFT save, since drafts don't affect books.

### RLS policy convention — never a permissive dev policy on a real table
Every new table uses the `auth_rw_<table>` pattern (see `013_chart_of_accounts.sql`, `031_purchase_orders.sql`, `032_account_link_setup.sql`):
```sql
CREATE POLICY "auth_rw_<table>" ON <table>
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON <table> FROM anon;
GRANT SELECT, INSERT[, UPDATE] ON <table> TO authenticated;
```
Never `CREATE POLICY ... FOR ALL USING (true) WITH CHECK (true)` on a real migration table — that permissive shape belongs only in pgTAP test fixtures, and was mistakenly copied into a real migration once already (caught and fixed same-session).

### Migration idempotency — every CREATE TRIGGER / CREATE POLICY needs a DROP IF EXISTS first
`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `ALTER TABLE ADD COLUMN IF NOT EXISTS`, `INSERT ... ON CONFLICT DO NOTHING`, and `CREATE OR REPLACE FUNCTION` are all naturally safe to re-run — but plain `CREATE TRIGGER` and `CREATE POLICY` are NOT (Postgres has no `IF NOT EXISTS` for either) and will error on a second run. Since a migration is very often re-run mid-session while iterating on a new module (a later statement fails, you fix it, you re-run the whole file), every new trigger/policy needs:
```sql
DROP TRIGGER IF EXISTS trg_<name> ON <table>;
CREATE TRIGGER trg_<name> ...

DROP POLICY IF EXISTS "auth_rw_<table>" ON <table>;
CREATE POLICY "auth_rw_<table>" ON <table> ...
```
Real bug caught live: migration 054 re-run failed with `trigger "trg_rih_purchase_invoices_updated_at" already exists` — would have hit the identical error on `CREATE POLICY` right after, had the trigger not been fixed first.

### Postgres aggregate gotcha — no MIN()/MAX() for uuid
`SELECT min(some_uuid_column)` raises `function min(uuid) does not exist` — uuid has no default aggregate. Caught live in `fn_approve_purchase_invoice` picking an "any one product" anchor for account-link resolution. Use `SELECT col INTO v FROM ... LIMIT 1` instead (or `(array_agg(col))[1]` if it must ride inside a single aggregate query).

### Immutability — never edit a posted/approved transaction in place
Once a GRN/voucher/PO is APPROVED or POSTED, no screen or function may UPDATE its lines or amounts. A correction is always a new reversing entry + a new correct entry, never an in-place edit — this is what makes historical reports and backdated cost/tax corrections trustworthy. `fn_save_finance_voucher`/`fn_save_purchase_order`/`fn_save_grn` already enforce this (block edits once status leaves DRAFT); keep that enforcement in every future `fn_save_*`.

### Error messages — never a raw ID, always the human label
Never interpolate a raw UUID (or any other system-generated id) into a `RAISE EXCEPTION`/`USING DETAIL` message, or into any Flutter-side error/snackbar text. Always resolve and show the human label instead — `[code] name` for master data (accounts, taxes, products, charges), matching the Account Picker convention. This applies app-wide, backend and Flutter alike, not just posting functions.
```sql
-- WRONG — user sees a meaningless UUID
USING DETAIL = format('Tax %s has no Input GL account configured.', v_tax_row.tax_id);

-- CORRECT — resolve the label first (join/select the code+name columns you need)
USING DETAIL = format('Tax [%s] %s has no Input GL account configured.', v_tax_row.tax_code, v_tax_row.tax_name);
```
Real bug caught live: `fn_approve_grn` showed `Tax c4dc5508-...-a914f785fa35 has no Input GL account configured.` — fixed in `046_grn_readable_error_messages.sql` (also fixed the two "no account resolved for product" messages and the charge-tax message in the same function, which had the identical defect). When adding a new `RAISE EXCEPTION` that references a row, pull its code/name columns into the query already in scope rather than reaching for `.id` as a shortcut.

### VAT/tax on a goods-in-transit document (GRN, and future Transfer/Adjustment) — never post it, always defer
VAT is a recoverable asset, not part of inventory cost, and it isn't yours to claim until the actual supplier tax invoice exists. A GRN's `tax_amount`/`tax_group_id` (item) and `tax_id`/`tax_amount` (charge) are only an *estimate* from the tax group assigned at entry — posting Input Tax at GRN time recognizes a credit before the document that entitles you to it exists, and risks mismatching the real invoice's tax (rate changes, exemptions, rounding). Fixed in `fn_approve_grn` via migration 050 (GR/IR provisional-liability pattern, user-specified):
- **At GRN**: Stock Dr = tax-exclusive item value + tax-exclusive apportioned charges. Purchase Accrual Cr = tax-exclusive item value. Each additional charge Cr's (or Dr's, if `nature='DEDUCT'`) its own **provisional/clearing** account for its tax-exclusive amount. No VAT line anywhere.
- **At the Purchase Invoice** (built — migration 054, see the dedicated section below): Dr Purchase Accrual (clears what GRN credited) + Dr Input VAT (the *real* invoiced amount) + Cr Supplier Account (the real payable) — one such entry per originating supplier (goods supplier and each charge's own supplier, e.g. a transport company, are cleared independently against their own provisional account — charges are NOT yet cleared by Purchase Invoice, see below).
- A charge's `nature` (`ADD`/`DEDUCT`) must flip its own account's Dr/Cr direction — a DEDUCT charge (e.g. a supplier rebate) posts Dr instead of Cr, same unsigned amount, since it reduces the landed cost rather than adding to the provisional liability. (A real bug: this was never applied — every charge posted Cr regardless of nature — fixed in the same migration.)
- The GRN's own stored totals and printed document are untouched — `tax_amount` stays on `rid_grn_lines`/`rid_grn_charge_lines` as the reconciliation estimate for the future Purchase Invoice screen.
- **Real bug, fixed in migration 051**: every voucher line's `trans_currency` was hardcoded to the company's base currency, with `base_rate` hardcoded to `1` — a GRN raised in a foreign currency (e.g. EUR, base USD) posted as if it were already in base currency, no conversion at all (only `local_amount` was ever correctly computed). Fixed to match the Payment/Receipt Voucher convention: `trans_currency` = the GRN's own currency for every line; `base_amount = trans_amount × header.rate_to_base`; `party_amount`/`party_currency` resolved **per account** (same-currency shortcut when that account's own `account_currency_id` matches the GRN's currency, otherwise a real `fn_get_exchange_rate` lookup) — never blindly base currency.

### Purchase Bill (Purchase Invoice) — closes the GR/IR loop GRN opened (migration 054)
Matches SAP MIRO / Oracle Payables "match to receipt" — researched and confirmed against both before building. One supplier per bill, one currency per bill (GRNs of a different currency are filtered out at the picker, same convention as GRN's own "pick currency, then pick POs" step).
- **No new line-items table.** A GRN either belongs to a bill or it doesn't (whole-GRN billing only, no partial-GRN split across bills — v1 scope). `rih_grn_headers.billed_invoice_no`/`billed_invoice_date` IS the linkage — doubles as the "already billed" flag AND answers "which GRNs are in bill X" via a plain `WHERE`, no junction table. Reserved at DRAFT save already (not just Approve), so two draft bills can't both claim the same GRN; un-reserved and re-reserved on every DRAFT edit.
- **DR Purchase Accrual**: replicate each linked GRN's own `ACCRUAL` lines from `rid_finance_lines` *exactly* (same account, same `base_amount`) — never a lump sum. `PURCHASE_ACCRUAL_ACCOUNT` can resolve differently per product/category, so only replaying the exact original lines guarantees an exact clearing.
- **DR Input VAT**: the real lump-sum VAT typed in from the supplier's paper invoice, apportioned two levels deep — first across the linked GRNs' lines by each line's share of the *estimated* tax that GRN deferred (`rid_grn_lines.tax_amount`), then within each line across its tax group's member taxes by rate weight (`fn_get_active_tax_rate`) — same weighting `fn_approve_grn` used before VAT deferral (049), now applied to the real figure. Resolved directly from `rim_taxes.gl_input_account_id`, **not** `fn_resolve_account_link` — a same-named `INPUT_VAT_ACCOUNT` link type was seeded in 054 but never actually consumed anywhere; removed as dead/misleading config in 056.
- **CR Supplier Account** (in the PUR voucher): `trans_amount`/`party_amount`/`party_currency` are the real invoice total at the bill's own rate, tagged `inv_bill_no`/`inv_bill_date` = the **supplier's own** invoice number/date (never our internal `invoice_no`) — this is what wires the payable into the existing, already-working "pending bills against this party" mechanism (`020_pending_bills_view.sql` is fully generic — any `rid_finance_lines` row with `inv_bill_no` set) for free, straight into Payment Voucher's Against Bill settlement. Its `base_amount`, however, is **forced** to exactly balance the PUR voucher against Accrual+VAT (see below) — it is deliberately *not* `trans_amount × header.rate_to_base` whenever GRN's rate differs from the bill's rate.
- **Exchange restatement — its own separate `EXC` voucher, never a plug line inside the `PUR` voucher** (migration 059, superseding 054/055's original single-voucher design): every voucher posted through `fn_post_voucher`/`fn_post_finance_voucher` **must balance on its own** — that's fundamental to the shared engine and to double-entry itself — so a GRN-rate-vs-bill-rate FX gap can never live as a plug line squeezed into the PUR voucher (054/055's original approach put that line's `trans_currency` in the company's *base* currency while every other line of the same voucher was in the bill's *invoice* currency, silently violating `rid_finance_lines`'s own documented rule that `trans_currency` is "locked from line 1" — one common transaction currency per voucher, see `019_finance_vouchers.sql`). Matches how real ERPs handle it (Tally posts a separate Journal voucher for realized exchange gain/loss; SAP's underlying accounting logic decomposes the same way even when bundled into one document): clearing the accrual at its *own* historical rate is a wash with zero FX impact (the PUR voucher, always balanced by construction — Supplier's `base_amount` there is forced to match Accrual+VAT's total); the *separate* `EXC` voucher then restates the resulting payable to the bill's *current* rate — two lines, **both natively in the company's base currency** (a pure valuation adjustment has no natural existence in the invoice's own currency), DR/CR `EXCHANGE_GAIN_LOSS_ACCOUNT` (seeded in 032, resolved via `fn_resolve_account_link` anchored on any one product from the linked GRN lines — always configured at COMPANY granularity in practice) vs CR/DR the Supplier account directly — **no `inv_bill_no`** on that Supplier line, since this is a pure GL valuation adjustment invisible to the party-currency pending-bills view (the party is still owed the exact same amount in their own currency regardless of how the base-currency translation moves). Both vouchers tag the same `source_doc_type`/`source_doc_no`, so the Purchase Bill screen's Posted Journal Entries section (which already queries by source doc) shows both with no Flutter change. `rih_purchase_invoices.posted_voucher_no` still stores only the PUR voucher's number.
- **Rate inheritance**: GRN's Against-PO consolidation now defaults its own rate from the PO's `rate_to_base`/`rate_to_local` instead of a fresh live lookup (still editable) — the PO rate is the actual commercial agreement, not a stale estimate to silently replace. Purchase Bill's rate defaults the same way from the most-recently-checked GRN. Both GRN's `party_rate` resolution (052) and its `cost_price_specific` rate (053) were fixed the same session to reuse the header's own confirmed rate — for base/local/GRN-currency accounts — instead of a fresh `fn_get_exchange_rate` lookup that could silently disagree with the rate the user just confirmed on the document. **Migration 057** fixed the one place this class of bug was missed: `v_rate_to_base` itself (feeding `v_unit_cost_base` → `rim_product_location.cost_price`/`ril_cost_price_history`, i.e. actual stock valuation) was still doing an unconditional fresh lookup for GRN-currency→base-currency — the exact same conversion already sitting in `v_header.rate_to_base` and already used for the journal voucher's own amounts. Found while writing pgTAP tests for Purchase Bill: a foreign-currency GRN with no matching `rim_exchange_rates` row failed Approve outright despite having a fully valid confirmed header rate. Fixed to `v_rate_to_base := v_header.rate_to_base` — no lookup needed at all.
- **Not yet handled**: `rid_grn_charge_lines` (freight/handling) charges each clear against their own provisional account per migration 050, but Purchase Bill doesn't clear them — a charge's real supplier (e.g. a transport company) is usually different from the goods supplier, so charge-clearing needs its own bill against that supplier, not this one. Flagged as a known gap, not yet built.
- **Posts as `PUR` (Purchase Voucher), not `JV`** (migration 055): `fn_post_voucher`'s `voucher_type_code` parameter is generic — only the *caller* decides what to pass. A document that books a REAL external payable/receivable against a REAL party bill (Purchase Invoice now; future Sales Invoice, Sales Return, Purchase Return) must post under its own dedicated voucher type so a Purchase Register / Sales Day Book can filter by voucher type — never the generic `'JV'`. GRN is the one deliberate exception: it books a *provisional* accrual before the real vendor bill exists, which is genuinely closer to a journal entry, so it stays on `JV`. The voucher type used for the GL posting (`PUR`) must be a **separate** `rim_voucher_types` code from the one used to number the source document itself (`PINV` for `invoice_no`) — `ril_trans_no_seq` keys its counter purely on `(company, location, voucher_type_code)`, so reusing the same code for both would make approving a bill silently consume/skip numbers from the invoice-numbering sequence.

### Purchase Return — "return" and "reverse" are ONE feature, never two (migration 061, batch/serial in 063)
User-specified: whether goods physically go back to the supplier or a GRN was simply entered wrong, it's the same document — `reason` is a free-text audit label, never a branch in the code. Flow: pick a Supplier → pick one or more of their APPROVED GRNs (billed or not) → lines pre-fill with GRN qty as suggested return qty → user edits/zeroes/removes → Approve.
- **One return can mix billed and unbilled GRNs.** Each line branches independently: an unbilled GRN's line reverses the still-provisional Accrual (posts a `JV`); a billed GRN's line reverses real Stock+Input VAT, with the Supplier DR posted once in aggregate (posts an `SDN` — Supplier Debit Note). A single Approve can post both vouchers together, tagged with the same `source_doc_type='PURCHASE_RETURN'`/`source_doc_no` so the Posted Journal Entries UI finds both for free (same pattern as Purchase Bill's PUR+EXC pair).
- **PO `qty_received` always rolls back**, regardless of `p_reopen_po` — that flag only gates whether the PO's own `status` recomputes back to `PARTIALLY_RECEIVED`.
- **Batch/serial-tracked products can NEVER go negative, full stop** (migration 063) — a batch or serial is a specific identifiable lot/unit, not a fungible quantity, so `allow_negative_stock` flags (item or location) never apply to it. The entry screen makes batch/serial allocation **mandatory** whenever a tracked line's return qty > 0 (stricter than GRN's own free-text batch/serial entry, which allows leaving a line un-split at DRAFT) — leaving it unallocated would silently fall through `fn_approve_purchase_return`'s `v_has_batches`/`v_has_serials` check into the plain aggregate movement, bypassing the strict check entirely. The picker shows only batches/serials the SPECIFIC source GRN line actually received (`rid_transaction_line_batches`/`rid_transaction_line_serials` filtered by that GRN's `source_doc_no`+`line_serial`) with each one's CURRENT ledger balance as a UX hint (`v_batch_stock_balance`/`v_serial_stock_status`) — real enforcement is server-side in `fn_post_stock_movement`, not this hint.
- **`fn_save_purchase_return`'s signature changed** from `(header, lines, charges, user_id)` to `(header, lines, batches, serials, charges, user_id)` in 063, mirroring `fn_save_grn`'s param order exactly — the old 4-param overload was explicitly `DROP FUNCTION`'d, not left as a dead orphan, since this was a straight signature change.

### Material Requisition + Material Issue for Consumption (migrations 066-068) — first Inventory module
Requisition mirrors PO's role relative to GRN (pure intent, no stock/GL effect); Issue mirrors GRN's role fulfilling it (posts stock + GL). One Issue can consolidate multiple APPROVED/PARTIALLY_ISSUED requisitions as long as they share the Issue's own From Location.
- **Department → Consumption Area → Account** (`rim_department_consumption_areas`): a Consumption Area belongs to exactly ONE Department and has exactly ONE expense account — company-wide UNIQUE on `consumption_area_id` alone (partial index, `WHERE is_deleted=false`), never on the (department, area) pair. `department_id`/`consumption_area_id` themselves are the SAME `rim_common_masters` columns already on `rid_grn_lines`/`rid_purchase_order_lines` since migration 031 — nothing new there, just a new table that turns that per-line pair into a resolvable GL account. Superseded the unused `STOCK_CONSUMPTION_ACCOUNT` link type (seeded 032, never wired to anything — removed in 066, same dead-config cleanup as `INPUT_VAT_ACCOUNT`'s removal in 056).
- **No document currency at all** — Material Issue is a pure internal stock/expense movement (no supplier/customer), so its `MIC` voucher posts entirely in the company's BASE currency (`trans_currency` = base, `base_rate` = 1 on every line) — `local_amount` is still derived via a fresh `fn_get_exchange_rate` (base→local) lookup for ledger-printing consistency, matching the always-multiply rule even when trans and base happen to coincide.
- **Valuation**: `fn_approve_material_issue` pre-fetches `rim_product_location.cost_price` (current moving average) itself, under the SAME row lock `fn_post_stock_movement` re-acquires internally — that function `RETURNS VOID` and never hands the cost back to the caller, so there's no other way to know the line's value for the Dr Expense/Cr Stock pair. One Dr/Cr pair PER LINE, no aggregation across lines sharing an account (same simplicity precedent as GRN/Purchase Return's own per-line postings).
- **Batch/serial support built in from day one** (unlike Purchase Return, which got it in a follow-up migration) — same mandatory-allocation + strict, flag-independent negative-stock check from 060/063. Candidates come from whatever is CURRENTLY in stock at the location (`v_batch_stock_balance`/`v_serial_stock_status` filtered to balance>0/IN_STOCK) — there's no "originating GRN line" a Requisition can point back to, unlike Purchase Return's GRN-line-scoped candidates.
- **Future-dated transactions are a hard block, always** (`p_trans_date > CURRENT_DATE` raises `FUTURE_DATE_NOT_ALLOWED`) — no company-configurable allowance, unlike backdating's `fn_check_backdate_allowed`. Deliberately simpler.
- **Two document-numbering codes (`MREQ`/`MISS`) + one separate GL posting code (`MIC`)** — same "numbering code != posting code" rule as Purchase Invoice's `PINV`/`PUR` split (055), since `ril_trans_no_seq` keys its counter on `(company, location, voucher_type_code)` alone.
- **`ric_locations.is_issue_allowed`** (new flag, default `true`) gates the From Location picker — mirrors `is_negative_stock_allowed`'s shape (028).
- **`ril_stock_ledger` has TWO separate CHECK constraints on `trans_type`**, both needing the same update whenever a new stock-movement type is introduced: `chk_stock_ledger_direction` (036, a named table-level constraint validating trans_type against the sign of `qty_change`) and `ril_stock_ledger_trans_type_check` (036's inline column-level CHECK, auto-named by Postgres — a plain enum whitelist regardless of direction). Neither had `MATERIAL_ISSUE` — every `fn_approve_material_issue` call failed one, then the other, each as a generic Postgres constraint violation deep inside `fn_post_stock_movement`, not a friendly `RAISE EXCEPTION` from the calling module. Fixed in 069 (direction) + 070 (enum). **Any brand-new `trans_type` passed to `fn_post_stock_movement` must be added to BOTH constraints** — easy to fix only one and get a second, confusingly identical-looking failure.

### Finance-line traceability — every auto-posted GL line must be findable back to its source
`rid_finance_lines` has `source_line_type`/`source_line_no` (migration 050) alongside the header's existing `source_doc_type/no/date` (037) — the header tells you *which document* posted a voucher, the line tells you *which line of that document* generated *this specific* Dr/Cr row. `fn_post_voucher`/`fn_save_finance_voucher` already pass through whatever extra keys a caller puts on a line object, so this is free for every future auto-posting module — just add `'source_line_type', '<TAG>', 'source_line_no', <the originating line's serial_no>` to each `jsonb_build_object(...)` a `fn_approve_*`/`fn_post_*` function builds. GRN's tags: `STOCK`/`ACCRUAL` (per item line, keyed by that line's own `serial_no`), `CHARGE` (per charge line, keyed by that charge's own `serial_no`). Keep tags short and generic (no per-doc-type prefix) — the header's `source_doc_type` already disambiguates which document a voucher came from.

### Barcode traceability — every transaction line table (migration 075)
`rim_products.barcode` and `rim_product_uom.barcode` (per-pack-size barcode — a carton and a piece of the same product can each carry their own) are product-master data; no transaction line table persisted WHICH barcode built that line until migration 075 added a `barcode TEXT` column to all 8 (GRN, PO, Material Requisition/Issue, Stock Transfer/Request/Receipt, Purchase Return — `rid_purchase_order_lines` already had it from day one). Every `fn_save_*` reads it identically: `nullif(v_line->>'barcode', '')` — one more optional JSONB key, no signature change.
- **Origin documents** (free product entry: GRN, PO, Material Requisition, Stock Transfer Request, Stock Transfer's DIRECT mode, Stock Adjustment) get a fresh per-row barcode-scan `TextFormField` + `_onBarcodeSubmitted` calling `getProductByBarcode` (needed on both the remote datasource AND the repository — `_ds` in every entry screen is the repository, not the raw datasource, so both layers need the method added). MUST be gated by `session.enableBarcode` — see "Company-configurable line fields" above.
- **Consolidation documents** (lines copied from a prior document: Material Issue ← Requisition, Purchase Return ← GRN, Stock Receipt ← Transfer, Stock Transfer's AGAINST_REQUEST ← Request) have no independent product-selection step — their barcode is **carried forward from the source line**'s own saved `barcode` column, never freshly scanned. No `enableBarcode` gating needed there since there's no UI control to gate, just a value threaded through the save payload (and the source line's own `getLines`-equivalent `select` must actually include `barcode`, or there's nothing to carry).
- **Real bug found live**: GRN, PO, and Material Requisition's scan flow already existed, but `_onBarcodeSubmitted` resolved the match then unconditionally called `row.barcodeCtrl.clear()` **before** the save payload was ever built — the scanned value was silently discarded on every save. Fix: store the resolved value into a separate `matchedBarcode` field on the row (sibling to `uomId`) before clearing the visible text field, and read `matchedBarcode` (not the now-empty controller) when building the payload.

### Stock Adjustment (migration 076) — increase/decrease stock at a location with a reason
Deliberately NOT combined with Stock Take/physical count — a fully separate future module, no shared `adjustment_type` column or other hook.
- **Cost is NEVER user-entered.** A `+` line's `unit_cost`/`unit_cost_specific` are fetched from `rim_product_location` at Approve time (same row lock `fn_post_stock_movement` re-acquires internally) and persisted onto the line for reporting — blending "current average" into itself is mathematically a no-op on cost, only quantity moves. A `+` line on a product/location with no established cost yet (`cost_price` NULL or 0 — never received via GRN) is a hard block: `COST_NOT_ESTABLISHED`, never a silent zero-value post. A `-` line is never blocked on this — it just records whatever cost is currently there, same as every other outward-movement precedent in this schema.
- **Batch/serial is dual-direction**, a first for this schema: a `+` line gets a GRN-style NEW-lot entry UI (user types a fresh batch_no/expiry/serial); a `-` line gets a Material-Issue-style EXISTING-lot candidate picker (`v_batch_stock_balance`/`v_serial_stock_status`). Both reuse the generic `rid_transaction_line_batches`/`rid_transaction_line_serials` tables unchanged — direction lives on the parent line's `adjust_flag`, never on the batch/serial row itself, so `fn_save_stock_adjustment`'s batch/serial handling is identical regardless of direction; only `fn_approve_stock_adjustment` branches on it.
- **GL**: `+` → Dr Stock Account / Cr Stock Adjustment Account; `-` → Dr Stock Adjustment Account / Cr Stock Account. `STOCK_ADJUSTMENT_ACCOUNT` link type was seeded back in migration 032 but never consumed until this module. `ADJUSTMENT_IN`/`ADJUSTMENT_OUT` were likewise already-valid `ril_stock_ledger.trans_type` values since migration 036, unused until now — no CHECK-constraint migration needed this time (unlike Material Issue's 069/070 gap for `MATERIAL_ISSUE`).
- **`ADJ`/`ADJV` voucher split** — same numbering-code-vs-posting-code separation as `PINV`/`PUR` and `MREQ`+`MISS`/`MIC`, for the same reason (`ril_trans_no_seq` keys its counter on `(company, location, voucher_type_code)` alone).
- **`IN-ADJ` menu entry** (`/inventory/adjustments`) already existed since the very first menu seed (migration 005) as a placeholder — same situation migration 071 documented for `IN-TRF`/Stock Transfer. **Always check `ric_master_menus` for an existing placeholder row before assuming a new module needs a menu-seed migration** — swapping the Flutter placeholder route for the real screen may be the only wiring needed.

### Opening Stock (migration 077) — establishes starting quantity + cost before go-live
One-time (per product/location) document with **no GL posting at all** — the first module in this schema to call `fn_post_stock_movement` without also calling `fn_post_voucher`. The company's overall opening trial balance is handled separately via a future Finance-side account-opening-balances upload; `rim_opening_balances` (013) is unrelated (Chart-of-Accounts opening balance per account per FY, a different shape of data).
- **One line per physical LOT/UNIT, not one line per product** — deliberate divergence from every other module's "line + child batch/serial table" shape (`batch_no`/`expiry_date`/`serial_no` live directly on `rid_opening_stock_lines`). A serial-tracked product with 5 units is 5 lines. Fits what this document actually is (a flat stock-take/legacy-export list) and made Excel-upload trivial.
- **Cost IS user-entered** — the one deliberate inversion of Stock Adjustment's rule, since this module's entire job is establishing the cost basis for the first time. `unit_cost` (base currency) required per line; `unit_cost_specific` derived via `fn_get_exchange_rate` when the product's `cost_currency_id` differs from base.
- **`OPENING_STOCK_ALREADY_ESTABLISHED` guard**: blocks a line at Approve if the product already has ANY stock/cost at that location (`current_stock <> 0 OR cost_price <> 0`) — prevents re-running opening stock on something already received via a real GRN.
- **First real consumers of two previously-dormant flags**: `MenuFeature.excelUploadAllowed` (Excel bulk upload for legacy-data migration at client onboarding, parsed client-side with the `excel` package, matched to products by `product_code`) and `session.enablePartNumber` (scan-to-add header field, alongside barcode).
- **`OPST`** voucher code — numbering only, no posting code needed since there's no posting at all.

### Stock Count (migrations 078/079) — physical stock take, two screens
Screen 1 (Counter): picks Location + category/nature filter, gets a pre-populated worksheet, counts blind (never sees system qty), Submits. Screen 2 (Manager): picks multiple SUBMITTED counts for the same location, sees them clubbed against system stock, Approves — which posts a real Stock Adjustment through the **existing** engine, never a bespoke posting path.
- **Blind count is enforced at the schema level**, not just the UI: `rid_stock_count_lines` has no `system_qty` column at all (unlike Stock Adjustment's own line), and the batch/serial entry on this screen is **pure free-text new-lot entry only** — no existing-lot candidate picker anywhere, since that would leak system data into what must stay blind.
- **`is_counted BOOLEAN`, not just nullable qty, is the authoritative "row touched" flag.** For a batch/serial-tracked product, "confirmed empty" (0 children, explicitly touched) and "never touched" (0 children, untouched) look identical unless flagged explicitly — a missed item must NEVER be silently treated as counted-zero. An explicit "Mark Counted — None Found" action is what lets a tracked product be confirmed-empty.
- **Variance basis = system stock AS OF a manager-chosen `as_of_date`, computed by summing `ril_stock_ledger`** (immutable, append-only, the schema's sole source of truth) — never a live read of `rim_product_location.current_stock`. Stays correct even if counting spans days or the manager reviews long after counting; a transaction posted after `as_of_date` provably has zero effect on the computed variance.
- **Never merge same-product quantities at write time** (confirmed codebase-wide convention across Purchase Bill←GRNs/GRN←POs/Material Issue←Requisitions — none of them merge). Screen 2's `rid_stock_count_review_sources` is a plain membership junction; the clubbed variance is computed on demand by `fn_compute_stock_count_variance`, called by BOTH the preview grid and Approve so what the manager sees is guaranteed to be what posts. Untracked/batch quantities SUM across sources (different counters, non-overlapping zones); serials use `DISTINCT` — the same physical serial found in two overlapping counts is one unit, never double-counted.
- **Unknown serial** (physically found, zero ledger history at this location): flagged `is_unknown_serial`, excluded from auto-adjustment entirely — no established cost/origin to safely invent a `+` line from. Batch gets normal `+`/`-` treatment (a never-before-seen batch is a legitimate `+`, same as Stock Adjustment already allows) — only serial gets the exception treatment.
- **Composes the existing Stock Adjustment engine rather than reimplementing it**: `fn_approve_stock_count_review` computes netted `+`/`-` lines then calls `fn_save_stock_adjustment` + `fn_approve_stock_adjustment` directly — inheriting cost-lookup, GL posting, and the strict batch/serial negative-stock rule for free. `rih_stock_adjustment_headers` gained nullable `source_doc_type`/`source_doc_no`/`source_doc_date` (mirrors `rih_finance_headers`' existing columns) so an auto-posted-from-Review adjustment traces back.
- **Reservation-once-consumed**, exact mirror of GRN's `billed_invoice_no` pattern: a `SUBMITTED` count picked into a manager's DRAFT review (`consolidated_into_review_no`/`date`) is locked from being picked into a second concurrent review, reserved at DRAFT save already.
- **Screen 1 is fully offline-capable** (Drift cache + `SyncEngine`, same as every other module) since neither Save nor Submit touches the ledger/GL — a store count spanning hours/days on unreliable connectivity is exactly the scenario offline mode exists for. **Screen 2 is deliberately online-only** — needs a live view of other counters' SUBMITTED status and a live ledger-based system-qty computation; a stale local replica would actively mislead the manager.
- **First Flutter consumer of `fn_category_subtree`** (024, existed since the Item Category migration but never called from the client before this).
- **`CNT`/`CNTR`** voucher codes — numbering only for both screens; all GL/stock posting happens under the existing `ADJ`/`ADJV` codes via the composed call.

---

## Dart / Flutter Rules (never get these wrong)

### Riverpod class names — exact spelling
| Use this | Never this |
|---|---|
| `ConsumerStatefulWidget` | `ConsumerStatefulMixin` |
| `ConsumerState<T>` | `ConsumerStateMixin`, raw `ConsumerState` |
| `ConsumerWidget` | anything else |
| `WidgetRef` | `Ref` (wrong in widget context) |

### Mixin with Riverpod — always parameterize
```dart
// CORRECT
mixin MyMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> { }
class _MyState extends ConsumerState<MyWidget> with MyMixin<MyWidget> { }

// WRONG — raw type causes "can't implement both" error
mixin MyMixin on ConsumerState { }
```

### PostgREST endpoint paths — never include /rest/v1/ in datasource paths
DioClient baseUrl already ends with `/rest/v1`. All datasource paths must start with just `/table_name`:
```dart
// CORRECT
_dio.get('/rim_product_flag_types', ...)
// WRONG — produces /rest/v1/rest/v1/rim_product_flag_types → 404
_dio.get('/rest/v1/rim_product_flag_types', ...)
```

### PostgREST partial select — include every non-nullable model field
When using a partial `select`, every field cast as non-nullable in `fromJson` (`as String`, `as int`, `as bool`) MUST be in the select. Omitting it returns `null` from PostgREST → runtime `TypeError: null is not a subtype of String`. Fields cast as nullable (`as String?`, `as bool? ?? default`) are safe to omit.
```dart
// CORRECT — all non-nullable fields included
'select': 'id,client_id,company_id,type_id,description,sort_order,is_active,is_deleted'

// WRONG — client_id missing → fromJson crashes at runtime
'select': 'id,type_id,description'
```
If in doubt, use `select: '*'` for single-record fetches.

### SwitchListTile / ListTile — never inside a bare Row
`ListTile` uses `Row(Expanded(...))` internally. Placing it inside an unconstrained outer `Row` passes `maxWidth = infinity` → "BoxConstraints forces an infinite width" crash.
```dart
// CORRECT — directly in Column
Column(children: [SwitchListTile(...)])

// WRONG — bare Row gives infinite width → crash
Row(children: [SwitchListTile(...)])
```
Same rule: `CheckboxListTile`, `RadioListTile`, `ExpansionTile`.

### DropdownButtonFormField in a fixed-width container — always set isExpanded: true
Without `isExpanded: true`, the dropdown sizes its selected-item display to the item's intrinsic content width, not the box width — a long item label (tax group, department, account name) overflows past a `SizedBox(width: ...)` edge, producing "RIGHT OVERFLOWED BY N PIXELS". Set `isExpanded: true` by default on every `DropdownButtonFormField` placed inside a fixed-width `SizedBox` (table columns, `Wrap` line-item rows, compact form grids) unless the item set is short and fixed (e.g. a 2-value Local/Import toggle, where overflow is impossible).

### DropdownButtonFormField height mismatch vs TextFormField — set isDense: true AND itemHeight: null
Even when both are wrapped in an identical `SizedBox(height: X)` with an identical `InputDecoration`, a `DropdownButtonFormField` still looks visually mismatched next to a plain `TextFormField` — it carries its own separate `isDense`/`itemHeight` pair (distinct from `decoration.isDense`) and defaults to Flutter's `kMinInteractiveDimension` (48px) touch-target floor regardless of the decoration. Set `isDense: true` and `itemHeight: null` on every `DropdownButtonFormField` that sits alongside `TextFormField`/`Autocomplete` fields in the same row/card, to remove that floor and let it hug the border the same way.

### rim_currencies column names
- ISO code: `currency_id` (NOT `currency_code`)
- Display: `${row['currency_id']} — ${row['currency_name']}`

### OfflineBanner — no parameters
`OfflineBanner` reads `sessionProvider` internally. Always: `const OfflineBanner()`. Never pass `visible:` or any other param.

### saveProduct — always pass isNew flag
Entry screens generate a UUID for new records and include it in the payload. The datasource cannot use `if (id == null) POST else PATCH` because id is always provided. Always call `saveProduct(payload, isNew: _isNew)`.

### Required field labels — use _req() helper, never plain asterisk in labelText
Use `label: _req('Field Name')` (a RichText widget with red `*`) instead of `labelText: 'Field Name *'`.
Every entry screen should have this static helper:
```dart
static Widget _req(String text) => RichText(
  text: TextSpan(
    text: text,
    style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w400),
    children: const [
      TextSpan(text: ' *', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600)),
    ],
  ),
);
```
Use it on any `InputDecoration` with a non-null validator. Do NOT put `*` in `labelText` strings.

### Form save — always give user feedback on validation failure
When `_formKey.currentState!.validate()` returns false, always show a snackbar before returning.
```dart
if (!_formKey.currentState!.validate()) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Please fill in all required fields.'), backgroundColor: Colors.orange),
  );
  return;
}
```

### Save exception handling — catch all, not just DioException
Never catch only `DioException` in a save handler. Always add a catch-all after it:
```dart
} on DioException catch (e) {
  setState(() { _saving = false; _error = e.response?.data?['message'] ?? 'Save failed.'; });
} catch (e) {
  setState(() { _saving = false; _error = 'Unexpected error: $e'; });
}
```

### JWT expiry check on app startup
`OfflineSessionCache.tryRestoreSession()` now decodes the JWT `exp` claim on startup.
If the token is already expired it deactivates the session and returns null → router sends user to login immediately.
Do NOT skip this check or move it — users must never reach the dashboard with an expired token.

### No deprecated Flutter/Dart APIs — ever
`flutter analyze` must stay at zero warnings. Never use deprecated members. Common ones:
| Deprecated | Use instead |
|---|---|
| `.withOpacity(x)` | `.withValues(alpha: x)` |
| `Switch(activeColor:)` | `Switch(activeThumbColor:)` |
| `Checkbox(activeColor:)` | `Checkbox(fillColor: WidgetStateProperty.all(...))` |
| `Autocomplete(value:)` | `Autocomplete(initialValue:)` |
| `DropdownButtonFormField(value:)` | `DropdownButtonFormField(initialValue:)` |
| `Radio(onChanged:)` | Wrap in `RadioGroup` ancestor |
Always add `const` to constructors/literals where all arguments are compile-time constants.
Always add `{ }` braces to single-statement `if`/`for` bodies (`curly_braces_in_flow_control_structures`).

### Before adding a method to an existing file — always read the file first
Dart has no method overloading. Duplicate method names are a compile error.
Always `Read` the full file before adding new methods or imports.

### pgTAP tests — hardcoded UUIDs, never temp tables
Supabase SQL Editor auto-commits after each `DO` block. Any `CREATE TEMP TABLE ... ON COMMIT DROP` is destroyed immediately — SELECT tests that follow cannot see the IDs.

**Correct pattern (always):**
```sql
BEGIN;
DO $$ DECLARE
  v_client_id uuid := '00000000-0000-0000-0000-000000000001'; -- hardcoded
  ...
BEGIN
  INSERT INTO ... VALUES (v_client_id, ...) ON CONFLICT (id) DO NOTHING;
END $$ LANGUAGE plpgsql;

SELECT plan(N);
SELECT ok(EXISTS(SELECT 1 FROM ... WHERE id = '00000000-0000-0000-0000-000000000001'), 'ok 1 — ...');
...
SELECT * FROM finish();
ROLLBACK;
```
Reference hardcoded UUIDs directly in every `SELECT ok()` — no variable passing across statements needed.

---

## Route Names Reference

```dart
RouteNames.login           // /login
RouteNames.dashboard       // /dashboard
RouteNames.sales           // /sales
RouteNames.salesInvoices   // /sales/invoices
RouteNames.purchase        // /purchase
RouteNames.inventory       // /inventory
RouteNames.finance         // /finance
RouteNames.customers       // /master/customers
RouteNames.products        // /master/products
// ... see lib/core/router/route_names.dart for full list
```
