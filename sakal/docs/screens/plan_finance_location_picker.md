# Plan: Location picker on Finance vouchers (INTER_ENTITY-only)

Status: **Approved, not yet implemented** — user is running `flutter test` on the current baseline first; implementation starts only after that's confirmed green.

## Context

Every Finance voucher screen (Journal, Contra, Expense, Payment/Receipt) currently sets `location_id` silently from `session.locationId` — no picker exists anywhere in Finance. That's fine under `SIMPLE` accounting (one company-wide P&L/Balance Sheet, location is just record-keeping), but under `INTER_ENTITY` mode each location GROUP is its own entity with its own books — which location a voucher posts against determines which entity's books it lands in, so the user needs to actually choose it rather than silently inherit whatever location their session happens to default to.

Research confirmed:
- `ric_companies.inter_location_model` (`SIMPLE`/`INTER_ENTITY`, migration `028_location_groups.sql`) is the single field governing this — no separate "books mode" setting exists.
- Only Stock Transfer has any existing `inter_location_model`/`group_id` awareness today (for cross-group transfer→invoice detection) — GRN/PO/Sales Invoice have a Location field but don't branch on the model; Finance vouchers have no field at all.
- `v_user_accessible_locations` (migration `127_sales_register_report.sql`) already does exactly the scoping needed — built for the Sales Register report's Location filter, same `ric_user_location_access` convention (zero active rows for a user = unrestricted/sees everything; any active rows = limited to that set).

**Explicitly out of scope for this plan** (per discussion): retrofitting `ric_user_location_access` enforcement onto GRN/PO/Sales Invoice/Stock Transfer's own Location pickers is a separate, later effort — this plan touches Finance vouchers only. Enforcement here is UI-filter-only (the picker simply never lists a location the user isn't granted) — no new server-side check function this round.

## Design

**Two new small shared providers** in `lib/core/providers/master_cache_providers.dart` (same file `accountsProvider`/`companyDetailsProvider` already live in, same single-purpose-FutureProvider convention):

```dart
final interLocationModelProvider = FutureProvider<String>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return 'SIMPLE';
  final res = await DioClient.instance.get('/ric_companies', queryParameters: {
    'id': 'eq.${session.companyId}', 'select': 'inter_location_model', 'limit': '1',
  });
  final list = List<Map<String, dynamic>>.from(res.data as List);
  return (list.isNotEmpty ? list.first['inter_location_model'] as String? : null) ?? 'SIMPLE';
});

final userAccessibleLocationsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return [];
  final res = await DioClient.instance.get('/v_user_accessible_locations', queryParameters: {
    'select': 'id,location_name', 'order': 'location_name.asc',
  });
  return List<Map<String, dynamic>>.from(res.data as List);
});
```
Defaulting to `'SIMPLE'` on any fetch failure/no-session is the deliberate fail-safe: on error, the new field simply doesn't appear and every screen behaves exactly as it does today (silent `session.locationId` inheritance) — never blocks the form.

**Per screen** (`journal_voucher_entry_screen.dart`, `contra_voucher_entry_screen.dart`, `expense_voucher_entry_screen.dart`, `finance_voucher_entry_screen.dart`):
1. `final interLocationModel = ref.watch(interLocationModelProvider).valueOrNull ?? 'SIMPLE';` and `final accessibleLocations = ref.watch(userAccessibleLocationsProvider).valueOrNull ?? const [];` near the top of `build()`.
2. `if (interLocationModel == 'INTER_ENTITY')` add a `SakalFieldCard(label: 'Location', required: true, editable: !locked, child: DropdownButtonFormField<String>(...))` into the existing header-fields grid — same shape as GRN's own Location field (`grn_entry_screen.dart:1485-1494`), just sourced from `accessibleLocations` instead of GRN's own unscoped `_locations`.
3. Default: when the field first appears for a brand-new voucher, seed `_locationId` from `session.locationId` **only if** it's present in `accessibleLocations` (it almost always will be, since a user's own default location is itself granted via the same access table) — otherwise leave unset, forcing an explicit pick. When resuming an existing DRAFT, `_locationId` continues loading from the saved header exactly as it does today (no change to that path).
4. Required-field validation: since the field is `required: true` whenever shown, add it to each screen's existing pre-save validation (same "show a snackbar, don't silently fail" convention already used for other required fields on these screens) so a DRAFT can't be saved with no location chosen once INTER_ENTITY is active.
5. When `interLocationModel == 'SIMPLE'` (the common case), nothing changes at all — no field, no behavior difference, `_locationId = session.locationId` exactly as today.

## Files touched

- `lib/core/providers/master_cache_providers.dart` — add the two providers above.
- `lib/features/finance/presentation/screens/journal_voucher_entry_screen.dart`
- `lib/features/finance/presentation/screens/contra_voucher_entry_screen.dart`
- `lib/features/finance/presentation/screens/expense_voucher_entry_screen.dart`
- `lib/features/finance/presentation/screens/finance_voucher_entry_screen.dart`

Each of the 4 gets the identical pattern from step 2-4 above — same shape repeated, no screen needs bespoke logic beyond wiring the field into its own existing header grid.

## Verification

No local Flutter/Postgres toolchain here:
1. Balance-check every edited file (brace/paren) same as every other session in this project.
2. Ask the user to confirm in the running app: with the test company set to `SIMPLE` (the default), open all 4 Finance voucher screens and confirm nothing changed — no Location field, saves work identically to before.
3. Flip a test company to `INTER_ENTITY` (Company Setup → Inter-Location Model — note this is locked once transactions exist, so use a fresh/test company) and confirm the Location field appears on all 4 screens, defaults sensibly, is required (blocks save with a message when left empty), and only lists locations the logged-in user actually has `ric_user_location_access` grants for (test with both an unrestricted user and one restricted to a subset of locations).
4. Confirm saving a voucher with a chosen location still correctly stamps `rih_finance_headers.location_id`, and resuming that DRAFT reloads the same location.

## Deferred follow-up (separate future plan, not this one)

`ric_user_location_access` enforcement on GRN/PO/Sales Invoice/Stock Transfer's own Location pickers (client-side filtering to granted locations, mirroring this plan's approach) — Stock Transfer additionally needs the From-location-only rule (destination/To location stays open, only the source location is access-checked). Server-side enforcement (a `fn_check_location_access`-style function, mirroring `fn_check_approve_permission`'s precedent) was explicitly deferred too, not just UI-side — both are open for a later session.
