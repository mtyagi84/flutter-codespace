# Finance — Payment & Receipt Voucher
## Screen Design Specification

**Scope:** CPV (Cash Payment), BPV (Bank Payment), CRV (Cash Receipt), BRV (Bank Receipt)
**Module:** Finance
**Status:** ✅ Flutter screen + SQL migrations DONE — running in Codespace

---

## Voucher Types in scope

| Code | Description | Line 1 (Cash/Bank) Nature |
|---|---|---|
| CRV | Cash Receipt Voucher | DR Cash |
| BRV | Bank Receipt Voucher | DR Bank |
| CPV | Cash Payment Voucher | CR Cash |
| BPV | Bank Payment Voucher | CR Bank |

Other voucher types (JV, SIV, SDN, SCN, CDN, CCN) have separate screens.

---

## Composite Transaction Key — Critical Design Rule

`trans_no` **alone is not unique** because the sequence resets monthly or yearly.
The same number can legitimately reappear in a later period.

**The correct identity for every transaction is `(trans_no, trans_date)` — they must always travel together.**

This applies to **all transaction header tables across all ERP modules** (Finance, Sales, Purchase, Inventory):
- `rih_finance_headers` unique key: `(client_id, company_id, location_id, trans_no, trans_date)`
- `rid_finance_lines` FK + unique key: includes `trans_date`
- `rid_cheque_register` FK: includes `trans_date`
- All future Sales/Purchase/Inventory header tables must follow the same pattern

---

## Business Rules

### Document Numbering
- Trans No assigned at **Draft save time** (not at Post).
- Format is parameterized per voucher type: template in `rim_voucher_types.trans_no_format`.
- Tokens: `{TYPE}` `{LOC}` `{YYYY}` `{MM}` `{DD}` `{SEQ5}` `{SEQ4}` `{SEQ6}`
- Sequence resets based on `reset_frequency`: DAILY | MONTHLY | YEARLY | NEVER
- Example: `{TYPE}/{LOC}/{YYYY}/{SEQ5}` → `BRV/HO/2026/00001`
- Sequence tracked in `rih_trans_no_seq`.

### Draft vs Posted
- **Save Draft** → `is_posted = false`. Fully editable. Appears in Drafts list.
- **Post Voucher** → `is_posted = true`. Locked permanently. Never editable again.
- Only users with `approve_allowed` on this feature can Post.
- Posted vouchers corrected via **Reversal** only (new opposite voucher linked via `reversal_of_trans_no`).

### Against Bill vs On Account
| | Against Bill (`is_on_account = false`) | On Account (`is_on_account = true`) |
|---|---|---|
| Party | Single customer/supplier | Multiple accounts (any type) |
| Bills table | Shows pending bills from `v_pending_bills` | Not shown |
| `inv_bill_no` on line | Populated (bill reference) | NULL |
| Settlement | Instant on Post — updates `rid_invoice_bill_settlement` | Deferred to a separate Allocation screen |
| Entry UX | Party dropdown → bill table → enter pay amounts | Table of account lines (Account / Amount / Remarks) |

### Line 1 — Cash / Bank (always)
- **Line 1 is always the Cash or Bank account** — enforced in UI and DB.
- `trans_nature` is auto-set from voucher type (DR for receipts, CR for payments). Not editable by user.
- All subsequent lines are the opposite nature — auto-set.
- Currency of the voucher = currency of the Cash/Bank account (locked when account is selected).

### Party Currency (per line)
- `party_currency` / `party_amount` / `party_rate` stored on **every line** — needed for ledger printing without joins.
- **Line 1 (Cash/Bank):** party_currency = bank account's own currency (same as trans_currency).
- **Against Bill lines:** party_currency = customer/supplier ledger currency; party_rate = 1 BASE = X party_currency.
- **On Account lines:** party_currency = that specific account's ledger currency (each line independently).
- Formula: `party_amount = base_amount × party_rate = (trans_amount / trans_rate) × party_rate`

### Rate Formulas
```
base_rate   = 1 BASE = X trans_currency    (e.g. 1 USD = 2825 CDF)
party_rate  = 1 BASE = X party_currency    (e.g. 1 USD = 1 USD = 1)

balance_trans = balance_party × base_rate / party_rate   (party → trans)
pay_party     = pay_trans     × party_rate / base_rate   (trans → party)
```

