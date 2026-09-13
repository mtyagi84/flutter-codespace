# Credit Sales Invoice — Test Plan
Route: `/sales/credit-invoices` | Module: SL — Sales | Feature Code: SL-CINV
Reuses the Quick Invoice (`rih_sales_invoices`) engine but with always-DEFERRED
dispatch and freely user-chosen currency. See `00_INDEX.md` for the Cross-Cutting
Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-C01 | Create with a freely-chosen currency | Pick a currency different from the customer's own ledger currency | Allowed (unlike Quick Invoice's auto-derive) | High | Not Started | |
| CINV-C02 | Stock always deferred | Add lines, save | No immediate stock/COGS dispatch, regardless of any setting | High | Not Started | |
| CINV-C03 | Hard future-date block | Attempt a future invoice date | Blocked | High | Not Started | |
| CINV-C04 | Date locked after first save | Save, then attempt to change the date | Blocked | Med | Not Started | |
| CINV-C05 | Save Draft vs Approve are separate steps (unlike Quick Invoice) | Save as Draft first | Stays DRAFT, does not auto-approve | High | Not Started | |

## Edit (DRAFT only)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-E01 | Edit a DRAFT | Change a line, Save | Persists | High | Not Started | |
| CINV-E02 | Immutability (CCC #5) | Approve, attempt edit | Blocked | High | Not Started | |

## View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| CINV-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| CINV-P01 | Print | Print an approved invoice | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-A01 | Button state after Approve (CCC #4) | Approve | Buttons disable — this module SHARES the Sales Invoice engine, cross-check whether the known Sales Delivery bug pattern also exists here | High | Not Started | |
| CINV-A02 | Permission gating (CCC #6, `SL-CINV`) | Approve without the right | Denied | High | Not Started | |
| CINV-A03 | A later Sales Delivery actually dispatches the stock | Approve the invoice, then create+approve a Sales Delivery against it | Stock/COGS dispatch happens at delivery time, not invoice time | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CINV-XS01 | Sales Register + Pending Bills | Approve | Both reflect it | High | Not Started | |
| CINV-XS02 | Sales Delivery / Pending Deliveries | Approve | Invoice appears as a valid source document for delivery | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
