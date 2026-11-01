# Stock Adjustment — Test Plan
Route: `/inventory/adjustments` | Module: IN — Inventory | Feature Code: IN-ADJ
See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

---
## Create
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ADJ-C01 | `+` line, cost auto-fetched | Add an increase line | Cost is NEVER user-entered — pulled from `rim_product_location.cost_price` at Approve time | High | Passed | E2E `test_stock_adjustment.js` 11/11: PRD-00002 (cost already established at 25 via Opening Stock), + 5 units. No cost field anywhere in the line UI — DB-verified Dr Stock 125 = 5 x the EXISTING `cost_price` (25), not any user input. Posted as `ADJV/MAIN/2026/00001`: Dr Stock Account 125 / Cr "Internal Transfers" (the `STOCK_ADJUSTMENT_ACCOUNT` configured in Phase 1's Account Link Setup test, ALS-04 — confirms that config carries through correctly end-to-end). `rim_product_location.current_stock=25` (20 opening + 5), `ril_stock_ledger` row `trans_type=ADJUSTMENT_IN, qty_change=+5`. |
| ADJ-C02 | `+` line, no established cost | Add a `+` line for a product never received via GRN | Hard-blocked `COST_NOT_ESTABLISHED`, never silently zero | High | Not Started | |
| ADJ-C03 | `-` line | Add a decrease line | Records whatever cost is currently there | High | Passed | E2E (2026-11-01, fresh scripts): PRD-00001 (QA Test Widget 48042, `current_stock=10`, `cost_price=100` at Main Store), Reason=Damage, Direction=Decrease, Qty Pack=3. Saved as `ADJ/MAIN/2026/00003` DRAFT, no cost field anywhere in the UI — same "never user-entered" rule as `+` lines, confirmed for `-` too. |
| ADJ-C04 | `+` batch/serial: new-lot entry | Add a tracked product on a `+` line | GRN-style fresh entry UI (CCC #10) | High | Not Started | |
| ADJ-C05 | `-` batch/serial: existing-lot picker | Add a tracked product on a `-` line | Material-Issue-style candidate picker (CCC #10) | High | Not Started | |
| ADJ-C06 | Reason from Common Masters | Pick a Stock Adjustment Reason | Default values present on a fresh tenant (2026-09-13 fix) | Med | Passed | Confirmed live: 6 default reasons pre-seeded on fresh tenant SK-98262 (Damage, Expiry, Theft / Shrinkage, Physical Count Variance, Data Entry Correction, Other) — used "Physical Count Variance". |

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
| ADJ-A02 | `-` posts Dr Stock Adjustment / Cr Stock | Approve a `-` | Correct GL direction | High | Passed | E2E (2026-11-01): approved `ADJ/MAIN/2026/00003` (3 x PRD-00001 Decrease, Damage). Posted `ADJV/MAIN/2026/00003`: Dr `[5800] Internal Transfers` 300.00 / Cr `[3600001] Stock Account` 300.00 — exact opposite direction of a `+` line, DB-verified correct. `ril_stock_ledger` row `trans_type=ADJUSTMENT_OUT, qty_change=-3.00`; `rim_product_location.current_stock` for PRD-00001 at Main Store dropped 10.0000 → 7.0000, `cost_price` unchanged at 100.0000 (valuation uses whatever cost was already there, per the documented rule). |
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
