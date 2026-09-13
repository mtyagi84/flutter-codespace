# Stock Adjustment — Test Plan
Route: `/inventory/adjustments` | Module: IN — Inventory | Feature Code: IN-ADJ
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ADJ-C01 | `+` line, cost auto-fetched | Add an increase line | Cost is NEVER user-entered — pulled from `rim_product_location.cost_price` at Approve time | High | Not Started | |
| ADJ-C02 | `+` line, no established cost | Add a `+` line for a product never received via GRN | Hard-blocked `COST_NOT_ESTABLISHED`, never silently zero | High | Not Started | |
| ADJ-C03 | `-` line | Add a decrease line | Records whatever cost is currently there | High | Not Started | |
| ADJ-C04 | `+` batch/serial: new-lot entry | Add a tracked product on a `+` line | GRN-style fresh entry UI (CCC #10) | High | Not Started | |
| ADJ-C05 | `-` batch/serial: existing-lot picker | Add a tracked product on a `-` line | Material-Issue-style candidate picker (CCC #10) | High | Not Started | |
| ADJ-C06 | Reason from Common Masters | Pick a Stock Adjustment Reason | Default values present on a fresh tenant (2026-09-13 fix) | Med | Not Started | |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ADJ-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| ADJ-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| ADJ-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| ADJ-P01 | Print | Print an approved adjustment | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ADJ-A01 | `+` posts Dr Stock / Cr Stock Adjustment | Approve a `+` | Correct GL direction | High | Not Started | |
| ADJ-A02 | `-` posts Dr Stock Adjustment / Cr Stock | Approve a `-` | Correct GL direction | High | Not Started | |
| ADJ-A03 | Negative stock blocked for tracked products | `-` a batch/serial past zero | Blocked, full stop | High | Not Started | |
| ADJ-A04 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| ADJ-A05 | Direct approval requires `IN-ADJ` permission | Approve directly on this screen without the right | Denied | High | Not Started | |
| ADJ-A06 | Composed-from-Stock-Count-Review approval does NOT need `IN-ADJ` separately | Approve via Stock Count Review with only `IN-CNR` | Succeeds (composition guard, `source_doc_type IS NULL` check) | Med | Not Started | |

## Cross-Screen Impact
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ADJ-XS01 | Stock Adjustment Register (both variants) | Approve | With/without-Value variants both reflect correctly per their own permission (`reports/inventory_reports.md`) | High | Not Started | |
| ADJ-XS02 | Auto-posted from Stock Count Review | Approve a Review | Resulting adjustment tags `source_doc_type='STOCK_COUNT_REVIEW'`, traceable | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
