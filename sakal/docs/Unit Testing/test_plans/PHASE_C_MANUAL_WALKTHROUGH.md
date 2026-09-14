# Phase C — Manual UI Walkthrough Script

**Why this exists**: Phases A and B already proved the NUMBERS are correct
(72 automated backend tests covering every business-logic path, plus a live
multi-tenant isolation proof). What's left is purely visual/UX judgment that
no backend test can observe — and, in this environment, that automation
attempt genuinely hit a wall (see "Why this is manual, not automated" below).
This is NOT a request to re-enter data and re-check numbers — that work is
done. This is a fast visual/UX pass over the highest-traffic screens.

**Budget**: a few focused hours, not days. One create→approve cycle per
screen, checking the 4 items below — skip anything that already looks
obviously fine on the first screen or two of a module (the bug pattern is
usually shared across a whole module, not screen-by-screen random).

## Why this is manual, not automated (checked 2026-09-14)
`flutter drive`/`integration_test` on Web requires `chromedriver` matching
the installed Chrome build. This environment's Chrome (153.0.8010.37) has no
published chromedriver release at all (confirmed against the official
Chrome-for-Testing index) — a genuine environment dead end, not something
fixable by writing more test code. The Windows-desktop alternative
(`flutter test -d windows`) requires enabling Windows Developer Mode, a
machine-wide security setting — deliberately not changed without asking
first, since it's outside the scope of a code/test change. If either of
these becomes available in a future session (chromedriver installed,
Developer Mode enabled), this walkthrough can be converted into the
automated single-screen `flutter drive` tests the roadmap originally
envisioned for CCC #4 and #7 (see `integration_test/README.md`).

## The 4 things to check on every screen below
(Full list of 10 in `00_INDEX.md`'s Cross-Cutting Checklist — these 4 are the
ones that actually hid a real bug this session and are purely visual, so
they're the ones worth your own eyes specifically.)

1. **Dr/Cr, never a bare negative.** Any balance that can be debit or credit
   shows an explicit `Dr`/`Cr` label, never a signed negative number.
2. **Currency shown wherever it can vary.** Any amount in other-than-base
   currency shows its currency code/symbol.
3. **Button state after the action.** Save Draft/Approve/Post/Cancel buttons
   correctly enable/disable/hide immediately after that action completes —
   no stale-enabled button on an already-approved document.
4. **Responsive at ~400px.** Resize the browser/window narrow — no
   `RenderFlex overflow`, no cut-off text, no unusable cramped layout.

## Screens (18, covering every module + one print check per module)

### Sales
- [ ] Sales Quotation — create, convert to Order
- [ ] Sales Order — create DIRECT, Approve
- [ ] Sales Invoice (Quick Invoice) — Cash sale, Credit sale
- [ ] Credit Sales Invoice — Save Draft, Approve
- [ ] Sales Return — against a Credit Sales Invoice (the exact scenario migration 187 fixed — confirm stock/COGS numbers on screen match what you'd expect)
- [ ] Sales Delivery — Approve (the exact screen CCC #4 was originally found on)
- [ ] Cash Receipt — settle a bill

### Purchase
- [ ] Purchase Order — create, Approve
- [ ] GRN — DIRECT and AGAINST_PO
- [ ] Purchase Invoice — against a GRN
- [ ] Purchase Return — against a billed GRN

### Inventory
- [ ] Stock Transfer (Request → Transfer → Receipt) — at least the Transfer step
- [ ] Stock Adjustment — a `+` and a `-` line
- [ ] Material Issue — against a Requisition
- [ ] Opening Stock — one line
- [ ] Stock Count (Counter + Manager Review) — one full cycle if practical

### Finance
- [ ] Payment/Receipt Voucher — the exact screen CCC #3 (Party Amount) was found on; confirm it now shows correctly for a same-currency account
- [ ] Journal Voucher — a bill-linked line
- [ ] Trial Balance / Account Ledger — the exact screens CCC #1/#2 (Dr/Cr label, currency) were found on; confirm both display correctly now (migration 184 already fixed the backend — this is confirming the FRONT END renders what the backend now sends)

## Print check (one per module, visual only)
- [ ] GRN — Print, check letterhead/signature/totals render correctly
- [ ] Sales Invoice — Print (POS-receipt style, no signature block — confirm this is correct by design, not a bug)
- [ ] Payment/Receipt Voucher — Print, check signature lines

## Recording results
Update the `Status` column in `00_INDEX.md` for each screen tested
(`Passed`/`Failed`), and if anything fails, add a row to `AUTOMATED_RUN_LOG.md`
following the same format as the 4 bugs already documented there — what was
found, which screen, and (once fixed) which commit fixed it.
