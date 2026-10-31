# Expense Voucher — Test Plan
Route: `/finance/expense-vouchers` | Module: FN — Finance | Feature Code: FN-EXP
Service-bill accrual with Odoo-style automatic tax. See `00_INDEX.md` for the
Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EXV-C01 | Simple expense with a normal (VAT) tax | Add an account+amount line with a VAT tax group | Tax ADDS to the payable, posts to `gl_input_account_id` | High | Passed | E2E `test_finance_expense_voucher.js` 14/14: Dr [6500001] QA Office Supplies 1000 USD, Dr [4400001] Input VAT 160 (16% of 1000, TVA Standard 16% group), Cr [4010001] Supplier 1160, balanced. DB-verified exactly. |
| EXV-C02 | Expense with a WITHHOLDING tax | Add a line with a WITHHOLDING tax group | Tax SUBTRACTS from the payable, posts to `gl_expense_account_id` | High | Not Started | |
| EXV-C03 | Bill linkage is mandatory | Attempt Save without a Bill No/Date | Blocked — always mandatory here, unlike JV's optional linkage | High | Passed | Confirmed live: Save Draft with Bill Date left blank failed with "Enter the supplier's Bill No and Bill Date." (Bill Date has no visible asterisk in the UI but is enforced as required server/client-side same as Bill No). |
| EXV-C07 | One DRAFT per supplier at a time | Save a 2nd DRAFT expense voucher for the same supplier while the 1st is still DRAFT | Blocked by `rih_expense_voucher_headers_client_id_company_id_supplier_i_key` (a real DB uniqueness constraint, not yet in the original test plan) | Med | Passed (found live) | Confirmed live while debugging this session's E2E run: a 2nd Save Draft attempt for the same supplier, with the 1st still DRAFT, failed with a raw "duplicate key value violates unique constraint" — the constraint itself works correctly (business rule: no duplicate pending accruals per supplier), but the error surfaced to the user is the raw Postgres message, not a human-readable one — worth a small follow-up fix (same "Error messages — never a raw ID" class of polish CLAUDE.md already documents elsewhere), not blocking. |
| EXV-C04 | Default Tax Group auto-suggests from the account | Pick an account with `default_tax_group_id` set | Tax Group pre-fills (never forced, can be changed) | Med | Not Started | |
| EXV-C05 | Client-side tax preview labeled "confirmed at Approve" | Watch the Net Payable preview while entering | Shown as a preview; the real computation happens server-side at Approve | Low | Not Started | |
| EXV-C06 | Editing the date on an existing DRAFT with lines | Change the Bill Date, Save | No FK violation (old-date-first line deletion ordering) | Med | Not Started | |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EXV-E01 | Edit a DRAFT | Change an amount, Save | Persists | High | Not Started | |
| EXV-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| EXV-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| EXV-P01 | Print | Print an approved voucher | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EXV-A01 | Server-side tax computation authoritative | Compare the client preview to the actual posted amounts | Server value is authoritative, matches expected tax math exactly | High | Not Started | |
| EXV-A02 | Supplier is always serial_no=1 | Approve, inspect the posted voucher's line order | Supplier line is serial_no=1 even though entered last | Low | Passed | Same E2E run as EXV-C01: Supplier CR line confirmed `serial_no=1`, Expense DR line `serial_no=2`, Input VAT DR line `serial_no=3` — despite being entered last in the UI (Supplier field is top-right, filled after the expense line). |
| EXV-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| EXV-A04 | Permission gating (CCC #6, `FN-EXP`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EXV-XS01 | Pending Bills reflects the payable | Approve | Appears in Pending Bills correctly | High | Not Started | |
| EXV-XS02 | Expense Report (Matrix) reflects it | Approve | Correct month/account bucket | High | Not Started | |
| EXV-XS03 | Withholding Tax Summary | Approve a withholding-tax expense | Reflects the withheld amount correctly | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
