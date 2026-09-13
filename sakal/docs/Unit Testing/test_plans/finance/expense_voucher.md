# Expense Voucher — Test Plan
Route: `/finance/expense-vouchers` | Module: FN — Finance | Feature Code: FN-EXP
Service-bill accrual with Odoo-style automatic tax. See `00_INDEX.md` for the
Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EXV-C01 | Simple expense with a normal (VAT) tax | Add an account+amount line with a VAT tax group | Tax ADDS to the payable, posts to `gl_input_account_id` | High | Not Started | |
| EXV-C02 | Expense with a WITHHOLDING tax | Add a line with a WITHHOLDING tax group | Tax SUBTRACTS from the payable, posts to `gl_expense_account_id` | High | Not Started | |
| EXV-C03 | Bill linkage is mandatory | Attempt Save without a Bill No/Date | Blocked — always mandatory here, unlike JV's optional linkage | High | Not Started | |
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
| EXV-A02 | Supplier is always serial_no=1 | Approve, inspect the posted voucher's line order | Supplier line is serial_no=1 even though entered last | Low | Not Started | |
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
