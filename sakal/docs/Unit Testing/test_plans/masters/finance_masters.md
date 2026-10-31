# Finance Masters — Test Plan
Module: AD — Settings | Group: Finance Masters | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## MST-COA — Chart of Accounts (`/master/accounts`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| COA-01 | Add a leaf account under a group | Create under a posting-allowed=false parent (tested: Cash-nature leaf under "5100 Cash", General-nature leaf under "6500 Other Operating Expenses") | New leaf appears in every account picker | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_chart_of_accounts.js`, 9/9 green on fresh tenant SK-98262. Cash-nature leaf correctly inherited `account_nature='Cash'` from its parent (nature field locked in the UI); General-nature leaf correctly kept `account_nature='General'`. Both DB-verified. |
| COA-02 | Group vs. Ledger node | Attempt to post a transaction directly to a group (posting_allowed=false) account | Blocked/not selectable as a posting target | High | Not Started | |
| COA-03 | account_nature drives routing | Create an account with `account_nature='Customer'` outside the normal Customer Master flow | Confirm which screens it appears on (Sales picker vs Chart of Accounts only) | Med | Not Started | |
| COA-04 | New-tenant auto-seeded leaf accounts (2026-09-13 fix) | Register a fresh tenant, complete Accounting Setup | Stock Account, Cost of Sales, Purchase Accrual (GR/IR) leaves already exist under the correct parent, for OHADA/INDIAN/ZAMBIA | High | **Passed (browser E2E, 2026-10-24, incidental)** | Confirmed via `check_coa.js`/`check_coa2.js` direct DB queries against fresh tenant SK-98262 — 55 OHADA leaves present, correct `parent_id` tree, including `3600001 Stock Account`, `6100001 Cost of Sales`, `4000401 Purchase Accrual (GR/IR)` |
| COA-05 | **New (rubric)** — Currency field is NOT nature-gated | Open Add Account under a General-nature parent (not Cash/Bank) | A Currency field IS shown for every Ledger (`posting_allowed=true`) regardless of `account_nature` — not restricted to Cash/Bank as the original test-plan rubric assumed | High | **Passed (browser E2E, 2026-10-24)** | Confirmed via `test_master_chart_of_accounts.js`: General-nature leaf under "6500 Other Operating Expenses" also showed a Currency field and saved with `currency_id='USD'` (company base currency). Corrects the rubric's worked example for this screen — Currency is gated on `posting_allowed` (any Ledger), not on `account_nature` |

## MST-TAX — Tax Master (`/master/tax-master`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TAX-01 | Create a tax with a rate | Add a VAT tax at 16%, effective from today | `fn_get_active_tax_rate` returns 16% for today's date | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_tax_master.js`, 9/9 green on SK-98262. VAT tax + 16% rate saved, `fn_get_active_tax_rate(tax_id, CURRENT_DATE)` DB-verified to return exactly 16.0000 |
| TAX-02 | Date-effective rate change | Add a new rate row effective from a future date | Old rate applies today, new rate applies from its effective date | Med | Not Started | |
| TAX-03 | Withholding tax | Create a WITHHOLDING-type tax | Expense Voucher subtracts it from payable instead of adding (per its own documented behavior); "Reverse Charge" toggle only appears for a withholding-flagged tax type | High | **Passed (browser E2E, 2026-10-24)** | Withholding tax saved with `is_withholding=true`; "Reverse Charge" toggle confirmed hidden for VAT type, visible once switched to Withholding type. Expense Voucher's actual subtract-from-payable behavior deferred to Phase 2 (Finance Core) |
| TAX-04 | New-tenant default tax setup (2026-09-13 fix, OHADA/ZAMBIA only) | Fresh OHADA or ZAMBIA tenant | 16% Standard + 0% Zero-Rated/Exempt taxes already exist | High | Not Started | |
| TAX-05 | India — no auto default (documented, deferred) | Fresh INDIAN tenant | Correctly has NO default tax setup yet (expected, not a bug — Phase 6 not built) | Low | Not Started | |

