# Contra Voucher (Finance) — Design + Build

## Context

Finance can already do party-facing cash/bank movement (CRV/BRV/CPV/BPV) and free-form GL entry (JV). Missing: a simple screen for money moving between the company's OWN Cash/Bank accounts — Cash↔Cash, Bank↔Bank, Cash→Bank (deposit), Bank→Cash (withdrawal). This is Tally's "Contra Voucher" (F4), the natural next piece given this app already borrows Tally's CRV/BRV/CPV/BPV/JV vocabulary.

Screen design: a two-block From/To layout (not a JV-style N-line grid), no manual Dr/Cr picker — direction is implicit (FROM=CR, TO=DR) — auto-derived label (Cash Transfer/Bank Transfer/Deposit/Withdrawal) for display only, optional collapsed Transfer Charge, full keyboard chain (Account→Amount→Account→Amount→Remarks→Save). Two ideas adopted from other systems: Odoo's *independently editable* From-amount/To-amount (never a locked one-way rate multiply) and Zoho's optional Transfer Charge line for a real bank fee.

Three architecture questions were resolved before the build (verbatim answers preserved below, since they're the reasoning the implementation follows).

---

## Q1 — What is trans_currency when FROM and TO accounts are different currencies?

**trans_currency = the FROM account's own currency**, one single value for the whole voucher — same "one common transaction currency per voucher, locked from line 1" rule already governing every voucher type in this schema (`019_finance_vouchers.sql`, reconfirmed by the Purchase Bill EXC-voucher split in migration 059, which exists specifically because a voucher can never silently mix trans_currencies across its own lines).

Consequence: **no separate "Currency" picker on screen at all**. Currency is whatever the picked FROM account's own `account_currency_id` is; TO's own currency is only used for its `party_amount` (see Q2).

## Q2 — How are Base/Local/Party amounts calculated?

Same architecture as every other voucher in this app (JV, CRV/BRV/CPV/BPV, GRN, Purchase Bill, ...): **computed client-side in Flutter, sent pre-computed in the line payload.** `fn_save_finance_voucher` stores exactly what it's given — no server-side recomputation. `fn_post_finance_voucher`'s only authoritative check is that DR total = CR total on `base_amount` at Approve/Post time.

Let `Ccy_F`/`Ccy_T` = FROM/TO account currencies, `A_F` = Amount entered (FROM), `A_T` = Amount Received entered (TO, independently editable per the Odoo idea).

**FROM line (CR)** — trans_currency = `Ccy_F`, trans_amount = `A_F`. base_amount/local_amount = `A_F × rate(Ccy_F→Base/Local)` (the JV reciprocal-rate widget, fetched once, editable). party_currency = `Ccy_F` ⇒ party_rate = 1, party_amount = `A_F`.

**TO line (DR)** — trans_currency is still `Ccy_F`, but trans_amount is **not** forced equal to `A_F` — it's the actual value that arrived, expressed back in `Ccy_F`: `trans_amount(TO) = A_T ÷ rate(Ccy_F→Ccy_T)` (or `= A_T` directly when `Ccy_F == Ccy_T`). party_currency = `Ccy_T`, party_amount = `A_T` (the literal typed value — party_amount is user-truth, not a formula output), party_rate = the implied `Ccy_F→Ccy_T` rate.

**Why a third line is genuinely needed, not cosmetic:** if `A_T`'s implied value in `Ccy_F` doesn't exactly equal `A_F` (a real bank fee, or the credited amount differs from the fetched rate), base_amount(FROM) ≠ base_amount(TO) — a real gap that must be posted or the entry misstates what each account holds. The screen auto-computes this gap live and pre-fills a **Transfer Charge / Adjustment** line (DR when value was lost, CR on a favorable variance), defaulting to `EXCHANGE_GAIN_LOSS_ACCOUNT` (already proven via Purchase Bill's EXC voucher) but freely re-pickable. No gap ⇒ the line never appears — the fast path stays exactly the two-block screen.

## Q3 — Reverse option for an already-posted entry

`fn_reverse_journal_voucher` (105) was re-read directly and found to be already 100% generic — no `voucher_type_code = 'JV'` check anywhere; it re-posts under the ORIGINAL voucher's own `voucher_type_code`. Renamed to `fn_reverse_voucher`, shared by both Journal Voucher and Contra Voucher — one reversal engine, not a duplicate.

---

## Build Session Notes

**Backend — `backend/migrations/106_contra_voucher.sql`**
- `rim_voucher_types_nature_check` extended to allow `'CONTRA'`; new system row `CTR` / `voucher_nature='CONTRA'` / `cash_bank_side=NULL` (a Contra has two simultaneous cash/bank legs, so "which side is the cash/bank leg" has no single answer, same reasoning as JV's own NULL).
- `fn_reverse_journal_voucher` → `fn_reverse_voucher`: `DROP FUNCTION` + `CREATE` with an identical body, fresh `GRANT EXECUTE`.
- Menu seed: `backend/functions/fn_seed_client_modules.sql` updated (Finance block, `FN-CTR` "Contra Voucher" between `FN-JRN` and `FN-CBK`) for future clients — **must be manually re-run in the Supabase SQL editor**, per this project's standing "Supabase Function Deployment Gap" convention (functions/ files aren't migrations, they don't auto-apply). Migration 106 itself backfills existing clients via the same `INSERT ... SELECT FROM ric_companies JOIN ric_system_modules` pattern migrations 092/095 already established — **adding the row alone does not grant access**; re-run `fn_grant_admin_access(user_id, client_id, company_id)` afterward for whichever users should see it.
- `backend/tests/106_contra_voucher_test.sql` — 11 pgTAP assertions: CHECK constraint extension, same-currency 2-line deposit (save/post/direction), cross-currency 3-line transfer with an auto-computed charge line (balance + literal party_amount preserved), `fn_reverse_voucher` reversing a CTR, and a **regression test that `fn_reverse_voucher` still correctly reverses a JOURNAL voucher** — protects Journal Voucher's own Reverse feature from the rename. Paren-balanced (217=217), assertion count matches `plan(11)`.

**Charge-account resolution — corrected mid-build, not what the plan originally assumed.** The plan's Flutter section assumed a reusable Dart helper "Purchase Bill already calls" for `EXCHANGE_GAIN_LOSS_ACCOUNT` resolution — checked and no such Dart helper exists anywhere in `lib/`. The actual resolution happens **entirely server-side**, and Purchase Bill's own EXC voucher resolves it inside its `fn_approve_purchase_invoice` PL/pgSQL function via `fn_resolve_account_link` (which requires a product anchor Contra has no equivalent of). The correct fit — confirmed by direct code read — is `fn_resolve_company_account_link(p_client_id, p_company_id, p_link_key)` (`104_cash_receipt.sql`), the COMPANY-granularity variant built specifically for "no natural product/category anchor" cases like Cash Receipt's own pure-customer-receipt FX gain/loss line. It already has `GRANT EXECUTE ... TO authenticated`, so it's called directly as a lightweight RPC from Flutter (`FinanceVoucherRepository.resolveCompanyAccountLink`, added through the full datasource/interface/impl stack) rather than needing any new backend posting logic — Contra still needs zero bespoke `fn_approve_*` function, exactly as planned.

**Real bugs caught in this screen's own manual review pass, fixed before ever running:**
1. Both `_swapFromTo()` and `_pickDate()` originally re-triggered rate refetching by calling `_onFromSelected(...)` with a **hand-built fake account map** (`{'account_code': '', 'account_name': '', ...}`) just to reuse its rate-fetching side effects. Since `_onFromSelected` unconditionally sets `_fromAccountDisplay = FinanceAccountPicker.displayString(account)` from whatever map it's given, both call sites would have silently corrupted the FROM account's displayed text to `"[] "` immediately after a swap or a date change. Fixed by extracting the rate-fetching logic into its own `_refreshBaseLocalRates()`, called directly by both sites without touching display state at all.
2. Neither fix alone would have made a swap visually work anyway: `SakalAutocomplete` (the widget underlying `FinanceAccountPicker`) only reads its `initialValue` once at first mount — a documented gotcha in this codebase, already worked around elsewhere (GRN's own picker: `key: ValueKey(initialText)`). Without a changing `key`, updating `_fromAccountDisplay`/`_toAccountDisplay` state after a programmatic swap would never refresh the visible text field. Fixed by giving the FROM/TO/Charge `FinanceAccountPicker` instances `key: ValueKey(accountDisplay)`, matching GRN's own established pattern exactly.
3. `_onFromSelected` re-picking a FROM account (or its amount changing) didn't re-check the Transfer Charge gap when the To Amount had already been manually typed by the user — the auto-suggestion silently no-ops once `_toAmountManuallyEdited` is true, so a stale gap could go undetected. Fixed by calling `_recomputeSuggestedCharge()` after every FROM-side change (selection, amount edit, swap), not only after TO-side changes.
4. A leftover no-op `[...lines]..sort((a, b) => 0)` in the DRAFT-resume loader (harmless — the branch already keys off each line's own `serial_no` field, not iteration order — but misleading given its own comment implied it was doing real ordering work) was removed for clarity.
5. Unused `theme_presets.dart` import removed (copied from the Journal Voucher screen, which genuinely uses `isCompactDensityProvider`; this screen never does).

**Verification status: NOT yet run against real Supabase or Codespace.** Brace/paren balance and full cross-reference of every new API call against its actual declared signature were done by direct reading (no local Flutter toolchain in this environment), not a compile. Next steps: run migration 106, re-run `fn_seed_client_modules.sql` manually in the Supabase SQL editor, run the pgTAP suite, `fn_grant_admin_access` for the relevant users, `flutter analyze` in Codespace, then a manual click-through — same-currency deposit end-to-end via keyboard only, a cross-currency transfer where the charge line auto-appears and balances, Reverse on a posted CTR, Reverse on an existing posted JV (regression check), and the FROM/TO swap button specifically (the bug class most likely to still have a rough edge, given points 1-2 above).
