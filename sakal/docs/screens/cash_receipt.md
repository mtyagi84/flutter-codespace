# Cash Receipt / Cash Collection — Full Build Plan

## Context

The user wants a screen where cash can be collected against any pending customer invoice (cash or credit sale), auto-approved on save like Quick Invoice, with minimal data entry and full keyboard navigation. A reserved placeholder for exactly this already exists: menu feature `SL-RCP` ("Cash Receipt", group `SL-TXN`/Transactions, `approve_allowed=false`), route `/sales/receipts`, and a stub `_Placeholder('Cash Receipt')` widget in `app_router.dart:307` — confirmed via research to be genuinely unbuilt, with no `docs/screens/cash_receipt.md` spec yet (unlike every other Sales screen).

Three parallel research agents confirmed this build is almost entirely composition of existing, proven mechanisms — no new architectural idioms:
- **Settlement/knock-off**: `v_pending_bills` (any posted finance line tagged `inv_bill_no`, with live balance computed from `rid_invoice_bill_settlement`) + `fn_save_finance_voucher`/`fn_post_finance_voucher`, called **directly** (never `fn_post_voucher`, which hardcodes `is_on_account=true`). Posting a `CRV` (Cash Receipt Voucher, `cash_bank_side='DR'`, `voucher_nature='RECEIPT'`) with one CR line per bill (`inv_bill_no`/`inv_bill_date` = that bill's own voucher `trans_no`/`trans_date`, **not** its invoice_no) auto-settles every bill in one shot — `fn_post_finance_voucher`'s settlement loop already does this with zero new SQL needed.
- **Exact reusable template**: Sales Invoice's own cash-collection code (`fn_approve_sales_invoice`, migrations 089/090) already builds this exact CRV shape for same-day cash sales, including the critical **"account_id matching rule"**: the settling line's `account_id` must be the exact value from the bill's own row (`v_pending_bills.account_id`), never re-derived, or `fn_post_finance_voucher`'s settlement lookup silently fails to find a match.
- **Two-CRV-per-currency-leg split**: already precedented — when both local and base cash are collected at once, Sales Invoice posts two entirely separate `CRV` vouchers (one voucher = one `trans_currency`, hard rule). This screen reuses that exact pattern.
- **Prefill source**: `ric_user_quick_invoice_setup` (location, local/base cash accounts) — read-only prefill for this screen, not written to.
- **FX gain/loss**: no existing precedent handles this for receivables (Purchase Bill's `EXC` voucher is the closest analog, but for payables/GR-IR timing). The user worked through the correct accounting by hand during scoping (see below) and confirmed the exact per-receipt, proportional-to-original-booking computation to implement.
- **`fn_resolve_account_link` cannot be reused for the Exchange Gain/Loss account** — verified by reading `032_account_link_setup.sql` directly: its cache table `rim_account_links` has `product_id UUID NOT NULL`, so the function architecturally requires a real product anchor. A cash receipt has no product line at all. Resolve `EXCHANGE_GAIN_LOSS_ACCOUNT` via a **direct** query against `rim_account_link_setup`/`rim_account_link_defaults` for the `COMPANY` granularity only (matching how this link type is "always configured at COMPANY granularity in practice" per the Purchase Bill precedent) — raise `ACCOUNT_LINK_NOT_CONFIGURED` with a human-readable detail if it's missing or configured at a different granularity.

Four scoping decisions were confirmed with the user directly:
1. **FX gain/loss**: computed **per receipt** (not deferred to full clearing) — proportional to whatever fraction of the original invoice is being settled this time, compared against the actual base-currency value of what's collected today. Verified against the user's own worked example: a 25,000 CDF invoice = 10 USD @2500 (2500 CDF/USD); a partial payment of 12,500 CDF @2600 → loss of 0.192307 USD; a later payment of the remaining 12,500 CDF @2400 → gain of 0.208333 USD. Confirmed correct.
2. **Per-invoice entry**: a single "Amount to Apply" field per invoice row, entered in **local currency** (bill balances converted-and-displayed in local-currency-equivalent terms) — not the bill's own party currency. The system auto-splits the local pool first, then the base pool, behind the scenes when both are entered.
3. **Offline**: Save can be queued offline (`SyncEngine`), landing as a real DRAFT once synced; Approve stays online-only, surfaced through the existing unified Pending Approvals screen — same split as Sales Delivery/Return, meaning this needs a genuine Save/Approve function pair and header status, not a single merged online-only action.
4. **Bill scope**: pending bills shown are scoped to the cashier's own current location only, matching how `v_pending_bills` is filtered everywhere else in the app.

---

## 1. Schema (migration `104_cash_receipt.sql`)

### Header + lines

```sql
CREATE TABLE rih_cash_receipt_headers (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id             UUID NOT NULL, company_id UUID NOT NULL, location_id UUID NOT NULL,
    receipt_no            TEXT NOT NULL, receipt_date DATE NOT NULL,
    customer_id           UUID NOT NULL REFERENCES rim_accounts(id),
    local_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,   -- cash entered in local currency, header pool 1
    base_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,   -- cash entered in base currency, header pool 2
    remarks               TEXT,
    status                TEXT NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    crv_local_voucher_no  TEXT, crv_local_voucher_date DATE,
    crv_base_voucher_no   TEXT, crv_base_voucher_date  DATE,
    exc_voucher_no        TEXT, exc_voucher_date DATE,        -- NULL if no FX adjustment was needed
    approved_by UUID, approved_at TIMESTAMPTZ,
    is_deleted BOOLEAN NOT NULL DEFAULT false,
    created_at, created_by, updated_at, updated_by,
    CHECK (local_amount > 0 OR base_amount > 0),
    UNIQUE (client_id, company_id, receipt_no, receipt_date)
);

CREATE TABLE rid_cash_receipt_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL, company_id UUID NOT NULL,
    receipt_no TEXT NOT NULL, receipt_date DATE NOT NULL, serial_no SMALLINT NOT NULL,
    inv_bill_no TEXT NOT NULL, inv_bill_date DATE NOT NULL,   -- the bill's own voucher trans_no/trans_date, from v_pending_bills — NEVER invoice_no
    bill_currency TEXT NOT NULL,                              -- snapshot of that bill's party_currency, display only
    applied_amount_local NUMERIC(18,4) NOT NULL CHECK (applied_amount_local > 0),
    is_deleted BOOLEAN NOT NULL DEFAULT false,
    created_at, created_by, updated_at, updated_by,
    UNIQUE (client_id, company_id, receipt_no, receipt_date, serial_no)
    -- composite FK to header (client_id, company_id, receipt_no, receipt_date)
);
```
Standard `auth_rw_*` RLS policy pair, `REVOKE ALL FROM anon`, `GRANT SELECT/INSERT/UPDATE TO authenticated`.

`customer_account_id` is deliberately **not** stored per line — it's always `header.customer_id`; `fn_approve_cash_receipt` re-fetches and validates each bill's own `account_id` matches the header's customer before using it (defense-in-depth against a stale/tampered draft).

### Voucher type — numbering only

```sql
INSERT INTO rim_voucher_types (voucher_type_code, type_description, voucher_nature, cash_bank_side, reset_frequency, trans_no_format, is_system)
VALUES ('CREC', 'Cash Receipt', 'RECEIPT', 'DR', 'YEARLY', 'CREC/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;
```
`CREC` numbers the receipt document itself (`fn_next_trans_no`) — never posted to the GL directly. GL posting reuses the existing `CRV` (settlement) and `EXC` (FX adjustment, already seeded by migration 059) codes, matching the established "numbering code ≠ posting code" rule (PINV/PUR, MREQ+MISS/MIC, SDEL/COS).

### New view: customers with pending bills (fills a real gap)

Research confirmed no existing query answers "which customers have pending invoices" — every current `v_pending_bills` consumer (Finance Voucher) picks the party *first*, then loads bills. Add a thin wrapper view so the customer picker can filter correctly:

```sql
CREATE OR REPLACE VIEW v_customers_with_pending_bills AS
SELECT DISTINCT b.client_id, b.company_id, b.location_id, b.account_id
FROM v_pending_bills b
JOIN rim_accounts a ON a.id = b.account_id
WHERE a.account_nature = 'Customer';

GRANT SELECT ON v_customers_with_pending_bills TO anon, authenticated, service_role;
```

---

## 2. `fn_save_cash_receipt(p_header JSONB, p_lines JSONB, p_user_id UUID) RETURNS TEXT`

Mirrors `fn_save_sales_delivery`'s shape:
- `p_header`: `{client_id, company_id, location_id, receipt_date, customer_id, local_amount, base_amount, remarks}`.
- `p_lines`: array of `{inv_bill_no, inv_bill_date, bill_currency, applied_amount_local}`.
- Validate: `customer_id` required; `local_amount > 0 OR base_amount > 0`; at least one line; every line's `applied_amount_local > 0` (zero-amount lines rejected outright, same defense-in-depth precedent as Sales Delivery's zero-qty check).
- **Sum-matches-header validation**: resolve a fresh `fn_get_exchange_rate(company, location, base_ccy, local_ccy, receipt_date)` and confirm `sum(applied_amount_local) ≈ local_amount + base_amount * rate` within the standard `0.01` tolerance — raise `RECEIPT_AMOUNT_MISMATCH` with both figures in the detail if not. This is a best-effort save-time check (the Flutter screen already gates the Save button on this); the authoritative math happens at Approve using approve-time rates.
- New-vs-edit DRAFT handling identical to every other module (delete+reinsert lines on re-save, block edits once `status != 'DRAFT'`).
- Returns the new `receipt_no` (`fn_next_trans_no(..., 'CREC')`).

---

## 3. `fn_approve_cash_receipt(p_client_id, p_company_id, p_receipt_no, p_receipt_date, p_approved_by) RETURNS VOID`

This is the core of the build. Structure:

1. Lock receipt header `FOR UPDATE`, must be `DRAFT`.
2. `fn_check_period_open(company_id, receipt_date)` + `fn_check_backdate_allowed(client_id, company_id, 'CASH_RECEIPT', receipt_date)`, **plus an unconditional hard `IF p_receipt_date > CURRENT_DATE THEN RAISE 'FUTURE_DATE_NOT_ALLOWED'`** — the user's requirement ("not the future date") is an absolute rule, not a company-configurable opt-in, so this needs the same belt-and-suspenders pair Sales Delivery already established (soft config check + unconditional hard guard), since `fn_check_backdate_allowed` alone is permissive-by-default when no control row exists for `'CASH_RECEIPT'`.
3. Resolve `local_ccy`/`base_ccy` for the company; resolve `local_cash_account_id`/`base_cash_account_id` via the **existing** `fn_quick_cash_account_local`/`fn_quick_cash_account_base` helpers (migration 089) keyed off `header.created_by` (the cashier who filled the form, same "cash sits in that cashier's drawer" reasoning already established for Quick Invoice) — raise `QUICK_INVOICE_NOT_CONFIGURED` if either is NULL and its pool amount is > 0.
4. **Per line — lock and re-validate each bill**, in a loop over lines **pre-sorted by `(inv_bill_no, inv_bill_date)`** (per this project's documented rule: lock one row per statement, in a loop over an already-sorted key list, never rely on `ORDER BY ... FOR UPDATE` to lock in order):
   - `SELECT party_amount, base_amount, party_currency, account_id, settled_amount FROM rid_finance_lines WHERE trans_no=inv_bill_no AND trans_date=inv_bill_date AND account_id=header.customer_id AND is_deleted=false FOR UPDATE` — this is both the concurrency lock (mirrors Sales Delivery/Return locking their source document) and the re-validation read.
   - If not found, or `account_id` doesn't match `header.customer_id` exactly → raise a clear error (defense against a tampered/stale draft).
   - Convert this line's `applied_amount_local` into the bill's own `party_currency` via a **fresh** `fn_get_exchange_rate(company, location, local_ccy, bill.party_currency, receipt_date)` (same "resolve fresh at approve time, never trust save-time values" precedent as Purchase Bill's rate-inheritance fixes) → this is the line's `party_amount_to_settle`.
   - Live balance = `bill.party_amount - bill.settled_amount` (or `- coalesce(sum from rid_invoice_bill_settlement)`, matching `v_pending_bills`' own computation exactly). If `party_amount_to_settle > live_balance` → raise `RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE` — this is what catches the real concurrency case (another device/user settled this bill between this receipt's Save and Approve).
   - Compute this line's **proportional original base share**: `bill.base_amount * (party_amount_to_settle / bill.party_amount_original)` — using the bill's **original total** `party_amount`, not the remaining balance, since that's what fixes the "per party-currency-unit" originally-booked rate for FX comparison, consistent across however many receipts eventually clear this one bill.
5. **Waterfall split across the two cash pools**: walk the lines (same sorted order) consuming from `header.local_amount` first, then `header.base_amount` for any remainder — a single line's `applied_amount_local` may straddle both pools (split into two "settlement fragments", one per pool, each carrying its own pro-rata share of `party_amount_to_settle` and of the proportional original base share computed in step 4). This is a real, supported edge case (e.g. the local pool has just enough for 3 invoices and a sliver of a 4th) — covered explicitly by a pgTAP test, not just assumed to work.
6. **Build CRV-LOCAL voucher** (if any fragments were funded from the local pool): header `{trans_no:NULL, voucher_type_code:'CRV', is_on_account:false, remarks:'Cash Collection <receipt_no>'}`; line 1 = Cash DR (`local_cash_account_id`, `trans_currency=local_ccy`, `trans_amount`=sum of local-funded fragments, `base_amount = trans_amount * local_to_base_rate`, always-multiply); lines 2+ = one Customer CR per local-funded fragment (`account_id=header.customer_id`, `trans_amount`=fragment's local amount, `party_amount`=fragment's `party_amount_to_settle` share, `party_currency`=that bill's currency, `inv_bill_no`/`inv_bill_date`=that bill's own values). Call `fn_save_finance_voucher` then `fn_post_finance_voucher` directly (never `fn_post_voucher`) — this is what triggers the existing settlement loop (`rid_invoice_bill_settlement` insert + `settled_amount` increment) with zero new SQL.
7. **Build CRV-BASE voucher** identically, if any fragments were funded from the base pool (`trans_currency=base_ccy`, `trans_amount` for each fragment = its local-equivalent portion **divided by** the base→local rate — going back through the same rate that produced it, matching the one place in this codebase that already divides instead of multiplies, Sales Invoice's own collected-amount-vs-invoice-total tolerance check).
8. **FX gain/loss**: for every settlement fragment across both vouchers, `fragment_actual_base = fragment's own CR line base_amount` (computed in step 6/7, via that fragment's own trans_currency→base conversion) vs `fragment_proportional_original_base` (from step 4/5, further pro-rated if the fragment is a partial split of a line). Net all fragments' `(actual - proportional_original)` together (sum with sign) into one `v_net_fx_diff`.
   - If `abs(v_net_fx_diff) > 0.0001`: resolve `EXCHANGE_GAIN_LOSS_ACCOUNT` via the **direct company-level lookup** described above (not `fn_resolve_account_link`). Build a 2-line `EXC` voucher, both lines natively in base currency (`trans_currency=base_ccy`, `base_rate=1`, mirroring Purchase Bill's EXC pattern exactly): if `v_net_fx_diff < 0` (collected less base value than proportionally booked) → DR Exchange Loss / CR Customer; if `> 0` → CR Exchange Gain / DR Customer, both for `abs(v_net_fx_diff)`. **No `inv_bill_no`** on the Customer line — pure GL valuation adjustment, invisible to `v_pending_bills`, exactly matching why Purchase Bill's EXC voucher omits it. Post via `fn_post_voucher(..., 'EXC', receipt_date, exc_lines, 'CASH_RECEIPT', receipt_no, receipt_date, approved_by)`.
   - If no material diff, skip — `exc_voucher_no` stays NULL, matching the header's own nullable design.
9. Mark receipt `APPROVED`, store `crv_local_voucher_no/date`, `crv_base_voucher_no/date`, `exc_voucher_no/date` (whichever were actually posted).

**Worked-example sanity check (must match a pgTAP test exactly)**: invoice 25,000 CDF = 10 USD booked @2500. Receipt 1: 12,500 CDF applied, today's rate 2600 CDF/USD. `party_amount_to_settle = 12500` (CDF is both local and party currency here, so no conversion needed for the party leg). `proportional_original_base = 10 * (12500/25000) = 5.0` USD. `fragment_actual_base = 12500 / 2600 = 4.807692` USD (via always-multiply from the CRV-LOCAL voucher: `trans_amount(CDF) * local_to_base_rate`, where `local_to_base_rate = 1/2600`). `v_net_fx_diff = 4.807692 - 5.0 = -0.192308` → **loss of 0.192308 USD**, DR Exchange Loss / CR Customer. Matches the user's own figure.

---

## 4. Flutter: Cash Receipt Feature Layer

New files under `lib/features/sales/`, mirroring Sales Delivery's exact structural set:
```
data/datasources/cash_receipt_remote_ds.dart
data/datasources/cash_receipt_local_ds.dart
data/repositories/cash_receipt_repository_impl.dart
domain/repositories/cash_receipt_repository.dart
presentation/providers/cash_receipt_providers.dart
presentation/screens/cash_receipt_entry_screen.dart
presentation/screens/cash_receipt_list_screen.dart
```
`route_names.dart` gains `cashReceiptEntry = '/sales/receipt-entry'` (the existing `salesReceipts = '/sales/receipts'` route in `app_router.dart:307` becomes the **list** screen, replacing `_Placeholder('Cash Receipt')` — matches the List→Entry convention used everywhere else). `ScreenPermissionMixin` wired per CLAUDE.md convention (`screenName = '/sales/receipts'`, matching the seeded `SL-RCP` feature's route).

**Entry screen key behaviors**:
- **Prefill on open** (read-only, non-editable): fetch `ric_user_quick_invoice_setup` for the session user (same `GET` shape `quick_invoice_setup_screen.dart` already uses) → Location, Local Cash Account, Base Cash Account displayed as plain text. If no row exists, block with a clear message (matches `QUICK_INVOICE_NOT_CONFIGURED`).
- **Receipt Date**: date picker, defaults to today, future dates disabled client-side (mirrors the server-side hard guard).
- **Customer picker**: `SakalAutocomplete`, options sourced from the new `v_customers_with_pending_bills` view joined to `rim_accounts` for display — only customers with an outstanding bill at this location appear.
- **On customer pick**: fetch pending bills via `GET /v_pending_bills?account_id=eq.<id>&location_id=eq.<loc>&company_id=eq.<company>` (identical query shape to Finance Voucher's own `_loadPendingBills`). For each distinct `party_currency` present among the returned bills, resolve two live rates once (`fn_get_exchange_rate(party_ccy→base_ccy)`, `fn_get_exchange_rate(party_ccy→local_ccy)`) and derive all three display columns per row from `balance_amount` — no per-row rate fetch, one fetch per distinct currency.
- **Header**: "Cash Received (Local)" and "Cash Received (Base)" fields, both optional, at least one must be `> 0`. Live-computed read-only "Total Receipt (Local Equivalent)" = `local + base * rate(base→local)`.
- **Invoice rows — three balance columns, per explicit user request** ("so that user can have a clear picture"), not just one local-equivalent figure:
  - **Balance (Customer Currency)** — `v_pending_bills.balance_amount`/`party_currency` as returned, unconverted, the bill's own ground truth.
  - **Balance (Base Currency)** — `balance_amount * rate(party_ccy→base_ccy)`.
  - **Balance (Local Currency)** — `balance_amount * rate(party_ccy→local_ccy)`.
  All three are read-only/informational. A single editable "Apply" field per row (entered in local currency, per the confirmed design) sits alongside them — the three balance columns are context, not additional entry fields. Running total of all "Apply" fields shown against the header total; Save disabled until they match within `0.01` tolerance.
- **Keyboard chaining**: mirrors Sales Invoice's per-row `FocusNode` pattern (`onFieldSubmitted` on one row's Apply field → `requestFocus()` on the next row's Apply field; the last row's submit moves focus to the Save button once totals match) — matches "keyboard navigable, minimal data entry."
- **Remarks**: optional free-text field, consistent with every other module's convention.
- **Save button** (single action, no separate "Approve" button on this screen — matches the seeded `SL-RCP.approve_allowed=false`):
  - **Online**: call `fn_save_cash_receipt` then immediately `fn_approve_cash_receipt` in the same action (mirrors Sales Invoice's own "Save IS approve" chaining).
  - **Offline**: `SyncEngine.enqueue(documentType:'CASH_RECEIPT', endpoint:'/rpc/fn_save_cash_receipt', payload:{...})` + local cache write; lands as a real DRAFT once synced, picked up later by the unified Pending Approvals screen — Approve is never queued offline.
- **Posted Journal Entries section**: once `APPROVED`, show `crv_local_voucher_no`/`crv_base_voucher_no`/`exc_voucher_no` (whichever are non-null) — built in from day one, not retrofitted later (avoiding the exact gap already caught and fixed once for Sales Invoice).
- No rate/tax/discount mechanics beyond what's described — the screen is deliberately simple.

---

## 5. Offline Support

Same shape as Sales Delivery's own build (schema bump to `24`, since Sales Delivery/Return already used `23`):
- `lib/core/database/tables/cash_receipt_cache_tables.dart` — `CashReceiptHeadersCache`/`CashReceiptLinesCache`.
- `cash_receipt_local_ds.dart`, repository `_local`/`_isOffline` plumbing.
- `SyncEngine._renameLocalDocument`: new `case 'CASH_RECEIPT':` branch.
- **Unified Pending Approvals screen** (`sales_pending_approvals_screen.dart`) gains a 4th document type: `CASH_RECEIPT`, listing DRAFT receipts (`listDraftCashReceiptsForReview`), dispatching to `fn_approve_cash_receipt` — same per-row error isolation the screen already has for the other three types. Card body shows the invoice(s) being settled and amounts, no stock preview needed (this document never touches stock).
- List screen: merge `listReceipts()` + pending-sync badge, matching the established pattern.

---

## 6. Print Support

Standard 4-switch registration in `print_field_registry.dart` + `cash_receipt_default_template.dart` + `print_template_provider.dart` case + `print_sample_data.dart` case — a payment receipt is exactly the kind of document a customer expects a printed acknowledgment for.
- **Scalar fields**: `header.receipt_no`, `.receipt_date`, `.customer_name`, `.location_name`, `.local_amount`, `.base_amount`, `.total_local_equivalent`, `.remarks`, `.status`, plus `_companyFields`/`_signatureFields`.
- **Lines table row fields**: `inv_bill_no`, `inv_bill_date`, `bill_currency`, `applied_amount_local` — no rate/tax fields, matching the document's own simple shape.
- **Signatures**: `prepared_by`=`created_by`, `authorised_by`=`approved_by` (for an online auto-approved receipt these resolve to the same person — expected, not a bug).

---

## 7. `docs/screens/cash_receipt.md`

Authored alongside the build, following the established template (`sales_delivery.md`'s structure): Screen Name → Description → Layout → Functionality (header fields, the waterfall-split algorithm, the FX gain/loss algorithm spelled out with the worked example) → Data Flow → Open Questions/Known Bugs → Build Checklist → Build Session Notes.

---

## 8. pgTAP: `backend/tests/104_cash_receipt_test.sql`

Mirrors the established structure (hardcoded UUIDs, `test_results` temp table). Minimum coverage:
1. Save + Approve a simple local-currency-only receipt against ONE pending bill (same currency as base, no FX) — assert `CREC`-numbered `receipt_no`, `DRAFT`→`APPROVED`, `CRV` voucher balanced, `v_pending_bills` balance reduced correctly, `settled_amount` incremented.
2. A receipt settling **two** bills in one action — confirm both get knocked off from a single CRV voucher (multi-invoice settlement, no new SQL needed beyond correct line construction).
3. A receipt entering **both** local and base amounts, funding across the waterfall — confirm two separate `CRV` vouchers are posted, each individually balanced.
4. A single bill's applied amount **straddling both pools** — confirm it produces two settlement fragments (one per voucher) and both correctly reduce the SAME bill's balance.
5. **The user's own worked FX example, exactly**: 25,000 CDF invoice = 10 USD @2500; partial receipt of 12,500 CDF @2600 → assert `EXC` voucher posts a **loss of 0.192308 USD** (DR Exchange Loss, CR Customer); a second receipt for the remaining 12,500 CDF @2400 → assert a **gain of 0.208333 USD**.
6. A receipt with `applied_amount` for a bill exceeding its live remaining balance → `RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE`.
7. Future-dated receipt → `FUTURE_DATE_NOT_ALLOWED`.
8. Header/line total mismatch at Save → `RECEIPT_AMOUNT_MISMATCH`.
9. Concurrency: two receipts drafted against the same bill's remaining balance, approved back-to-back — the second, if it would overshoot, gets `RECEIPT_AMOUNT_EXCEEDS_PENDING_BALANCE` rather than a silent overshoot (mirrors Sales Delivery/Return's own proven concurrency test shape).

---

## Verification Plan

1. Run migration 104 against Supabase; confirm no `CREATE TRIGGER`/`CREATE POLICY` re-run failures.
2. Run `104_cash_receipt_test.sql` — target 100% pass, with particular scrutiny on test 5 (the user's own worked FX example) since it's the most novel and highest-risk piece of logic in this build.
3. `flutter analyze` clean (0 warnings) across all new/changed files.
4. Manual click-through: open Cash Receipt screen → confirm Location/Local Cash Account/Base Cash Account are prefilled and read-only → pick a customer with pending bills → enter a local-currency amount → apply it across two invoices via keyboard-only entry → Save → confirm auto-approval, CRV voucher visible, both invoices' balances reduced → repeat with both local and base amounts entered → confirm two CRV vouchers post → test with a foreign-currency (non-local, non-base) customer invoice to confirm the FX gain/loss voucher posts correctly → Save offline (airplane mode) → confirm "Pending sync" badge → reconnect → confirm sync + the draft appears in the unified Pending Approvals screen → Approve there → confirm settlement completes.
5. Print preview — confirm invoice-line breakdown prints correctly, signatures resolve real names.

---

## Build Session Notes (2026-07-22)

Built end-to-end in one session: migration 104 (`rih_cash_receipt_headers`/`rid_cash_receipt_lines`, `CREC` voucher type, `v_customers_with_pending_bills` view, `fn_resolve_company_account_link` helper, `fn_save_cash_receipt`, `fn_approve_cash_receipt`), pgTAP suite (`104_cash_receipt_test.sql`, 16 assertions), full Flutter layer (datasources, repository, providers, entry screen, list screen, route wiring), offline support (Drift cache tables at schema v24, local datasource, `SyncEngine` `CASH_RECEIPT` case), Cash Receipt wired into the unified Pending Approvals screen as a 4th document type, and print support (registry, default template, sample data).

**Two renames applied per user feedback during plan review, before any code was written**: `rid_sales_receipt`→`rid_cash_receipt` (and the header table renamed to match: `rih_cash_receipt_headers`), and the pending-invoice picker rows show three separate currency columns (Customer/Base/Local) rather than a single local-equivalent figure, so the cashier has the full picture at a glance. Functions/files/voucher code (`CREC`) all renamed consistently to `cash_receipt`/`CashReceipt` throughout, not just the two tables literally named.

**FX gain/loss algorithm — confirmed against the user's own hand-worked example before writing any SQL**: 25,000 CDF invoice = 10 USD booked @2500 (2500 CDF/USD); a partial receipt of 12,500 CDF @2600 → the proportional original booking (5.0 USD) vs. the actual base value collected (12500/2600 = 4.807692 USD) → a **loss of 0.192307 USD**, matching the user's figure exactly (stored value rounds to 0.1923 at this schema's standard NUMERIC(18,4) precision — same number, not a discrepancy). The remaining 12,500 CDF @2400 on a later receipt → **gain of 0.208333 USD** (stored 0.2083). Computed **per receipt** (not deferred to full bill clearing), proportional to whatever fraction of the bill's *original* `party_amount` is being settled this time — never the remaining balance, which stays constant across however many receipts eventually clear one bill.

**Two real bugs caught and fixed during my own review pass, before any external testing**:
1. `fn_resolve_account_link` cannot resolve `EXCHANGE_GAIN_LOSS_ACCOUNT` for this document — its cache table `rim_account_links.product_id` is `NOT NULL`, an architectural requirement a receipt with no product line can't satisfy. Added `fn_resolve_company_account_link` — a direct `rim_account_link_setup`/`rim_account_link_defaults` lookup restricted to `COMPANY` granularity (the only granularity that makes sense for a link type with no product/category/location context).
2. Two Flutter bugs in the entry screen: (a) `_bills` rows were disposed synchronously inside the same `setState` that replaced the list on customer/date change — the exact same FocusNode-disposal timing bug this project already hit once on Sales Invoice's line rows (`feedback_sales_invoice_focusnode_dispose_crash`); fixed with the same deferred-to-screen's-own-`dispose()` pattern (`_pendingBillDisposal`). (b) `_reloadBaseToLocalRate()` was called before the header's real `receipt_date` was loaded when reopening a DRAFT, computing the live-validation rate against today's date instead of the draft's own date; fixed by reordering `_init()` so the rate (and the pending-bills fetch) resolve only after the header load completes.

**Waterfall split (local pool first, then base pool) and the possibility of a single bill straddling both pools** — a real, tested edge case (test 3 in the pgTAP suite), not just an assumption. Each fragment gets its own pro-rated share of both the party-currency settlement amount and the proportional-original-base figure, so the FX computation stays correct even when a bill's applied amount is split across two separately-posted CRV vouchers.

**Verification status**: **Backend confirmed** — migration 104 applied clean and `104_cash_receipt_test.sql` passed all 16/16 assertions against real Supabase (2026-07-22), including test 11/12 (the user's own worked FX example, exact match) and test 8/9 (a single bill straddling both cash pools). **Flutter confirmed** — `dart run build_runner build` generated the new Drift tables (schema v24) with no errors (187 outputs, one harmless SDK/analyzer version-mismatch warning only), and `flutter analyze` came back clean (0 issues) in Codespace. Not yet done: `flutter test`, and the manual click-through per the Verification Plan above (this is the one layer no automated check covers — keyboard-only entry across multiple invoices, the 3-currency-column display, offline save + Pending Approvals round-trip, and print preview all still need a real run-through in the browser).
