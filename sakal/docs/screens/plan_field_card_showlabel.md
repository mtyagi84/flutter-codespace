# Remove redundant per-cell labels in line-item table rows

Status: Implemented 2026-08-16 (Journal Voucher desktop only, pilot).

## Context

Every desktop line-items table in the app (Journal Voucher's Account Lines, and 20 other entry screens following the "Line-items grid" mandatory pattern) renders a dark `SakalTableHeaderBar` column-header row, then one data row per line built from `SakalFieldCard` cells — and `SakalFieldCard` always renders its own label above the value, even though the column header directly above it already says the same thing. User's observation, confirmed correct: this is pure redundancy that inflates row height for no benefit — the label only earns its keep on a standalone field (e.g. the header-section "Voucher No"/"Currency" cards) where there's no table header to already announce it.

## Design

`lib/core/widgets/sakal_field_card.dart` gained a new optional `bool showLabel = true` on both `SakalFieldCard(...)` and `SakalFieldCard.readOnly(...)`. Defaults `true` — every existing call site across the whole app is unaffected. When `false`:
- The `RichText` label + its gap `SizedBox` are skipped entirely (a straightforward conditional inside the existing `Column`'s `children` list).
- The card's default height also shrinks (32px dense / 40px comfortable, vs. the label-inclusive 40/54px `DensityMetrics.rowHeight`) — hiding just the label without shrinking the row would leave the freed space as dead whitespace instead of actually making the row shorter, defeating the point. Still overridable via the existing `height` param.
- `required`'s red asterisk (part of the label text) is lost too when hidden — accepted trade-off; `SakalTableHeaderBar` headers don't carry a required-marker convention either, and Save-time validation still enforces required-ness regardless of any visual cue.

**Scope, per explicit user decision**: Journal Voucher only, desktop only, for this round ("let's see how it goes" before touching the other 20 screens). `journal_voucher_entry_screen.dart`'s `_buildLineCard` now passes `showLabel: isMobile` on every line-item `SakalFieldCard`/`SakalFieldCard.readOnly` (Account, Parent Group, Currency, Amount, Dr/Cr, Base/Local/Party Amount, Remarks) — true (label shown) on the mobile Wrap-card branch, false (no label, shorter row) on the desktop `SakalScrollableTable` row. Header-section fields (Voucher No/Date/Currency/etc., which have no column header above them) are untouched.

## Files touched

- `lib/core/widgets/sakal_field_card.dart` — new `showLabel` param (generic, reusable capability).
- `lib/features/finance/presentation/screens/journal_voucher_entry_screen.dart` — `_buildLineCard`'s line-item fields opt in via `showLabel: isMobile`.

## Follow-up (explicitly deferred, not part of this change)

The identical redundancy exists on the other 20 screens using `SakalTableHeaderBar` + `SakalFieldCard` line-item rows (Sales Invoice, Purchase Order, GRN, Stock Transfer, etc.). Roll out `showLabel: isMobile` to each opportunistically once JV's own result is confirmed good — same incremental-rollout shape as `SakalAutocomplete`/`SakalAdaptiveList` before it.

## Verification

No local Flutter toolchain — balance-checked after every edit. User to confirm in the running app:
1. Desktop Account Lines table: rows visibly shorter, no per-cell label text, values still clearly aligned under their column headers.
2. Mobile line cards: unchanged (still show their own labels).
3. Header-section fields (Voucher No, Currency, etc.): unchanged.
4. `flutter analyze` — zero new warnings.
