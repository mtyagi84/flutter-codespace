# POS Touch-First Redesign — on-screen keypad/keyboard, bug fixes, UX gaps

Status: Approved 2026-10-03, implemented 2026-10-03 (not yet click-tested by the user).

## Context

User tested the live POS module end-to-end and rated it 2/10, with 10 concrete
pieces of feedback (verbatim, with screenshots) after trying Device Setup →
Shift Open → New Sale → Reports → Return → Price Check. Two things became
clear on inspection:

1. **Every numeric/text field in POS today is a plain Flutter `TextField`
   relying on the OS/browser's own on-screen keyboard** — but POS v1
   (docs/pos/00_index.md onward) was built and reviewed entirely on a desktop
   browser with a real keyboard+mouse attached, so this gap was never
   surfaced until the user tried it on hardware that behaves like a real
   till (no physical keyboard, and Windows/Chrome do not reliably auto-pop a
   touch keyboard for web `<input>` elements the way Android/iOS do). The
   one place this was already done right is `PosPinPad`
   (`lib/features/pos/presentation/widgets/pos_pin_pad.dart`) — a dedicated,
   self-contained on-screen keypad built specifically because "no password
   UI anywhere on the till" meant no reliance on any native keyboard. The
   fix for the rest of POS is to generalize that same proven pattern, not
   to chase the OS keyboard.
