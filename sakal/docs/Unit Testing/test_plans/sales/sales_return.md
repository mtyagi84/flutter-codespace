# Sales Return — Test Plan
Route: `/sales/returns` | Module: SL — Sales | Feature Code: SL-RET
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-C01 | Return against an approved Sales Invoice | Pick invoice, return some/all lines | Saves as DRAFT | High | Not Started | |
| SRET-C02 | Batch/serial-tracked return | Return a tracked product | Mandatory allocation from what was originally sold (CCC #10) | High | Not Started | |

## Edit / View
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| SRET-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |

## List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| SRET-P01 | Print | Print an approved return | Renders correctly with signatures | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-A01 | Stock returns to inventory | Approve | `ril_stock_ledger`/`rim_product_location` reflect the inward movement | High | Not Started | |
| SRET-A02 | Cash refund (if applicable) | Approve a cash-refund return | Composed CRV/CPV settlement voucher posts correctly, tagged with `source_doc_type='SALES_RETURN'` so it's exempt from the unrelated `FN-PRV` permission guard | High | Not Started | |
| SRET-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable correctly | High | Not Started | |
| SRET-A04 | Permission gating (CCC #6, `SL-RET`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRET-XS01 | Sales Return Register | Approve | Reflects it (`reports/sales_reports.md` RETR-01) | High | Not Started | |
| SRET-XS02 | Original invoice / customer ledger | Approve | Customer's balance reduces correctly, Account Ledger shows the reversal (CCC #1) | High | Not Started | |
| SRET-XS03 | Stock reports | Approve | Stock Ledger/Balance reflect the inward movement | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