### Cheque Payments
- Payment Mode: **locked to CASH** for CRV/CPV; **editable** for BRV/BPV.
- If `payment_mode = CHEQUE`: header shows Cheque No + Cheque Date fields.
- **Cheque No is required** when payment mode = CHEQUE (validated before save).
- A row is inserted into `rid_cheque_register` on posting. `cheque_date` falls back to `trans_date` if not entered.
- Cheque status: ISSUED → CLEARED | BOUNCED | CANCELLED (managed on a separate Cheque Register screen).

---

## Tables (as of Migration 021)

### `rih_finance_headers`
| Column | Type | Notes |
|---|---|---|
| client_id, company_id, location_id | uuid | Tenant key |
| **trans_no** | text | Generated on first save by `fn_next_trans_no` |
| **trans_date** | date | Together with trans_no forms the unique identity |
| voucher_type_code | text FK | CRV / BRV / CPV / BPV |
| payment_mode_code | text FK | CASH / CHEQUE / NEFT etc. |
| is_on_account | boolean | false = Against Bill, true = On Account |
| reference_no | text | External ref |
| reference_date | date | |
| cheque_no | text | Only when payment_mode = CHEQUE |
| cheque_date | date | COALESCE to trans_date in post function |
| remarks | text | Overall voucher remark |
| is_posted | boolean DEFAULT false | |
| posted_at, posted_by | | Set on Post |
| reversal_of_trans_no | text FK self | For reversal link |
| **Unique key** | | `(client_id, company_id, location_id, trans_no, trans_date)` |

### `rid_finance_lines`
| Column | Type | Notes |
|---|---|---|
| client_id, company_id, location_id | uuid | |
| trans_no | text | Composite FK with trans_date |
| **trans_date** | date | Added in migration 021 — backfilled from header |
| serial_no | integer | 1 = Cash/Bank, 2+ = counterpart accounts |
| account_id | uuid FK | rim_accounts |
| trans_nature | text | DR / CR |
| trans_amount | numeric(18,4) | In transaction currency |
| trans_currency | text | Locked from line 1 account |
| base_amount | numeric(18,4) | In company base currency |
| base_rate | numeric(18,8) | 1 BASE = X trans_currency |
| local_amount | numeric(18,4) | In local/regional currency |
| local_rate | numeric(18,8) | 1 BASE = X local_currency |
| party_amount | numeric(18,4) | In account's ledger currency — ALL lines |
| party_currency | text | Account's own currency — ALL lines |
| party_rate | numeric(18,8) | 1 BASE = X party_currency — ALL lines |
| inv_bill_no | text | Invoice reference (self-ref on invoice, payment-ref on receipt) |
| inv_bill_date | date | Paired with inv_bill_no — composite invoice key |
| settled_amount | numeric(18,4) DEFAULT 0 | Running total of payments received |
| line_remarks | text | Editable on party/On Account lines |
| **Unique key** | | `(client_id, company_id, location_id, trans_no, trans_date, serial_no)` |
| **FK** | | `(client_id, company_id, location_id, trans_no, trans_date)` → rih_finance_headers |

### `rid_cheque_register`
| Column | Type | Notes |
|---|---|---|
| trans_no | text | Composite FK with trans_date |
| **trans_date** | date | Added in migration 021 |
| cheque_no | text NOT NULL | |
| cheque_date | date NOT NULL | Falls back to trans_date in fn_post |
| bank_name, branch | text | |
| cheque_status | text DEFAULT 'ISSUED' | ISSUED / CLEARED / BOUNCED / CANCELLED |
| cleared_date, bounced_date | date | |
| cancellation_reason | text | |
| **FK** | | `(client_id, company_id, location_id, trans_no, trans_date)` → rih_finance_headers |

### `v_pending_bills` (VIEW — migration 020 + updated in 021)
Shows invoice lines that still have an outstanding balance — used by Against Bill mode.

| Column | Source | Notes |
|---|---|---|
| client_id, company_id, location_id, account_id | rid_finance_lines | |
| trans_no, trans_date | rih_finance_headers | Original invoice header |
| inv_bill_no, inv_bill_date | rid_finance_lines | The invoice number (self-referencing) |
| bill_amount | l.party_amount | Original invoice amount in party currency |
| party_currency | | |
| settled_amount | SUM(paid_amount) from rid_invoice_bill_settlement | |
| balance_amount | bill_amount − settled_amount | Only rows > 0.001 shown |

**Filter conditions:** `inv_bill_no IS NOT NULL`, `is_posted = TRUE`, `is_deleted = FALSE`, `balance > 0.001`

