# Screen Map & Responsive Mockups

## Target devices (researched, see `00_index.md` context)
| Class | Width | Notes |
|---|---|---|
| Handheld companion | 360-480px | Not primary v1 hardware; mockups still verified down to this width since a supervisor's phone may open Approvals/Price Check |
| Tablet | 768-1024px | Mobile-companion checkout, price check, supervisor approvals |
| Primary cashier touchscreen | 1366x768 and 1920x1080 landscape | The real target — a 15"-15.6" fixed till, large tap targets, high contrast |
| Customer-facing display | 480-800px landscape, read-only | Running basket + total only, no input controls |

## Screen map (all 12, reference BRD Appendix C)
| # | Screen | Audience | Mockup file | Artifact |
|---|---|---|---|---|
| 1 | Login | All users | `mockups/01_login.html` | https://claude.ai/artifact/TNUj8mepuQByzaCZkSv9GY |
| 2 | POS Home | Cashier | `mockups/02_pos_home.html` | https://claude.ai/artifact/JNMT1bmRxpGAUDx9AdCjbM |
| 3 | New Sale | Cashier | `mockups/03_new_sale.html` | https://claude.ai/artifact/W7v7jTccT8oNW11UijytmA |
| 4 | Payment | Cashier | `mockups/04_payment.html` | https://claude.ai/artifact/7YpRzYagXogbbddfZf6TNK |
| 5 | Hold Sales | Cashier/Supervisor | `mockups/05_hold_sales.html` | https://claude.ai/artifact/3c9A9wWLPnLVpRwvUncrEz |
| 6 | Sales History | Cashier/Supervisor | `mockups/06_sales_history.html` | https://claude.ai/artifact/TNHqaPVijhTQkSTGs8u9Xr |
| 7 | Return | Cashier/Supervisor | `mockups/07_return.html` | https://claude.ai/artifact/1Mq1mC5RybhBZNCcsueGg3 |
| 8 | Price Check | Cashier | `mockups/08_price_check.html` | https://claude.ai/artifact/JU1hneraaHsKKkRf7ugqzz |
| 9 | Shift/Cash | Cashier/Supervisor | `mockups/09_shift_cash.html` | https://claude.ai/artifact/S8TkuJLY97qCTcVtDXdjAB |
| 10 | Approvals | Supervisor/Manager | `mockups/10_approvals.html` | https://claude.ai/artifact/6gKFFiSEj9V6WhT82GmnS8 |
| 11 | Admin | Admin/Manager | `mockups/11_admin.html` | https://claude.ai/artifact/VNn3ZsBdwyopb9HGLLtygB |
| 12 | Reports | Manager/Finance/Admin | `mockups/12_reports.html` | https://claude.ai/artifact/2j72dsfU5G4mCUzNg33eg8 |
| 13 | Supervisor Override (at-counter modal, not a standalone screen) | Cashier + Supervisor, same device | `mockups/13_supervisor_override.html` | https://claude.ai/artifact/JNJR4rfrhjMTxwdUhfAxuJ |
| 14 | Till Idle Lock (modal, not a standalone screen) | Cashier, same device | `mockups/14_idle_lock.html` | https://claude.ai/artifact/XXYnRxVYu7p5mgX1gLiSDn |

Note: four artifacts (Held Sales, Sales History, Price Check, Shift &amp; Cash)
display their title from the HTML `<title>` tag rather than the `title`
parameter passed at publish time — e.g. "Held Sales" instead of "POS Held
Sales" — both read unambiguously; left as-is.

## Revision 2026-10-01 — user walkthrough feedback, fixed in the mockups + docs
1. **Login has no keyboard on a touchscreen till.** Split into two tiers: a
   rare device-level username/password login (binds the device), and a
   frequent cashier-level 4-6 digit PIN on a big numeric keypad (new
   `rim_users.pin_hash` + `fn_pos_pin_login`, see `06_access_security.md` §4).
2. **A cashier should never have to tap "New Sale" every time.** Login lands
   directly on New Sale; completing a sale resets it in place for the next
   customer; Home is an optional menu reached via a persistent nav rail now
   shown on every cashier screen, not a required stop.
3. **Credit sales were documented but missing from the mockups.** New Sale
   now has the same Cash/Credit toggle Quick Invoice already has; Payment now
   lists Customer Account as a tender method.
4. **Approval was ambiguous — one screen tried to do two jobs.** Split into
   (a) a real-time, blocking modal on the cashier's OWN device for anything
   that needs a yes/no right now (new mockup #13, Supervisor Override), and
   (b) "Manager Review" (renamed from "Approvals Queue"), opened from a
   manager's own device, for the small set of things that can wait (a shift's
   cash variance, a record of today's overrides). See
   `05_returns_exchange_void_approvals.md` §0.

## Revision 2026-10-02 — PIN-only till, user feedback
1. **No password anywhere on the till.** Login (#1) dropped its password
   fallback entirely — "forgot PIN" now routes to a manager reset, never a
   password box. Device provisioning (the one place a real username/password
   is still used) moved to the back-office admin screen, outside the POS
   surface. New `rim_users.pin_hash`, `fn_pos_pin_login`, `fn_set_user_pin`
   (collision-checked for uniqueness per company), and device-scoped PIN
   lockout — see `06_access_security.md` §4.
2. **Supervisor Override (#13) now uses a manager PIN keypad**, not username/
   password — consistent with the till having no password UI at all. A badge/
   QR scan alternative is noted as a Phase 2 option.
3. **Cash In/Cash Out confirmed already in scope**, any currency — no mockup
   change needed; see `rih_pos_payouts` in `01_data_model.md` §2 and the
   Shift &amp; Cash mockup's (#9) existing four-button row.

## Revision 2026-10-02 — five gaps folded into Phase 1, finance posting resolved
1. **Till idle-lock** (new mockup #14) — PIN-only re-verification overlay
   after `pos_idle_lock_minutes`, session/cart untouched.
2. **Weighted products, min-price floor, age-restricted confirmation, and the
   quick-pick grid** — all added to New Sale (#3): a quick-pick strip under
   the scan bar, a weighed line example, and an age-restricted line with its
   ID-verified tag. See `01_data_model.md` §1a and
   `02_pricing_promotions_loyalty.md` for the full design (all five add zero
   new tables).
3. **Finance posting for cash sales is consolidated at shift close**, not
   per invoice — matches Odoo's own POS accounting model, resolved as
   DEC-21 in `11_open_decisions.md`; see `03_payments_multicurrency.md` §4
   and `04_shift_cash_management.md`'s Close step. Credit sales are
   unaffected. No mockup change needed — this is a backend posting-timing
   decision invisible to the cashier.

Each mockup is a standalone, self-contained HTML file (no build step — open
directly in a browser) styled with SAKAL's existing brand tokens (`#1B3A6B`
Deep Navy / `#D4860B` Amber Gold / `#2E7D32` positive / `#C62828` negative)
but with POS's own larger-tap-target, higher-contrast treatment suited to a
shop-floor touchscreen rather than the denser back-office density. Admin and
Reports intentionally look closer to SAKAL's existing back-office density
(they're expected to mostly reuse existing screens/the reporting engine, per
`10_phase_plan.md`), while the other 10 use the POS-specific touch-first look.

## Artifact links
Filled in immediately below as each mockup is published — see the end of
this document for the final list once all 12 are live.
