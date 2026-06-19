# Finance — Payment & Receipt Voucher
## Screen Design Specification

**Scope:** CPV (Cash Payment), BPV (Bank Payment), CRV (Cash Receipt), BRV (Bank Receipt)
**Module:** Finance
**Status:** Design agreed — SQL + Flutter pending

---

## Voucher Types in scope for this screen

| Code | Description | Cash/Bank DR/CR |
|---|---|---|
| CRV | Cash Receipt Voucher | DR Cash |
| BRV | Bank Receipt Voucher | DR Bank |
| CPV | Cash Payment Voucher | CR Cash |
| BPV | Bank Payment Voucher | CR Bank |

Other voucher types (JV, SDN, SCN, CDN, CCN, SIV) have separate screens.

---

## Business Rules

### Document Numbering
- Trans No assigned at **DRAFT save time** (not at post).
- Format is **parameterized per voucher type** using a template string stored in `rim_voucher_types.trans_no_format`.
- Tokens: `{TYPE}` `{LOC}` `{YYYY}` `{MM}` `{DD}` `{SEQ5}` `{SEQ4}` `{SEQ6}`
- Sequence resets based on `reset_frequency`: DAILY | MONTHLY | YEARLY | NEVER
- Sequence tracked in `rih_trans_no_seq (company_id, location_id, voucher_type)`.
- Example format `{TYPE}/{LOC}/{YYYY}/{SEQ5}` → `CRV/KIN/2026/00001`

### Draft vs Posted
- **Save Draft** → `is_posted = false`. Fully editable. Appears in Drafts list.
- **Post Voucher** → `is_posted = true`. Locked permanently. Never editable again.
- Only users with `approve_allowed` on this feature can Post.
- Posted vouchers can only be corrected via a **Reversal** (new opposite voucher linked via `reversal_of_trans_no`).

### On Account vs Against Invoice
- **Against Invoice** (`is_on_account = false`): Single customer/supplier only. `inv_bill_no` and `inv_bill_date` populated on the party line. Settlement table updated on posting.
- **On Account** (`is_on_account = true`): Multiple customers/suppliers/accounts allowed. `inv_bill_no = NULL`. Settlement done later via a separate allocation screen.

### Line Rules
- **Line 1 is always the Cash or Bank account** — enforced in UI and DB.
- Line 1 `trans_nature` is auto-set from `rim_voucher_types.cash_bank_side` (DR for receipts, CR for payments). User cannot change it.
- All subsequent lines are the opposite nature — auto-set, user cannot change.
- `line_remarks` is editable **only on party lines (line 2+)**. For On Account with multiple parties, each party has their own remark.
- `header.remarks` = overall voucher remark (for voucher header/footer).

### Multi-Currency
- Transaction currency = currency of the Cash/Bank account selected on line 1 (locked when account is chosen).
- User enters `trans_amount`. System auto-calculates `base_amount` and `local_amount` using exchange rates.
- `party_amount` / `party_currency` / `party_rate` stored on **every line** (not just party lines) — needed for ledger printing of any account without joining other tables.
- User can override the exchange rate if needed (stored in `party_rate` / `base_rate` / `local_rate`).

### Cheque Payments
- If `payment_mode = CHEQUE`, header shows `cheque_no` and `cheque_date`.
- A row is inserted into `rih_cheque_register` on posting.
- Cheque status: ISSUED → CLEARED | BOUNCED | CANCELLED (managed from a separate Cheque Register screen).

---

## Tables

### `rim_voucher_types` (master)
| Column | Type | Notes |
|---|---|---|
| voucher_type_code | text PK | CRV, CPV, BPV, BRV, JV... |
| type_description | text | |
| voucher_nature | text | RECEIPT / PAYMENT / JOURNAL / DEBIT_NOTE / CREDIT_NOTE / STOCK |
| cash_bank_side | text | DR / CR / NULL |
| reset_frequency | text | DAILY / MONTHLY / YEARLY / NEVER |
| trans_no_format | text | e.g. `{TYPE}/{LOC}/{YYYY}/{SEQ5}` |
| is_system | boolean | SAKAL-shipped vs client-defined |
| standard tenant + audit columns | | |

### `rim_payment_modes` (master)
| Column | Type | Notes |
|---|---|---|
| payment_mode_code | text | CASH, CHEQUE, NEFT, RTGS, WIRE, DD |
| payment_mode_name | text | |
| is_active | boolean | |
| standard tenant + audit columns | | |

### `rih_trans_no_seq` (sequence tracker)
| Column | Type | Notes |
|---|---|---|
| client_id, company_id, location_id | uuid | |
| voucher_type_code | text | |
| current_seq | integer | incremented atomically |
| last_reset_date | date | compared to reset_frequency |

### `rih_finance_headers`
| Column | Type | Notes |
|---|---|---|
| trans_no | text | generated on first save |
| trans_date | date | |
| voucher_type_code | text FK | rim_voucher_types |
| payment_mode_code | text FK | rim_payment_modes |
| is_on_account | boolean | On Account = true, Against Invoice = false |
| reference_no | text | external ref |
| reference_date | date | |
| cheque_no | text | only when payment_mode = CHEQUE |
| cheque_date | date | |
| remarks | text | overall voucher remark |
| is_posted | boolean DEFAULT false | |
| posted_at | timestamptz | |
| posted_by | uuid FK rim_users | |
| reversal_of_trans_no | text FK self | for reversal link |
| standard tenant + audit columns | | |

