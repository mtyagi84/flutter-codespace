# Finance Reports — Test Plan
Module: FN — Finance | Group: Reports + Bank Reconciliation Statement | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. a real transaction / Currency & Dr-Cr display (CCC #1/#2) / Export &
Print / Permission-denied / CCC**.

---
## FN-RPT-LDG — Account Ledger (`/reports/ACCOUNT_LEDGER`) — 2 KNOWN OPEN BUGS

| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| **LDG-BUG-01** | **[OPEN BUG, found 2026-09-13] Closing balance shows as a bare negative** | Open Account Ledger for any account whose closing balance is a credit balance | **Expected**: balance displays as e.g. `12,500.00 Cr`, never `-12,500.00`. **Actual**: shows a bare negative number. | **High** | **Failed** | Not yet fixed — root-cause and fix the display formatting (likely in the ledger's amount-rendering widget/formatter, not the underlying SQL sign convention, which per `rid_finance_lines`'s own always-unsigned + `trans_nature` design is presumably already correct at the data layer) |
| **LDG-BUG-02** | **[OPEN BUG, found 2026-09-13] Party-currency statement doesn't show the currency** | Open Account Ledger for a customer/supplier whose ledger currency differs from base, in their own ledger currency | **Expected**: every amount column shows the currency code/symbol (e.g. "CDF 1,250.00"). **Actual**: no currency indicator shown at all. | **High** | **Failed** | Not yet fixed |
| LDG-01 | Every account nature loads | Run for a Customer, a Supplier, and a General account | All three load without error | High | Not Started | |
| LDG-02 | Opening balance carries forward | Run for a date range starting mid-year | Opening balance line matches the account's true balance as of the start date | High | Not Started | |
| LDG-03 | Data accuracy vs. a real transaction | Post a Journal Voucher touching this account, re-run the ledger | The new line appears with the exact amount and correct Dr/Cr side | High | Not Started | |
| LDG-04 | Base currency vs. Local currency toggle | Toggle Base/Local | Amounts convert correctly, both sides still Dr/Cr-labeled per CCC #1 | Med | Not Started | |
| LDG-05 | Drilldown to source document | Click a ledger line | Navigates to the originating voucher/invoice | Med | Not Started | |
| LDG-06 | Print/Export | Export to PDF | Same Dr/Cr and currency formatting as on-screen (CCC #1/#2 apply to print too, not just screen) | Med | Not Started | |

## FN-TRB — Trial Balance (`/reports/TRIAL_BALANCE`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRB-01 | Loads with no error (regression for the 2026-09-13 report-definitions fix) | Open on a freshly-registered tenant | Loads correctly, no "Unable to load this report" | High | Not Started | |
| TRB-02 | Total Dr = Total Cr | Run for any period | The two columns sum to the same total | High | Not Started | |
| TRB-03 | Every balance is Dr/Cr labeled (CCC #1) | Inspect several rows | No bare negative numbers anywhere | High | Not Started | |
| TRB-04 | Opening Stock / Opening Balances included | Upload an opening balance, re-run | Reflected correctly | Med | Not Started | |

## FN-PNL / FN-RPT-PNL — Profit & Loss (Summary + Account Detail)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PNL-01 | Summary loads, hierarchical tree correct | Run for a period with transactions | Arbitrary-depth account tree renders, subtotals roll up correctly | High | Not Started | |
| PNL-02 | Account Detail drilldown matches Summary | Click through from Summary to Detail for one line | Numbers match exactly | High | Not Started | |
| PNL-03 | Net Profit/Loss ties to Balance Sheet | Compare P&L's net result to BS's Retained Earnings movement | They tie out | High | Not Started | |

## FN-BSH / FN-RPT-BSD — Balance Sheet (Summary + Account Detail)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BSH-01 | Assets = Liabilities + Equity | Run for any date | Balances exactly | High | Not Started | |
| BSH-02 | OHADA split-root classification | Run on an OHADA-standard company | Classification matches OHADA convention, not INDIAN's | Med | Not Started | |
| BSH-03 | Zambia standard (new, untested) | Run on a ZAMBIA-standard company | Renders correctly with the new COA's account structure | High | Not Started | |

## FN-RPT-CFS / FN-RPT-CFD — Cash Flow (Summary + Detail)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CFS-01 | Direct method reconciliation_diff = 0 | Run for a period | The report's own internal reconciliation check passes | High | Not Started | |
| CFS-02 | Cash↔Bank transfers excluded | Do a Contra Voucher moving Cash to Bank | Does NOT appear as an inflow/outflow (it's not a real cash-flow event) | High | Not Started | |

## FN-RPT-PBR / PBG / PBS — Pending Bills (Register / by Customer / by Supplier)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PB-01 | A newly-invoiced bill appears | Approve a Sales Invoice/Purchase Bill with `inv_bill_no` set | Appears immediately in Pending Bills | High | Not Started | |
| PB-02 | Settlement via Payment/Receipt Voucher clears it | Settle the bill fully | Disappears from Pending Bills | High | Not Started | |
| PB-03 | Partial settlement | Settle partially | Remaining balance shown correctly, still Dr/Cr labeled (CCC #1) | Med | Not Started | |
| PB-04 | Currency-regrouped view | View for a party in a foreign ledger currency | Currency shown per CCC #2 | High | Not Started | |

## FN-RPT-CAG / FN-RPT-SAG — Customer / Supplier Ageing
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| AGE-01 | Buckets correct | Create bills at various ages | Each lands in the correct ageing bucket | High | Not Started | |
| AGE-02 | Currency shown (CCC #2) | Run for a foreign-currency party | Currency indicated | High | Not Started | |

## FN-RPT-EXR — Expense Report (Matrix)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EXR-01 | Month-wise matrix loads | Post Expense Vouchers across 2+ months | Correct month columns, correct totals | High | Not Started | |
| EXR-02 | Withholding tax reduces payable correctly | Post an expense with a WITHHOLDING tax | Reflected correctly, not double-counted | Med | Not Started | |

## FN-RPT-DBK — Day Book / Voucher Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| DBK-01 | Filter by voucher type | Filter to JV only | Only Journal Vouchers show | Med | Not Started | |

## FN-RPT-CHQ — Cheque Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CHQ-01 | Cheque payment appears | Make a cheque payment via Payment Voucher | Appears with correct cheque number/date | Med | Not Started | |

## FN-RPT-VAT / FN-RPT-WHT — VAT/Tax Return Summary, Withholding Tax Summary
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| VAT-01 | Matches actual tax posted | Post transactions with known tax amounts, compare | Report totals match exactly | High | Not Started | |
| VAT-02 | New OHADA/ZAMBIA default tax groups appear correctly (2026-09-13) | Run on a fresh tenant with the new default 16% tax | Report correctly reflects transactions using the new default tax setup | Med | Not Started | |

## FN-RPT-RAT — Financial Ratio Analysis
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| RAT-01 | Ratios compute correctly | Compare a couple of ratios (e.g. current ratio) to manual calculation from the Balance Sheet | Match | Med | Not Started | |

## FN-RPT-CBP — Cash & Bank Position Summary
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CBP-01 | Reflects all Cash/Bank accounts | Compare to Chart of Accounts' Cash/Bank leaf balances | Match | Med | Not Started | |

## FN-RPT-BRS — Bank Reconciliation Statement
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| BRS-01 | Matches Bank Reconciliation Matching screen's own state | Reconcile some lines, run the report | Reconciled/unreconciled split matches what was done on the Matching screen | High | Not Started | |

---
## Cross-Cutting Checklist reminder
**This file is the direct home of both currently-open bugs (#1, #2 from the plan).**
Every report above that shows a balance or a foreign-currency amount must be
re-checked against CCC #1/#2 once those two bugs are fixed — treat LDG-BUG-01/02
as the template repro, then spot-check 3-4 other reports in this file for the
same underlying formatting issue (it's very likely NOT unique to Account Ledger
if the root cause is a shared amount-formatting widget/function).
