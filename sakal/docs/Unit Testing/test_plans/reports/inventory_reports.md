# Inventory Reports — Test Plan
Module: IN — Inventory | Group: Reports | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. `ril_stock_ledger` (the one source of truth) / Export & Print /
Permission-denied / CCC**.

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
| SDL-01 | Running balance correct | Run for a product with multiple movements | Running balance matches at every row | High | Not Started | |
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
| SAD-01 | Qty-only variant, no cost shown | Run as a user without cost-visibility permission | Values correctly hidden, qty still shown | High | Not Started | |
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
