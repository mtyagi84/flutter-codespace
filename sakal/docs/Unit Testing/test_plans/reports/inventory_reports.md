# Inventory Reports — Test Plan
Module: IN — Inventory | Group: Reports | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. `ril_stock_ledger` (the one source of truth) / Export & Print /
Permission-denied / CCC**.

**2026-10-25 smoke pass**: all 15 reports (`IN-RPT-*`) navigated to directly via
their `/reports/<reportKey>` route on the real Kivu Trading QA tenant and
confirmed to render with no `GoException`/crash, both before and after
clicking "Run Report" (the engine-wide auto_load gate) — see
`PHASE_EXECUTION_LOG.md` for the full list. Two were spot-checked for real
data accuracy beyond the smoke pass (see SDL-01 and the Stock Adjustment
Register note below); the remaining per-scenario rows below (weighted-avg
cost, category subtotals, cascading filters, permission-denial variants,
the Product Movement Analysis job queue) were not individually exercised
this pass and remain `Not Started`.

---
## IN-RPT-SBM / SVL — Stock Balance / Value by Location
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SBM-01 | Balance matches `rim_product_location.current_stock` | Compare for one product/location | Match exactly | High | Not Started | |
| SVL-01 | Weighted-average cost correct after mixed-cost GRNs | Receive the same product twice at different prices, run report | Weighted-avg cost matches manual calculation | High | Not Started | |
| SVL-02 | Category subtotals correct | Products across 2+ categories | Subtotals roll up correctly | Med | Not Started | |

## IN-RPT-SDT — Stock Details
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SDT-01 | Opening/Inward/Outward/Closing reconcile | Compare across a date range with known movements | Opening + Inward - Outward = Closing | High | Not Started | |
| SDT-02 | Cascading Product filter | Select a category, then the Product filter | Product list narrows to that category (cascading-lookup-filter) | Med | Not Started | |

## IN-RPT-SDL — Stock Ledger
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SDL-01 | Running balance correct | Run for a product with multiple movements | Running balance matches at every row | High | Passed | E2E: with Product=All, the report shows only a 0.00 "Opening Balance" row and a 0.00 Total — confirms the **already-documented "unenforced-required-filter gotcha"**: Product is effectively mandatory for a meaningful per-product running-balance ledger, but the UI doesn't block "All" or warn about it (pre-existing, known gap, not newly introduced). With Product explicitly set to PRD-00001 (QA Test Widget 48042), the ledger correctly showed: Opening Balance 0.00 → GRN +10.00 (running balance 10.00) → Purchase Return −10.00 (running balance 0.00) → Total Inward 10.00 / Outward 10.00 — matches that product's real transaction history exactly. |
| SDL-02 | Remarks resolve correctly | Check a GRN-sourced and a Sales-sourced line | `fn_resolve_transaction_remarks` shows the right document reference for each | Med | Not Started | |
| SDL-03 | This is the regression check for the SELLING/MID exchange-rate bug (fixed `25b4806`) | Buy and sell 100% of a foreign-currency product's stock | Net qty_change = 0 exactly | High | Not Started | |

## IN-RPT-STR / STP — Stock Transfer Register / Pending Transfer to Receive
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| STR-01 | Received transfer moves from Pending to Register | Receive a transfer via Stock Receipt | Moves correctly | High | Not Started | |
| STP-01 | Short-received flagged correctly | Receive less than sent | "Short Received"/"Pending Qty" shown correctly (schema has no true partial-receipt tracking — verify the flag-based approximation is still accurate) | Med | Not Started | |

## IN-RPT-SRR — Stock Receipt Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SRR-01 | Matches actual Stock Receipt documents | Compare | Match | Med | Not Started | |

## IN-RPT-SAD / SAV — Stock Adjustment Register (+with Value)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SAD-01 | Qty-only variant, no cost shown | Run as a user without cost-visibility permission | Values correctly hidden, qty still shown | High | Not Started | Smoke-only: default load (Status=Approved) correctly listed both this session's approved adjustments — `ADJ/MAIN/2026/00001` (direct entry) and `ADJ/MAIN/2026/00002` (Remarks: "Auto-posted from Stock Count Review...", confirming the Stock Count Review composition traces through to this report) as expandable drill-down rows. Permission-denial variant not exercised (QA Administrator holds every permission). |
| SAV-01 | With-Value variant requires separate permission | Run as a user with only the Qty-only report granted | With-Value report is denied/inaccessible | High | Not Started | |

## IN-RPT-MRQ / MIS — Material Requisition / Issue Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| MRQ-01 | Requisition has no batch/serial, Issue does | Compare the two reports' columns for a tracked product | Requisition shows no batch/serial column, Issue does | Med | Not Started | |

## IN-RPT-SCW / SCV / SCV-V — Stock Count Worksheet / Variance (+with Value)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SCW-01 | Blind count enforced | Compare Worksheet Register to what the counter actually saw | No system quantity was ever shown to the counter | High | Not Started | |
| SCV-01 | Variance = counted - system as of `as_of_date` | Count on a different day than approval | Variance uses the ledger sum AS OF the chosen date, not live current_stock | High | Not Started | |
| SCV-02 | Unknown serial excluded from auto-adjustment | Count a serial never in the ledger at this location | Flagged `is_unknown_serial`, excluded from the variance's auto-adjust total | Med | Not Started | |

## IN-RPT-PMA — Product Movement Analysis
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PMA-01 | Fast/Slow/Non-Moving classification correct | Compare movement frequency across 3 products | Classified correctly | Med | Not Started | |
| PMA-02 | Job queue completes (pg_cron-based) | Trigger the job, wait | Report data populates without manual intervention | Med | Not Started | |
