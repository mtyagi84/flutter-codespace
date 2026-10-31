# Material Requisition — Test Plan
Route: `/inventory/requisitions` | Module: IN — Inventory | Feature Code: IN-MRQ
Pure intent, no stock/GL effect — mirrors PO's role relative to GRN. See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| MRQ-C01 | Create a requisition | Pick Department → Consumption Area (cascading picker), add lines, Save | Saves as DRAFT | High | Passed | E2E `test_material_req_issue.js` 9/9: FROM Main Store, PRD-00002 Qty Pack 3, Department "QA Admin Dept" → Consumption Area "QA Office Supplies Consumption" — the cascading picker correctly showed ONLY this department's own linked area (confirmed via screenshot, single-option dropdown). Saved and approved as `MREQ/MAIN/2026/00001`. |
| MRQ-C02 | No batch/serial on Requisition (by design) | Add a tracked product | No batch/serial UI — this document has no originating-lot to allocate against | Med | Not Started | |
| MRQ-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| MRQ-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| MRQ-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| MRQ-A01 | Approve — no stock/GL effect | Approve | Confirm no posting (pure intent) | High | Passed | DB-verified: `rim_product_location.current_stock` unchanged at 25 after Requisition Approve — confirms pure intent, exactly matching PO's own precedent. |
| MRQ-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| MRQ-A03 | Permission gating (CCC #6, `IN-MRQ`) | Approve without the right | Denied | High | Not Started | |
| MRQ-XS01 | Convert to Material Issue | Consolidate into a Material Issue, same From Location | Lines carry forward correctly — see `material_issue.md` | High | Not Started | |
| MRQ-XS02 | Material Requisition Register | Approve | Reflects it (`reports/inventory_reports.md`) | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
