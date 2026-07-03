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
| Inventory (stock, transfers, adjustments) | Pending |
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
- **`fn_post_voucher(...)`** (`backend/migrations/037_voucher_posting_engine.sql`) — the only entry point for auto-generated GL postings. Composes the existing `fn_save_finance_voucher` + `fn_post_finance_voucher` rather than reimplementing them; tags the header `source_doc_type/no/date` + `posting_source='AUTO'`.
- **`fn_post_stock_movement(...)`** (`backend/migrations/036_stock_posting_engine.sql`) — the only entry point for stock movement. Writes `ril_stock_ledger` (immutable) and updates `rim_product_location.current_stock`/`cost_price` atomically, guaranteeing `current_stock` always equals `SUM(ledger.qty_change)`.
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

### Immutability — never edit a posted/approved transaction in place
Once a GRN/voucher/PO is APPROVED or POSTED, no screen or function may UPDATE its lines or amounts. A correction is always a new reversing entry + a new correct entry, never an in-place edit — this is what makes historical reports and backdated cost/tax corrections trustworthy. `fn_save_finance_voucher`/`fn_save_purchase_order`/`fn_save_grn` already enforce this (block edits once status leaves DRAFT); keep that enforcement in every future `fn_save_*`.

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
