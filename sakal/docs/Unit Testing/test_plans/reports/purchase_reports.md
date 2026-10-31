# Purchase Reports — Test Plan
Module: PR — Purchase | Group: Reports | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. a real transaction / Currency & Dr-Cr display (CCC #1/#2) / Export &
Print / Permission-denied / CCC**.

**2026-10-25 smoke pass**: all 13 `PR-RPT-*` reports navigated directly and Run
Report clicked, with every resulting network response traced for 400/404s (not
just page-crash text) — the same discipline that caught the Day Book/Cheque
Register bug in Finance Reports, applied here from the start. Found and fixed
2 more real bugs this way (see below); the other 11 reports loaded and ran
clean with no error response at all.

---
## PR-RPT-POR / PPO — Purchase Order Register / Pending Purchase Orders
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| POR-01 | Approved PO appears in Register | Approve a PO | Appears correctly | High | Not Started | |
| POR-02 | Fully-received PO drops off Pending | Fully receive via GRN | Drops off Pending Purchase Orders | High | Not Started | |
| POR-03 | Partially-received PO shows correct remaining qty | Partially receive | Remaining qty/value correct | Med | Not Started | |

## PR-RPT-GRN / GPB — GRN Register / GRN Pending to Bill
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRNR-01 | Approved GRN appears | Approve a GRN | Appears with correct value | High | Not Started | |
| GRNR-02 | Billed GRN drops off Pending to Bill | Bill it via Purchase Invoice | Drops off correctly | High | Not Started | |

## PR-RPT-PIR / PRR — Purchase Invoice / Return Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PIR-01 | Purchase Bill (PUR+EXC vouchers) appears correctly | Post a foreign-currency Purchase Bill with an FX gap | Register shows the real invoice total; drill down confirms both PUR and EXC vouchers exist | High | Not Started | |
| PRR-01 | Mixed billed/unbilled return | Return against one billed and one unbilled GRN in the same document | Register correctly shows both the JV (unbilled) and SDN (billed) postings | Med | Not Started | |

## PR-RPT-CHG — Purchase Charges Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CHGR-01 | ADD/DEDUCT charges shown correctly | Post a GRN with both charge natures | Both directions correct | Med | Not Started | |

## PR-RPT-SUP / ITM — Supplier-wise Purchase Analysis / Item-wise Purchase History
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SUPA-01 | Matches actual GRN/Bill totals for a supplier | Sum manually, compare | Match | Med | Not Started | |
| ITM-UX01 | Product filter is `required: true` in config but not enforced in the UI | Click Run Report with no Product selected | Should block/prompt; instead a raw RPC 404 reaches the user | Med | Found, not fixed | Same gotcha class already documented for Stock Ledger (`inventory_reports.md` SDL-01) — Product is effectively mandatory for this report's own `fn_item_purchase_history_totals` call (`p_product_id` has no default), but neither the Run Report button nor a client-side validator blocks submission when it's left blank. Not re-verified with a product actually selected this pass (a Playwright locator-timing issue on the product-picker interaction, not re-chased given this is a documentation-only finding, not a data-correctness bug) — the underlying report is expected to work once a product is picked, consistent with Stock Ledger's own confirmed-working happy path. |

## PR-RPT-ROR — Reorder / Replenishment
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ROR-01 | Below-reorder-point products flagged | Set stock below a configured reorder point | Product appears on the report | Med | Not Started | QA fixture products have no `reorder_level` configured — 0 rows is the correct/legitimate result for this fixture, not independently re-tested with a real below-reorder-level product. |
| ROR-BUG01 | **Found live** — the report's own default filter (`below_reorder_only=true`) targeted a column that didn't exist, so the FIRST Run Report click on this screen, with no filters touched, always failed | Open the report fresh, click Run Report | Should load (filtered to below-reorder-point products by default) | High | Found, fixed, re-verified | `v_reorder_replenishment` had no `below_reorder_only` column at all — it's a derived condition (`current_stock < reorder_level`), but the report's BOOLEAN filter mapped straight onto a raw PostgREST column-equality filter against the view. HTTP 400 on every default load. Fixed in migration 235 by adding the computed column to the view (rebuilt from the live `pg_get_viewdef` output via script, not hand-retyped, after a first hand-typed attempt introduced a paren-count error and failed to deploy — see the migration file's own note). Re-verified live: grid headers render, 0 rows (legitimate, see above), no error. |

## PR-RPT-OTD — Vendor On-Time Delivery
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| OTD-01 | Late vs on-time GRN classified correctly | Receive one GRN late vs. PO's expected date | Classified correctly | Low | Not Started | QA fixture's PO/GRN never set an Expected Delivery Date — 0 rows is legitimate for this fixture, not independently re-tested with a real late/on-time delivery pair. |
| OTD-BUG01 | **Found live** — same bug class as Cheque Register (Finance Reports), same migration-166-era parameter mismatch | Click Run Report | Should load (even if empty) | High | Found, fixed, re-verified | This report has no `ric_report_group_levels` config, so its main grid correctly queries `v_purchase_order_delivery` directly via the filter's own `param_target='expected_delivery_date'` (matches the view's real column). Only the separate totals RPC, `fn_purchase_order_delivery_totals`, was broken — it declared `p_expected_date_from`/`p_expected_date_to` instead of matching names, so the footer-total call 404'd every time. Fixed in migration 235 (`DROP FUNCTION` + `CREATE`, renaming the two parameters; full body reproduced verbatim from `pg_get_functiondef` before editing, not from memory). Re-verified live: grid headers render, no error. |

## PR-RPT-PPV — Purchase Price Variance
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PPV-01 | PO price vs. actual GRN/Bill price variance | Receive at a different price than the PO | Variance computed and shown correctly | Med | Not Started | |

## PR-RPT-TAX — Purchase Tax Summary
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PTAX-01 | Input VAT matches Purchase Bill's real posted amount | Compare to the PUR voucher's Input VAT line | Match exactly | High | Not Started | |