**JOIN fix (migration 021):** Header JOIN now uses `h.trans_no = l.trans_no AND h.trans_date = l.trans_date` (composite key, not just trans_no).

### `rid_invoice_bill_settlement`
| Column | Notes |
|---|---|
| trans_no, trans_date | Payment voucher's header composite key |
| voucher_type_code | |
| account_id | Customer or supplier account |
| inv_bill_no, inv_bill_date | Original invoice's composite key |
| settlement_no | 1st, 2nd, 3rd... partial payment |
| was_balance | Outstanding before this payment (party currency) |
| paid_amount | Amount applied (party currency) |
| paid_amount_trans | Same in transaction currency |

---

## PG Functions

### `fn_next_trans_no(client_id, company_id, location_id, voucher_type_code)`
Returns next document number atomically; handles sequence reset by frequency.

### `fn_save_finance_voucher(p_header jsonb, p_lines jsonb, p_user_id uuid) → text`
Returns the saved `trans_no`.

**New voucher** (trans_no blank):
1. Call `fn_next_trans_no` to get trans_no
2. INSERT header
3. INSERT all lines with trans_date copied from header

**Edit draft** (trans_no provided):
1. Validate voucher exists and is NOT posted
2. DELETE existing lines (releases FK hold so trans_date can change)
3. UPDATE header (trans_date may change freely now)
4. INSERT lines with current trans_date

> ⚠️ Cannot use simple UPSERT `ON CONFLICT (trans_no) DO UPDATE SET trans_date = ...` because changing trans_date on a draft would insert a NEW row (different composite key). Must split into explicit DELETE → UPDATE → INSERT.

### `fn_post_finance_voucher(p_client_id, p_company_id, p_location_id, p_trans_no, p_trans_date, p_posted_by)`
1. Lock header row using composite key `(trans_no, trans_date)` — `FOR UPDATE`
2. Validate not already posted
3. Validate DR = CR (tolerance 0.01)
4. Mark `is_posted = true`
5. If `cheque_no IS NOT NULL`: insert into `rid_cheque_register` (cheque_date = `COALESCE(cheque_date, trans_date)`)
6. If `is_on_account = false`: for each line with `inv_bill_no IS NOT NULL`:
   - Look up original invoice line using `(trans_no=inv_bill_no, trans_date=inv_bill_date)` composite key
   - Get current `was_balance`
   - Insert settlement row into `rid_invoice_bill_settlement`
   - Update `settled_amount` on the original invoice line

### `fn_reverse_finance_voucher(trans_no, trans_date, reversed_by, reason)` *(not yet built)*
Creates mirror-image voucher, links via `reversal_of_trans_no`.

---

## Flutter Screen — Actual Implementation

**File:** `lib/features/finance/presentation/screens/finance_voucher_entry_screen.dart`

### Header Card (5 rows)

All fields are `SizedBox(height: 56)` — **explicit height on every field**, not IntrinsicHeight. This is the only reliable way to get identical field heights across all rows because `DropdownButtonFormField` reports a larger intrinsic height than `TextFormField`. A shared `const dec` (`InputDecoration`) and `field()` helper remove boilerplate.

| Row | Fields |
|---|---|
| Row 1 | Voucher Type (dropdown) \| Voucher No (read-only display) \| Date (date picker) |
| Row 2 | Cash/Bank Account (dropdown) \| Currency (display chip) \| Rate (editable, hidden when same as base) |
| Row 3 | Payment Mode (locked for cash types) \| Ref No \| Ref Date \| Remarks |
| Row 4 (conditional) | Cheque No \| Cheque Date — shown only when payment_mode = CHEQUE |
| Row 5 | Against Bill ◉ / On Account ○ radio toggle |

### Account Query (PostgREST embedded join)
```
GET /rim_accounts?select=id,account_name,account_nature,
    rim_currencies!account_currency_id(currency_id)
```
Currency extracted via:
```dart
String _extractCurrency(Map<String, dynamic> account) {
  final rel = account['rim_currencies'];
  if (rel is Map) return rel['currency_id'] as String? ?? _baseCurrency;
  return _baseCurrency;
}
```

### Against Bill Section
1. Customer/Supplier dropdown (filters to `account_nature IN (Customer, Supplier)`)
2. On party selection: fetch party rate from `fn_get_exchange_rate` if party currency ≠ base
3. Horizontally scrollable pending bills table from `v_pending_bills`:

