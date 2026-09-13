# Cash Receipt — Test Plan
Route: `/sales/receipts` | Module: SL — Sales | Feature Code: SL-RCP
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| RCP-C01 | Create a receipt settling a specific bill | Pick customer + bill, enter amount | Party Amount populates correctly (CCC #3 — cross-check against the Payment/Receipt Voucher bug, this may be a different code path) | High | Not Started | |
| RCP-C02 | On-account receipt | Receive without tying to a specific bill | Saves correctly | High | Not Started | |
| RCP-E01 | Edit a DRAFT | Change amount, Save | Persists | High | Not Started | |
| RCP-A01 | Composed CRV voucher posts | Approve | Voucher tagged `source_doc_type='CASH_RECEIPT'`, exempt from unrelated `FN-PRV` permission | High | Not Started | |
| RCP-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| RCP-A03 | Permission gating (CCC #6, `SL-RCP`) | Approve without the right | Denied | High | Not Started | |
| RCP-XS01 | Pending Bills reduces | Settle a bill fully | Disappears from Pending Bills | High | Not Started | |
| RCP-XS02 | Cash Receipt / Collections Register | Approve | Reflects it (`reports/sales_reports.md` CRR-01) | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
