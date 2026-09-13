# Stock Transfer — Test Plan
Route: `/inventory/transfers` | Module: IN — Inventory | Feature Code: IN-TRF
SAME_BOOK vs INTER_ENTITY depends on `ric_companies.inter_location_model` +
`location.group_id`. See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-C01 | SIMPLE model — pure stock movement | Transfer between two locations under SIMPLE | Pure stock transfer, no financial posting | High | Not Started | |
| TRF-C02 | INTER_ENTITY, same group | Transfer within the same location group | Pure stock transfer, no financial posting (same as SIMPLE) | High | Not Started | |
| TRF-C03 | INTER_ENTITY, different group | Transfer across groups | Inter-entity invoice created using each group's own customer/supplier account | High | Not Started | |
| TRF-C04 | DIRECT mode | Fresh product entry | Barcode/tracked-product entry works (CCC #9/#10) | Med | Not Started | |
| TRF-C05 | AGAINST_REQUEST mode | Consolidate a Transfer Request | Lines/barcode carried forward from the request, no fresh scan | Med | Not Started | |

## Edit / View / List / Print
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-E01 | Edit a DRAFT | Change qty, Save | Persists | High | Not Started | |
| TRF-V01 | Reload matches saved state | Save, reopen | Matches | High | Not Started | |
| TRF-L01 | Filter by status | Apply filter | Correct subset | Med | Not Started | |
| TRF-P01 | Print | Print an approved transfer | Renders correctly | Med | Not Started | |

## Approve
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-A01 | Stock leaves source location | Approve | Source location's stock decreases correctly | High | Not Started | |
| TRF-A02 | Never restricted from external transactions | Confirm a location involved in a transfer can still do POs/Sales freely | No restriction leaks across | Med | Not Started | |
| TRF-A03 | Button state after Approve (CCC #4) | Approve | Buttons disable | High | Not Started | |
| TRF-A04 | Permission gating (CCC #6, `IN-TRF`) | Approve without the right | Denied | High | Not Started | |

## Cross-Screen Impact (Convert-to-Stock Receipt is the natural next step)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TRF-XS01 | Stock Transfer Register + Pending Transfer to Receive | Approve, then receive via Stock Receipt | Moves correctly between the two reports | High | Not Started | |
| TRF-XS02 | Short-received flagged | Receive less than transferred | Short-received flag/pending qty shown correctly on the report side | Med | Not Started | |

## Cross-Cutting Checklist
Apply all 10 items from `00_INDEX.md`.
