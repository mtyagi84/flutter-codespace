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
clients → companies → locations
```
- 1 client → multiple companies
- 1 company → multiple locations (stores/warehouses, each can have own server)
- Consolidation: UPSERT from location servers → central server (no conflicts — composite key)
- Same codebase works for SaaS (cloud-hosted) or on-premise (client's LAN server)

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
