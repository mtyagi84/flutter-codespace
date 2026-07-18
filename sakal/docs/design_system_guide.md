# SAKAL Design System — What It Is, and How to Roll It Onto a New Screen

This documents the visual redesign built across the 2026-07-18 sessions,
starting from a Figma-first plan that was abandoned in favor of a
user-provided `ERP_REDESIGN_MASTER_SPEC.md` (generic/templated, adapted
rather than copied — see `docs/screens/ERP_REDESIGN_MASTER_SPEC.md`), then
refined through an HTML mockup (built with the Artifact tool, iterated 3
times against real screenshots) before any Flutter code was written, then
built and iteratively fixed against **Sales Invoice** (`sales_invoice_entry_screen.dart`
+ `sales_invoice_list_screen.dart`) as the pilot screen.

**Purpose of this document**: every other screen in the app (~40 of them)
still uses the pre-redesign look. Converting one is meant to be
**mechanical**, not a design discussion — this doc is the playbook so that
doesn't have to be re-litigated per screen. If you're picking up a
conversion task, read §7 first and come back to the rest as reference.

---

## 1. Theme engine

`lib/core/theme/theme_presets.dart` — `ThemePreset` enum (`navy` / `emerald`
/ `slate` / `terracotta`) with a `ThemePresetConfig` per preset (`primary`,
`secondary`, `accent`, `background` — exact hex values live there).
`themePresetProvider` is a plain Riverpod `StateProvider<ThemePreset>`
(this app's convention — never a second `ChangeNotifier`-based state
system). `AppTheme.forPreset(config)` (`lib/core/theme/app_theme.dart`)
builds the reactive `ThemeData`, wired into `app.dart`'s root
`MaterialApp.theme`.

