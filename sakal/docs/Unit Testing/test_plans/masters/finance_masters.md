# Finance Masters — Test Plan
Module: AD — Settings | Group: Finance Masters | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## MST-COA — Chart of Accounts (`/master/accounts`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| COA-01 | Add a leaf account under a group | Create under a posting-allowed=false parent | New leaf appears in every account picker | High | Not Started | |
| COA-02 | Group vs. Ledger node | Attempt to post a transaction directly to a group (posting_allowed=false) account | Blocked/not selectable as a posting target | High | Not Started | |
| COA-03 | account_nature drives routing | Create an account with `account_nature='Customer'` outside the normal Customer Master flow | Confirm which screens it appears on (Sales picker vs Chart of Accounts only) | Med | Not Started | |
| COA-04 | New-tenant auto-seeded leaf accounts (2026-09-13 fix) | Register a fresh tenant, complete Accounting Setup | Stock Account, Cost of Sales, Purchase Accrual (GR/IR) leaves already exist under the correct parent, for OHADA/INDIAN/ZAMBIA | High | Not Started | |

## MST-TAX — Tax Master (`/master/tax-master`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TAX-01 | Create a tax with a rate | Add a VAT tax at 16%, effective from today | `fn_get_active_tax_rate` returns 16% for today's date | High | Not Started | |
| TAX-02 | Date-effective rate change | Add a new rate row effective from a future date | Old rate applies today, new rate applies from its effective date | Med | Not Started | |
| TAX-03 | Withholding tax | Create a WITHHOLDING-type tax | Expense Voucher subtracts it from payable instead of adding (per its own documented behavior) | High | Not Started | |
| TAX-04 | New-tenant default tax setup (2026-09-13 fix, OHADA/ZAMBIA only) | Fresh OHADA or ZAMBIA tenant | 16% Standard + 0% Zero-Rated/Exempt taxes already exist | High | Not Started | |
| TAX-05 | India — no auto default (documented, deferred) | Fresh INDIAN tenant | Correctly has NO default tax setup yet (expected, not a bug — Phase 6 not built) | Low | Not Started | |

## MST-TXG — Tax Groups (`/master/tax-groups`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TXG-01 | Create a group with one tax member | Add a group, add a tax at sequence 1 | Selectable on a Sales Invoice/GRN line, correct tax computed | High | Not Started | |
| TXG-02 | Compound group (sequence order matters) | Add a compound tax at a higher sequence than its source | Compound calculates on top of the source correctly | Med | Not Started | |
| TXG-03 | New-tenant default groups (2026-09-13, OHADA/ZAMBIA) | Fresh OHADA/ZAMBIA tenant | "VAT/TVA Standard 16%" and "Zero-Rated/Exempt 0%" groups exist and are usable immediately on GRN/Sales Invoice | High | Not Started | |

## MST-ALS — Account Link Setup (`/master/account-link-setup`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ALS-01 | New-tenant auto-wired links (2026-09-13 fix) | Fresh tenant, complete Accounting Setup | STOCK_ACCOUNT, PURCHASE_ACCRUAL_ACCOUNT, SALES_ACCOUNT, COST_OF_SALES_ACCOUNT already wired at COMPANY granularity — GRN and Sales Invoice can be approved with zero manual setup | High | Not Started | |
| ALS-02 | Change a COMPANY-level link | Change the Stock Account link to a different account | New transactions resolve to the new account; old cached `rim_account_links` rows unaffected until cleared | Med | Not Started | |
| ALS-03 | CATEGORY granularity | Switch a link type to CATEGORY, set per-category defaults | Products resolve their account by walking up their category tree to the nearest configured ancestor | Med | Not Started | |
| ALS-04 | Unconfigured link type (one of the other 9) | Attempt a transaction that needs e.g. STOCK_ADJUSTMENT_ACCOUNT before it's configured | Fails loudly with a clear message, never posts to no account | High | Not Started | |

## MST-IAL — Item Account Links (`/master/item-account-links`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| IAL-01 | ITEM-granularity override | Set a specific product's own account override | That product's transactions use the override, others use the CATEGORY/COMPANY default | Med | Not Started | |

## MST-CHG — Additional Charges (`/master/additional-charges`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CHG-01 | Create an ADD-nature charge | Add a Freight charge, nature=ADD | Posts as a Cr (or Dr if DEDUCT) correctly on GRN/PO | High | Not Started | |
| CHG-02 | DEDUCT-nature charge | Add a Rebate charge, nature=DEDUCT | Flips Dr/Cr direction correctly vs. an ADD charge | High | Not Started | |
| CHG-03 | Charge with its own tax | Set a `tax_id` on a charge | Charge tax computes independent of any product tax group | Med | Not Started | |

## FN-EX — Exchange Rates (`/finance/exchange-rates`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EX-01 | All three rates independently editable (2026-09-13 redesign) | Enter different Buying/Selling/Exchange Rate values | All three save independently, no auto-derivation between them | High | Not Started | |
| EX-02 | All three mandatory | Leave one blank, Save | Blocked with a validation message | High | Not Started | |
| EX-03 | Exchange Rate is what's actually used everywhere | Set Exchange Rate to a distinct value from Buying/Selling, raise a foreign-currency GRN then Sales Invoice for all the stock | COGS and cost basis derive from the SAME Exchange Rate — net Stock GL movement is exactly zero (this is the regression check for the SELLING/MID bug fixed `25b4806`) | High | Not Started | |
| EX-04 | Save button top-right (2026-09-13 layout fix) | Open the screen | Save button is in the header, not the bottom of the page | Low | Not Started | |

## MST-OB — Opening Balance (`/master/opening-balances`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| OB-01 | Excel upload of opening balances | Upload a valid file | Balances land correctly against the right accounts/FY | High | Not Started | |
| OB-02 | Trial Balance reflects opening balances | After upload, run Trial Balance | Opening balances included in the totals, correct Dr/Cr side (CCC #1) | High | Not Started | |

---
## Cross-Cutting Checklist reminder
This whole group is where the 2026-09-13 new-tenant starter-kit fixes concentrate —
ALS-01, TAX-04, TXG-03, COA-04 together are the actual regression test for that
entire session's work. Test them together against a genuinely NEW tenant
registration, not just the QA tenant that was manually backfilled.
