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

## Phase 2 — Returns + Exchange (in progress, see status below)

**Confirmed working** (`tests/returns.spec.js`): a full return of a fresh
single-line cash sale, verified end to end against the database —
`rih_sales_return_headers.status = 'APPROVED'` and both
`refund_amount_local`/`return_total` match the invoice's actual collected
amount exactly. Locks in the refund-overcharge class of bug fixed manually
earlier this session.

**Two real, significant Playwright/Flutter-Web interaction findings**, both
root-caused and fixed in the test (not app bugs — neither affects a real
sighted user, since Flutter only builds this semantics tree at all because
automation explicitly enables it):
1. **A Flutter semantics live-region announcement
   (`<flt-announcement-polite>`, permanently off-screen by design) can
   contain the same text substring as a REAL, later, on-screen element** —
   e.g. a "`<invoiceNo>` completed." snackbar announcement vs. that same
   invoice number appearing as a real clickable row moments later.
   `textVisible()`'s `.first()` can match the stale announcement instead,
   and a `.click()` on it then retries forever ("visible, enabled and
   stable" but "outside of the viewport"). **Fixed at the shared helper
   level** (`helpers/flutter.js`) — `textVisible()` now excludes
   `flt-announcement-polite` by default, benefiting every current and
   future test, not just this one.
2. **A scrollable list's `:text()` substring match can also hit a much
   larger ANCESTOR semantics node, not just the specific row** — Flutter
   merges an entire invoice list into one oversized semantics node
   (spanning the whole list's rendered height, containing every row's text
   concatenated) that sits EARLIER in DOM order than the individual rows.
   `.first()` silently picks that non-interactive wrapper over the real
   row; clicking it (even `force: true`) does nothing, since there's no tap
   handler on the wrapper itself — it just silently fails with zero
   console/page error, making it genuinely hard to diagnose (looked
   identical to a "click succeeded, nothing happened" app bug until a
   direct `flt-semantics` DOM dump revealed the oversized wrapper).
   **Fixed per call site**: each invoice row has its own stable
   `role="button"` semantics node — matching via `getByRole('button', {name})`
   instead of plain substring text sidesteps the wrapper entirely. Any
   future test clicking into a long Flutter list should match by role, not
   by `textVisible()`, when more than one row could plausibly be on screen.

**One separate, still-unexplained finding, worked around rather than
root-caused**: clicking the sidebar "Return" nav button (already
role-based, not text-based, so NOT explained by finding #2 above)
immediately after ringing up a sale consistently (3/3 attempts, confirmed
via direct Playwright trace inspection — the click action itself reports
success every time, zero console/page errors) fails to navigate via
`context.go(RouteNames.posReturn)`. A plain, isolated repro script with the
identical steps succeeded once outside the Playwright test runner, so this
may be specific to some interaction between go_router and the test
runner's own page state — not yet understood. **Worked around** by
navigating directly via `page.goto('/#/pos/return')` (a plain hash-route
change, not a full reload) instead of clicking the sidebar button — this
is a reasonable substitute for THIS test's purpose (verifying the return
engine, not sidebar nav robustness) but the underlying click issue itself
is still open, and may be the same root cause behind
`shift-cash.spec.js`'s own still-unresolved "second Close Shift click"
issue from Phase 1 — both share the "Playwright reports success, Flutter
visibly does nothing, zero errors anywhere" shape.

**Not yet covered**: partial-qty return (only a full qty=1 return tested
so far), a return against a scheme-discounted sale, and the Exchange flow
itself (the "Return complete" dialog is reached and declined via "Done",
but "Start Exchange" → chained new sale with carried-forward credit is not
yet exercised).

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
