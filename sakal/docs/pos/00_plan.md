# SAKAL POS (Supermarket) — Requirements, Data Model, Workflows & Screen Designs

Status: Implemented 2026-10-01 — all 12 linked docs, the 00_index, and all 12 HTML mockups (each also published as a Claude Artifact) are written. See `00_index.md` for the reading order and `09_screens_and_mockups.md` for the Artifact links. No Flutter/SQL code has been written yet — that's the next, separate phase once these are reviewed.

## Context

SAKAL is adding Point-of-Sale as a new module family inside the existing app:
Supermarket POS first, Restaurant POS later (shares the same terminal/shift/
tender/loyalty backbone, adds a table/order/kitchen-ticket layer this plan does
not cover). **This is built by us, in this codebase, directly -- not handed off
to an external coding agent.** The deliverable is therefore internal project
documentation plus reviewable screen designs, written at the level of detail
CLAUDE.md already expects for a new module (see its "Plan-mode plans" and
"Adding a new module" conventions), not an onboarding document for someone with
zero context.

The user supplied a generic, very thorough reference BRD
(`sakal/docs/Supermarket_POS_BRD_Flutter_Supabase_Codex.docx`, extracted and
read in full -- 36 sections covering scope, roles, org/POS structure, access,
device security, pricing/tax/discount engine, promotions, bundles, loyalty,
payments/multi-currency, held sales, returns/exchange, void/approval, shift/
cash management, payouts, inventory integration, offline sync, reporting,
audit, non-functional requirements, a conceptual data model, workflows,
acceptance criteria, phase plan, and a screen map). It assumes a blank Supabase
project. **All of its scoped business areas are in scope for v1** (the user
confirmed: full scope, no Phase-2 deferral this time -- loyalty, schemes,
bundles, multi-currency split tender, shift/cash management, all included
now), and **all 12 screens from its Appendix C get full responsive HTML
mockups**, not just a cashier-critical subset.

Two research passes (Explore agents, already run) confirmed what SAKAL already
has vs. what's genuinely new:
- **Nothing POS-shaped exists today** -- no shift/till/cash-up/day-close/
  loyalty/scheme/bundle/hold-sale/device-binding concept anywhere. The one
  forward-reference is in `pdf_flow_renderer.dart`: real ESC/POS thermal output
  is "deferred until a POS screen exists to drive it."
- **The direct ancestor is "Quick Invoice"** (migrations 088-090,
  `sales_invoice_entry_screen.dart`, `docs/screens/sales_invoice.md`) -- a
  cash-first, auto-approve-on-save sales screen with FEFO batch/serial
  auto-allocation, discount governance (`ric_user_sales_controls`), tax
  groups, charges, and a per-user cash-account config
  (`ric_user_quick_invoice_setup`). POS sales will be `rih_sales_invoices`
  rows (reusing its engine), tagged with a new `pos_shift_id`; POS returns
  reuse Sales Return (migration 099) the same way.
- Full reuse inventory (tenancy, permissions, products/pricing, tax,
  currency/exchange rates, account-link framework, offline `SyncEngine`,
  the generic reporting engine, Sales Return/Delivery) is already compiled
  from this session's research -- listed in the deliverable's own appendix
  rather than repeated here.
- **Loyalty clarification from the user**: a POS sale does NOT need to resolve
  to a real `rim_accounts` customer to track loyalty -- the cashier asks for a
  mobile number only if the customer agrees to share it. Loyalty is keyed off
  a lightweight phone-number-identified profile, independent of whether a
  full customer account exists.
- **Standard POS monitor sizes researched** (for the responsive screen
  designs): handheld/mobile POS 5"-6" (Clover Flex, Square Terminal); tablet
  POS 8"-12.1" (Toast Go 2, Square Stand 9.7", general tablet sweet spot
  10.1"-12.1"); fixed single-screen countertop 15"-15.6" is the most common
  (resolution 1280x1024 or 1366x768 @ 16:9, Full HD 1920x1080 increasingly
  common); fixed dual-screen setups pair a 14"-15.6" cashier display with a
  7"-10.1" customer-facing display (e.g. Clover Station Duo: 14"+8"); larger
  21.5" Full HD all-in-ones exist for bigger counters. The HTML mockups will
  target concrete breakpoints derived from this: ~360-480px (handheld
  companion), ~768-1024px (tablet, portrait and landscape), ~1366x768 and
  1920x1080 landscape (primary cashier touchscreen), plus a narrow
  ~480-800px customer-facing display variant (read-only running total/basket).

## Deliverable (produced in this codebase, kept separate from any other
module's plan/doc files -- nothing here touches `contra_voucher.md` or the
Contra Voucher plan)

New folder: **`sakal/docs/pos/`**, split into focused linked files (per the
user's own "do whatever you feel like" -- splitting is the right call given
the size of the source material) plus a mockups subfolder:

1. `00_index.md` -- scope, how this module relates to Quick Invoice, phasing,
   links to every file below, and the "already built vs. net-new" summary.
