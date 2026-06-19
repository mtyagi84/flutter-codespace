# SAKAL ERP — Next Session Handoff

Last updated: 2026-06-23  
Last commit: `7260925` — Payment/Receipt Voucher entry + list screens  
Branch: `main` (always)

---

## Where We Are

Finance module first transaction screen is built and pushed.  
The screens work end-to-end **in code** — they need Supabase migrations run + browser testing.

### Screens built so far
| Screen | Route | File |
|---|---|---|
| Exchange Rates | `/finance/exchange-rates` | `lib/features/finance/presentation/screens/exchange_rate_screen.dart` |
| Voucher Entry (CRV/BRV/CPV/BPV) | `/finance/payment-receipt` | `lib/features/finance/presentation/screens/finance_voucher_entry_screen.dart` |
| Voucher List | `/finance/voucher-list` | `lib/features/finance/presentation/screens/finance_voucher_list_screen.dart` |

---

## STEP 1 — Run Pending SQL in Supabase (Blocker)

These must be run in order in the Supabase SQL editor before any screen can be tested.  
**Confirm which ones are already done** — check Supabase table list before running.

| Migration | File | Tables / Functions Created | Already run? |
|---|---|---|---|
| 009 | `backend/migrations/009_divisions.sql` | `rim_divisions` | Confirm |
| 010 | `backend/migrations/010_cities.sql` | `rim_cities` | Confirm |
| 011 | `backend/migrations/011_alter_users.sql` | Alters `ric_users` | Confirm |
| 012 | `backend/migrations/012_permissions_fn.sql` | `fn_get_user_menu`, `ric_user_menu_permissions` | Confirm |
| 013 | `backend/migrations/013_chart_of_accounts.sql` | `rim_accounts`, `rim_account_groups` | Confirm |
| 014 | `backend/migrations/014_add_is_deleted.sql` | Alters multiple tables | Confirm |
| 015 | `backend/migrations/015_accounts_address_fields.sql` | Alters `rim_accounts` | Confirm |
| 016 | `backend/migrations/016_add_allowed_column.sql` | Adds `add_allowed` column to permissions | Confirm |
| **017** | `backend/migrations/017_voucher_types_payment_modes.sql` | `rim_voucher_types`, `rim_payment_modes` + seeds | **NOT RUN** |
| **018** | `backend/migrations/018_exchange_rates.sql` | `rim_exchange_rates`, `fn_get_exchange_rate`, `fn_replicate_exchange_rates` | **NOT RUN** |
| **019** | `backend/migrations/019_finance_vouchers.sql` | `rih_finance_headers`, `rid_finance_lines`, `ril_trans_no_seq`, `rid_invoice_bill_settlement`, `rid_cheque_register`, `fn_next_trans_no`, `fn_save_finance_voucher`, `fn_post_finance_voucher` | **NOT RUN** |

Also run in Supabase:
- `backend/functions/fn_get_user_menu.sql` (if 012 is done but this function is missing)

---

## STEP 2 — Wire Screens to Sidebar Menu

The sidebar reads `rim_master_menus` from Supabase. Until the voucher screens are added there,  
they won't appear in the Finance menu — users can only reach them by typing the URL directly.

### Run this SQL in Supabase after 019 is done:

```sql
-- Add Finance voucher menu items (adjust module_code / group_code to match your seeds)
-- Check existing menu structure first:
-- SELECT * FROM ric_master_menus ORDER BY module_code, group_code, serial_no;

INSERT INTO ric_master_menus (module_code, group_code, feature_code, feature_name, screen_name, icon_name, serial_no, is_active, is_deleted)
VALUES
  ('FIN', 'VOUCHERS', 'CASH_RECEIPT',  'Cash Receipt',   '/finance/payment-receipt', 'receipt',        10, true, false),
  ('FIN', 'VOUCHERS', 'BANK_RECEIPT',  'Bank Receipt',   '/finance/payment-receipt', 'account_balance',20, true, false),
  ('FIN', 'VOUCHERS', 'CASH_PAYMENT',  'Cash Payment',   '/finance/payment-receipt', 'payments',       30, true, false),
  ('FIN', 'VOUCHERS', 'BANK_PAYMENT',  'Bank Payment',   '/finance/payment-receipt', 'account_balance',40, true, false),
  ('FIN', 'VOUCHERS', 'VOUCHER_LIST',  'Voucher List',   '/finance/voucher-list',    'list_alt',       50, true, false),
  ('FIN', 'RATES',    'EXCHANGE_RATES','Exchange Rates',  '/finance/exchange-rates',  'currency_exchange',10, true, false)
ON CONFLICT DO NOTHING;
```