| Column | Width | Notes |
|---|---|---|
| Bill No | 130 | Left-aligned |
| Bill Date | 95 | Left-aligned |
| Bill Amt (party curr) | 110 | Right-aligned |
| Paid (party curr) | 100 | Right-aligned |
| Balance (party curr) | 100 | Right-aligned, red |
| Balance (trans curr) | 105 | Right-aligned, converted |
| Pay (trans curr) | 125 | **Editable** text field |
| Pay (party curr) | 110 | Right-aligned, calculated, green |

### On Account Section
- Column headers shown **once at top** (Account | Amount (currency) | Remarks) — not repeated per row.
- Each data row: account dropdown (no label), amount field, remarks field, remove button.
- When an account's currency differs from trans currency, currency code shown as `suffixText` on the amount field.
- `+ Add Line` button top-right.
- Duplicate accounts greyed out in dropdown.

### Data Models
```dart
class _BillRow {
  final String transNo, transDate, invBillNo;
  final String? invBillDate;
  final double billAmount, settledAmount, balanceAmount;
  final String partyCurrency;
  final TextEditingController payTransCtrl;
}

class _AccountLine {
  String? accountId, accountName;
  String accountCurrency;   // ledger currency of this account (per-line)
  final TextEditingController amountCtrl, remarksCtrl;
}
```

### Validations (before Save Draft)
- Voucher type must be selected
- Cash/Bank account must be selected
- Against Bill mode: party must be selected
- Payment mode = CHEQUE: cheque_no must be non-empty
- Total amount > 0
- At least one payment line (bills with pay > 0, or On Account lines with amount > 0)

### Known Dart Quirk
`.firstOrNull?['key'] as String?` inside a ternary expression causes a parse error — Dart consumes the `?` as the ternary operator instead of the null-aware index operator. Fix: split into two statements.
```dart
// Wrong — Dart parse error inside ternary:
final name = id != null ? list.where(...).firstOrNull?['name'] as String? : null;

// Correct:
final acc  = id != null ? list.where(...).firstOrNull : null;
final name = acc?['name'] as String?;
```

### Text Selection (app-wide)
`SelectionArea` wraps `MaterialApp.router` in `lib/app.dart`. Flutter Web renders text on canvas by default — not browser-selectable. `SelectionArea` makes all `Text` widgets selectable app-wide. Form fields opt out automatically.

---

## Migrations Applied

| Migration | What it does |
|---|---|
| 019_finance_vouchers.sql | rih_finance_headers, rid_finance_lines, rid_cheque_register, rid_invoice_bill_settlement, fn_save/post/reverse_finance_voucher, fn_next_trans_no |
| 020_pending_bills_view.sql | CREATE VIEW v_pending_bills |
| 021_composite_trans_key.sql | Widen unique key to (trans_no, trans_date) on all 3 tables; add trans_date to lines + cheque_register; update v_pending_bills JOIN; rewrite fn_save + fn_post with composite key |

**DDL order in migration 021 (critical):**
Child FK constraints must be dropped BEFORE the parent unique index can be dropped.
1. DROP rid_finance_lines_header_fk
2. DROP rid_cheque_register_header_fk
3. DROP uq_rih_finance_headers
4. ADD new uq_rih_finance_headers (with trans_date)
5. ADD trans_date to child tables, backfill, NOT NULL
6. ADD new child FKs (composite)

---

## Seed Data

**File:** `backend/seeds/seed_dummy_invoices.sql`

Inserts 5 posted SIV (Sales Invoice Voucher) headers + lines so the Against Bill mode has bills to display. Auto-discovers customer and revenue accounts for the given company. Invoice 4 includes a partial settlement (2000 paid, 6000 outstanding) to test the balance column.

Fill in `p_client_id`, `p_company_id`, `p_location_id` at the top of the DO block before running.

---

## What is NOT in this screen

- Journal Voucher (JV) — separate screen
- Debit/Credit Notes (SDN/SCN/CDN/CCN) — separate screens
- Sales Invoice Voucher (SIV) — separate Sales module screen
- Cheque Register management — separate screen
- On Account → Against Bill allocation — separate Allocation screen
- Bank Reconciliation — separate screen
- Reversal flow — `fn_reverse_finance_voucher` not yet built

---

*Design agreed: 2026-06-21*
*Screen built: 2026-06-25 (commit ff2ac9a)*
*Composite key + cheque register + party currency fixes: 2026-06-26 (commits 74939f1, 6203a66, aaa8fb6, 6714097)*
*Text selection (SelectionArea): 2026-06-26 (commit 750220d)*
*Trans No: assigned at Draft save time*
*No delete — correction by Reversal only*
