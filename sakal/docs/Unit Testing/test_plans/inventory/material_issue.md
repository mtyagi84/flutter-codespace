# Material Issue — Test Plan
Route: `/inventory/material-issue` | Module: IN — Inventory | Feature Code: IN-MIS
Fulfills a Material Requisition, posts stock + GL (unlike the Requisition itself).
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| MIS-C01 | Consolidate 1+ requisitions, same From Location | Pick requisitions, Save | Lines carry forward correctly | High | Passed | E2E `test_material_issue.js` 9/9: consolidated `MREQ/MAIN/2026/00001`, line correctly carried PRD-00002/3 PCS/Department+Area. Posted as `MISS/MAIN/2026/00001` → GL `MIC/MAIN/2026/00001`: Dr "Internal Transfers" (the Consumption Area's linked expense account) 75 / Cr "Stock Account" 75 (3 x `cost_price` 25). Stock: `current_stock=22` (25-3), `ril_stock_ledger` row `trans_type=MATERIAL_ISSUE, qty_change=-3`. **Real finding**: the Issue Qty Pack field shows the SAME "pre-filled value not bound to form state until touched" gap already confirmed on Purchase Return (`PRET-UI01`) — worked around identically (click, re-type same value, tab out, before Save). This is the SECOND screen with this exact symptom, raising the likelihood it's a shared component/pattern bug rather than two independent issues — worth checking both screens' line-grid widgets for a common root cause in a follow-up session. |
| MIS-C02 | Batch/serial existing-lot picker | Add a tracked product | Candidates come from what's CURRENTLY in stock (no originating-GRN-line scoping, unlike Purchase Return) | High | Not Started | |
| MIS-C03 | No document currency — always base | Create an issue | `trans_currency`=base, `base_rate`=1 on every line | Med | Passed | DB-verified: both GL lines show `trans_currency='USD'` (the company's base currency) despite this screen having no currency field at all — matches the documented always-base design. |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| MIS-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| MIS-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| MIS-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| MIS-A01 | Dr Expense / Cr Stock, per line | Approve | Correct Consumption-Area-resolved expense account used, one Dr/Cr pair per line | High | Not Started | |
| MIS-A02 | Negative stock blocked for tracked products | Issue a batch/serial past zero | Blocked, full stop, flag-independent | High | Not Started | |
| MIS-A03 | Future-dated hard block | Attempt a future-dated issue | Blocked, no company-configurable override | High | Not Started | |
| MIS-A04 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| MIS-A05 | Permission gating (CCC #6, `IN-MIS`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| MIS-XS01 | Material Issue Register | Approve | Reflects it, WITH batch/serial columns (unlike Requisition's own register) | High | Not Started | |
| MIS-XS02 | Expense reports reflect the consumption | Approve | The resolved Consumption Area's expense account shows the movement | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
