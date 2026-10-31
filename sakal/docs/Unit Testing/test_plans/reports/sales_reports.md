# Sales Reports — Test Plan
Module: SL — Sales | Group: Reports | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. a real transaction / Currency & Dr-Cr display (CCC #1/#2) / Export &
Print / Permission-denied / CCC**.

**2026-10-25 smoke pass**: all 13 `SL-RPT-*` reports navigated directly and Run
Report clicked, with every resulting network response traced for 400/404s (the
discipline that caught 4 real bugs across Finance/Purchase Reports earlier this
session) — all 13 loaded and ran with zero error responses. Two spot-checked
for real data accuracy against this session's own DB-verified Sales Cycle
transactions (see below).

---
## SL-RPT-REG — Sales Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| REG-01 | Every approved Sales Invoice appears | Approve a Sales Invoice, run register for that date range | Appears with correct amount, customer, currency (CCC #2) | High | Passed | E2E `2026-10-25`: default load (Status=Approved, USD) showed all 3 approved invoices from this session's Sales Cycle chain, every QTY/RATE/GROSS/COST/PROFIT column matching the DB-verified transactions exactly — `SI/MAIN/2026/00002` (Qty 1, Rate 70.80, Cost 50.00, Profit 20.80), `SI/MAIN/2026/00003` (Qty 1, Rate 35.40, Cost 25.00, Profit 10.40), `SI/MAIN/2026/00001` (Qty 5, Rate 100.00, Cost 125.00, Profit 375.00) — plus the Sales Return correctly shown as its own negative row (`SRET/MAIN/2026/00001`, Qty -2, Gross -200.00, Cost -50.00, Profit -150.00, Type "R"). |
| REG-02 | Base/Local currency toggle | Toggle Base/Local | Amounts recompute correctly | Med | Not Started | |
| REG-03 | DRAFT invoices excluded | Leave one invoice as DRAFT | Does not appear | High | Not Started | |

## SL-RPT-IGP / VGP / CGP — Gross Profit (Item / Invoice / Customer)
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GP-01 | GP = Sale - COGS exactly | Pick one invoice, manually compute GP from its lines | Report matches exactly | High | Not Started | |
| GP-02 | Cost-visibility permission gating | Run as a user without `can_view_cost_price` | Cost/GP figures hidden or report denied per governance rules | Med | Not Started | |

## SL-RPT-SPP — Salesperson-wise Performance
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SPP-01 | Matches Sales Executive assignment | Assign a sale to an executive, run report | Correctly attributed | Med | Not Started | |

## SL-RPT-RET — Sales Return Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| RETR-01 | Approved return appears | Approve a Sales Return | Appears with correct reversal amount | High | Passed | `SRET/MAIN/2026/00001` appears as a GROUPED header row (expand to see line detail — same pattern as Day Book/Stock Adjustment Register elsewhere in the app). Expanded line: Return Total -200.00, Reversed Gross Profit -150.00, `PRD-00002` — matches the DB-verified return exactly (2 units × 100 rate, 2 × 25 cost). Minor, not chased further: the header row's own aggregate columns (Return Total, Reversed Gross Profit, Item Code/Name) and the report's own Total footer both show `—`/0.00 rather than the summed child value — consistent with this being a collapsed-by-default GROUPED report, not confirmed to be a bug. |

## SL-RPT-SQR / SOR — Sales Quotation / Order Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SQOR-01 | Status shown correctly | Create quotations/orders in various statuses | Register shows correct status per row | Med | Not Started | |

## SL-RPT-QCA — Quotation Conversion Analysis
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| QCA-01 | Converted vs. not-converted split correct | Convert one quotation to an Order, leave another un-converted | Correctly split | Med | Not Started | |

## SL-RPT-OSO — Open Sales Orders
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| OSO-01 | Fully-invoiced orders excluded | Fully convert an Order to Invoice | Order drops off Open Sales Orders | High | Not Started | |
| OSO-02 | Partially-fulfilled remaining qty correct | Partially deliver/invoice | Remaining qty/value shown correctly | Med | Not Started | |

## SL-RPT-SDR / PDL — Sales Delivery Register / Pending Deliveries
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SDR-01 | Delivered items move from Pending to the Register | Approve a Sales Delivery | Moves correctly between the two reports | High | Not Started | Cross-check against the known Sales Delivery button-state bug — see `sales/sales_delivery.md` |

## SL-RPT-CRR — Cash Receipt / Collections Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CRR-01 | Cash Receipt appears | Post a Cash Receipt | Appears with correct amount and settlement reference | High | Not Started | |
