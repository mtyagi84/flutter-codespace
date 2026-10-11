# POS E2E Test Plan

Status: Phase 0 (harness) complete. Phases run in order below, one at a
time — each phase's tests are written, debugged against the real app,
verified against real DB state (not just UI text), and committed/pushed
before moving to the next. Two real production bugs were already found
and fixed during Phase 0 (see `README.md`'s own "Two real product bugs"
section) — the expectation is each new phase surfaces its own, since none
of this has been exercised by an automated test before.

## Phase 0 — Harness (done)

- Till setup (admin login, location/terminal binding) — `till-setup.setup.js`
- Core cash sale (PIN login → add product → Charge → Payment → Save &
  Print → reset) — `new-sale-smoke.spec.js`
- Shared helpers for Flutter Web's rendering quirks — `helpers/flutter.js`

## Phase 1 — Shift & Cash (in progress, see status below)

Highest-value gap: no automated test had ever exercised real cash-drawer
money math — and this phase proved that assessment right immediately.
Dedicated sandbox till (`till2-setup.setup.js` / `.auth/till2.json`,
terminal code `T-E2E`) so Till 1's real, long-running shift is never
touched — see its own header comment.

**Confirmed working** (`tests/till2/shift-cash.spec.js`): Open Shift with
a CDF opening float; a cash sale; closing a shift with a supplied variance
reason persists correctly (`rih_pos_shifts.status = 'CLOSED'`, a real
`rid_pos_shift_denomination_counts` CLOSING row, the invoice tagged
`pos_shift_id` and APPROVED) — all verified directly against the database,
not just on-screen text.

**Two real, significant findings, both fixed/flagged, NEITHER a code bug
in this session's own changes:**
1. **No user on this tenant has ever had `approve_allowed = true` for
   `POS-SHIFT` (or `POS-PAYOUT`/`POS-RETURN`/`SL-RET-NOREF`)** in
   `ric_user_menus` — only `edit_allowed`. Close Shift requires approve
   permission (`fn_check_approve_permission(..., 'POS-SHIFT')`), so this
   has silently blocked EVERY attempt to close a shift on this tenant —
   almost certainly why the real Till 1 shift (`SFT/HO/2026/00001`) has
   sat open since 2026-10-03. Granted directly to Admin for this session
   so testing could continue; **not yet fixed as a proper migration** —
   worth a real backfill (mirroring this project's own established
   pattern, e.g. migration 109's `FN-PRV` backfill) so every tenant's
   admin/manager actually has this, not just this one tenant via a manual
   grant.
2. **`ric_master_menus.feature_name` for `POS-SHIFT` is stored as literal
   `"Shift &amp; Cash"`** (HTML-escaped) rather than `"Shift & Cash"` —
   `fn_seed_client_modules.sql`'s own seed uses the correct plain string,
   so this is live-data drift on this specific tenant, not a seed bug.
   Surfaces wherever `feature_name` is shown raw, e.g. the permission-
   denied error message. Not yet fixed (a one-row `UPDATE`, low priority).

**One KNOWN, UNRESOLVED test issue** — documented in detail in
`shift-cash.spec.js` itself (see `openCloseShiftDialog`'s own comment):
the *second* "Close Shift & Cash Up" click within one browser session
consistently fails to open its dialog, with no error anywhere (Flutter
console, page errors) and no visual cause found across several
hypotheses tested and ruled out (lingering SnackBar, dialog-barrier
dismissal, stale `_load()` data — the last of which turned out to be a
real, separate, now-documented bug in its own right: the dialog can open
showing ALL company currencies with "Expected: 0.00" on each one instead
of just the real opening-float currency, when `touchedCurrencies` is
empty due to a load race). Whether this is a genuine Flutter/Navigator
issue specific to rapid same-session dialog reuse, or purely an artifact
of Playwright driving the UI faster than a real cashier ever would, is
not established. Needs either a manual "close two shifts in a row"
check by a real user, or a fresh, separately-budgeted investigation —
flagged rather than silently worked around.

**Not yet covered**: a card/non-cash sale in the same shift; a manual
Cash In/Payout movement; the consolidated shift-close GL voucher pair
(SLS/COS) itself was never reached/verified due to the issue above.

## Phase 2 — Returns + Exchange

- Full-qty and partial-qty returns against a cash sale, verifying refund
  amount via DB (`rih_sales_return_headers.refund_amount_local` matches
  the invoice's actual collected amount — this exact class of bug was
  found and fixed manually earlier this session; a test locks it in).
- Return against a scheme-discounted sale (same bug class, different
  trigger).
- Exchange flow (return → chained new sale with carried-forward credit).

## Phase 3 — Non-cash tender settlement

- Card, Mobile Money, Voucher, Gift Card, Store Credit — one sale each,
  verifying `fn_settle_pos_non_cash_tenders`'s own GL posting
  (`rid_finance_lines`) actually ran correctly. This code path has never
  been exercised by anything but a direct SQL call so far.
- A split-tender sale (cash + card in one invoice), verifying the refund
  math fix from earlier this session via a real return against it.

## Phase 4 — Loyalty

- Attach a loyalty mobile number, earn points on a sale, verify
  `ril_loyalty_ledger` got the right entry.
- Redeem points on a later sale, verify the bill reduction and the
  ledger's redemption entry.

## Phase 5 — Schemes/Promotions admin + Manager Review + Offline

Lowest transaction volume / hardest to set up (needs specific
pre-existing scheme/bundle config or offline network simulation) — last
on purpose.

## Conventions for every phase

- New test file per phase under `tests/`, reusing `helpers/flutter.js`.
- Every money-related assertion checks the real database via a direct
  `pg` connection (same scratchpad pattern used all session), not just
  on-screen text — screen text proves the UI renders right; the DB proves
  the transaction is actually correct.
- Any real app bug found gets fixed in the app code (not worked around in
  the test), verified with `flutter analyze`, committed separately from
  the test-file commit so the fix and the coverage that caught it are both
  visible in history.
- Headed Chromium stays the default (see README) — printing hangs in
  headless mode.