### `rih_finance_lines`
| Column | Type | Notes |
|---|---|---|
| trans_no | text FK | rih_finance_headers |
| serial_no | integer | 1 = Cash/Bank, 2+ = others |
| account_id | uuid FK | rim_accounts |
| trans_nature | text | DR / CR |
| trans_amount | numeric(18,4) | in transaction currency |
| trans_currency | text | locked from line 1 account |
| base_amount | numeric(18,4) | in company base currency |
| base_rate | numeric(18,8) | exchange rate applied |
| local_amount | numeric(18,4) | in local/regional currency |
| local_rate | numeric(18,8) | exchange rate applied |
| party_amount | numeric(18,4) | in party/ledger currency — ALL lines |
| party_currency | text | ALL lines (for ledger report) |
| party_rate | numeric(18,8) | ALL lines |
| inv_bill_no | text | party lines only, NULL elsewhere |
| inv_bill_date | date | party lines only |
| settled_amount | numeric(18,4) DEFAULT 0 | updated as invoices settled |
| line_remarks | text | party lines only (editable in UI) |
| standard tenant + audit columns | | |

### `rih_invoice_bill_settlement`
| Column | Type | Notes |
|---|---|---|
| trans_no | text FK | the payment/receipt transaction |
| trans_date | date | |
| voucher_type_code | text | |
| account_id | uuid FK | customer or supplier account |
| inv_bill_no | text | invoice/bill being settled |
| inv_bill_date | date | |
| settlement_no | integer | 1st, 2nd, 3rd... payment against this bill |
| was_balance | numeric(18,4) | outstanding before this payment (party currency) |
| paid_amount | numeric(18,4) | amount applied (party currency) |
| paid_amount_trans | numeric(18,4) | same in transaction currency |
| standard tenant + audit columns | | |

### `rih_cheque_register`
| Column | Type | Notes |
|---|---|---|
| trans_no | text FK | rih_finance_headers |
| cheque_no | text | |
| cheque_date | date | date written on cheque |
| bank_name | text | |
| branch | text | |
| cheque_status | text DEFAULT 'ISSUED' | ISSUED / CLEARED / BOUNCED / CANCELLED |
| cleared_date | date | |
| bounced_date | date | |
| cancellation_reason | text | |
| standard tenant + audit columns | | |

---

## Screen Layout

### Entry Screen (for CRV/BRV/CPV/BPV)

```
┌──────────────────────────────────────────────────────────────────┐
│  Voucher Type: [CRV - Cash Receipt ▼]     Date: [2026-06-21]    │
│  Trans No:  CRV/KIN/2026/00001 (auto)     Mode: [CHEQUE ▼]      │
│  Ref No: [_______________]  Ref Date: [_______]                  │
│  Against Invoice ●   On Account ○                                │
│  Remarks: [__________________________________________________]   │
├──────┬───────────────────────────┬──────────────┬────────────────┤
│  No  │ Account                   │ DR Amount    │ CR Amount      │
├──────┼───────────────────────────┼──────────────┼────────────────┤
│  1   │ [Cash Account ▼] (locked) │ 1,000.00     │                │  ← DR auto for CRV
│  2   │ [Customer A/c ▼]          │              │ 1,000.00       │  ← CR auto for CRV
│      │ Bill: INV-2026-001        │              │ Bal: 1,200     │
│      │ Remarks: [__________]     │              │                │
│  [+ Add Line]                   │              │                │
├──────┴───────────────────────────┴──────────────┴────────────────┤
│  Currency: CDF  Base Rate: 2800  Local Rate: 1.00               │
│  Base (USD): 357.14    Local (CDF): 1,000.00                    │
├──────────────────────────────────────────────────────────────────┤
│              [Save Draft]              [Post Voucher]            │
└──────────────────────────────────────────────────────────────────┘
```

### Voucher List / Drafts Screen (separate screen)

- Filter by: Voucher Type | Date Range | Status (Draft / Posted / All) | Account
- Columns: Trans No | Date | Voucher Type | Amount | Mode | Status | Actions
- **Edit button** enabled only for Draft vouchers
- **Post button** available to users with `approve_allowed`
- **Reverse button** available on Posted vouchers (to authorized users)

---

## PG Functions needed

| Function | Purpose |
|---|---|
| `fn_next_trans_no(voucher_type, client_id, company_id, location_id)` | Generate next document number atomically, handle reset |
| `fn_save_finance_voucher(header JSON, lines JSON[])` | Upsert header + lines in one atomic call |
| `fn_post_finance_voucher(trans_no, posted_by)` | Set is_posted=true, insert settlement rows, insert cheque register row |
| `fn_reverse_finance_voucher(trans_no, reversed_by, reason)` | Create mirror-image voucher, link via reversal_of_trans_no |

---

## What is NOT in this screen

- Journal Voucher (JV) — separate screen
- Debit/Credit Notes — separate screens
- Cheque Register management — separate screen
- Invoice/Bill allocation (On Account → Against Invoice) — separate allocation screen
- Bank Reconciliation — separate screen

---

*Design agreed: 2026-06-21*
*Trans No: assigned at Draft time*
*No delete — correction by Reversal only*