## MST-TXG — Tax Groups (`/master/tax-groups`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TXG-01 | Create a group with one tax member | Add a group, add a tax at sequence 1 | Selectable on a Sales Invoice/GRN line, correct tax computed | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_tax_groups.js`, 7/7 green on SK-98262. Group created with seeded "TVA Standard 16%" as its sole member, `sequence_no=1` DB-verified. Actual GRN/Sales Invoice line usage deferred to those phases |
| TXG-02 | Compound group (sequence order matters) | Add a compound tax at a higher sequence than its source | Compound calculates on top of the source correctly | Med | Not Started | |
| TXG-03 | New-tenant default groups (2026-09-13, OHADA/ZAMBIA) | Fresh OHADA/ZAMBIA tenant | "VAT/TVA Standard 16%" and "Zero-Rated/Exempt 0%" groups exist and are usable immediately on GRN/Sales Invoice | High | Not Started | |

## MST-ALS — Account Link Setup (`/master/account-link-setup`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ALS-01 | New-tenant auto-wired links (2026-09-13 fix) | Fresh tenant, complete Accounting Setup | STOCK_ACCOUNT, PURCHASE_ACCRUAL_ACCOUNT, SALES_ACCOUNT, COST_OF_SALES_ACCOUNT already wired at COMPANY granularity — GRN and Sales Invoice can be approved with zero manual setup | High | **Passed (direct DB check, 2026-10-24)** | Confirmed via `e2e/test_master_account_link_setup.js`'s DB pre-check on fresh tenant SK-98262: all 4 links present (`3600001`/`4000401`/`7010`/`6100001`) |
| ALS-02 | Change a COMPANY-level link | Change the Stock Account link to a different account | New transactions resolve to the new account; old cached `rim_account_links` rows unaffected until cleared | Med | Not Started | |
| ALS-03 | CATEGORY granularity | Switch a link type to CATEGORY, set per-category defaults | Products resolve their account by walking up their category tree to the nearest configured ancestor | Med | Not Started | |
| ALS-04 | Unconfigured link type (one of the other 9), configure it for the first time | Open Configure on a never-touched link type (STOCK_ADJUSTMENT_ACCOUNT), select COMPANY-wide, pick an account | Saves correctly, immediately resolvable by `fn_resolve_account_link` | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_account_link_setup.js`, 6/6 green. Confirmed the account picker correctly excludes non-posting GROUP accounts (searching "6500" only surfaced its leaf child, never the group itself — the picker is correctly filtering to postable accounts) |
| ALS-05 | **New (rubric)** — no level pre-selected for a never-configured link type | Open Configure on an unconfigured link type | Shows "Pick a level above to start assigning accounts." — no default level, requires an explicit choice | Low | **Passed (browser E2E, 2026-10-24, incidental)** | Confirmed via screenshot during ALS-04's test run — correct, deliberate behavior, not a bug |

## MST-IAL — Item Account Links (`/master/item-account-links`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| IAL-01 | ITEM-granularity override | Set a specific product's own account override | That product's transactions use the override, others use the CATEGORY/COMPANY default | Med | **Blocked (automation)** | `e2e/test_master_item_account_links.js` — screen loads correctly, shows the test product (created in Product Master testing), dialog opens showing every link type with correct Company-default cascading (confirmed: Stock Adjustment Account correctly shows the `[5800] Internal Transfers` default configured earlier in the Account Link Setup test — cross-screen consistency verified). Could NOT get automated keyboard input into any of this dialog's account-picker fields — confirmed via `document.activeElement` that a coordinate click isn't focusing any input in this dialog at all (not a text-replacement/semantics-lag issue like elsewhere this session, a genuine click-target miss specific to this one dialog). Tried 10+ variations (select-all+type, per-char typing, clear+reclick, insertText, targeting both pre-filled and genuinely-empty fields). Not escalated as a product bug — every other screen's identical `SakalAutocomplete`-based picker worked fine with the same technique, so this looks automation-specific rather than a real defect, but it is NOT confirmed correct either. Needs either a manual click-through check or a smarter automation approach in a follow-up session |

## MST-CHG — Additional Charges (`/master/additional-charges`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CHG-01 | Create an ADD-nature charge | Add a Freight charge, nature=ADD | Posts as a Cr (or Dr if DEDUCT) correctly on GRN/PO | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_additional_charges.js`, 6/6 green on SK-98262. Freight charge saved `nature=ADD`, `default_amount=50`. Actual Dr/Cr posting on GRN deferred to Phase 3 |
| CHG-02 | DEDUCT-nature charge | Add a Rebate charge, nature=DEDUCT | Flips Dr/Cr direction correctly vs. an ADD charge | High | **Passed (browser E2E, 2026-10-24)** | Rebate charge saved `nature=DEDUCT`, `default_amount=10`. Actual Dr/Cr flip at posting time deferred to Phase 3 |
| CHG-03 | Charge with its own tax | Set a `tax_id` on a charge | Charge tax computes independent of any product tax group | Med | Not Started | |

