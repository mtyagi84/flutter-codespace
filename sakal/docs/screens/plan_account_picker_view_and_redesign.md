# Account picker: SQL-view parent-name lookup + 3-column popup redesign

Status: Implemented 2026-08-16, with one mid-implementation design pivot on Part 2 (see below).

## Follow-up: Part 2 pivoted from inline dropdown to a separate desktop dialog

The first implementation of Part 2 (a header row + `OverflowBox` width fix on the existing inline `RawAutocomplete` dropdown) shipped but was still visibly broken live — the popup rendered at roughly the ANCHOR FIELD's own narrow width regardless of `optionsMinWidth`, wrapping the new header text character-by-character. Root cause: `RawAutocomplete`'s own `CompositedTransformFollower` hands `optionsViewBuilder` an incoming `maxWidth` already bounded to near the field's width — `ConstrainedBox(minWidth: ...)` gets silently clamped back down via `BoxConstraints.enforce()` (constraints only ever tighten going down the tree), so no `minWidth` value could ever actually take effect. An `OverflowBox` fix was attempted (a standard technique for escaping ambient constraints) — this WAS applied and kept, as a real, valid bug fix to `SakalAutocomplete`'s inline dropdown path for any other future caller — but the user, seeing the still-fundamentally-anchored-to-a-narrow-field design, asked instead for a genuinely separate popup window, independent of field size, confirmed desktop-only (mobile's existing bottom-sheet stays untouched).

**Final design**: `SakalAutocomplete` gained a new opt-in `desktopDialogMode` flag (default `false` — every other consumer unaffected). When set, desktop tapping/focusing the field opens a centered modal `Dialog` (`_DesktopAutocompleteDialog`, new widget, closely mirrors the existing `_MobileAutocompleteSheet` but as a `Dialog` instead of a bottom sheet, with a fixed `640x560` max size independent of the field, PLUS Up/Down/Enter/Escape keyboard navigation reusing the same `Focus(onKeyEvent:)`-wrapping-the-TextField technique already proven in this file's inline dropdown path) instead of the inline `RawAutocomplete` overlay. `FinanceAccountPicker` sets `desktopDialogMode: true`; every other `SakalAutocomplete` consumer (product pickers, etc.) is unaffected since the flag defaults false.

Files touched (final): `lib/core/widgets/sakal_autocomplete.dart` (OverflowBox fix retained + new `desktopDialogMode`/`_DesktopAutocompleteDialog`), `lib/features/finance/presentation/widgets/finance_account_picker.dart` (now passes `desktopDialogMode: true`, header/row-divider styling unchanged and reused inside the new dialog).

## Context

`accountsProvider` (`lib/core/providers/master_cache_providers.dart`) and its sync-cache duplicate (`lib/core/sync/master_data_modules.dart`'s `_syncCustomersSuppliers`) need to show each account's **parent group name** (e.g. for the Group/Parent Group column in `FinanceAccountPicker`, Opening Balance's screen, etc.).

Two different PostgREST embed-hint forms for the self-referencing `rim_accounts!parent_id` relationship were tried live this session and both failed:
1. `!parent_id` (column-name hint) — resolved to the *reverse* relationship (this account's children, not its parent), so it silently came back empty for every leaf/postable account (the only kind ever shown in a picker) — Group Name was blank everywhere.
2. `!rim_accounts_parent_id_fkey` (FK constraint name, independently verified correct via `pg_constraint`) — PostgREST rejected it outright ("no matches were found"), even after `NOTIFY pgrst, 'reload schema';`, breaking every account picker in the app.

The current, currently-shipped workaround (`6c194f3`) avoids the embed entirely: fetch `parent_id` as a plain column, then a **second** PostgREST query for just the distinct parent ids' names, joined client-side in Dart. This works but costs an extra HTTP round-trip and is more code than necessary.

The user then suggested resolving `parent_name` **server-side via a plain SQL join/subquery**, exposed through a view — eliminating both the embed-ambiguity problem AND the second round-trip in one move. This is the right fix: it's the same pattern this codebase already relies on heavily (`v_pending_bills`, `v_batch_stock_balance`, `v_opening_balance_summary`, `v_sales_details_base`, etc. — CLAUDE.md documents this as an established, proven convention), and a plain SQL join is not subject to PostgREST's self-referencing-embed relationship-resolution quirks at all, since it's just a regular column on a regular view by the time PostgREST sees it.

Separately, the user also asked for the account picker's popup to be redesigned into a proper 3-column table with a header row — the current popup "doesn't look professional" and truncates account names on narrow fields.

## Design — Part 1: SQL view

### New migration — `134_rim_accounts_parent_name_view.sql`

```sql
CREATE OR REPLACE VIEW v_rim_accounts_with_parent AS
SELECT c.*,
       p.account_name AS parent_name
FROM   rim_accounts c
LEFT JOIN rim_accounts p
       ON  p.id         = c.parent_id
       AND p.client_id  = c.client_id
       AND p.company_id = c.company_id;

GRANT SELECT ON v_rim_accounts_with_parent TO authenticated;
```

- `SELECT c.*` passes through every existing `rim_accounts` column unchanged — both consumers select different subsets today, a passthrough view means neither needs a different column list, just retargeted at the view.
- `LEFT JOIN` (not a correlated subquery) — functionally identical, standard, matches the join style already used elsewhere in this schema's own views.
- No RLS policy needed on the view itself — Postgres enforces the underlying table's RLS policy through the view automatically.

### `lib/core/providers/master_cache_providers.dart` — `accountsProvider`

- Change the request path from `/rim_accounts` to `/v_rim_accounts_with_parent`.
- Select list becomes `id,account_code,account_name,account_nature,posting_allowed,parent_name,rim_currencies!account_currency_id(currency_id)`.
- Remove the two-query parent-lookup block added in `6c194f3` entirely.
- After fetching, one-line transform: if `parent_name` is non-null, set `a['parent'] = {'account_name': a['parent_name']}` — preserves the exact shape every consumer already reads, zero consumer-file changes needed.

### `lib/core/sync/master_data_modules.dart` — `_syncCustomersSuppliers`

Same treatment: query the view, select gains `parent_name` instead of `parent_id`, remove the two-query lookup block, same one-line transform before `AccountsLocalDs(db).upsertAccounts(...)`.

## Design — Part 2: 3-column popup redesign

Clarified with the user:
- **Style**: bold/shaded header row with a bottom border, plus thin light-grey horizontal dividers between rows — no vertical column-separator lines.
- **Column order**: no preference — keep current order (Account Code, Account Name, Group Name).
- **Searchability**: already true today (`FinanceAccountPicker.matchesSearch` already checks code, name, and parent) — no new work needed.
- **Mobile untouched**: `SakalAutocomplete` already branches on `Responsive.isMobile` — mobile uses a completely separate `_MobileAutocompleteSheet` (bottom sheet), never the desktop `RawAutocomplete` overlay. The new header param only wires into the desktop path, so mobile's interaction pattern is structurally unaffected. The per-row column layout IS shared with mobile via `optionBuilder`, so the new row dividers will show there too — a harmless visual improvement, not an interaction change.

### `lib/core/widgets/sakal_autocomplete.dart`
New optional `final Widget? optionsHeader;` param (defaults `null`, every other consumer unaffected). In the desktop `optionsViewBuilder`, when non-null, wrap the ListView in `Column(mainAxisSize: min, children: [optionsHeader!, Flexible(child: <ListView>)])` so it stays pinned above the scrolling list.

### `lib/features/finance/presentation/widgets/finance_account_picker.dart`
- New `static Widget _headerRow()` — shaded background, bold labels in the same column widths/flex as `optionRow`, bottom border.
- `optionRow` gains a light bottom border per row.
- `build()` passes `optionsHeader: _headerRow()`.

Since `FinanceAccountPicker` is the one shared widget behind every Finance account picker, this cascades to all of them automatically.

## Verification

No local Flutter/Postgres toolchain here — balance-check after every edit; the user runs the migration and retests:
1. `flutter analyze` / `flutter test`.
2. Group/Parent Group shows real values everywhere (Opening Balance, Journal Voucher, Account Ledger filter) instead of "—".
3. Offline sync still populates the local Drift cache correctly.
4. Desktop: header row appears, columns aligned, search still works across all 3 columns, Up/Down/Enter still work.
5. Mobile: bottom sheet unchanged, no header appears there.
6. No other `SakalAutocomplete` consumer visually affected.
