Status: Implemented 2026-09-26 (not yet committed/deployed). Notes: `SakalFieldCard` gained `onTap`/`focusNode` (card owns the InkWell so it can draw the focus ring) instead of the planned `focusable` flag — an InkWell wrapped outside the card never put focus inside the card's own Focus node.

# Contra Voucher — read-only system-rate strip, computed exchange/transfer difference, focus/layout fixes

## Context

User reported five issues on the Contra Voucher (Finance) and asked for a discussion of how the
form should work, benchmarked against accounting standards/Odoo/Tally rather than just agreeing
with their proposal. Verified from the actual code + a live query of the posted voucher:

- The unlabelled field at the top ("1 USD = ? CDF" is literally its label text) is NOT the rate
  between the two selected accounts. It is the FROM currency's base/local conversion rate, editable,
  and used only to stamp `base_amount`/`local_amount` on the 3 lines. Every line shares it, so the
  voucher always balances whatever is typed, and nothing visible changes -- hence "changing it does
  nothing".
- The rate that actually drives the To-amount suggestion and the difference row is a SECOND, hidden
  rate (`_fromToRate`, FROM->TO cross rate fetched from the Exchange Rates master). It is never shown.
- The difference row is computed correctly (`gap = From - To/rate`, DR when received less, CR when
  more) but in the FROM currency with no currency label -- for 282,500 CDF -> 95 USD it shows 14,125
  (CDF), not 5 (USD).
- Why the posted CTR/HO/2026/00001 has only 2 rows: 282,500 CDF -> 100 USD is exactly the system
  rate (1 USD = 2,825 CDF), gap = 0, so no third row is created -- correct behavior. The 1500 typed
  into the Transfer Charge box in the other screenshot is never read at save (`chargeAmt` is rebuilt
  from `_gap`), so a manually typed charge is silently dropped.
- Two further real bugs: a missing exchange rate silently becomes 1 (`r ?? 1`), so a voucher can post
  at 1 USD = 1 CDF; and the date fields never draw a focus ring (`SakalFieldCard` only draws it when
  `editable`, and the date pickers are read-only cards wrapped in an InkWell).

## Decisions confirmed by the user

1. **Booking method B**: both legs at the SYSTEM rate (Exchange Rates master), the difference vs the
   actual amount typed is posted to P&L immediately (Tally / Odoo-exchange-difference / IAS 21 spot
   recognition). Rejected alternative: book at actual rate + rely on period-end revaluation (SAKAL has
   no revaluation, so foreign bank base values would drift forever).
2. Difference displayed in **the two transfer currencies** (From and To); base shown additionally only
   when base is a third currency.
3. Keep **one combined Exchange Gain/Loss account** (`EXCHANGE_GAIN_LOSS_ACCOUNT` link, as Purchase
   Bill/Cash Receipt already do). No chart/seed change; Forex Gain account is a possible later item.
4. The system rate is **read-only** (user's proposal, agreed): the rate master is the control point.

Direction check answered: receiving account Dr, paying account Cr (FROM=Cr, TO=Dr) -- already how the
screen works.

## Part A -- Rates and difference (front-end only; NO backend/migration change)

File: `lib/features/finance/presentation/screens/contra_voucher_entry_screen.dart`
(+ small pure helper file for testability, `contra_voucher_math.dart` in the same feature).

Posting model is unchanged and already correct: voucher `trans_currency` = FROM currency; TO line is
`trans_amount = To / rate` with `party_amount` = the literal To amount; the optional third line is the
difference in FROM currency. All three balance exactly in both trans currency and `base_amount`
(worked example, voucher in CDF: Dr USD bank 95 USD [268,375 CDF, base 95.00]; Dr Exchange loss
[14,125 CDF, base 5.00]; Cr CDF bank 282,500 CDF [base 100.00]). Same shape for a gain (To 102 ->
Cr exchange gain 2.00 USD).

1. **New read-only "Exchange Rate" strip**, placed directly under Reference No / Reference Date, with a
   proper label. Shown only when both accounts are picked and currencies differ: system rate in human
   orientation ("1 USD = 2,825.00 CDF"), the actual implied rate + % deviation, and a non-blocking
   amber warning past ~5%. Hidden for same-currency transfers.
2. **Remove the editable top base/local rate field(s)**. `_baseRateCtrl`/`_localRateCtrl` stay as
   internal, silently fetched and never user-editable.
3. **Missing rate blocks the save**, never defaults to 1, with a message pointing to Finance -> Exchange
   Rates. `_fromToRate` refreshed on From select, To select, swap and date change.
4. **Difference row = computed, read-only amount; only the account is editable.** Appears automatically
   when |gap| > 0.01; manual "Add Transfer Charge" button and typed-amount path removed (eliminates the
   silently-ignored typed charge). Title by sign (Exchange Loss / Transfer Charge, Exchange Gain, or
   Transfer Charge for same-currency). Amount shown in both transfer currencies. Default account =
   `EXCHANGE_GAIN_LOSS_ACCOUNT` for different currencies; none for same currency. To-amount auto-suggest
   kept, plus a "Reset to system rate" action once To was manually edited.

## Part B -- UX fixes

1. Initial focus -> Reference No; Tab/Enter to Reference Date; after the date is picked, focus continues
   to the From account.
2. Top margin: scroll body padding top 0 -> 16.
3. Visible focus ring on Reference Date / Voucher Date: opt-in `focusable` flag on `SakalFieldCard`.
4. Label + position of the rate field: covered by Part A.1.

## Out of scope
- Month-end revaluation of foreign-currency bank balances (unrealized gain/loss).
- Separate Forex Gain income account/link type.
- Top-margin fix on the other Finance voucher screens.

## Tests / verification
- Pure helpers extracted into `contra_voucher_math.dart` with unit tests using the worked numbers
  (282,500 CDF -> 95 USD = loss 14,125 CDF = 5.00 USD; -> 102 USD = gain 2.00 USD; exact 100 -> none;
  same currency 100 -> 98 = fee 2).
- `flutter analyze` clean; manual scenarios per the approved plan.
