# Payments & Multi-Currency Tender

## 1. Payment methods (v1)
Cash, Card, Mobile Money, Voucher, Gift Card, Store Credit, Customer Account
(credit sale to a real `rim_accounts` customer — reuses Quick Invoice's
existing CREDIT `sale_type` unchanged), Loyalty Points (see
`02_pricing_promotions_loyalty.md`). Each is a `rid_pos_tender_lines.tender_method`
value (`01_data_model.md` §2) — adding a new method later is one more CHECK
value plus, if it needs its own GL clearing account, one more
`rim_account_link_types` row; no schema change.

## 2. Split, multi-currency tender
One sale -> many `rid_pos_tender_lines` rows, each its own `tender_method` and
`currency_id`. Example (matching the reference BRD's worked case): a 282,500
CDF invoice paid 200 USD cash + 50,000 CDF cash + a 20,000 CDF voucher —
three tender lines, `tender_amount`/`currency_id` as typed, `exchange_rate`
and `base_equivalent_amount` resolved per line via `fn_get_exchange_rate`
(never a single invoice-wide rate reused across currencies — the exact
mistake Contra Voucher's own rate redesign fixed for a 2-currency transfer,
generalized here to N tender lines).

Validation at save (`fn_save_sales_invoice`, additive): `SUM(base_equivalent_amount)
across all tender lines >= grand_total's base equivalent` (not `==`, since
cash tenders routinely overpay for change) — rejects underpayment outright
(matching Quick Invoice's own existing "no partial collection" rule, extended
from one pair of fields to N tender lines summed).

### Change
Change is always returned in the **invoice's own currency** by default
(`change_given_currency_id` defaults to the invoice currency); a company
policy flag (`ric_companies.pos_allow_change_in_foreign_currency`, new,
default false) lets a cashier instead give change in whichever currency is
on hand (e.g. a DRC drawer routinely gives CDF change on a USD cash tender) —
when used, `change_given_amount`/`change_given_currency_id` on the CASH
tender line record exactly what left the drawer, so the cash-up formula in
`04_shift_cash_management.md` can net it correctly per currency.

## 3. Payment state machine
```
PENDING -> PROCESSING -> SUCCESS | FAILED | CANCELLED
SUCCESS -> REFUNDED | REVERSED   (via a Sales Return's own refund tender line)
```
Cash/voucher/loyalty tender lines go straight to `SUCCESS` (no external
confirmation step needed). Card/mobile-money tender lines stay `PENDING` /
`PROCESSING` until a real payment-terminal integration confirms them — **the
POS must never mark a card/mobile line `SUCCESS` merely because a request was
sent**; v1 ships this as a manual "mark as confirmed" step by the cashier
(the physical card terminal is a separate device the cashier operates and
confirms against, same as most small-retail POS deployments today) — a real
API integration (Stripe Terminal, a local mobile-money gateway) is a named
Phase-2/hardware-integration item, not a v1 blocker, consistent with the ESC/
POS printer driver being phased the same way.

## 4. GL posting — CREDIT stays per-invoice; CASH is consolidated at shift close
Confirmed with the user, and matching how Odoo POS actually works (checked
directly, not assumed): a `pos.order` posts its stock move immediately but
does **not** create a journal entry per order — Odoo aggregates the whole
session into a small number of journal entries when the session closes, by
payment method and tax rate. Only an explicit customer invoice (the credit-
sale case) gets its own, individual journal entry. SAKAL POS follows the same
split, and for the same reason: a cash sale creates no receivable to track
individually, so there is nothing a per-invoice GL entry buys that a shift-
level consolidated one doesn't, while the per-invoice version costs real
`rid_finance_lines` row growth multiplied across every till, every day,
forever (a till doing ~300 cash sales/shift would post roughly 3,000 finance-
line rows per shift under the old per-invoice design; consolidated, the same
shift posts on the order of 40-80 rows — see `04_shift_cash_management.md`'s
Close step for the mechanism).

- **CREDIT sale_type** (Customer Account) is **unchanged from today's Quick
  Invoice behavior** — `fn_approve_sales_invoice` posts the full Customer DR /
  Sales CR / Tax CR / COGS voucher set immediately, exactly as now. This path
  never touches `rid_pos_tender_lines` or shift consolidation at all.
- **CASH sale_type, when `pos_shift_id` is set**: `fn_approve_sales_invoice`
  still calls `fn_post_stock_movement` immediately (stock accuracy, batch/
  serial, negative-stock checks are never deferred) but **skips posting any
  Sales/Tax/COGS/settlement voucher at all**. `rid_pos_tender_lines` is
  written and the invoice is `APPROVED`, but no `rih_finance_headers` row
  exists for it yet.
- **At shift close**, a new `fn_close_pos_shift` aggregates every CASH
  invoice (and any return) belonging to that shift:
  - Sales + Tax, grouped by `(currency, sales GL account, tax rate)` — one
    Sales voucher per currency actually used that shift (same pattern as
    GRN/Purchase Bill's own "a voucher can only have one trans_currency"
    rule).
  - COGS, grouped by `(currency, COGS account)`, summing the exact per-unit
    cost already locked in by each sale's own real-time stock movement — no
    recomputation, no loss of cost granularity, just one posting instead of
    many.
  - Settlement (the Dr leg), grouped by `(currency, tender_method)` straight
    from `rid_pos_tender_lines`'s own totals for the shift — **CASH** to the
    shift's cash account (the same number the cash-up formula already
    computes, by construction), **CARD/MOBILE_MONEY** to that method's own
    clearing account (`CARD_CLEARING_ACCOUNT`/`MOBILE_MONEY_CLEARING_ACCOUNT`,
    new `rim_account_link_types` rows, resolved via
    `fn_resolve_company_account_link` — no product anchor, same pattern as
    `EXCHANGE_GAIN_LOSS_ACCOUNT`), **VOUCHER/GIFT_CARD/STORE_CREDIT** to their
    own liability accounts, **LOYALTY_POINTS** posts no settlement leg at all
    (it already reduced `grand_total` before tender lines were summed).
  - Every voucher is tagged `source_doc_type='POS_SHIFT'`,
    `source_doc_no=shift_no` — drilling from one cash invoice to "its own"
    GL entry isn't possible anymore (same trade-off a physical Z-tape always
    implied); drilling from a SHIFT to its GL entries is exactly as direct as
    before. No report built in this design depends on GL timing — the
    Z-report and every other POS report read `rih_sales_invoices`/
    `rid_pos_tender_lines` directly, never the GL, so "today's sales so far"
    is accurate in real time regardless of when the GL entry posts.
  - A cash return processed mid-shift nets into the CURRENT shift's own
    close, never retroactively into the original sale's (possibly already
    closed) shift.
- **This is the only mode for v1** — not a company-configurable toggle. Two
  parallel posting paths would cost more to build than the value of a choice
  nobody's asked for yet; add a toggle later only if a real need appears.

Bank Reconciliation (already built, migration 174-176) is still the natural
place a later settlement batch reconciles the card/mobile-money clearing
account against the real bank/payment-provider statement — no new
reconciliation mechanism needed, same as before.

The composed vouchers from `fn_close_pos_shift` are tagged the same way
`fn_post_voucher` already tags every auto-posted voucher, so the existing
permission-composition guard (migrations 111/113/114) exempts them from
requiring unrelated Payment/Receipt Voucher permission automatically — gated
instead by `POS-SHIFT`'s own `approve_allowed` (see `06_access_security.md`).

## 5. Reconciliation
`rid_pos_tender_lines` is the one table a shift's tender-method totals,
currency totals, and card/mobile terminal references all read from — the
Z-report (see `08_reporting_audit.md`) sums it directly; no separate
payment-summary table needed.