**What's theme-reactive today**: `Sidebar`, `TopBar`, all the shared
widgets in §3, `SegmentedButton` app-wide (themed once via
`AppTheme`'s `segmentedButtonTheme`, see §3.7).
**What's still hardcoded `AppColors.X`**: every screen not yet converted —
the vast majority of the app. Converting a screen to the shared widgets in
§3 is what makes it theme-reactive; there's no separate "make it
theme-aware" step.

### 1.1 Density toggle

`isCompactDensityProvider` (same file) — `bool` `StateProvider`. `DensityMetrics.of(isCompact)`
gives `{rowHeight, margin}`: **dense** = 40px / 12px, **comfortable** = 54px / 18px.
Every shared field/row widget in §3 reads this itself — a screen using
those widgets gets density-awareness for free, no per-screen wiring.

---

## 2. Number formatting

Two independent axes (confirmed against how Odoo/SAP solve the same
problem — see `project_number_format_settings` memory for the full
research writeup):

1. **Grouping style** — `ric_companies.number_format`
   (`'INTERNATIONAL'` = 115,356.00 vs `'INDIAN'` = 1,15,356.00), a
   company-level setting editable on the Company Setup screen ("Number
   Format" section). Carried on `UserSession.numberFormat`.
2. **Rate/price decimal precision** — `rim_currencies.rate_decimal_places`
   (default 2, 0-6), **per currency** — a USD unit price might need 4-5dp,
   CDF only needs 2. Editable on Company Setup's "Currency Decimal Places"
   section (one row per active currency).

Calculated **totals** (Gross/Tax/Grand Total, any report subtotal) are a
third, DELIBERATELY NOT configurable rule: always fixed at 2 decimals
regardless of currency, matching universal accounting practice.

`lib/core/utils/app_number_format.dart` — `AppNumberFormat.amount(value, numberFormat)`
(fixed 2dp, for totals/read-only amounts) and `AppNumberFormat.rate(value, decimalPlaces:, numberFormat:)`
(currency-specific, for price/rate fields). Built from an explicit ICU
pattern (`'#,##,##0.00'` for Indian) rather than `NumberFormat.decimalPatternDigits(locale: 'en_IN')`
— verified against the actual installed `intl` package that `en_IN`
isn't in its compiled locale tables, which would have silently produced
the wrong grouping.

**Read-only numeric values** (Amount columns, Financial Summary, Posted
Journal Entries) → `AppNumberFormat.amount()`/`.rate()`, wrapped in
`SakalFieldCard.readOnly(..., numeric: true)` or `SakalListColumn(..., numeric: true)`
(see §2.1).

**Live-editable numeric fields** (Rate specifically) → `SakalFormattedNumberField`
(§3.6) — format-on-blur, never live-as-you-type (avoids `TextInputFormatter`
cursor-position complexity). **Not yet extended** to Qty/Discount% fields —
flagged, not done.

**Decimal keyboard on mobile** — any field holding a fractional value
MUST use `keyboardType: const TextInputType.numberWithOptions(decimal: true)`,
never bare `TextInputType.number` (which hides the decimal-point key on
many Android on-screen keyboards — a real bug users hit typing "10.05").
Genuine integer-only fields (sort order, a decimal-places *setting*, a
whole-unit count) correctly keep `TextInputType.number`.

### 2.1 Numeric right-alignment — standing rule

**Number columns/values are always right-aligned.** Not a one-off style
choice — set `numeric: true` on any new numeric `SakalListColumn` or
`SakalFieldCard.readOnly()` from the start. See
`feedback_numeric_right_align_convention` memory. Still open: live-editable
numeric `TextFormField`s need their own explicit `textAlign: TextAlign.right`
at each call site (not covered by the `numeric` flag, which only
positions the widget within its card, not text inside a text field).

---

## 3. Shared widgets (`lib/core/widgets/`)

Build every new/converted screen on these — don't hand-roll an
`InputDecorator`/`Card`/table header again.

### 3.1 `SakalFieldCard`
The "label above bold value" field shell (mockup's `.stat`/`.stat.editable`).
Two constructors: `SakalFieldCard({label, child, required, editable, height, numeric})`
for a live input, `SakalFieldCard.readOnly({label, value, required, height, numeric})`
for a plain display value.

- `editable: true` + actual focus → distinct visual states (read-only
  gray / editable-idle darker-gray / editable-**focused** accent+glow).
  Tracked via an internal ancestor `FocusNode` (`hasFocus` is true for
  itself or any descendant in the focus chain) — zero wiring needed at
  the call site, existing child `FocusNode`s (implicit or explicit) keep
  working unchanged.
- `numeric: true` → right-aligns label + value (§2.1).
- Density-aware automatically (label size/gap/padding/value size all
  scale together in dense mode — see `feedback_sakal_field_card_dense_clipping`
  memory for why ALL of them have to move together, not just the outer box).
- For any input placed as `child`, give it `decoration: SakalFieldCard.bareDecoration`
  (strips the input's own border so only the card draws one) and
  `style: SakalFieldCard.valueTextStyle(ref.watch(isCompactDensityProvider))`.

### 3.2 `SakalFieldRow`
12-column grid (Oracle-APEX convention, user-specified): `SakalFieldRow(isMobile:, children:, spans:)`.
Omit `spans` → equal division among however many children (the common
case — header rows use this). Pass `spans: [4,3,3,2]` (sums to 12) for a
row that genuinely needs uneven columns (e.g. Charges — a charge *name*
needs more room than a short numeric value). On mobile, stacks children
full-width in a `Column` instead of a `Row`.

### 3.3 `SakalTableHeaderBar`
Dark, theme-reactive header for a document's own inline line-items table
(desktop). Takes caller-built `cells` (not a rigid flex spec) — the caller
wraps each header cell in the *exact same* `SizedBox`/`Expanded` shape as
its own data row, guaranteeing pixel alignment. `SakalTableHeaderBar.label(text, {textAlign})`
gives the standard header text style.

### 3.4 `SakalLineItemCard`
Mobile counterpart of 3.3 — dark-headed card (title/subtitle + optional
trailing action + optional delete) over a `Wrap` of `fields`, with room
for `body` (e.g. batch/serial allocation) and `footer`.

### 3.5 `SakalFinancialSummaryCard`
The solid-preset-color totals block. `SakalFinancialSummaryCard({rows: [SakalSummaryRow(...)], total, currencyCode, eyebrow, totalLabel})`.
Reads `session.numberFormat` and the active theme preset internally.

### 3.6 `SakalFormattedNumberField`
Format-on-blur numeric display for a field whose *underlying* controller
is read elsewhere via `double.tryParse()` (Rate fields, mainly). Owns a
**separate internal display controller** — the real controller you pass
in is NEVER given comma-formatted text, so every existing calculation
call site stays untouched. Shows plain digits while focused, grouped +
rounded-to-`decimalPlaces` on blur.

### 3.7 `SegmentedButton` (themed, not a separate widget)
`AppTheme.forPreset()`/`.light` both set a `segmentedButtonTheme` (pill
shape, dark filled selected segment) — any `SegmentedButton` in the app
picks this up automatically, no per-screen styling.

### 3.8 `SakalAdaptiveList` (existing widget, redesign-updated)
The shared mobile-card/desktop-table list shell (used by 14 list
screens already). Header is now dark/theme-reactive (was fixed
`AppColors.primary`). `SakalListColumn(label, {flex, numeric})` — set
`numeric: true` for a numeric column (§2.1). Card-vs-table switch is now
`!Responsive.isDesktop(context)` (cards for the whole mobile+tablet
range, table only ≥1024px) — see §4.

### 3.9 `SakalAutocomplete` (existing widget)
Searchable picker (product/customer/account) with Up/Down/Enter keyboard
nav — `RawAutocomplete`-based, owns its own paired `FocusNode`/`TextEditingController`.
Not redesign-specific but part of the same "use the shared widget, don't
hand-roll" discipline.

---

## 4. Responsive breakpoints

`lib/core/utils/responsive.dart` — **three** zones, not two:

| Zone | Width | Sidebar | List screens (`SakalAdaptiveList`) | Forms |
|---|---|---|---|---|
| Mobile | <600px | Drawer (hidden) | Cards | Stacked fields |
| **Tablet** | 600-1024px | Auto-collapsed to 56px icon-only, regardless of the user's own toggle | Cards | Desktop-style (unconverted) |
| Desktop | ≥1024px | Full 240px, respects the user's toggle | Table | Desktop-style |

**Real bug fixed 2026-07-18**: `isTablet`/`isTabletOrDesktop` existed in
`Responsive` but were referenced NOWHERE else in the app — every screen
only checked `isMobile`, so the whole tablet range silently got full
desktop treatment (full sidebar + full data table), causing real
overflow/wrapping at e.g. 739px. Fixed at the two shared choke-points
(`AppShell`, `Sidebar`, `SakalAdaptiveList`) — **not per-screen**. See
`project_responsive_breakpoints` memory.

**Deliberately not yet done**: individual entry-screen forms still only
branch at the 600px mobile line (no tablet-specific field-stacking mode)
— judged "good enough" combined with the sidebar recovery, not an
oversight. Revisit if a form-heavy screen still feels cramped in the
tablet zone specifically.

---

## 5. Navigation chrome

### 5.1 TopBar
Themed to `activePreset.primary` (was pure white) — every child
(leading icon, title, density/theme toggle icons, user avatar/name)
updated for contrast against a dark bar; the user avatar specifically
uses `activePreset.secondary` (not `.primary`, which would make it blend
into the now-same-color bar).

### 5.2 Back button
`TopBar`'s `leading` slot now shows a back arrow (`context.pop()`)
whenever `context.canPop()` is true (i.e. the current screen was reached
via `context.push()` — any entry/detail screen opened from a list), and
falls back to the existing menu/sidebar-collapse icon otherwise (a
top-level, sidebar/drawer-navigated screen, reached via `context.go()`).
No per-screen wiring needed — this is entirely in the shared `TopBar`.

### 5.3 Mobile drawer (Sidebar)
Touch-target sizing is now mobile-aware: module/group/feature rows grow
from 32-40px (desktop, mouse-precision-appropriate) to 44-52px on mobile
(the standard minimum touch-target guideline), with larger text (11-12px
→ 13-14px). Real bug also fixed: the sidebar's collapsed (icon-only, no
labels) state is a single global toggle with no concept of which layout
is looking at it — a user who collapsed the DESKTOP sidebar would have
had that same state leak into the MOBILE drawer, showing tiny unlabeled
icon buttons. Mobile now always forces the full expanded (labeled) list,
independent of the desktop collapse toggle.

---

## 6. What's converted so far

| Screen | Status |
|---|---|
| Sales Invoice Entry | Fully converted (pilot) |
| Sales Invoice List | Fully converted |
| Company Setup | Number Format + Currency Decimal Places sections added (new UI only — rest of screen unconverted) |
| Everything else (~40 screens) | **Not converted** — still hardcoded `AppColors.X`, old field styling, `SakalAdaptiveList` header now inherited automatically (shared-widget change) but each screen's own entry-form fields are untouched |

---

## 7. Converting a new screen — the checklist

Follow this mechanically; don't re-derive the visual language each time.

**List screen** (already on `SakalAdaptiveList`):
1. Nothing required — the dark header and card/table breakpoint already
   apply automatically via the shared widget.
2. Mark any numeric `SakalListColumn` with `numeric: true`, and
   right-align the matching cell in your own `rowBuilder`/`cardBuilder`.
3. Route Grand-Total-style values through `AppNumberFormat.amount()`.
4. If the screen has its own filter row (search/dropdown), rebuild it on
   `SakalFieldCard` (§3.1) instead of raw `DropdownButton`/`TextField` —
   see `sales_invoice_list_screen.dart`'s filter row for the reference
   shape.

**Entry/form screen**:
1. Header fields → `SakalFieldRow` + `SakalFieldCard`/`SakalFieldCard.readOnly`.
   Use `SakalFieldCard.bareDecoration` + `SakalFieldCard.valueTextStyle(isCompact)`
   for any nested `TextFormField`/`DropdownButtonFormField`/`SakalAutocomplete`.
2. Line-items table (if any) → `SakalTableHeaderBar` (desktop) +
   `SakalLineItemCard` (mobile), same column order/widths on both, per
   §3.3's alignment note.
3. Rate/price fields → `SakalFormattedNumberField` instead of a plain
   `TextFormField`, wired to that currency's `rate_decimal_places` (see
   `sales_invoice_entry_screen.dart`'s `_rateDecimalPlaces` getter for the
   lookup pattern via `currenciesProvider`).
4. Totals section → `SakalFinancialSummaryCard`.
5. Posted-voucher / journal-entry display (if the module has one) →
   reuse the `SakalTableHeaderBar`-based pattern from `_buildPostedVoucherSection`
   in `sales_invoice_entry_screen.dart`.
6. Every numeric `TextFormField` → confirm `keyboardType: const TextInputType.numberWithOptions(decimal: true)`
   if it can hold a fraction.
7. Run this project's own **MANDATORY pre-completion self-check**
   (Pack/Loose/Barcode/Batch-Serial — see root `CLAUDE.md`) — this design
   system doesn't replace that checklist, it's an addition to it.

**Either kind of screen**: no changes needed for TopBar/Sidebar/back-button/
responsive breakpoints — those are already app-wide via the shared shell.

---

## 8. Known gaps (flagged, not silently missing)

- Live-editable Qty/Discount% fields: no comma-grouping, no forced
  right-align yet (Rate is the only field with `SakalFormattedNumberField`
  so far).
- `rate_decimal_places` has no per-field VALIDATION yet (a user can still
  type a 6th decimal on a currency capped at 2 — display rounds it on
  blur, but nothing rejects the extra input while typing).
- Entry-screen forms have no tablet-zone-specific field layout — only
  list screens (`SakalAdaptiveList`) and the shell (`AppShell`/`Sidebar`)
  got the tablet-zone treatment.
- Mobile card views (as opposed to desktop tables) are not right-aligned
  even for numeric values — a card's top-to-bottom reading flow doesn't
  have the same "column" structure a table row does, so this wasn't
  treated as an obvious violation of §2.1's rule. Ask if this is wanted.
