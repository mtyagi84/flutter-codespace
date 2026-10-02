# Open Business Decisions

Adapted from the reference BRD's §35, trimmed to what this session didn't
already resolve, with a recommended SAKAL-consistent default for each —
confirm or override before implementation starts.

| ID | Decision | Recommended default | Why |
|---|---|---|---|
| DEC-01/02 | Tax rounding order, inclusive vs. exclusive | Reuse the existing `rim_taxes.is_price_inclusive` per tax, unchanged — no new POS-specific tax behavior | Already a solved, per-deployment setting |
| DEC-03 | Offline limits (duration, amount, allowed tenders, loyalty redemption, credit sales) | Max 24h offline, no cap on amount (same as Quick Invoice today), cash/voucher/loyalty-earn allowed offline, loyalty **redemption** and CREDIT sale type **not** allowed offline | Matches existing Quick Invoice offline scope; redemption/credit both need a live check |
| DEC-04 | Do held sales reserve stock? | No | Matches reference BRD's own recommendation and SAKAL's existing "DRAFT never affects books" principle |
| DEC-05 | Return-without-receipt policy | Permission-gated (`SL-RET-NOREF`), refund at current selling price, always requires supervisor approval | Safest default; a business can loosen later |
| DEC-06 | Refund method policy | Default to original tender method; store credit as a fallback | Matches most POS norms (Odoo/Square) |
| DEC-07 | Cash variance threshold | A configurable flat amount per currency, company-level (e.g. 50 CDF / 1 USD equivalent); **user must confirm the actual number** | No sensible universal default — depends on the business's own risk tolerance |
| DEC-08 | Payout approval threshold | A configurable flat amount per currency, company-level; **user must confirm the actual number** | Same as above |
| DEC-09 | Promotion stacking policy | `is_stackable` per scheme, resolved by `priority` (see `02_pricing_promotions_loyalty.md` §2) | Already specified; flagged here only to confirm the business is happy with "explicit opt-in stacking" rather than "stack everything by default" |
| DEC-10 | Loyalty qualification basis | Post-discount, pre-tax (`earn_basis='POST_DISCOUNT'`) | Common retail convention; avoids earning points on tax |
| DEC-11 | Point expiry policy | Configurable months, default 12; expired points are not recoverable | Standard loyalty-program norm |
| DEC-12 | Concurrent POS sessions | Disallowed by default (`pos_allow_concurrent_sessions=false`) | Safer default for a cash-handling context |
| DEC-13 | Device replacement process | Admin unbinds the old device, blocks it, binds the new one to the same terminal — no automatic inheritance | Matches the explicit, auditable device-binding design in `06_access_security.md` |
| DEC-14 | Credit sales in Supermarket POS | Supported (reuses Quick Invoice's existing CREDIT `sale_type`) but **online-only** | Already technically possible; just confirming it's wanted at the till, not just back-office |
| DEC-15 | Gift card / store credit | GL leg only in v1 (liability account, no balance-tracking UI yet); full gift-card lifecycle (issue, partial redeem, balance check) is Phase 2 | Keeps v1 scope bounded while still letting it be used as a tender type today |
| DEC-16 | Hardware integrations | Phase 2/8 (see `10_phase_plan.md`) — no specific scanner/printer/drawer/scale model chosen yet | **User to confirm actual hardware** once a pilot store is chosen |
| DEC-17 | Invoice numbering policy | Reuse the existing per-location `SI/{LOC}/{YYYY}/{SEQ}` scheme, unchanged — a POS sale is still a Sales Invoice | No reason to diverge from what already works |
| DEC-18 | Receipt channels | Print (PDF via `PrintEngine`) in v1; email/SMS/QR digital receipt is Phase 2 | Matches the printing roadmap in `00_index.md`/CLAUDE.md |
| DEC-19 | Multi-store pricing | Reuses `fn_get_active_price`'s existing location-aware Price Master — no new mechanism | Already solved |
| DEC-20 | Security policy (PIN length, lockout, session timeout, offline grace) | **Superseded 2026-10-02**: the till is PIN-only (no password UI at all, see `06_access_security.md` §4), PIN-set collision-checked per company, lockout is device-scoped (not user-scoped), idle-lock at a configurable `pos_idle_lock_minutes` (default 3); offline grace = 24h (DEC-03) | User-driven redesign — PIN-only is both simpler and more appropriate for a touchscreen till than password login |
| DEC-21 | Finance posting for cash sales | **Resolved 2026-10-02**: consolidated at shift close (`fn_close_pos_shift`), not per invoice — see `03_payments_multicurrency.md` §4 and `04_shift_cash_management.md`. Credit sales are unaffected (still mandatory, per-invoice, immediate) | User-specified, matches Odoo's own POS accounting model; avoids multiplying `rid_finance_lines` row growth by every cash sale |
