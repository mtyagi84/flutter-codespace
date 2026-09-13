# Sales Masters — Test Plan
Module: AD — Settings | Group: Sales Masters | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## MST-CUST — Customer Master (`/master/customers`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CUST-01 | Create a customer | Fill required fields (name, ledger currency, credit terms), Save | Appears in Sales Order/Invoice customer pickers; a `rim_accounts` row is created with `account_nature='Customer'` | High | Not Started | |
| CUST-02 | Ledger currency setting | Set a ledger currency different from base | Customer's statements/ledger show in that currency (cross-check Account Ledger report — CCC #2) | High | Not Started | |
| CUST-03 | Credit limit / credit days | Set a credit limit, attempt a sale exceeding it | Sales Invoice either blocks or warns per configured behavior | Med | Not Started | |
| CUST-04 | Credit block | Set `is_credit_blocked=true` | New credit sales to this customer are blocked | High | Not Started | |
| CUST-05 | Customer Category (2026-09-13 default values) | Open Category dropdown on a fresh tenant | Retail/Wholesale/Distributor/Corporate/Government values present without manual setup | Med | Not Started | |
| CUST-06 | Duplicate account_code prevention | Save without an explicit code | `fn_next_account_code` assigns the next sequential code correctly | Med | Not Started | |
| CUST-07 | Deactivate a customer with open bills | Attempt to deactivate | Either blocked or allowed with a clear warning (verify actual behavior, don't assume) | Med | Not Started | |

## SL-PRC — Price Master (`/sales/price-master`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRC-01 | Create a price batch for a product | Add product + selling price + currency, Save | Sales Order/Invoice pick up this price via `fn_get_active_price` | High | Not Started | |
| PRC-02 | Currency-aware price resolution | Set a price in USD, raise a Sales Order in CDF | Price converts correctly using the exchange rate, not used raw | High | Not Started | |
| PRC-03 | Approve required (`approve_allowed=true`) | Save a batch as DRAFT, then Approve | Only APPROVED batches are used for pricing | High | Not Started | |
| PRC-04 | No price configured → override flow | Create a Sales Invoice line for a product with no Price Master row | `PRICE_NOT_CONFIGURED` triggers the Override Price UI, requires a reason | High | Not Started | |

## SL-EXE — Sales Executives (`/sales/sales-executives`)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| EXE-01 | Create a sales executive | Fill required fields, Save | Appears in Sales Order/Invoice Sales Executive picker | Med | Not Started | |
| EXE-02 | Salesperson Performance report reflects assignment | Create a sale assigned to an executive, run the report | Executive's numbers include this sale | Med | Not Started | |

---
## Cross-Cutting Checklist reminder
CCC #2 (currency display) matters heavily here — Customer ledger currency and
Price Master's own currency are two separate, easily-confused concepts; test both.
