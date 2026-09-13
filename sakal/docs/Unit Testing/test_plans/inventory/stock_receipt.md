# Stock Receipt — Test Plan
Route: `/inventory/stock-receipts` | Module: IN — Inventory | Feature Code: IN-SRC
Fulfills a Stock Transfer, mirrors GRN's role fulfilling a PO. See `00_INDEX.md`
for the Cross-Cutting Checklist ("CCC #N").

---
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRC-C01 | Receive a full transfer | Pick the transfer, confirm full qty | Saves as DRAFT | High | Not Started | |
| SRC-C02 | Short receipt | Receive less than transferred | "Short Received" tracked correctly (schema has no true partial-receipt tracking — this is a flag-based approximation, verify it's still accurate) | High | Not Started | |
| SRC-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| SRC-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| SRC-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| SRC-A01 | Stock lands at destination | Approve | Destination location's stock increases correctly | High | Not Started | |
| SRC-A02 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| SRC-A03 | Permission gating (CCC #6, `IN-SRC`) | Approve without the right | Denied | High | Not Started | |
| SRC-XS01 | Stock Receipt Register + Pending Transfer to Receive | Approve | Both reflect it correctly | High | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
