# Stock Transfer Request — Test Plan
Route: `/inventory/stock-transfer-requests` | Module: IN — Inventory | Feature Code: IN-STR
Pure intent, no stock/GL effect — mirrors PO's role relative to GRN. See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| STR-C01 | Create a request | Pick from/to location, add lines, Save | Saves as DRAFT, no stock effect | High | Passed | E2E `test_stock_transfer_request.js` 8/8: FROM Main Store, TO QA Second Store, PRD-00002 Qty Pack 5, Save Draft then Approve. Posted as `STRQ/MAIN/2026/00001`. |
| STR-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| STR-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| STR-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| STR-A01 | Approve — still no stock effect | Approve | Confirm no stock/GL posting happens (pure intent, like a PO) | High | Passed | DB-verified: `rim_product_location.current_stock` unchanged at 22 after Request Approve — pure intent, same as PO/Material Requisition. |
| STR-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| STR-A03 | Permission gating (CCC #6, `IN-STR`) | Approve without the right | Denied | High | Not Started | |
| STR-XS01 | Convert to Stock Transfer | Consolidate this request into a Stock Transfer (AGAINST_REQUEST mode) | Lines/barcode carry forward correctly — see `stock_transfer.md` TRF-C05 | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