**Note:** Each Cash Receipt / Bank Receipt etc. item should pass a `voucherType` when navigating —  
update the AppShell sidebar navigation logic to pass GoRouter `extra: {'voucherType': 'CRV'}` etc.  
Look at `lib/core/layout/app_shell.dart` — wherever `context.go(feature.screenName)` is called,  
change to `context.go(feature.screenName, extra: {'voucherType': feature.featureCode})` for voucher screens.

---

## STEP 3 — Fix Checklist Gaps (in priority order)

### Gap 1 — Permissions not wired (Section E of checklist) ⚠️ HIGH

**No screen in the codebase has done this yet** — it's a codebase-wide gap.  
Pattern to implement (do this in all screens going forward):

```dart
// In screen's _init(), after loading master data:
MenuFeature? _perms;

// Load permissions for this screen
final menuRes = await DioClient.instance.post('/rpc/fn_get_user_menu', data: {
  'p_user_id': session.userId,
});
final modules = (menuRes.data as List)
    .map((m) => MenuModule.fromJson(m as Map<String, dynamic>))
    .toList();
_perms = modules
    .expand((m) => m.groups)
    .expand((g) => g.features)
    .where((f) => f.screenName == '/finance/payment-receipt')
    .firstOrNull;

// Then in build():
// - Hide Save Draft if !(_perms?.addAllowed ?? false) for new, !(_perms?.editAllowed ?? false) for existing
// - Hide Post Voucher if !(_perms?.approveAllowed ?? false)
// - If _perms == null → redirect to dashboard (view_allowed check)
```

Files to update:
- `lib/features/finance/presentation/screens/finance_voucher_entry_screen.dart`
- `lib/features/finance/presentation/screens/finance_voucher_list_screen.dart`
- All other screens (CoA, Customer, Supplier, Exchange Rates) — do as part of a permissions pass

---

### Gap 2 — Account dropdown needs to be searchable (Section F) ⚠️ HIGH

`DropdownButtonFormField` with 500 accounts is unusable on the voucher entry screen.  
Replace the account selector on both line 1 and party lines with a searchable modal.

Pattern used in CoA screen for country dropdown (already built):
- Show a dialog with a `TextField` (search)
- Query `/rim_accounts?account_name=ilike.*{query}*&limit=20` on each keystroke (debounce 300ms)
- Display results in a `ListView`

File: `lib/features/finance/presentation/screens/finance_voucher_entry_screen.dart`  
The `_buildLineRow()` method — replace `DropdownButtonFormField<String>` for account selection.

---

### Gap 3 — Lines table overflows on mobile (Section G) ⚠️ MEDIUM

The 6-column lines table (serial, account, DR, CR, remarks, remove) will overflow at <600 px.

Fix in `_buildLinesSection()` in the entry screen:
```dart
if (Responsive.isMobile(context)) {
  // Card layout: one card per line, stacked vertically
  return _buildLinesCards(locked);
} else {
  return _buildLinesTable(locked); // existing table code
}
```

Card layout per line should show: account dropdown, amount field (labelled DR or CR), remarks, remove button.

---

### Gap 4 — Error banner missing Retry button (Section D) LOW

In both screens, update `_errorBanner()` or the error state to include a retry:

```dart
// Entry screen — in build(), where _error != null:
_errorBanner(_error!, onRetry: _init)

// List screen — where _error != null:
_errorBanner(_error!, onRetry: _load)
```

Update `_errorBanner()` widget to accept an `onRetry` callback.

---

### Gap 5 — pgTAP tests for finance voucher functions (Section I) LOW

Write `backend/tests/019_finance_vouchers_test.sql`.  
Use `backend/tests/001_permissions_fn_test.sql` as the template.

Functions to test:
- `fn_next_trans_no` — verify sequence increments, format tokens expand correctly, DAILY/MONTHLY/YEARLY/NEVER reset logic
- `fn_save_finance_voucher` — happy path (create draft), update draft, blocked on posted voucher
- `fn_post_finance_voucher` — balanced voucher posts, unbalanced raises exception, already-posted raises exception

---

## STEP 4 — Next Screens to Build (After Finance Voucher is Complete)

From the ERP module plan in CLAUDE.md:

### Option A — Complete Finance Module first
1. **Journal Voucher screen** (JV type) — route already exists at `/finance/journal`, placeholder
2. **Cash Book report** — ledger view of all Cash/Bank accounts
3. **Trial Balance** — calls a PG function, read-only report

### Option B — Pivot to Sales Module (higher user value)
1. **Sales Invoice** — creates `rih_sales_header` + `rid_sales_lines`
2. Auto-posts finance journal entries via a PG function
3. Links to CoA customer accounts

**Recommendation:** Option B — users need to enter sales first before finance entries are meaningful.

---

## Reference — Key Files Modified This Session

| File | What it does |
|---|---|
| `lib/features/finance/presentation/screens/finance_voucher_entry_screen.dart` | CRV/BRV/CPV/BPV entry form |
| `lib/features/finance/presentation/screens/finance_voucher_list_screen.dart` | Voucher list with type/date/status filters |
| `lib/core/utils/voucher_logic.dart` | Pure functions: `line1Nature`, `counterNature`, `drTotal`, `crTotal`, `isVoucherBalanced`, `toBaseAmount`, `toLocalAmount` |
| `test/features/finance/voucher_logic_test.dart` | 26 unit tests for voucher_logic.dart |
| `lib/core/router/route_names.dart` | Added `paymentReceipt`, `voucherList` |
| `lib/core/router/app_router.dart` | Wired both routes with GoRouter extra |
| `backend/migrations/017_voucher_types_payment_modes.sql` | `rim_voucher_types`, `rim_payment_modes` + seeds |
| `backend/migrations/018_exchange_rates.sql` | `rim_exchange_rates`, exchange rate functions |
| `backend/migrations/019_finance_vouchers.sql` | All finance header/line tables + 3 PG functions |

---

## Navigation Pattern — How to Open Voucher Screens

```dart
// New Cash Receipt (from menu or button)
context.push(RouteNames.paymentReceipt, extra: {'voucherType': 'CRV'});

// New Bank Receipt
context.push(RouteNames.paymentReceipt, extra: {'voucherType': 'BRV'});

// New Cash Payment
context.push(RouteNames.paymentReceipt, extra: {'voucherType': 'CPV'});

// New Bank Payment
context.push(RouteNames.paymentReceipt, extra: {'voucherType': 'BPV'});

// Open existing voucher (from list, from search)
context.push(RouteNames.paymentReceipt, extra: {'transNo': 'CRV/KIN/2026/00001'});

// Voucher list
context.go(RouteNames.voucherList);
```

---

## Codespace Commands (Run After `git pull`)

```bash
# Pull latest
git pull

# Run tests (pure Dart — no Flutter binding needed)
flutter test test/features/finance/voucher_logic_test.dart
flutter test test/features/finance/exchange_rate_logic_test.dart

# Check for compile errors
flutter analyze

# Run the app
flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0
```

---

*Sign-off: 2026-06-23. All code committed at `7260925`. Resume from STEP 1 (run 017-019 in Supabase).*
