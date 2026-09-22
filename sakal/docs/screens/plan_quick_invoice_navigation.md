Status: Approved, not yet implemented (2026-09-22)

# Quick Sales Invoice — keyboard-first entry, post-save print flow, reset-for-next, dense rows default

## Context

User's own framing: "The major task is Navigation on screen. We will start from Sales Module" —
Quick Sales Invoice is the highest-volume, most repetitive screen in the app (POS-style cash
sale entry), and today it requires far too much mouse use and manual re-navigation between
invoices. Five concrete asks, plus one unrelated bug spotted in the same screenshot:

0. **Bug**: the sidebar shows "Reports" twice under Sales. Root-caused (see below) — a
   `group_serial_no` data drift on one report row, the same bug class this project has hit
   twice before (migration 093's own header documents the first occurrence).
1. Cursor should auto-focus the Customer/Walk-in-Customer field the moment the screen opens.
2. A keyboard shortcut for Save, usable from anywhere on the screen (not just when a Save
   button happens to have focus).
3. After Save (which already auto-approves), ask "Do you want to print?" — always appears
   (see Part 2's corrected understanding below). Manual Print button clicks (view mode) should
   never show a confirmation — confirmed this already works correctly today, no change needed
   there.
4. After save (+ print or skip), the screen should reset itself for the next invoice — no
   navigating away and back.
5. The app should default to **Dense Rows**, not Comfortable Rows.

## Part 0 — Fix: duplicate "Reports" folder under Sales

Root cause, confirmed by reading the actual files: `fn_get_user_menu.sql`'s group-listing query
groups by `(group_code, group_name, group_serial_no)` together (`SELECT DISTINCT ...`) — so two
rows sharing the same `group_code`/`group_name` but a **different** `group_serial_no` render as
two separate folders. `backend/functions/fn_seed_client_modules.sql` and every later Sales
report migration (163/164/165) consistently seed Sales' Reports group as
`('SL-RPT', 'Reports', 1)` — except `backend/migrations/127_sales_register_report.sql:241`,
which inserts the "Sales Register" feature under `('SL-RPT', 'Reports', 2)`. This is the exact
same drift class migration 093 already fixed once for `SL-TXN`/"Transactions" (093's own header
comment documents that earlier incident verbatim).

Fix: confirm live via
`SELECT feature_code, group_serial_no FROM ric_master_menus WHERE group_code='SL-RPT'`, then a
small migration: `UPDATE ric_master_menus SET group_serial_no = 1 WHERE group_code = 'SL-RPT'
AND group_serial_no <> 1` — company-wide, not tenant-specific, since this is seed-data drift
that could affect any company that had 127 run before 128's full reseed.

## Part 1 — Keyboard-first entry on Quick Invoice

File: `lib/features/sales/presentation/screens/sales_invoice_entry_screen.dart`.

**Confirmed today**: zero `FocusNode`s on any header field (Customer/Walk-in Name/Sales
Person/Discount) — only the line-grid already has a chaining mechanism
(`_addLine()` auto-focuses a new row's `productFocusNode`; Disc%'s `onFieldSubmitted` moves
focus to that row's own `(+)` button; pressing the focused `(+)` button adds a line and focuses
its Product field). No app-wide keyboard-shortcut precedent exists anywhere in this codebase
today (checked `app_shell.dart` and grepped the whole `lib/` tree for
`Shortcuts`/`CallbackShortcuts`/`LogicalKeyboardKey`) — this introduces the pattern for the
first time, so keep it simple and scoped to this screen rather than over-building a shared
shortcut framework nobody else needs yet.

- **Auto-focus on open**: add a `FocusNode` for whichever field is actually the first real
  entry point (`_partyNameCtrl`'s Walk-in Customer field for Cash+Direct mode; the Customer
  `SakalAutocomplete` for Credit+Direct mode — Against-Quotation/Order modes have no free-typed
  customer field, so their first focus target is instead the picker/first line). Request focus
  in the same `WidgetsBinding.instance.addPostFrameCallback` `_init()` already uses, once
  loading completes.
- **Header field chaining**: give each header field still missing one a `FocusNode`, and wire
  `onFieldSubmitted`/`onEditingComplete` so Enter moves forward in a sensible order (Walk-in
  Name → Mobile → Address → Sales Person → first line's Product), reusing exactly the
  `FocusNode.requestFocus()` idiom the line grid already proves out — no new mechanism, just
  extending the existing one upward into the header.
- **Alt+S saves from anywhere** (confirmed with the user: Alt+S, not Ctrl+S/Ctrl+A/F9 — no
  known browser/OS reservation for Alt+S on Chrome/Edge; Firefox's classic menu bar, which
  would intercept Alt+letter combos, is hidden by default so this is safe in practice). Wrap
  the screen body in a `Focus` + `onKeyEvent` at the Scaffold/body level (same low-level
  technique `sakal_autocomplete.dart` already uses for its own arrow-key handling — not
  `Shortcuts`/`Actions`, simpler and proven to already work in this app), checking
  `HardwareKeyboard.instance.isAltPressed && event.logicalKey == LogicalKeyboardKey.keyS`, and
  invoking the same `_saveAndApprove()` the Save button already calls. Must fire regardless of
  which descendant field currently has focus (a key event bubbles up through `Focus` ancestors
  when not consumed by the focused field itself, which is how the autocomplete's own handler
  already works).

## Part 2 — Post-save print flow, per-user configurable

**Corrected understanding (from direct user feedback on the first draft of this plan)**: the
"Do you want to print?" confirmation ALWAYS appears after Save — it is not itself the
configurable thing. What's configurable per-user is what happens when the user answers **Yes**:
print straight to their own default printer with no PDF-viewing step in the way ("Direct
Print"), or show/download the PDF for them to handle themselves ("On Screen" — today's only
behavior).

**Confirmed today**: `_printInvoice()` calls `PrintEngine.printDocument(...)` directly with no
confirmation dialog — correct already for manual print-button clicks (view mode), no change
needed there. `PrintEngine.printDocument` (`lib/core/printing/print_engine.dart`) currently
routes ALL web traffic (`kIsWeb`, regardless of desktop or mobile browser) through
`Printing.sharePdf(...)` — a plain file download — and reserves `Printing.layoutPdf(...)` (which
opens the browser's native PDF viewer and immediately triggers ITS print dialog — a real,
already-working "one click away from the printer" flow) for native desktop builds only. That
narrowing was a deliberate fix for a real reported bug: on a MOBILE browser, `layoutPdf`'s
in-page preview overlay has no back button and traps the user.

**Confirmed with the user**: true zero-click silent printing is not achievable from any browser
(a hard security restriction in every browser, not a gap in this app) — "Direct Print" here
means the closest real equivalent: open the PDF and immediately trigger the browser's own print
dialog on it (`Printing.layoutPdf`), so the user's one remaining click sends it straight to
their own already-configured default printer. "On Screen" keeps today's plain download
(`Printing.sharePdf`) so the user can view/save/print at their own pace.

**New setting**: a per-user preference, `print_mode`: `'DIRECT'` or `'ON_SCREEN'` (default).
Stored in a brand-new table, deliberately separate from `rim_users`/`ric_user_menus` (same
reasoning already established for `ric_user_menu_favorites`, migration 202: a personal UI
preference should never live on a row that also carries real permissions). One new migration:

```sql
CREATE TABLE ric_user_preferences (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL REFERENCES ric_clients(id),
    company_id UUID NOT NULL REFERENCES ric_companies(id),
    user_id UUID NOT NULL REFERENCES rim_users(id),
    print_mode TEXT NOT NULL DEFAULT 'ON_SCREEN' CHECK (print_mode IN ('DIRECT','ON_SCREEN')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (client_id, company_id, user_id)
);
```
RLS: `auth_rw_user_preferences`, same JWT-`user_id`-scoped pattern as `ric_user_menu_favorites`
(migration 202) — a user can only ever read/write their own row. One row per user (not
per-document-type) — global today, but the column-per-setting shape leaves room to grow later
without a redesign.

**`PrintEngine.printDocument` gets a new `directPrint` flag** (default `false`, so every other
screen's existing call sites are unaffected): when `true` and `kIsWeb`, use `layoutPdf` instead
of `sharePdf`. Native desktop keeps using `layoutPdf` unconditionally either way (it's already
the direct behavior there, the flag is a no-op on that platform).

**UI**: add a "Direct Print" / "On Screen" choice to the TopBar avatar popup menu, right next to
the existing Comfortable/Dense Rows toggle (`lib/core/layout/top_bar.dart`) — same self-service,
same visual location. Fetched once at login (alongside the existing menu fetch) into a small
`userPreferencesProvider` (`StateProvider<String>` holding `print_mode`, mirroring
`isCompactDensityProvider`'s own shape) and written straight to `ric_user_preferences` on
change.

**Screen behavior**: after `_saveAndApprove()` succeeds, always show a plain `AlertDialog`
("Print this invoice now?" Yes/No). On **Yes**: call `_printInvoice()`, passing
`directPrint: userPreferencesProvider.value == 'DIRECT' && !Responsive.isMobile(context)` — the
mobile-width guard is a deliberate, explicit carve-out to avoid reintroducing the exact
"trapped overlay, no back button" bug `print_engine.dart`'s own comment already documents;
on a narrow/mobile viewport, printing always falls back to On Screen regardless of the user's
saved preference, since `layoutPdf`'s overlay genuinely isn't safe to use there. On **No**:
skip printing. Either way, once resolved, proceed to Part 3's reset.

## Part 3 — Reset for the next invoice (no navigating away and back)

**Confirmed today**: on successful save, the screen calls `_loadExisting(invoiceNo, ...)` and
stays on the now-approved, now-read-only document — there is no existing "new invoice"/reset
method anywhere in this file (confirmed: no `_resetForm`/`_newInvoice`, grepped).

New `_resetForNextInvoice()` method, called after Part 2's print-or-skip resolves:
- Reuses everything `_init()` already fetched once (`_taxGroups`, `_users`, `_quickSetup`,
  `_additionalCharges`, `_currencyDecimalPlaces`, `_canOverridePrice`/`_canGiveDiscount`/
  `_maxDiscountPercent`) — **no re-fetch**, this must be fast (it's meant to feel instant
  between invoices, not repeat a network round trip every time).
  Clears document-level state instead: `_invoiceNo = null`, `_status = 'DRAFT'`, disposes every
  existing line/charge row via the screen's own already-present `DeferredRowDisposal` mixin
  (`deferRowDisposal(...)` — same convention already used for line/charge removal elsewhere in
  this exact file), clears `_lines`/`_charges`, resets header text controllers (Walk-in Name,
  Mobile, Address, Remarks, header discount), then replays the same "fresh DIRECT invoice"
  branch `_init()`'s own `else` clause already does: reapply the cash customer if
  `_saleType == 'CASH'` (`_applyCashCustomer`), `_addLine()` for one blank starting line.
- Finishes by requesting focus back onto the same field Part 1's auto-focus targets — the
  invoice-entry loop closes on itself.

## Part 4 — Dense Rows as the default

**Confirmed today**: `isCompactDensityProvider` (`lib/core/theme/theme_presets.dart:71`) is a
plain `StateProvider<bool>((ref) => false)` — in-memory only, not persisted anywhere (no
SharedPreferences/localStorage/DB), resets every reload regardless. Since the user only asked
for the *default* to change, not for the choice to persist across sessions, this is a
one-line change: flip the initializer to `(ref) => true`. Persisting a user's own override
(if they switch back to Comfortable) is explicitly out of scope for this pass — flagged as a
natural future extension of Part 2's new `ric_user_preferences` table, not built now.

## Files touched

**Backend**: one new migration covering both Part 0's data fix and Part 2's new
`ric_user_preferences` table (unrelated to each other but both small/additive, same pattern
already used in this project for bundling small unrelated fixes into one migration file).

**Flutter**:
- `lib/features/sales/presentation/screens/sales_invoice_entry_screen.dart` — header
  `FocusNode`s + chaining, Alt+S handler, post-save "print now?" dialog +
  `directPrint` pass-through, `_resetForNextInvoice()`.
- `lib/core/printing/print_engine.dart` — new `directPrint` bool parameter on
  `printDocument(...)`, default `false` (every other existing call site unaffected).
- `lib/core/theme/theme_presets.dart` — `isCompactDensityProvider` default flip.
- `lib/core/layout/top_bar.dart` — new Direct Print / On Screen choice.
- `lib/core/providers/session_provider.dart` (or `theme_presets.dart`, matching wherever
  `isCompactDensityProvider` already lives) — new `userPreferencesProvider`, fetched once at
  login alongside the existing menu fetch (`login_screen.dart`'s own post-login block).

## Verification
- `flutter analyze` clean (targeted + full project).
- Live DB check confirms `SL-RPT`'s `group_serial_no` is now uniformly `1`, and the sidebar
  shows exactly one "Reports" folder under Sales with all 13+ reports inside it.
- Manual smoke test once deployed: open Quick Invoice — cursor lands on Walk-in Customer Name
  immediately; enter a full invoice using only the keyboard (Enter/Tab through header and
  lines, Alt+S to save) with no mouse click required; confirm "Print this invoice now?" always
  appears after save; with On Screen selected (default), Yes downloads the PDF as today; switch
  to Direct Print in the avatar menu, confirm Yes instead opens the PDF and immediately triggers
  the browser's print dialog on a desktop-width window, and confirm it falls back to the On
  Screen download behavior on a narrow/mobile-width window even with Direct Print selected;
  confirm either path clears the screen and refocuses Walk-in Customer Name, ready for the next
  invoice with no navigation; confirm a manual Print-button click on an already-saved invoice
  still shows no confirmation; confirm a fresh page load defaults to Dense Rows.
