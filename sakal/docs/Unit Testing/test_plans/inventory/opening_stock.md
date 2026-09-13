# Opening Stock — Test Plan
Route: `/inventory/opening-stock` | Module: IN — Inventory | Feature Code: IN-OPN
One-time (per product/location) document with NO GL posting at all. See
`00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| OPN-C01 | One line per lot/unit | Add a serial-tracked product with 3 units | 3 separate lines, not 1 line qty=3 | High | Not Started | |
| OPN-C02 | Cost IS user-entered (the one deliberate inversion) | Enter a unit cost | Saves correctly, establishes cost basis | High | Not Started | |
| OPN-C03 | `OPENING_STOCK_ALREADY_ESTABLISHED` guard | Attempt on a product that already has stock/cost at that location (e.g. from a real GRN) | Blocked at Approve | High | Not Started | |
| OPN-C04 | Excel bulk upload | Upload a valid file | Lines land correctly; template's own downloadable header list matches what the parser accepts (a past bug: template omitted manufacturing_date) | High | Not Started | |
| OPN-E01 | Edit a DRAFT | Change a line, Save | Persists | High | Not Started | |
| OPN-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| OPN-A01 | Approve — NO GL posting | Approve | Confirm zero GL voucher created, only stock movement | High | Not Started | |
| OPN-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| OPN-A03 | Permission gating (CCC #6, `IN-OPN`) | Approve without the right | Denied | High | Not Started | |
| OPN-XS01 | Stock reports reflect it | Approve | Stock Balance/Value/Ledger all show the new opening position | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