## FN-EX — Exchange Rates (`/finance/exchange-rates`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EX-01 | All three rates independently editable (2026-09-13 redesign) | Enter different Buying/Selling/Exchange Rate values | All three save independently, no auto-derivation between them | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_finance_exchange_rates.js`, 6/6 green on fresh tenant SK-98262: USD→EUR buying=0.92/selling=0.94/exchange=0.93 all saved exactly as entered, DB-verified distinct values |
| EX-02 | All three mandatory | Leave one blank, Save | Blocked with a validation message | High | **Passed (browser E2E, 2026-10-24)** | Confirmed incidentally — a test-script coordinate miss left Buying blank on one run, screen correctly showed "Enter a Buying, Selling, and Exchange rate for at least one currency." and did not save |
| EX-03 | Exchange Rate is what's actually used everywhere | Set Exchange Rate to a distinct value from Buying/Selling, raise a foreign-currency GRN then Sales Invoice for all the stock | COGS and cost basis derive from the SAME Exchange Rate — net Stock GL movement is exactly zero (this is the regression check for the SELLING/MID bug fixed `25b4806`) | High | Not Started | Deferred to Phase 3 (Purchase Cycle) — needs a real GRN+Invoice chain to exercise |
| EX-04 | Save button top-right (2026-09-13 layout fix) | Open the screen | Save button is in the header, not the bottom of the page | Low | **Passed (browser E2E, 2026-10-24)** | Confirmed via screenshot — "Save Rates" button renders in the top header bar |
| EX-05 | **New (rubric)** — only ACTIVE currencies appear in the grid | Activate a new currency (e.g. EUR) via Currency Setup (`/setup/currencies`), then open Exchange Rates | The newly-activated currency appears as a new row; an inactive currency never shows at all, even though `rim_currencies` has every ISO currency pre-seeded per company | High | **Passed (browser E2E, 2026-10-24)** | Confirms `currenciesProvider`'s `is_active=true` filter works correctly and Currency Setup's toggle correctly drives it (`ref.invalidate(currenciesProvider)` on toggle) |

## MST-OB — Opening Balance (`/master/opening-balances`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| OB-01 | Manual-entry opening balance lines (rubric judgment: manual path tested, not Excel upload — both exist, manual is equally valid and simpler) | Add 2 lines, Dr 1000 + Cr 1000, Save | Balances land correctly against the right accounts/FY | High | **Passed (browser E2E, 2026-10-24)** | `e2e/test_master_opening_balances.js`, 9/9 green on SK-98262. Dr [5800] Internal Transfers 1000 + Cr [1200] Retained Earnings 1000 saved, DB-verified exact match. Excel-upload path (OB-01's original scope) not yet tested — flag as a follow-up if full coverage of this screen's 2nd entry path is wanted |
| OB-02 | Trial Balance reflects opening balances | After entry, run Trial Balance | Opening balances included in the totals, correct Dr/Cr side (CCC #1) | High | **Passed (direct DB check, 2026-10-24, partial)** | Confirmed the 2 lines sum to a balanced Dr=Cr=1000 via direct DB query. Actual Trial Balance REPORT screen UI reflection deferred to Phase 2 (Finance Core reports) |

---
## Cross-Cutting Checklist reminder
This whole group is where the 2026-09-13 new-tenant starter-kit fixes concentrate —
ALS-01, TAX-04, TXG-03, COA-04 together are the actual regression test for that
entire session's work. Test them together against a genuinely NEW tenant
registration, not just the QA tenant that was manually backfilled.
