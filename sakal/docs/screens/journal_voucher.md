# Journal Voucher (Finance) — Full Build Plan

## Context

The Finance module can already post arbitrary GL entries in two ways: automatically (every `fn_approve_*` module calling `fn_post_voucher` under `voucher_type_code='JV'`) and manually for Payment/Receipt Vouchers (`finance_voucher_entry_screen.dart`, types `CRV`/`BRV`/`CPV`/`BPV`). There is no manual-entry screen for a pure, free-form multi-account Dr/Cr journal entry — the menu placeholder for it (`FN-JRN` "Journal Entry", route `/finance/journal`) has existed since the very first menu seed but still resolves to a bare `_Placeholder` widget in `app_router.dart:482`.

This build is also an explicit POC for a new exchange-rate data-entry pattern: displaying the rate as the literal, always-multiply-ready value (no hidden inversion), with a small popup to enter its easier-to-type reciprocal when that value is a tiny decimal — which, for this app's real currency pairs (USD base against CDF/ZMW), will be the **normal** case, not an edge case. The user has said this will roll out to every other Finance screen once proven here.

Four more decisions were added after the user's first two reads of this plan (§6-§8 below): Cash/Bank accounts are excluded from JV's own account picker (that's exclusively Payment/Receipt Voucher territory); a JV line that debits a Customer or credits a Supplier auto-tags itself as a new bill so it flows straight into the existing pending-bills settlement machinery, with the reverse directions optionally able to settle an *existing* bill at the user's own choice, never forced; and a richer multi-column account picker for Finance screens specifically. Document attachments (originally §8) has been pulled out entirely, per explicit instruction — the user wants a separate discussion first, since the base64-in-Postgres approach this plan proposed is the wrong direction: they want cloud storage (Cloudflare/Cloudinary-style) with only a URL stored in the DB, not the file itself. Recorded as its own follow-up item, not part of this build at all.

Three research findings shape this plan:

1. **The existing screen's On-Account mode cannot be reused for JV.** It forces a fixed Cash/Bank line 1 and one uniform Dr/Cr side for every other line (`finance_voucher_entry_screen.dart:735-800`) — structurally incompatible with a JV's need for arbitrary lines, no forced first line, and a per-line Dr/Cr selector. Confirmed via user decision: **build JV as its own new screen**, reusing the same repository, account-picker widget, offline `SyncEngine` wiring, and print template — not extending the existing 1769-line file.
2. **The posting engine needs zero changes.** `fn_save_finance_voucher`/`fn_post_finance_voucher` (`050_grn_vat_deferral_and_line_traceability.sql`, `058_voucher_balance_check_uses_base_amount.sql`) have no special-casing of serial_no=1 as a cash/bank line anywhere — they generically loop over whatever `p_lines` array is given, and the DR=CR balance check already sums `base_amount` (not `trans_amount`), which is exactly what a multi-currency-safe JV needs. `rim_voucher_types.JV` is already seeded (`voucher_nature='JOURNAL'`, `cash_bank_side=NULL`) and already flows through this same function today for every auto-posted journal entry — just never manually.
3. **The existing rate field hides an inversion the user's spec doesn't want** (see "How this reconciles" above) — JV displays the always-multiply rate directly; the reciprocal popup is the typing aid.
4. **The backdate check has a real bug**, confirmed by reading `fn_check_backdate_allowed` directly (`035_period_close_backdated_control.sql:141-170`): it compares `trans_date` against `current_date` evaluated at Approve time, not at the moment the document was actually created — so a same-day-created draft approved a day later can falsely trip as backdated. Fixed at the shared-function level (below), which fixes it for all five voucher types at once.

---

## 1. Backend fix: `fn_check_backdate_allowed` reference-date parameter

`fn_check_period_open` is left untouched — it asks "is this books-period currently open," which is correctly evaluated live at Approve time (a period can close between save and approve; that must still block). Only the *backdate* check ties itself to the wrong clock.

```sql
CREATE OR REPLACE FUNCTION fn_check_backdate_allowed(
    p_client_id        UUID,
    p_company_id       UUID,
    p_transaction_type TEXT,
    p_trans_date       DATE,
    p_reference_date   DATE DEFAULT CURRENT_DATE  -- NEW, backward-compatible
) RETURNS VOID LANGUAGE plpgsql AS $$
...
    IF NOT v_ctrl.allow_future_date AND p_trans_date > p_reference_date THEN ...
    IF v_ctrl.max_backdate_days IS NOT NULL
       AND p_trans_date < (p_reference_date - v_ctrl.max_backdate_days) THEN ...
```
Every one of the ~50 existing call sites (Sales Delivery, GRN, Cash Receipt, Sales Return, ...) keeps calling it with 4 args, defaulting `p_reference_date` to `CURRENT_DATE` — **zero behavior change for them**. `fn_post_finance_voucher` is updated to pass `v_header.created_at::date` as the 5th arg, registering a new call: `fn_check_backdate_allowed(p_client_id, p_company_id, 'FINANCE_VOUCHER', p_trans_date, v_header.created_at::date)` — this one change corrects the behavior for all five voucher types (CRV/BRV/CPV/BPV/JV) at once, since they all post through this same function.

**Deferred, not in this build**: retrofitting every other module's own `fn_approve_*`/`fn_post_*` to pass its own `created_at` — recorded in the Deferred register below.

---

## 2. Reciprocal-rate entry — new reusable widget

New shared widget, `lib/core/widgets/sakal_reciprocal_rate_field.dart` (name tentative), since this is explicitly framed as infrastructure for every future Finance screen, not a one-off:
- Wraps a rate `TextFormField` showing the always-multiply value directly (`1 <TRANS> = X <BASE>`, i.e. what `fn_get_exchange_rate(trans→base)` returns, used unmodified via `toBaseAmount(amount, rate)`).
- A small `@` icon button appears **only when the current rate value is `< 1`** (matches the user's stated condition exactly — for CDF/ZMW-vs-USD this will be true almost always in practice, but the widget stays conditional, not hardcoded to "always show").
- Tapping it opens a small dialog showing `1 / currentRate` (the "easy" number, e.g. 95) in its own editable field. Confirming recomputes `1 / enteredValue` and writes that back into the main rate field — the dialog is a *pure data-entry convenience*, never a second source of truth; the main field's value is always what actually gets used.
- Exposed as `value`/`onChanged` (a plain controlled numeric field), so it can wrap the header's own trans→base rate field, trans→local rate field, and (if useful later) any per-line party-rate field without JV-specific coupling.

---

## 3. Schema: no new tables

Reuses `rih_finance_headers`/`rid_finance_lines` unchanged — a JV is just another `voucher_type_code='JV'` row with `is_on_account=true` (never settles a specific bill; if a future need arises to let a JV line settle a bill via `inv_bill_no`, that's a compatible, additive extension, not part of this build) and no forced first line.

---

## 4. Flutter: `JournalVoucherEntryScreen` (new)

New files under `lib/features/finance/`, mirroring the existing Finance Voucher feature's structural set (same repository/datasource — `FinanceVoucherRepository` already has everything needed: `save`/`post`/`fetchExchangeRate`/account search/`cacheVoucherLocally`; no new repository methods required):
```
presentation/screens/journal_voucher_entry_screen.dart
presentation/screens/journal_voucher_list_screen.dart   -- if no shared list view already covers JV; check finance_voucher_list_screen.dart's own type filter first
```

**Header section** (matches the user's spec exactly):
1. Voucher No — auto (blank until first save), read-only.
2. Voucher Date — date picker, defaults today, no future date (client-side guard mirrors the server's own `FUTURE_DATE_NOT_ALLOWED`), further constrained by whatever `ric_backdated_entry_control` allows for `'FINANCE_VOUCHER'`.
3. Currency — `SakalAutocomplete`/dropdown over active `rim_currencies`. Same-as-base ⇒ rate locked at 1 (no rate fields shown at all, matching "if trans currency is same as base currency then rate is 1").
4. Rate fields (trans→base, trans→local) — the new reciprocal-rate widget from §2, auto-fetched via `fn_get_exchange_rate` on currency pick, user-editable.
5. Reference No / Reference Date — plain text + date, both optional (already existing header columns, `reference_no`/`reference_date`).

**Line grid** — the core new UI, one row per account:
- Account — the new Finance multi-column picker (§8), **filtered to `account_nature NOT IN ('Cash','Bank')`** (§6) — a JV never touches a cash/bank account; that's exclusively Payment/Receipt Voucher's job.
- Parent Group Name — read-only, derived from the picked account's own parent (already available from the same account-search payload the picker itself uses).
- Account Currency — read-only, from the account master (`account_currency_id`).
- Amount (trans currency) — user-entered.
- Dr/Cr — **per-line** toggle (this is the one genuinely new interaction vs. every existing voucher screen, which all hardcode a nature per line-group) — a compact segmented control or two-state chip, not a dropdown, to keep the row fast to fill.
- Base Amount — read-only, computed live: `amount × headerBaseRate`.
- Local Amount — read-only, computed live: `amount × headerLocalRate`.
- Party Amount — read-only, computed live per the existing rule (same-as-base ⇒ equals base amount; same-as-local ⇒ equals local amount; otherwise a fresh `fn_get_exchange_rate(trans→partyCcy)` cross-rate, exact same logic already proven in `_payParty`/`_AccountLine.partyRate`).
- Remarks — free text, optional.
- Running footer row: Dr total / Cr total / difference (trans, base, local — though as established in the research, base/local balance is a **linear consequence** of trans balancing under one shared header rate, so a single trans-balance check is sufficient; all three are still *displayed* for transparency since the user asked for it).

No `inv_bill_no`/`inv_bill_date` columns appear in the visible grid — that tagging (§7) is computed automatically behind the scenes, never a field the user fills in, keeping the row exactly as many columns as specified.

**Keyboard navigation** — reuses the exact `FocusNode`-chaining pattern already proven on Sales Invoice's line rows (`Product → Qty → Rate → Disc% → (+) → next row's Product`): `Account → Amount → Dr/Cr → Remarks → (+) → next row's Account`. A trailing `(+)`/`(x)` icon pair per row, `(+)` always appends and moves focus to the new row.

**Draft/Approve/Copy/Print**:
- Save Draft / Approve(Post) — same two-call shape as the existing screen (`fn_save_finance_voucher` then `fn_post_finance_voucher`), gated by `canAdd`/`canEdit`/`canApprove` via `ScreenPermissionMixin` against the already-seeded `FN-JRN` feature row.
- Copy — duplicate current in-memory state as a new unsaved draft (same behavior as the existing screen's `_applyCopy`, no longer gated to On-Account-mode-only since JV has no other mode).
- Print — reuses `printTemplateProvider('VOUCHER')` unchanged; only addition is a `'JV': 'Journal Voucher'` label entry alongside the existing four in whatever label map the new screen builds its own print document with.
- Offline — reuses the existing `documentType: 'FINANCE_VOUCHER'` / `endpoint: '/rpc/fn_save_finance_voucher'` SyncEngine wiring verbatim (already proven, no new case needed); Approve stays online-only (`!isOffline` gate, same as today).

**Reversal (new, small)** — a "Reverse" action on an already-`APPROVED` JV: creates a new JV with every line's Dr/Cr flipped, same accounts/amounts, tagged `reversal_of_trans_no` (column already exists on `rih_finance_headers`, currently dormant — this is its first real consumer) pointing at the original. One new function, `fn_reverse_journal_voucher(p_client_id, p_company_id, p_trans_no, p_trans_date, p_user_id) RETURNS TEXT`, built on the exact same `fn_save_finance_voucher`+`fn_post_finance_voucher` pair — no new posting logic, just line-nature inversion. Matches the Immutability principle already central to this app (never edit a posted entry, always reverse + re-enter) and directly answers "how do you correct a wrong JV" without inventing a new mechanism.

---

## 6. Cash/Bank exclusion from the JV account picker

A one-line filter addition to whatever account-search query the picker (§8) issues: `account_nature NOT IN ('Cash','Bank')` (the exact enum, confirmed from `013_chart_of_accounts.sql:78-79`: `'General','Customer','Supplier','Cash','Bank','Employee','Tax'`). No schema change — purely a query-time restriction, scoped to JV's own picker instance only (Payment/Receipt Voucher's own cash/bank picker obviously keeps showing them, since that's its entire purpose).

---

## 7. Bill-linkage auto-tagging — a JV line can create a new bill

**The rule, exactly as specified**: a line that **debits** a Customer, or **credits** a Supplier, is treated as creating a new bill (the same shape as an Invoice's own Customer DR line, or a Bill's own Supplier CR line) — `inv_bill_no`/`inv_bill_date` get set automatically so it appears in `v_pending_bills` and becomes collectible/payable through the exact same machinery Cash Receipt and Payment/Receipt Voucher's Against-Bill mode already use. Cascade: `reference_no`/`reference_date` if both are filled in, else the JV's own `voucher_no`/`voucher_date`.

**Architecture**: this logic lives in the **JV screen's own save-payload construction** (Flutter), never inside `fn_save_finance_voucher` — that function is shared by every voucher type and every auto-posting module in the app (Payment/Receipt Vouchers, GRN's provisional accrual JV, Purchase Bill's PUR/EXC pair, ...); baking JV-specific "a customer debit is secretly an invoice" logic into it would silently change behavior everywhere else that happens to debit a customer account. Every other module that tags `inv_bill_no` already does it the same way — the calling code decides, the shared function just stores whatever it's given.

**A real edge case, handled explicitly**: two lines in the same JV can't both auto-tag the *same* customer (or supplier) — they'd collide on `(account_id, inv_bill_no)`, which `v_pending_bills` expects to identify exactly one bill. Validated at Save: if a JV has more than one debit-to-the-same-customer (or credit-to-the-same-supplier) line, reject with a clear message asking the user to combine them into one line — same "one line = one identifiable bill" discipline every other module in this schema already follows.

**Confirmed complementary addition — entirely the user's choice, never forced**: the user's own rule only covers the *increasing* directions (customer debit, supplier credit). The reverse — a line that **credits** a Customer or **debits** a Supplier — gets an **optional** "Settle against bill?" affordance: leave it off and the line posts as a plain on-account entry (today's only behavior); switch it on and a picker appears (the exact same mechanism Cash Receipt's entry screen already has — `v_pending_bills` filtered to that specific account), letting the user pick which existing bill this line reduces. Nothing is auto-populated and nothing is required — nature auto-tagging (§7's main rule) is automatic because it's unambiguous (a customer debit line is *always* a new receivable, full stop), but bill *settlement* is inherently a judgment call the user makes per line, so it stays opt-in.

---

## 8. Finance-specific multi-column Account Picker

**Scoped to Finance module screens only** — Sales/Purchase account pickers (customer/supplier/product-adjacent) keep the existing `[code] name` + small grey parent-subtitle convention unchanged; this is a Finance-specific enhancement, not a global widget change, per explicit instruction.

**Why**: in Finance, two accounts can legitimately share the same name under different parent groups (e.g., "Rent" under Expense vs. "Rent" under Provisions) — the existing subtitle hint is too subtle to disambiguate quickly. The fix shows Account Code, Account Name, and Parent Group as three genuinely separate, aligned columns in the dropdown, not a stacked primary/subtitle pair — **and all three are searchable**, confirmed against how account data actually reaches this picker.

**Confirmed feasible, not just in theory**: the account picker doesn't run a live per-keystroke backend query at all. `accountsProvider` (`master_cache_providers.dart:150-172`) fetches the full account list **once** per session (up to 500 rows), with `parent:rim_accounts!parent_id(account_name)` already embedded in that same payload, and caches it — every keystroke afterward filters that already-in-memory list in Dart. So this isn't a PostgREST query-syntax question (which is where searching across an embedded/joined table inside an `or=` filter can get genuinely awkward) — it's just widening the existing filter predicate from `code.contains(q) || name.contains(q)` to also check `parentName.contains(q)`, since the parent name is already sitting in memory alongside the rest of the row.

**Implementation**: `SakalAutocomplete` already supports the 3-column *display* without any core widget change — it takes an `optionBuilder` callback per instance (already how the existing "code+name, small parent subtitle" rendering is done today), so this is a different `optionBuilder` (a `Row` of three aligned cells instead of a two-line `Column`), not a new widget. Add one small shared helper, e.g. `sakalFinanceAccountOptionRow(account)` in a common Finance-widgets location — both the rendering AND the widened 3-field `optionsBuilder` search predicate live there — used by JV's own line-account picker, and worth retrofitting to the existing Payment/Receipt Voucher screen's own cash/bank + party + on-account pickers in the same pass (same module, same ambiguity problem, and the shared helper makes it nearly free) — flagged for confirmation, not silently assumed.

---

## 9. Odoo comparison — what's being adopted vs. deliberately deferred

Odoo's Journal Entries (`account.move`, `move_type='entry'`) offer several ideas beyond the user's literal spec:

**Adopting now** (cheap, directly matches stated goals):
- **Keyboard-first grid entry** (Tab/Enter driven) — directly matches "as flexible as possible and user friendly, specially in navigation and data entry"; built via §4's FocusNode chain.
- **One-click Reverse** — Odoo's own "Reverse Entry" wizard; SAKAL already has the dormant column, this is a small, high-value addition given how central the Immutability/reversal-only principle already is everywhere else in this app.
- **Post-time-only balance enforcement, unbalanced drafts allowed** — already how `fn_save_finance_voucher`/`fn_post_finance_voucher` split responsibilities; no new design needed, JV inherits it for free.

**Deliberately deferred** (real ideas, real added scope — recorded, not built):
- **Auto-balance-remaining-line** (Odoo lets the last line's amount auto-fill to whatever balances the entry). Worth adding as a small UX polish pass once the base screen is proven — flagged, not blocking this build.
- **Recurring/template journal entries** (save a JV shape for reuse, e.g. monthly depreciation) — a real future win, meaningfully bigger scope (a new template table + a "load from template" flow).
- **Line-level tax on a JV** — Odoo supports this; SAKAL's manual JVs are typically pure adjustment entries with tax already settled through the transactional modules, so this looks like scope not need — flagged for the user to override if wrong.
- **Attachments** — pulled entirely out of this build (see Context above) pending a separate discussion on cloud storage.

---

## Deferred / Follow-Up Work Register

1. **App-wide backdate reference-date retrofit** — `fn_check_backdate_allowed`'s new `p_reference_date` param (§1) only gets wired for Finance Voucher/JV in this build. Every other module's own `fn_approve_*`/`fn_post_*` (Sales Delivery, Sales Return, Cash Receipt, GRN, Purchase Invoice, ...) still compares against live `CURRENT_DATE`, meaning the exact "saved today, approved tomorrow" false-positive the user found could still occur elsewhere. A full retrofit is mechanical but touches ~15 functions — worth a dedicated pass once this pattern is proven here.
2. **Reciprocal-rate widget rollout to Payment/Receipt Voucher** — the user's own stated intent ("eventually add this feature to all finance screens"). The existing screen's rate field currently displays the *inverted* value and silently re-inverts it before use (see "How this reconciles" above) — once the new widget is proven on JV, retrofitting `finance_voucher_entry_screen.dart` removes that hidden-inversion behavior too.
3. **Multi-column account picker rollout to Payment/Receipt Voucher** (§8) — flagged for confirmation in this same build; if not confirmed, becomes its own follow-up item instead.
4. **Auto-balance-remaining-line, recurring JV templates** — see Odoo comparison above.
5. **Generic document attachments (cloud storage, URL-only in DB)** — pulled out of this build entirely per explicit instruction; needs its own dedicated planning discussion (which cloud service, upload flow, offline behavior when a file was attached without connectivity) before any schema or screen work.
6. **Customer Credit/Debit Note** — the item this session was originally about to scope before pivoting to JV first; still queued, not abandoned. Now has an interesting overlap with §7: a JV that debits a customer *is* effectively a debit note once bill-linkage tagging exists — worth revisiting whether a dedicated CDN/CCN screen is still needed, or whether it becomes a thin, reason-code-focused wrapper around what JV already does, once JV ships.

---

## Verification Plan

1. Run the `fn_check_backdate_allowed` migration; confirm every existing call site still compiles/behaves identically (spot-check one, e.g. Sales Delivery's own future-date pgTAP test, still passes unchanged).
2. New pgTAP test for the reference-date fix itself: configure `max_backdate_days=0` for `'FINANCE_VOUCHER'`, save a voucher today, fast-forward the *approval* call's notion of "today" isn't directly mockable in pgTAP — instead assert the SQL logic directly: call `fn_check_backdate_allowed` with `p_trans_date = p_reference_date` (should always pass regardless of what `CURRENT_DATE` is) vs. `p_trans_date < p_reference_date - max_backdate_days` (should still correctly fail) — proves the comparison basis changed correctly without needing to simulate elapsed real time.
3. pgTAP for the JV path itself: save+approve a 3-line JV (no cash/bank line at all) in a foreign currency, confirm it posts through `fn_save_finance_voucher`/`fn_post_finance_voucher` unchanged, balances correctly, and `fn_check_period_open`/the new backdate check both fire correctly.
4. pgTAP for `fn_reverse_journal_voucher` — reverse a posted JV, confirm the new voucher's lines are exactly inverted and balanced, `reversal_of_trans_no` populated.
5. pgTAP for bill-linkage auto-tagging (§7): approve a JV with a customer-debit line and no reference no/date → confirm it appears in `v_pending_bills` tagged with the JV's own voucher no/date; a second JV with reference no/date filled in → confirm those values are used instead; a JV with two lines debiting the *same* customer → confirm it's rejected at Save with a clear validation message; a JV with a customer-*credit* line where the user did NOT opt into bill-settlement → confirm it posts as a plain on-account line with no `inv_bill_no`; the same but WITH bill-settlement opted in and a bill picked → confirm it settles that specific bill exactly like Cash Receipt's own settlement does.
6. pgTAP/manual check that the JV account picker's query genuinely excludes `Cash`/`Bank` accounts (§6) — attempt to search for a known cash account by code, confirm it doesn't appear.
7. `flutter analyze` clean (no local toolchain in this environment — needs the user to run it in Codespace, per established workflow).
8. Manual click-through: open Journal Voucher screen → confirm header prefill/currency/rate flow → pick a currency where the rate is a tiny decimal → confirm the `@` icon appears → open the popup, enter an easy number, confirm the main field updates correctly → add 3+ lines via keyboard only (no mouse) with mixed Dr/Cr, confirming the account picker never offers a Cash/Bank account and shows Code/Name/Parent as separate columns → confirm running balance footer → Save Draft → Approve → confirm GL posted correctly in Finance Voucher's own list/report, and that a customer-debit line shows up as a pending bill → Reverse → confirm the mirror entry posts correctly → Copy → confirm a fresh unsaved draft opens with the same lines → Print.

---

## Build Session Notes (2026-07-23)

Full build completed exactly per this approved plan — no scope deviation. Files:

**Backend**
- `backend/migrations/105_journal_voucher.sql` — `fn_check_backdate_allowed` gained `p_reference_date` (DROP+CREATE, backward-compatible default); `fn_post_finance_voucher` now passes `v_header.created_at::date` as that 5th arg (plain safe `CREATE OR REPLACE`, signature unchanged); new `fn_reverse_journal_voucher(...)` — locks/validates the original (must be posted, not already reversed via a `reversal_of_trans_no` uniqueness check), flips every line's `trans_nature`, deliberately drops `inv_bill_no`/`inv_bill_date` on the reversal (a reversal is a pure GL mirror, never a new bill), saves+posts via the existing shared pair, then stamps `reversal_of_trans_no` — the first real consumer of that previously-dormant column.
- `backend/tests/105_journal_voucher_test.sql` — 12 pgTAP assertions: reference-date fix (3), save/approve/balance a cash/bank-free multi-line JV (3), reversal (3), bill-linkage auto-tagging surfaces in `v_pending_bills` (3). Paren-balance verified (55=55).

**Flutter**
- `lib/core/widgets/sakal_reciprocal_rate_field.dart` — new reusable widget (§2), `@`-icon only when rate `< 1`, popup edits the reciprocal and writes `1/entered` back.
- `lib/features/finance/presentation/widgets/finance_account_picker.dart` — new Finance-only 3-column (Code/Name/Parent Group) searchable account picker (§8), built on `SakalAutocomplete`'s existing `optionBuilder` hook — no core widget change needed.
- `lib/features/finance/presentation/screens/journal_voucher_entry_screen.dart` — new screen (§4): free-form per-line Dr/Cr, Cash/Bank excluded from the picker (§6), bill-linkage auto-tagging + optional reverse-direction settlement (§7), keyboard-chained line entry, Save/Approve/Copy/Reverse/Print, offline Save-only (Approve stays online-only).
- `lib/features/finance/presentation/screens/journal_voucher_list_screen.dart` — new list screen, `SakalAdaptiveList`, filters `voucherTypeCode: 'JV'`.
- `finance_voucher_remote_ds.dart` / `finance_voucher_repository.dart` / `finance_voucher_repository_impl.dart` — added `reverseJournalVoucher(...)` through the full stack.
- `route_names.dart` / `app_router.dart` — added `journalVoucherEntry` route; `journalEntry` (`/finance/journal`, the pre-existing `FN-JRN` menu placeholder) now resolves to the real list screen instead of `_Placeholder`.

**Real bugs caught and fixed during the build (self-review, before ever running against Supabase):**
1. `FinanceVoucherHeader.createdByName`/`postedByName` were initially (wrongly) treated as raw user IDs needing a second lookup against a fetched `_users` list — these fields are already-resolved names via the repository's own SQL join. Fixed by removing the unnecessary lookup machinery entirely.
2. The entry screen called `reverseJournalVoucher(...)` on the repository before that method existed anywhere in the stack — added through datasource → interface → impl.
3. **Party Amount rule violation, caught in the post-build manual review pass**: the plan's own spec (§4) says party currency == base ⇒ party amount == base amount, == local ⇒ == local amount, otherwise a fresh cross-rate — but the first implementation only special-cased "party currency == trans currency" (rate=1) and fell through to an independent `fn_get_exchange_rate` lookup for the base/local cases too. That lookup could silently disagree with the header's own rate fields whenever the user edited them via the new reciprocal-rate widget — exactly the class of bug already caught and fixed once before in GRN's own party-rate resolution (052/053: "reuse the header's own confirmed rate... instead of a fresh lookup that could silently disagree"). Fixed by converting the per-line party rate into a live getter (`_partyRateFor`) that reads `_baseRate`/`_localRate` directly for those two cases — automatically correct even after a rate edit, with no extra plumbing — and by re-fetching the "genuinely a fourth currency" case whenever the header's own trans currency changes (`_onCurrencySelected` now loops every line and calls `_refreshLinePartyRate`), since that cross-rate was previously left stale if a currency change happened after lines already had accounts picked.

**Separately flagged, not fixed in this session**: `cash_receipt_entry_screen.dart` passes a raw `String` where `SakalAutocomplete.initialValue` is actually typed `TextEditingValue?` — a real pre-existing type bug in already-shipped code, discovered while building this screen's own (correctly-typed) `finance_account_picker.dart`. Not touched here since it's out of scope for this build; needs its own follow-up fix.

**Verification status: NOT yet run against real Supabase or Codespace.** Next steps for the user: run migration 105, run the pgTAP suite (`105_journal_voucher_test.sql`), `flutter analyze`/`flutter pub get` in Codespace (no local Flutter toolchain in this environment — verification here was file-by-file brace/paren balance checks plus a full manual cross-reference of every new API call against its actual declared signature, not a compile), then the manual click-through in item 8 above.

---

## Live-Testing Bug Fix Pass (2026-08-15 → 2026-08-17)

First real hands-on testing of the shipped screen (well after the original build above) surfaced a cluster of real bugs plus several UX requests, fixed across several sessions. Grouped by topic, not strictly chronological.

### Approve / status / print — one shared root cause

Approving a JV created in the same screen session (never navigated away from) left the Approve button active and status stuck on DRAFT, and Print showed no Prepared/Approved-by names — all three traced to one bug: `_init()`'s post-approve reload was gated on `widget.editTransNo != null`, but that's an **immutable constructor param** only set when the screen was opened to EDIT an existing voucher — a voucher created fresh in the same session has its trans_no in the `_transNo` **state** variable instead, so the reload silently no-op'd every time. Fixed via a new `effectiveTransNo = widget.editTransNo ?? _transNo` fallback. The identical bug was found and fixed the same way in Contra Voucher and Expense Voucher, since all three share this exact `_init()` shape.

### List screen not refreshing on return from the entry screen

`JournalVoucherListScreen` relied solely on `_openNew()`/`_openEdit()`'s own `await context.push(...) => _load()` to refresh — but a screen covered by a pushed route stays mounted (never disposed/rebuilt) the whole time it's covered, and some real navigation paths back to the list weren't triggering that reload. Fixed by overriding `didPopNext()` (the list screen already subscribes to the shared `RouteObserver` via `ScreenHeaderMixin`) to also call `_load()`, making the refresh unconditional on any return to the screen, not just the one push()-await path. Same fix applied to Sales Order's list screen.

### TopBar stuck showing a stale title (the hardest bug, 3 real attempts)

Reported live: approving a JV then clicking "Journal Entry" in the sidebar left the TopBar showing the old voucher's title/Reverse/Print actions with the List screen's content rendering underneath it. Root-caused via `/dev/logs` (the in-app log viewer) after adding tracing to `ScreenHeaderMixin`:

1. **First cause, found and fixed**: `ReportScreen` (used by Account Ledger, Sales Register, every report) never registered a header via `ScreenHeaderMixin` at all — it relied entirely on the *previous* screen's own `dispose()` correctly clearing the shared header state. Fixed by giving `ReportScreen` a real header registration.
2. **Second cause, found via `/dev/logs`**: `refreshScreenHeader()`'s `WidgetsBinding.instance.addPostFrameCallback` was occasionally firing while `BuildOwner.building` was still true during a Navigator route transition, throwing "Tried to modify a provider while the widget tree was building" — the exception aborted mid-notification, so the TopBar never learned about the new title even though the internal ownership bookkeeping had already updated. Fixed by switching both the claim (`refreshScreenHeader`) and the clear (`dispose`) to `Future.microtask` instead of a post-frame callback.
3. **Third cause, found live immediately after #2 shipped**: the microtask-based *clear* started racing **ahead** of the newly-navigated screen's own claim, wiping the header to blank (company-name fallback) instead of leaving it stale — the opposite symptom. Root cause: GoRouter's route-transition teardown doesn't reliably dispose the old screen within the same synchronous frame as the new screen's `build()`, so a same-turn microtask ordering assumption was wrong. **Final fix**: `dispose()`'s clear now uses `Future.delayed(400ms)` instead of a same-turn microtask, giving any real claim from the newly-navigated screen (which happens within milliseconds) time to win first; the delayed clear only ever takes effect if genuinely nothing claims ownership afterward.

All three fixes live in `lib/core/layout/screen_header.dart` (shared — benefits every screen using `ScreenHeaderMixin`, not just JV).

### Header field spacing, focus flow, and Remarks propagation

- Voucher No/Date/Currency fields were touching the TopBar directly (`SingleChildScrollView`'s top padding was 0) and touching each other (default `SakalFieldRow` spacing felt too tight for this row specifically) — fixed with 20px top padding and a wider 24px inter-field spacing for this one row.
- Initial screen focus landed on the first line's own Account field, which — after `FinanceAccountPicker` gained `desktopDialogMode` (see below) — immediately popped the account picker dialog open unprompted on every fresh screen load. Redirected initial focus to the Currency field instead.
- Currency selection now advances focus to Reference No; picking a Reference Date advances focus to Remarks. The Currency→Reference No hop needed the focus request moved to **after** `_onCurrencySelected`'s own async rate-lookup chain fully resolved — requesting it earlier let an in-flight rebuild (triggered by that chain's own `setState` calls) silently detach the just-requested focus's real text-input connection, landing focus on Remarks instead with a visible ring but no actual keyboard input until a real mouse click reopened it.
- Header Remarks now live-propagates into any account line whose own Remarks is still empty, on every keystroke — the naive "seed once, at line-creation time" version missed the single-line-JV case entirely, since the first line is auto-added in `initState()` before Remarks has anything typed into it.

### Account Lines table — scrollable, not wrapping; then decluttered

- Desktop line rows were a `Wrap` of fixed-width `SizedBox`es (~1340px total) that pushed fields onto a second line once the viewport was narrower than that. Rebuilt using this app's standard `SakalTableHeaderBar` + `SakalScrollableTable` pattern — one continuous horizontally-scrollable row per line, matching Purchase Order's own product list. Mobile kept its existing per-field-labeled Wrap card, `Column`-of-full-width-fields instead of a packed `Wrap` (see below).
- **Redundant per-cell labels removed** (user's own observation: every cell repeated its column's own header text above the value, wasting vertical space for no benefit once the dark `SakalTableHeaderBar` already names each column). `SakalFieldCard`/`SakalFieldCard.readOnly` gained a new `showLabel` param (default `true`, every other caller in the app unaffected); JV's desktop line cells pass `showLabel: isMobile`. Piloted on JV alone first, then — once confirmed good — rolled out the same way to all 18 other screens with a desktop line-items table (Sales Invoice/Order/Quotation/Delivery/Return, Purchase Order/Return, GRN, Stock Adjustment/Receipt/Transfer(+Request)/Count, Material Issue/Requisition, Opening Balance, Opening Stock, Price Master). Purchase Invoice (no line-items grid) and Stock Count Review (plain `Text` cells, never `SakalFieldCard`) don't apply.
- **Font-weight inconsistency, found once labels were removed and rows got visually simpler**: the Account picker, Amount field, and Remarks field were each silently falling back to Flutter's own default (non-bold) field style, unlike the readonly cells and the Dr/Cr dropdown (both already bold via `SakalFieldCard.valueTextStyle`). `FinanceAccountPicker` gained a `style` param (forwarded to its underlying `SakalAutocomplete`); all three fields now pass the same shared bold style explicitly.
- Amount/Base/Local/Party Amount column headers now right-align, matching their numeric values below.
- `SakalScrollableTable` (shared) gained a 10px trailing gap inside its scrolled content so the horizontal scrollbar's own track never renders flush against the last row — benefits every screen using this widget, not just JV.
- **Mobile**: fields were packed 2-3 per row via a `Wrap` of fixed widths (e.g. Parent Group + Currency fit on the same 440px-wide line) — inconsistent with how the wider fields (Account, Remarks) rendered. Changed to every field full-width, one per row, in a plain `Column`.

### Account picker — Group Name bug (backend) and popup redesign

Two separate but related fixes, both benefiting every Finance account picker (JV, Contra, Expense, Payment/Receipt, Account Ledger's own filter — not just JV):
- **Group Name was blank everywhere**, root-caused to a PostgREST self-referencing embed (`rim_accounts!parent_id(...)`) that resolved to the *reverse* relationship (an account's children, not its own parent) — every account shown in any picker is a leaf/postable account with zero children, so the embed always came back empty. Two embed-hint fix attempts (column name, then FK constraint name) both failed live against this project's real PostgREST for different reasons. **Final fix**: a new SQL view, `v_rim_accounts_with_parent` (migration 134), resolves `parent_name` via a plain `LEFT JOIN` server-side — sidesteps PostgREST embedding entirely. `accountsProvider` and the offline sync cache both switched to query the view.
- **Popup redesign**: `FinanceAccountPicker`'s dropdown gained a pinned header row (Account Code / Account Name / Group Name) with subtle row dividers. The first attempt (widening the existing inline `RawAutocomplete` dropdown) still rendered at roughly the anchor field's own narrow width in practice, regardless of `optionsMinWidth` — a `RawAutocomplete` follower-width quirk. **Final fix**: `SakalAutocomplete` gained an opt-in `desktopDialogMode` — clicking/focusing the field on desktop now opens a genuinely separate, fixed-size (640×560) modal `Dialog` with its own search box, the same header row, and full Up/Down/Enter/Escape keyboard navigation, completely independent of the field's own width. Mobile is unaffected (it already used a separate bottom-sheet path). `FinanceAccountPicker` opts in; every other `SakalAutocomplete` consumer defaults to the unchanged inline dropdown.

### Reverse — real bug: was auto-posting with zero review

`fn_reverse_voucher` (the shared backend function, also used by Contra/Expense/Payment-Receipt Voucher) flips every line's Dr/Cr **and posts the reversal atomically in the same call**, on `CURRENT_DATE` — no draft stage, no chance to review or change the date before it's live. Redesigned Reverse to work client-side instead, exactly mirroring the existing Copy action (no server round-trip until the user actually clicks Save/Approve): loads the flipped-Dr/Cr lines into a new unsaved draft in the same screen, defaulting to today's date but freely editable, tagging the eventual saved document with `reversal_of_trans_no` (via a new `_reversalOfTransNo` field threaded into the save payload) so the traceability the old RPC provided server-side is preserved. Same fix applied to Contra Voucher (reusing its own existing `_swapFromTo()`, since reversing a transfer genuinely is swapping From/To). **Deliberately not applied** to Expense Voucher (its Reverse targets a differently-coded posted GL voucher, not the Expense Voucher document itself — needs a larger redesign to fix the same way) or Payment/Receipt Voucher (has no Reverse button in its UI at all currently).

### Files touched across this pass

`journal_voucher_entry_screen.dart`, `journal_voucher_list_screen.dart`, `contra_voucher_entry_screen.dart`, `expense_voucher_entry_screen.dart`, `sales_order_list_screen.dart`, `lib/core/layout/screen_header.dart`, `lib/core/reporting/sakal_report_screen.dart`, `lib/core/widgets/sakal_field_card.dart` (+ all 18 other line-item screens' own `showLabel` rollout), `lib/core/widgets/sakal_autocomplete.dart`, `lib/core/widgets/sakal_scrollable_table.dart`, `lib/features/finance/presentation/widgets/finance_account_picker.dart`, `lib/core/providers/master_cache_providers.dart`, `lib/core/sync/master_data_modules.dart`, `backend/migrations/134_rim_accounts_parent_name_view.sql`.

---

## Two regressions from the `showLabel` rollout, found and fixed same-session (2026-08-19)

The `showLabel` rollout above (18 screens) surfaced two follow-on bugs during retest, both app-wide, neither specific to JV:

1. **`SakalAutocomplete`'s inline dropdown broke for every non-`desktopDialogMode` consumer** — Product pickers everywhere (Sales Order/Quotation/Invoice, Stock Transfer, ...) and every generic Account picker (Cash Receipt/Payment Voucher's Cash Account field, Purchase Order's Account field) stopped showing a dropdown at all. Root cause: the inline dropdown's `OverflowBox` (added to escape `RawAutocomplete`'s own narrow ambient width constraint) used `maxWidth: double.infinity` — a genuinely unbounded width Flutter can't lay out a `Column`/`ListView` chain against. Fixed with a large-but-finite `maxWidth: 900`. `desktopDialogMode` consumers (`FinanceAccountPicker`) were unaffected — they don't use this code path. Fixed in `sakal_autocomplete.dart`, pushed as `911296e`.
2. **Stale `height: 56` overrides on ~14 line-item screens** produced visibly jagged row heights once `showLabel: false` shrank `SakalFieldCard`'s own default height but a `SizedBox(width: X, height: 56, child: field)` wrapper around a subset of a row's cells kept those specific cells pinned at the old size. Fixed by stripping `, height: 56` from every such wrapper (leaving just `width:`) across `purchase_order_entry_screen.dart`, `sales_order_entry_screen.dart`, `sales_quotation_entry_screen.dart`, `sales_delivery_entry_screen.dart`, `sales_return_entry_screen.dart`, `grn_entry_screen.dart`, `purchase_return_entry_screen.dart`, `price_master_entry_screen.dart`, `stock_adjustment_entry_screen.dart`, `stock_receipt_entry_screen.dart`, `stock_transfer_entry_screen.dart`, `stock_transfer_request_entry_screen.dart`, `material_issue_entry_screen.dart`, `material_requisition_entry_screen.dart`. Pushed as `42182ec`.

## Print template fix pass (2026-08-19)

Live review of JV's printed PDF (against a reference letterhead mockup) found several real defects, all fixed this session:

- **JV split off into its own dedicated print template** (`document_type='JOURNAL_VOUCHER'`, `journal_voucher_default_template.dart`) instead of continuing to share `document_type='VOUCHER'` with Payment/Receipt Voucher and Contra Voucher. Needed specifically to give JV's own lines table separate **Debit**/**Credit** columns (`_buildPrintDocument()` now emits `debit`/`credit` per line instead of a single `amount`) without breaking the other two screens' printed output — both still emit `amount`, not `debit`/`credit`, and share the original template. A first attempt edited the shared template directly and was caught and reverted before committing (see [[feedback_check_latest_function_signature]]-style lesson: check every consumer of a shared asset before changing its shape, not just the one you're testing). Registered in `print_field_registry.dart` (4 switches + `documentTypes` + `documentTypeLabel`) and `print_template_provider.dart`, per the standard "adding a new document type" checklist in CLAUDE.md.
- **`signatures` nesting bug — the real cause of blank Prepared By / Authorised By** (not a data-population issue, as first suspected): JV's, Contra Voucher's, and Expense Voucher's own `_buildPrintDocument()` all nested `'signatures': {...}` *inside* `'header'`, but the template binds `'signatures.prepared_by'`/`'signatures.authorised_by'` against the document **root** — confirmed by comparing against `finance_voucher_entry_screen.dart`, the one screen that already had it right. Fixed by moving `signatures` to a top-level sibling of `header`/`lines`/`totals` in all three files.
- **Letterhead layout**: company address/city now render directly under the company name (not under the logo) via `spacer_2`/`spacer_3` invisible elements that reserve the logo's own column width on rows with no left-hand element — this flowing x/y/w layout model has no true multi-row "column" concept, so a lone element on a row with nothing at `x:1` otherwise starts flush at the page margin, not indented to match the row above. Document title ("Journal Voucher") and Voucher No now sit top-right (mirroring the reference mockup), each paired with company_name/company_address/company_city on the same three rows so both sides stay vertically aligned. Applied to both the shared `voucher_default_template.dart` (Payment/Receipt + Contra) and the new JV-specific template — safe for the shared one since every consumer supplies the same header field names, only the lines-table shape differs.
- **Footer — Printed By / Printed On / Page N of M** — genuinely new capability, added once to the shared renderer: `PdfCanvasRenderer.render()` gained optional `printedByName`/`printedOn` params, wired into `pw.MultiPage`'s `footer:` callback (`context.pageNumber`/`context.pagesCount`), right-aligned, small grey text. `PrintEngine.printDocument()` threads both through as new optional params. Wired into all four Finance voucher screens this session (JV, Contra, Expense, Payment/Receipt — `session.fullName` + `DateTime.now()` at print time); the other ~20 screens using `PrintEngine.printDocument()` are unaffected (params are optional) and pick this up automatically once opportunistically wired the same way, same rollout shape as `showLabel`/`SakalAutocomplete`.
- Files touched: `journal_voucher_entry_screen.dart`, `contra_voucher_entry_screen.dart`, `expense_voucher_entry_screen.dart`, `finance_voucher_entry_screen.dart`, `lib/core/printing/pdf_canvas_renderer.dart`, `lib/core/printing/print_engine.dart`, `lib/core/printing/print_field_registry.dart`, `lib/core/printing/print_template_provider.dart`, `lib/core/printing/default_templates/voucher_default_template.dart`, new `lib/core/printing/default_templates/journal_voucher_default_template.dart`. Pushed as `6275db1`.
- **Not yet done**: the same letterhead-layout fix (address-under-name, title/voucher-no top-right) hasn't been ported to the other ~16 document-type templates — deliberate opportunistic follow-up, not part of this pass.

**Verification status**: balance-checked file-by-file (no local Flutter toolchain); user has been running `flutter analyze`/`flutter test` and manually retesting after each round, catching the 2nd and 3rd TopBar-header attempts live. Reverse's new client-side behavior and the Contra Voucher port of it have not yet been manually retested by the user as of this note.

---

## Print design pass, part 2 — the alignment saga, `PrintElementType.block`, and full app-wide rollout (2026-08-19, later same day)

Continuation of the pass above. What looked like a solved problem (letterhead alignment) took **four real attempts** before landing, each one caught live by the user pointing at the actual rendered PDF — a good case study in not trusting "the flex math says this should work" over what's actually on screen.

### Attempt 1 — logo capped to 0.5in, kept side-by-side with company_name (failed)
Reported: too much wasted space. Root cause diagnosed (correctly) as the logo's real configured size (defaults 1×1in ≈ 72pt) making its shared row far taller than the 2-3 lines of text beside it. Fixed by capping the *displayed* logo size in the letterhead specifically (`pdf_canvas_renderer.dart`'s image case, `maxLetterheadLogoIn = 0.5`) — this cap itself was correct and survived every later attempt.

### Attempt 2 — logo moved to its own row, text stacked below (rejected by user, not a bug)
To guarantee alignment without relying on flex-matching, logo was pulled onto its own row (y:1 alone), with company_name/title/address/voucher_no/city/date flowing as tight rows below. This technically worked (no misalignment) but changed the *visual composition* from side-by-side to stacked — user explicitly wanted logo beside the company name, not on top: **"is it that difficult?"** Reverted.

### Attempt 3 — fixed-width shared column for the logo/spacer, kept side-by-side (failed)
Back to side-by-side, but instead of trusting matching flex ratios (`w:` values) across `company_name`'s row and `company_address`'s row to independently land at the same x-boundary, gave the logo's own column a literal fixed width (36pt, matching the 0.5in cap) via a new `_isLogoColumn`/`_logoColumnWidthPt` special-case in `_buildRow`. Balance-checked, reasoned through carefully, looked correct on paper. **Still visibly misaligned when the user tested it** — company_address still didn't line up under company_name. Root cause never fully diagnosed (no local renderer to inspect); reverted rather than keep guessing.

### Attempt 4 — `PrintElementType.block` (the actual fix)
Gave up on any cross-row alignment mechanism entirely. New element type: a fixed vertical stack of sub-elements rendered as **one `pw.Column`**, so company_name/address/city (or title/doc-no/date) are literally the same widget tree, one under the other — alignment is a property of `pw.Column`, not of two independently-laid-out `pw.Row`s happening to agree. This is the only approach that's *structurally* guaranteed rather than *configured* to be correct, and it held up on retest.
Full mechanism: `print_models.dart` gained `PrintElement.lines` (a `List<PrintElement>`, JSON round-tripped); `pdf_canvas_renderer.dart` and `pdf_flow_renderer.dart` both gained a `block` case; `print_template_designer_screen.dart`'s `_ElementDraft` gained a `lines` field (preserved on load/save, no per-line editor UI yet) and all 4 exhaustive `PrintElementType` switches got a case. Every letterhead is now one row: `logo` + `company_block` (name/address/city) + `title_block` (title/doc-no/date, right-aligned).

**A fifth, smaller alignment bug** surfaced once block was in place: a right-aligned block's title text sat short of the true right margin (same margin the divider/table below it correctly reached) — on "Purchase Return" specifically, not on JV, which is what let it slip through the first review. Root cause: `pw.Column` shrink-wraps to its widest line by default; the first fix wrapped it in `pw.SizedBox(width: double.infinity)`, which only *looked* like it worked for JV because "Journal Voucher" is wide enough to nearly reach the margin regardless of whether the SizedBox trick actually did anything. Real fix: wrap the Column in `pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end)` instead — Row's own space-filling behavior is far more basic and reliably implemented in this `pdf` package than an infinite-width SizedBox nested inside an Expanded. **Lesson for this specific `pdf` package**: prefer `Row(mainAxisAlignment:)`/`Column(mainAxisAlignment:)` over `SizedBox(width/height: double.infinity)` for "fill available space" — the former has been reliable every time it's been tried this session, the latter has now failed silently twice (title_block here, and implicitly whatever the first `SakalAutocomplete` OverflowBox `maxWidth: double.infinity` bug from earlier this session shares in spirit, though that was a Flutter-proper bug, not this `pdf` package).

### Full app-wide rollout — all 21 remaining templates + 20 entry screens
Once the `block` fix was proven on Purchase Order and GRN (converted by hand as references), the exact same redesign was replicated to Sales Invoice/Order/Quotation/Return/Delivery, Purchase Invoice/Return, Cash Receipt, Expense Voucher, and every Inventory document, via 4 parallel background agents each given the two reference files and an explicit 7-step recipe (title_block extraction, div1/div3 accent, div_totals insertion where a totals block exists, sig-above-the-line rules matching however many signature columns a document actually has). Every file balance-checked before commit; several diffs (including every agent-flagged deviation — no totals block on delivery notes/requisitions, 3 signature columns on Delivery, Stock Count's single `submitted_by` instead of `approved_by`) spot-checked directly. Same pass wired `printedByName`/`printedOn` into all 20 remaining entry screens' `PrintEngine.printDocument()` calls (previously only the 4 Finance voucher screens had this) via a second scripted pass (CRLF-aware regex, since the first attempt silently matched 0 files due to `\r\n` line endings).
Pushed as `3d4ac2b`.

### Signatures data-supply — the other half of CLAUDE.md's known gap, now closed
CLAUDE.md's Print/PDF section had flagged since 2026-07-18 that ~10 modules still needed their own `_buildPrintDocument()` to supply a `'signatures'` map — this session closed that gap for all of them (ended up being 14, not 10, once Cash Receipt/GRN's own already-supplied maps were double-checked). Real discovery mid-pass: **8 of these modules had no `_users`/user-lookup mechanism in their datasource/repository stack at all** — GRN, Purchase Return, Purchase Invoice, Material Issue, Stock Transfer Request/Transfer/Receipt, Stock Adjustment. For these, a full `getUsers()`/`getUsersForAutocomplete()` (querying `/rim_users`, `id,full_name`) had to be added through the remote datasource, the domain repository interface, AND the repository impl — not just the screen — since there was no existing pattern to reuse the way Purchase Order's own already-working `getUsers` could be. Material Requisition's own pre-existing `getUsersForAutocomplete` had a real, separate bug (`select: 'full_name'` missing `id`) — noted but deliberately not touched by this pass (out of scope; flagged for a future fix).
`created_by`/`approved_by` were already being fetched from the backend in every case (every remote datasource selects `'*,...'` for its header row) — they just weren't mapped into the Dart model classes, or (for screens using a raw `Map<String, dynamic>` header instead of a typed model — Material Requisition, Price Master, Opening Stock, Stock Count, Stock Count Review) needed no model change at all, just `header['created_by']`/`header['approved_by']` read directly.
**Stock Count's own deliberate exception**: it has no approve step of its own (only Submit — approval happens one level up on Stock Count Review, per that module's own composition design, see the Stock Count section above), so its `authorised_by` binds to its own `submitted_by` column instead of a nonexistent `approved_by`.
Built via 3 more parallel background agents (Purchase/GRN group, Inventory group A, Inventory group B — Stock Count/Review/Opening Stock/Price Master), each given Sales Invoice's and Purchase Order's already-complete implementations as reference. All 57 touched files balance-checked; a representative sample (GRN, Purchase Return, Material Requisition, Price Master, Stock Count, Stock Transfer) diffed directly against the reference pattern before committing.
Pushed as `144827a` (renderer fix + Purchase Order reference) and `b088124` (remaining 13 modules).

### Files touched across this whole part-2 pass
Model layer: `purchase_order_model.dart`, `grn_model.dart`, `purchase_return_model.dart`, `purchase_invoice_model.dart`, and 5 Inventory models (`material_issue`, `stock_adjustment`, `stock_receipt`, `stock_transfer`, `stock_transfer_request`) all gained a `createdBy` field. Plumbing layer: 8 modules' remote datasource + domain repository interface + repository impl each gained a `getUsers`-style method. Screen layer: all ~24 entry screens using `PrintEngine.printDocument()` (signatures + footer wiring). Template layer: all 22 `default_templates/*.dart` files (letterhead restructure + accent styling). Engine layer: `print_models.dart` (`PrintElement.lines`), `pdf_canvas_renderer.dart` (block case + Row/mainAxisAlignment.end fix + footer split), `pdf_flow_renderer.dart` (block case), `print_template_designer_screen.dart` (`_ElementDraft.lines` + 4 switches).
