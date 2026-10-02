# Feature Checklist — what's in the POS design, what's reused, what's open

A scan-and-sanity-check view across all the docs in this folder. ✅ = fully
specified for v1. ♻️ = works already via an existing SAKAL mechanism, no new
build. ⏳ = deliberately Phase 2 (named, not forgotten). ❓ = an open item,
not yet decided.

## Login & access
- ✅ PIN-only till login, no password UI on the till at all
- ✅ Device provisioning (one-time, admin, back-office, real password)
- ✅ Device binding to a terminal, device block
- ✅ Per-terminal user access (permanent/temporary/shift-based)
- ✅ Device-scoped PIN lockout after repeated failures
- ✅ Concurrent-session policy (company-configurable)
- ✅ **Till auto-lock on idle** — folded into Phase 1 2026-10-02; PIN-pad
  overlay after `pos_idle_lock_minutes`, no session/JWT loss

## Product & pricing
- ♻️ Product catalog, barcodes (incl. per-pack-size barcode), categories, brand
- ♻️ Price Master (customer-specific and generic pricing, multi-currency)
- ♻️ Tax groups, inclusive/exclusive, exemptions
- ♻️ Batch/serial tracking with FEFO auto-allocation
- ♻️ `is_saleable`/`is_discountable` product flags
- ✅ Price snapshotted on the line — editing a product's price never rewrites history
- ✅ **Weighted products / scale integration** — folded into Phase 1
  2026-10-02 for barcode-weight parsing + manual entry; a real connected
  scale stays Phase 2 (hardware dependency)
- ✅ **Minimum selling price floor** — folded into Phase 1 2026-10-02,
  `rim_products.min_selling_price`, hard-blocked even for a supervisor override
- ✅ **Age-restricted / controlled-sale flag** — folded into Phase 1
  2026-10-02, ID-check confirmation + audit log entry
- ✅ **Quick-pick grid for unbarcoded items** — folded into Phase 1 2026-10-02,
  `rim_products.is_quick_pick` flag

## Core sale
- ✅ Scan/search, cart, qty change, remove line
- ✅ Cash/Credit toggle (Credit reuses Quick Invoice's existing engine)
- ✅ Line discount within cashier limit, override above it
- ✅ Automatic scheme/promotion application (see below)
- ✅ Bundle sale (3 modes: commercial, preassembled, dynamic mix)
- ✅ Optional customer capture by phone number for loyalty (no forced account)
- ✅ Hold / resume a sale, auto-expiry
- ✅ Sale auto-resets for the next customer (no navigation between customers)

## Promotions / schemes (all 10 types from the reference document)
- ✅ Percent off, fixed amount off, Buy X Get Y, Buy X Get a discount, fixed
  price for N qty, mix & match, slab/tiered quantity, free item, bill
  threshold, coupon code
- ✅ Deterministic priority + stacking resolution
- ✅ Usage limits (total + per customer)
- ✅ Cashier-visible explanation snapshot on the receipt

## Loyalty
- ✅ Phone-number-first enrollment, no forced customer account
- ✅ Earn / redeem / expire / return-reversal / bonus / manual adjustment,
  all as an immutable ledger
- ✅ Tier multiplier, min/max redemption rules, point expiry
- (noted, not a gap) Redeemed points are **not** auto-restored on a later
  return of that same sale — deliberate, documented, fraud-prevention choice

## Payments
- ✅ Split, multi-tender, multi-currency on one sale
- ✅ Cash, Card, Mobile Money, Voucher, Gift Card, Store Credit, Customer
  Account (credit), Loyalty Points
- ✅ Change calculation, optional change-in-a-different-currency policy
- ✅ Payment state machine (card/mobile never marked successful without confirmation)
- ⏳ Live card/mobile-money terminal API integration — v1 is a manual "mark confirmed" step
- ⏳ Full gift-card/store-credit balance lifecycle — v1 posts the GL leg only

## Finance posting (resolved 2026-10-02 — see DEC-21)
- ✅ Credit sale: mandatory, per-invoice, immediate GL (unchanged from today's Quick Invoice)
- ✅ Cash sale: stock movement real-time per invoice; Sales/Tax/COGS/settlement
  GL consolidated once at shift close (`fn_close_pos_shift`), grouped by
  currency/account/tax rate/tender method — matches Odoo's own POS accounting
  model, avoids multiplying GL row growth by every cash sale
- ✅ No report depends on GL timing — Z-report and friends read the sales/
  tender tables directly

## Returns, exchange, void
- ✅ Return against a receipt, line-level qty cap, mandatory reason
- ✅ Return without a receipt (permission-gated, supervisor-approved)
- ✅ Exchange (return + new sale in one flow)
- ✅ Void routed through Return (no separate reversal mechanism)
- ✅ Loyalty points reversed proportionally on return

## Approvals
- ✅ Real-time, at-the-counter, manager-PIN override (discount, return-without-
  receipt, high-value refund, payout-over-threshold)
- ✅ Separate async Manager Review for things that can wait (shift variance,
  a record of today's overrides)

## Shift & cash management
- ✅ Open shift with opening float (per currency), optional denomination count
- ✅ Cash-in, cash-out, payout, cash drop — any currency
- ✅ Expected-cash formula, counted cash, variance, mandatory reason, approval
  above threshold
- ✅ Immutable once closed; close also posts the shift's consolidated GL

## Offline
- ✅ Sale (Direct, Cash), hold/resume, shift open/close, cash movements
- ✅ Return, exchange, approvals — deliberately online-only (same reasoning
  as the rest of SAKAL)
- ❓ **Offline limits need real numbers** — max offline duration, max sale
  amount, which tenders are allowed offline (`11_open_decisions.md` DEC-03 is
  still open)

## Reporting & audit
- ♻️ Plugs into SAKAL's existing generic reporting engine, not a new engine
- ✅ Z-report/shift summary, sales by cashier/terminal, payment totals,
  returns, promotions, loyalty, cash variance, voids/overrides
- ✅ Append-only POS audit log (no update/delete at all)
- ⏳ Push/SMS notifications — v1 is in-app only

## Hardware (named, scoped to Phase 2 on purpose)
- ⏳ Real ESC/POS thermal printer driver (v1 prints a PDF via the existing print engine)
- ⏳ Cash drawer hardware kick
- ⏳ Connected scale (weighted products otherwise fully supported in v1 — see above)
- ⏳ Barcode scanner — works today as a keyboard-wedge device, no special code needed
- ⏳ Customer-facing second display
- ⏳ Digital receipts (email/SMS/QR)

## Deliberately out of scope (matches the original reference document)
Self-checkout, e-commerce storefront, full workforce scheduling, marketing
automation. **Not** out of scope, unlike a from-scratch POS vendor would
assume: full accounting/GL, full inventory/warehouse, full procurement — SAKAL
already has all three, and POS reuses them directly rather than rebuilding a
lightweight version.

## Summary
Every item flagged ❓ in the previous pass has been resolved and folded into
Phase 1, except offline limits (DEC-03), which is the one remaining number
only the user can set.