2. **This same root cause explains two of the "bugs" directly**: a numeric
   `TextField` initialized with literal text `'0'`
   (`_OpenShiftCardState._ctrlFor`, `pos_shift_screen.dart:285`) has no
   select-all-on-focus, so tapping in and typing inserts digits around the
   existing `"0"` depending on cursor position rather than replacing it —
   confirmed live (point #3: typed "2530" became "02530"). A dedicated
   on-screen numpad that builds its value from explicit digit-button taps
   (exactly how `PosPinPad` already works) makes this class of bug
   structurally impossible, not just patched.
3. **A separate, real bug, independent of the keyboard issue**: POS Reports
   (`pos_reports_screen.dart:84`) sums `opening_amount` across ALL
   currencies into one blended `_openingFloat` number with no currency
   grouping at all — entering 1500 CDF + 10 USD cannot mathematically
   produce one correct combined figure, and the screen shows 15010.00
   (point #7). The Close-Shift dialog on the SAME screen
   (`pos_shift_screen.dart`'s `_expectedFor`) already does this correctly,
   grouped per currency — Reports just never adopted that pattern.

## Decisions made while researching (stated here so the "why" survives)

- **On-screen numpad/keyboard, not reliance on the OS keyboard, for every
  POS data-entry point.** This is the single biggest lever — it directly
  fixes #2, #3, #6, #9, and half of #8 and #10, and matches what every real
  POS device in the market actually does (Square, Toast, Clover, Lightspeed
  all ship their own on-screen numeric pad; none rely on the OS's touch
  keyboard for amount/qty entry).
- **Cash Out vs Payout (#5) — these ARE functionally duplicated today**: both
  post `direction='OUT'`, the only backend difference is Payout restricts
  the "other side" account picker to non-cash accounts
  (`_nonCashAccounts`). Real POS systems (researched: Square's Cash
  Management) distinguish exactly 3 concepts — **Paid In**, **Paid Out**
  (an expense, always needs a reason/account), and a separate **Cash
  Drop/Safe Drop** (moving excess cash to the safe for security, NOT an
  expense). Collapsed the 4 buttons to 3 — **Cash In**, **Pay Out** (merges
  the old "Cash Out" and "Payout" into one clearly-labeled action), **Cash
  Drop** — each with a one-line subtitle explaining what it is. This is a
  UI-only change: the backend keeps accepting `CASH_OUT` as a valid
  `movement_type` (no migration, no schema change) — the UI simply stops
  offering it as a separate button and the merged "Pay Out" button always
  sends `PAYOUT`.
- **Return screen (#8) — browse first, type only as fallback.** Rebuilt
  around a date picker (default today) + a tappable list of that day's
  APPROVED invoices (same visual pattern already proven on
  `pos_hold_sales_screen.dart`), with the existing invoice-number search
  field kept as a secondary fallback (useful for scanning a printed
  receipt's barcode) backed by the new on-screen keyboard instead of a bare
  `TextField`. `getApprovedInvoices` (used by both this screen and the
  back-office Sales Return screen) gained one new **optional**
  `invoiceDate` parameter, unused by existing callers — additive, not a
  breaking change.
- **New Sale touch-first pass (#6, #10)**: the header's row of small
  `IconButton`s (36dp hit targets) became a horizontally-scrollable row of
  larger labeled touch buttons; raw Qty `TextField`s on cart lines became a
  `[-] qty [+]` stepper (tap the number to open the numpad for an
  exact/fractional value); a new "×N next scan" quick-qty control lets a
  cashier set a quantity BEFORE scanning (standard "quantity-then-scan" POS
  flow) so scanning the same item 5 times isn't the only way to sell 5
  units.
- **Scope deliberately NOT covered by this pass** (consistent with this
  module's existing documented v1 scope cuts): a full IME-grade keyboard
  with autocorrect/predictive text, weighted-barcode (embedded-weight EAN)
  parsing, multi-currency split tender UI. The on-screen keyboard built
  here is intentionally simple — large QWERTY keys + shift + space +
  backspace + Done — enough for invoice numbers / product-name fallback
  search, not a general-purpose IME.

## New shared widgets (`lib/features/pos/presentation/widgets/`)

1. **`pos_numpad.dart` — `PosNumpad`**: digits 0-9, one decimal point, Clear,
   Backspace, built from the same `_PinKey`-style large touch tile already
   proven in `pos_pin_pad.dart` (visually consistent, same tap/haptic
   feedback). Pure widget, no text-field semantics at all — builds a string
   buffer from scratch via button taps only, which is what makes the
   "0 prefixed, prepend bug" class of error structurally impossible.
2. **`pos_amount_field.dart` — `PosAmountField`**: the thing screens actually
   use in place of a raw `TextField` for any money/qty/percent value. Renders
   as a large, bordered, tappable "display box" (label + current value,
   right-aligned, big font) — tapping it opens a `showModalBottomSheet`
   containing `PosNumpad` plus a "Done" button; confirming calls back with
   the parsed `double`. Takes `label`, `value`, `suffixText` (e.g. a
   currency code), `enabled`. Used for: Open Shift's per-currency opening
   float, Cash Movement's Amount field, Close Shift's per-currency Counted
   Amount, New Sale's Rate/Discount%/Collected fields.
3. **`pos_qty_stepper.dart` — `PosQtyStepper`**: a `[-]  qty  [+]` row, large
   tap targets (44dp circular buttons), increments/decrements by 1 on
   tap; tapping the number itself opens the same numpad sheet for a
   precise/fractional value. Used on New Sale cart lines and Return's
   per-line Return Qty.
4. **`pos_keyboard.dart` — `PosKeyboardField`/`PosKeyboard`**: compact
   on-screen QWERTY (lowercase + Shift for caps, Space, Backspace, Done),
   same tappable "display box → bottom sheet" pattern as `PosAmountField`.
   Used for: Return's manual invoice-number fallback search, Price Check's
   manual fallback search — in every case the PRIMARY flow stays
   scan-first/autofocus (a barcode scanner acts as a keyboard-wedge and
   needs no on-screen UI at all); the keyboard is an explicit, visible
   fallback, never the default interaction.
5. **`pos_session_guard.dart` — `buildPosSessionGuardError`**: the "This
   isn't a POS till session…" error block, now with a **"Go to POS Login"**
   button (`context.go(RouteNames.posLogin)`) alongside the existing Retry —
   replaces the near-identical copies previously duplicated across
   `pos_shift_screen.dart`, `pos_new_sale_screen.dart`,
   `pos_hold_sales_screen.dart`, `pos_reports_screen.dart`.

## Screen-by-screen changes (all implemented)

**`pos_shift_screen.dart`**
- `_OpenShiftCardState`: per-currency `TextField`s replaced with
  `PosAmountField` (fixes #2/#3 at the root — state is now a
  `Map<String, double>`, no `TextEditingController` at all for these
  fields).
- `_open()`: on success, `context.go(RouteNames.posSale)` instead of
  staying on this screen (fixes #4).
- Movement grid: 4 buttons → 3 full-width `_MovementTile`s (`Cash In` /
  `Pay Out` / `Cash Drop`), each with an icon, title and one-line subtitle;
  `Pay Out` always calls `_openMovementDialog('PAYOUT')` (fixes #5).
- `_CashMovementDialog`/`_CloseShiftDialog`: Amount / Counted Amount fields
  are now `PosAmountField`.
- `buildPosSessionGuardError` wired into the error state (fixes #1).

**`pos_reports_screen.dart`**
- `_loadShiftTotals` now groups opening float, cash-in, cash-out+payout
  (merged), and cash-drop **by `currency_id`** into `Map<String, double>`
  fields, mirroring `pos_shift_screen.dart`'s own correct `_expectedFor`
  pattern. Cash sales are attributed to the company's own local currency
  (the only currency a drawer physically holds). One "Cash Movements (CCY)"
  card is rendered **per currency actually touched**, never one blended
  number (fixes #7).
- `buildPosSessionGuardError` wired in.

**`pos_new_sale_screen.dart`**
- `_PosLineRow` refactored off `TextEditingController`s entirely (`qty`,
  `rate`, `discountPct` are now plain `double` fields) — removes the raw-
  `TextField` input-bug class from this screen too.
- Header: 6 icon-only buttons replaced by a horizontally-scrollable row of
  `_HeaderActionButton`s (icon + visible label, ~84×58dp) (fixes #6).
- New `_pendingQty` field + a tappable "×N" control next to the search bar
  opens `PosNumpad` to set a quantity that applies to the next product
  added (scan or search), then resets to 1 (fixes #10, set-before-scan
  half).
- Cart line `Qty` → `PosQtyStepper`; `Rate`/`Disc %` → `PosAmountField`
  (fixes #10's adjust-after-scan half, plus #2/#3's root cause here too).
- `Collected` field → `PosAmountField` (nullable `_collectedAmount`, shows
  the running grand total until overridden).
- `buildPosSessionGuardError` wired in.

**`pos_return_screen.dart`**
- `_ReturnableLine.returnQtyCtrl` replaced with a plain `double returnQty`.
- Added a date picker (default = today, `_pickDate`/`_selectedDate`) and a
  tappable list of that date's APPROVED invoices (`_loadRecentInvoices`,
  same card layout as `pos_hold_sales_screen.dart`) shown whenever no
  invoice is loaded yet; tapping a row calls the existing `_findInvoice`.
- Manual invoice-number search kept as an explicit fallback below the list,
  now via `PosKeyboardField` instead of a bare `TextField`; a "Back to
  invoice list" link returns from a loaded invoice to the browsing view
  (fixes #8).
- Per-line Return Qty → `PosQtyStepper` (fixes the #10 overlap here too).
- `getApprovedInvoices` gained the optional `invoiceDate` parameter across
  `sales_return_repository.dart` (interface), `sales_return_repository_impl.dart`,
  and `sales_return_remote_ds.dart` (`params['invoice_date'] = 'eq.$invoiceDate'`
  only when supplied) — existing back-office Sales Return call sites
  unaffected.

**`pos_price_check_screen.dart`**
- Added a keyboard-icon button next to the search field opening
  `PosKeyboard` as an explicit manual-entry fallback; default
  scan-first/autofocus behavior unchanged (fixes #9).

**`pos_hold_sales_screen.dart`**
- `buildPosSessionGuardError` wired in (fixes #1 there too).

## Files touched
- New: `pos_numpad.dart`, `pos_amount_field.dart`, `pos_qty_stepper.dart`,
  `pos_keyboard.dart`, `pos_session_guard.dart` (all under
  `lib/features/pos/presentation/widgets/`).
- Edited: `pos_shift_screen.dart`, `pos_reports_screen.dart`,
  `pos_new_sale_screen.dart`, `pos_return_screen.dart`,
  `pos_price_check_screen.dart`, `pos_hold_sales_screen.dart`.
- Edited (additive param only): `sales_return_repository.dart`,
  `sales_return_repository_impl.dart`, `sales_return_remote_ds.dart`.
- No backend migration needed for this pass — every fix here is
  Flutter-side (UI/UX + one reporting-aggregation bug); `CASH_OUT` stays a
  valid, unused-by-UI backend value rather than being removed.

## Verification
- `flutter analyze` clean — targeted on `lib/features/pos/` +
  `lib/features/sales/`, and on the full project — confirmed after the
  implementation pass, including a follow-up fix for two title-row `Row`s
  (in `pos_numpad.dart`/`pos_keyboard.dart`) that needed an `Expanded` wrap
  per this project's own mandatory Row/Column layout self-check.
- **Not yet manually smoke-tested by the user.** Suggested walkthrough once
  deployed, mirroring the original test sequence: Device Setup → PIN Login
  → Open Shift (type an amount on the new numpad, confirm the value shown
  matches exactly what was tapped, no digit doubling) → lands directly in
  New Sale → set "×3 next scan" then scan one item, confirm qty 3 added →
  bump qty with the stepper → Charge → Shift & Cash shows 3 clearly-labeled
  movement buttons → record a Pay Out and a Cash Drop → POS Reports shows
  opening float and cash movements correctly broken out **per currency**
  (1500 CDF and 10 USD shown as two separate lines, never summed together)
  → Return screen shows today's invoices as a tappable list by default,
  picking one works exactly like the old type-the-number flow → Price
  Check's keyboard-icon fallback opens and types a SKU correctly.
