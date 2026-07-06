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

### Save/Approve buttons — top-right of the header row (all entry screens)
Every entry screen places its primary action buttons (`Save Draft`, `Approve`, `Post`, etc.) in the **top header row, right-aligned next to the title** — never at the bottom of the scrollable form. Desktop: `Row(children: [Expanded(child: titleBlock), if (canSave || canApprove) actionButtons])`. Mobile: stack the buttons in a `Column` below the title block instead of inline, to avoid overflow on narrow screens. Extract the title+status block into its own small widget (e.g. `_buildTitleBlock`) so it can be reused in both the mobile and desktop branches.
Template: `lib/features/purchase/presentation/screens/purchase_order_entry_screen.dart`.
This supersedes the earlier bottom-of-form placement used by Finance Voucher Entry — retrofit older screens opportunistically, don't leave the two conventions coexisting long-term.

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

### Finance-line traceability — every auto-posted GL line must be findable back to its source
`rid_finance_lines` has `source_line_type`/`source_line_no` (migration 050) alongside the header's existing `source_doc_type/no/date` (037) — the header tells you *which document* posted a voucher, the line tells you *which line of that document* generated *this specific* Dr/Cr row. `fn_post_voucher`/`fn_save_finance_voucher` already pass through whatever extra keys a caller puts on a line object, so this is free for every future auto-posting module — just add `'source_line_type', '<TAG>', 'source_line_no', <the originating line's serial_no>` to each `jsonb_build_object(...)` a `fn_approve_*`/`fn_post_*` function builds. GRN's tags: `STOCK`/`ACCRUAL` (per item line, keyed by that line's own `serial_no`), `CHARGE` (per charge line, keyed by that charge's own `serial_no`). Keep tags short and generic (no per-doc-type prefix) — the header's `source_doc_type` already disambiguates which document a voucher came from.

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