2. `01_data_model.md` -- every new table (full column lists, under the existing
   `client_id/company_id/location_id` tenancy + `auth_rw_<table>` RLS
   convention): `ric_pos_terminals`, terminal/user assignment (extends
   `ric_user_quick_invoice_setup` or a sibling access table mirroring
   `ric_user_location_access`'s shape), `rih_pos_shifts` +
   `rid_pos_shift_denomination_counts`, `rid_pos_tender_lines` (multi-currency
   split tender), `rih_pos_payouts` (cash-in/out/payout/drop unified with a
   `movement_type`), `rih_sales_invoices.pos_shift_id` + a `HELD` status for
   hold/resume, `rim_loyalty_programs` / `rih_customer_loyalty_profiles`
   (phone-number-keyed, optional real customer link) / `ril_loyalty_ledger`
   (append-only, mirrors `ril_stock_ledger`'s "ledger is truth" principle),
   `rim_pos_schemes` / `rim_pos_scheme_rules` (percent/amount/BXGY/fixed-price/
   mix-match/slab/free-item/time-window/customer-tier/coupon/bill-threshold),
   `rim_product_bundles` / `rim_bundle_components` (commercial/preassembled/
   dynamic-mix modes). Every table explicitly says which existing SAKAL table
   it extends vs. replaces vs. is brand new next to.
3. `02_pricing_promotions_loyalty.md` -- the deterministic pricing/discount/
   tax/rounding sequence (reusing `fn_get_active_price`/tax group machinery),
   the promotion engine's deterministic overlap/priority/stacking rule, bundle
   explosion into components for stock+GL, and the full loyalty rule
   configuration plus earn/redeem/expire/reverse/adjust ledger design.
4. `03_payments_multicurrency.md` -- split multi-tender design (reusing
   `rim_currencies`/`fn_get_exchange_rate`), payment state machine, voucher/
   gift-card/store-credit as tender types.
5. `04_shift_cash_management.md` -- shift lifecycle (OPEN -> CASH_UP_PENDING ->
   CLOSED), opening float, expected-cash formula, denomination cash-up,
   variance plus supervisor-approval (modeled on `fn_verify_discount_override`),
   cash-in/out/payout/drop.
6. `05_returns_exchange_void_approvals.md` -- POS return/exchange reusing
   Sales Return's engine, void/cancel rules, the full approval-record shape.
7. `06_access_security.md` -- POS user/terminal/device access model: how it
   maps onto `ric_master_menus`/`ric_user_menus` (new feature codes),
   `ric_user_location_access`, and a new device-registration/binding table
   (nothing like this exists today) -- permanent/temporary/shift-based
   assignment, concurrent-session policy, device block.
8. `07_offline_sync.md` -- extends `SyncEngine`/`generateLocalId()`/Drift cache
   exactly like Quick Invoice, but widens "approve stays online-only" to cover
   shift open/close too (a new consideration Quick Invoice never needed).
9. `08_reporting_audit.md` -- Z-report/shift/cashier/promotion/loyalty reports
   plugged into the existing generic reporting engine (migration 116); audit
   trail reusing `AppLogger` plus a dedicated POS audit table for sensitive
   money/stock/access actions.
10. `09_screens_and_mockups.md` -- the screen map (all 12 from the source
    BRD's Appendix C), responsive breakpoints from the monitor-size research
    above, and a table linking each screen to its mockup file + published
    Artifact URL.
11. `10_phase_plan.md` -- delivery phases adapted from the source BRD's
    Phase 0-8, explicitly marking which phases are mostly "already built in
    SAKAL" (tenancy/RLS/auth/tax/pricing/currency = Phase 0 is largely done)
    vs. genuinely new work.
12. `11_open_decisions.md` -- the source BRD's 20 open business decisions,
    trimmed to the ones not already answered by this session (tax rounding,
    offline limits, cash variance threshold, promotion stacking policy, etc.)
    for the user to resolve before implementation starts.

**Mockups**: `sakal/docs/pos/mockups/` -- 12 standalone, responsive HTML files
(Login, POS Home, New Sale, Payment, Hold Sales, Sales History, Return, Price
Check, Shift/Cash, Approvals, Admin, Reports), styled consistently with
SAKAL's existing brand (`AppColors` -- Deep Navy `#1B3A6B` / Amber Gold
`#D4860B`, per `CLAUDE.md`'s Theme & Brand section) but with POS's own
larger-tap-target, high-contrast-for-a-shop-floor treatment, each tested at
the breakpoints above. Each one is also **published as a Claude Artifact** for
an instant clickable preview (no dev server needed) -- the mockups in the repo
are the source of truth for the real Flutter implementation later; the
Artifacts are a reviewable copy of the same content.

## What this plan does NOT do

No Flutter or SQL code is written in this task -- this is the requirements +
design phase CLAUDE.md expects before a new module's screens get built (see
its "Adding a new module" workflow). Actual implementation (migrations, Drift
tables, screens) is a distinct, later effort once this documentation and the
mockups are reviewed and approved.

## Verification

After writing: re-read `09_screens_and_mockups.md` against `01_data_model.md`
for consistency (every field a mockup shows must exist in the data model),
open each published Artifact once to confirm it renders correctly at a
touch-target-appropriate size, and give the user the `docs/pos/00_index.md`
entry point plus the 12 Artifact links.
